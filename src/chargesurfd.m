// chargesurfd: battery charge "surfing" (hysteresis) and heat protection for macOS 27.
//
// On macOS 27 (release builds) the SMC charge-control keys (CH0B/CH0C/CHTE and the
// firmware-limit keys bfF0/bfD0/bfE0) are gated behind a private entitlement and return
// kIOReturnNotPrivileged even to root. The remaining path is macOS's own charge limit:
// a root process can write an exact target (10-99%) into PowerUIAgent's preference domain
// and ask it to reload. The mechanism follows charlie0129/batt (pkg/powerui, GPL-2.0).
//
// Modes:
//   CHARGE : limit = upper. Switches to SAIL once the battery reaches upper.
//   SAIL   : limit follows the current percentage and only ever goes down, so the Mac
//            neither charges nor drains while plugged in. This also holds above upper
//            (for example after a top-up): ChargeSurf never asks macOS to drain the
//            battery down to upper; it sails from wherever it is. At 100% the macOS limit is
//            released (macOS limits stop at 99%), so a topped-up battery is held, not drained.
//            Switches to CHARGE once the
//            battery drops below lower.
//   TOP UP : charges to 100% with no limit, then turns itself off and sails from 100%.
//   HEAT   : when the battery temperature reaches heat_stop, the limit is pinned to the
//            current percentage until it cools down to heat_resume.
//
// Usage (root): chargesurfd run | status | reset

#import <Foundation/Foundation.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#include <dlfcn.h>
#include <math.h>
#include <notify.h>
#include <objc/message.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "smc.h"

#define CONFIG_PATH "/Library/Application Support/ChargeSurf/config"
#define STATUS_PATH "/Library/Application Support/ChargeSurf/status"
#define LOG_PATH    "/Library/Logs/ChargeSurf.log"
#define CONFIG_NOTIFICATION "io.github.mirakoz.chargesurf.config"
static CFStringRef const kDomain = CFSTR("com.apple.smartcharging.topoffprotection");

typedef struct {
    int lower, upper;
    int heat_enabled;
    double heat_stop, heat_resume;
    int interval, full_charge, disabled;
} Config;
enum { MODE_CHARGE, MODE_SAIL };

static volatile sig_atomic_t stop_requested = 0;
static void on_signal(int s) { (void)s; stop_requested = 1; }

static void log_msg(const char *fmt, ...) {
    FILE *f = fopen(LOG_PATH, "a"); if (!f) f = stderr;
    char t[32]; time_t now = time(NULL);
    strftime(t, sizeof t, "%Y-%m-%d %H:%M:%S", localtime(&now));
    fprintf(f, "%s  ", t);
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f); if (f != stderr) fclose(f);
}

// ---- Config -------------------------------------------------------------------

static Config config_read(void) {
    Config c = { 60, 80, 1, 35.0, 32.0, 30, 0, 0 };
    FILE *f = fopen(CONFIG_PATH, "r");
    if (f) {
        char line[128];
        while (fgets(line, sizeof line, f)) {
            char k[32]; double v;
            if (line[0] == '#' || sscanf(line, " %31[^= ] = %lf", k, &v) != 2) continue;
            if (!strcmp(k, "lower")) c.lower = (int)v;
            else if (!strcmp(k, "upper")) c.upper = (int)v;
            else if (!strcmp(k, "heat_protection")) c.heat_enabled = v != 0;
            else if (!strcmp(k, "heat_stop")) c.heat_stop = v;
            else if (!strcmp(k, "heat_resume")) c.heat_resume = v;
            else if (!strcmp(k, "interval")) c.interval = (int)v;
            else if (!strcmp(k, "full_charge")) c.full_charge = v != 0;
            else if (!strcmp(k, "disabled")) c.disabled = v != 0;
        }
        fclose(f);
    }
    // Clamp nonsense to safe values.
    if (c.upper > 99) c.upper = 99;
    if (c.upper < 20) c.upper = 80;
    if (c.lower < 10 || c.lower >= c.upper) c.lower = c.upper - 20 < 10 ? 10 : c.upper - 20;
    if (c.heat_stop < 25 || c.heat_stop > 50) c.heat_stop = 35;
    if (c.heat_resume >= c.heat_stop) c.heat_resume = c.heat_stop - 3;
    if (c.interval < 10) c.interval = 10;
    return c;
}

// Same canonical format the menu bar app writes. Written in place to keep owner/mode.
static void config_write(const Config *c) {
    FILE *f = fopen(CONFIG_PATH, "w"); if (!f) return;
    fprintf(f, "# ChargeSurf settings (the menu bar app writes this file too)\n"
               "lower=%d\nupper=%d\nheat_protection=%d\nheat_stop=%.0f\nheat_resume=%.0f\n"
               "interval=%d\nfull_charge=%d\ndisabled=%d\n",
            c->lower, c->upper, c->heat_enabled, c->heat_stop, c->heat_resume,
            c->interval, c->full_charge, c->disabled);
    fclose(f);
}

// ---- Sensors ------------------------------------------------------------------

static int battery_read(int *percent, int *on_adapter, int *charging) {
    int ok = -1;
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info) return -1;
    CFArrayRef list = IOPSCopyPowerSourcesList(info);
    for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
        CFDictionaryRef d = IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, i));
        if (!d) continue;
        CFStringRef type = CFDictionaryGetValue(d, CFSTR(kIOPSTypeKey));
        if (!type || CFStringCompare(type, CFSTR(kIOPSInternalBatteryType), 0) != 0) continue;
        CFNumberRef cur = CFDictionaryGetValue(d, CFSTR(kIOPSCurrentCapacityKey));
        CFNumberRef max = CFDictionaryGetValue(d, CFSTR(kIOPSMaxCapacityKey));
        CFStringRef st = CFDictionaryGetValue(d, CFSTR(kIOPSPowerSourceStateKey));
        CFBooleanRef ch = CFDictionaryGetValue(d, CFSTR(kIOPSIsChargingKey));
        if (charging) *charging = ch && CFBooleanGetValue(ch);
        int c = 0, m = 100;
        if (cur) CFNumberGetValue(cur, kCFNumberIntType, &c);
        if (max) CFNumberGetValue(max, kCFNumberIntType, &m);
        *percent = m > 0 ? (int)lround(100.0 * c / m) : c;
        *on_adapter = st && CFStringCompare(st, CFSTR(kIOPSACPowerValue), 0) == 0;
        ok = 0;
    }
    if (list) CFRelease(list);
    CFRelease(info);
    return ok;
}

// Hottest battery sensor in °C: TB0T..TB2T (float), fallback B0AT (0.1 K).
static double battery_temp(void) {
    double hottest = NAN;
    const char *keys[] = { "TB0T", "TB1T", "TB2T" };
    for (int i = 0; i < 3; i++) {
        SMCVal v; float f;
        if (smc_read(keys[i], &v) || v.size != 4 || strcmp(v.type, "flt ")) continue;
        memcpy(&f, v.bytes, 4);
        if (f > 0 && f < 100 && (isnan(hottest) || f > hottest)) hottest = f;
    }
    if (isnan(hottest)) {
        SMCVal v;
        if (!smc_read("B0AT", &v) && v.size == 2)
            hottest = (((v.bytes[0] << 8) | v.bytes[1]) / 10.0) - 273.15;
    }
    return hottest;
}

// ---- macOS native charge limit (PowerUIAgent) -----------------------------------

static id gClient = nil;

static BOOL responds(id o, const char *sel) { return o && [o respondsToSelector:sel_registerName(sel)]; }

static int macos_supported(void) {
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27;
}

static id powerui_client(void) {
    if (gClient) return gClient;
    if (!dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI", RTLD_NOW)) return nil;
    Class cls = NSClassFromString(@"PowerUISmartChargeClient");
    if (!cls) return nil;
    id o = ((id (*)(id, SEL, id))objc_msgSend)([cls alloc], sel_registerName("initWithClientName:"), @"chargesurf");
    const char *required[] = { "getMCLLimitWithError:", "isMCLCurrentlyEnabled:", "enableMCL:", "disableMCL:" };
    for (int i = 0; i < 4; i++) if (!responds(o, required[i])) { [o release]; return nil; }
    gClient = o;
    return gClient;
}

static int agent_state(int *limit, int *enabled) {
    id c = powerui_client(); if (!c) return -1;
    NSError *e = nil;
    unsigned char v = ((unsigned char (*)(id, SEL, NSError **))objc_msgSend)(c, sel_registerName("getMCLLimitWithError:"), &e);
    if (e) return -2;
    unsigned long long on = ((unsigned long long (*)(id, SEL, NSError **))objc_msgSend)(c, sel_registerName("isMCLCurrentlyEnabled:"), &e);
    if (e) return -3;
    *limit = v; *enabled = on != 0;
    return 0;
}

static int agent_call(const char *sel) {
    id c = powerui_client(); if (!c) return -1;
    NSError *e = nil;
    BOOL ok = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(c, sel_registerName(sel), &e);
    if (!ok || e) { log_msg("ERROR: %s: %s", sel, e ? [[e description] UTF8String] : "failed"); return -2; }
    return 0;
}

// Root's preference domain, which the root PowerUIAgent reads.
static int pref_read(int *limit, int *enabled) {
    if (!CFPreferencesSynchronize(kDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)) return -1;
    CFPropertyListRef f = CFPreferencesCopyValue(CFSTR("MCLFeatureState"), kDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPropertyListRef t = CFPreferencesCopyValue(CFSTR("mclLimitValue"), kDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    int fv = 0, tv = 0;
    if (f && CFGetTypeID(f) == CFNumberGetTypeID()) CFNumberGetValue(f, kCFNumberIntType, &fv);
    if (t && CFGetTypeID(t) == CFNumberGetTypeID()) CFNumberGetValue(t, kCFNumberIntType, &tv);
    if (f) CFRelease(f);
    if (t) CFRelease(t);
    *enabled = fv == 1; *limit = *enabled ? tv : 100;
    return 0;
}

static int pref_write(int limit) {
    int one = 1;
    CFNumberRef f = CFNumberCreate(NULL, kCFNumberIntType, &one);
    CFNumberRef t = CFNumberCreate(NULL, kCFNumberIntType, &limit);
    CFPreferencesSetValue(CFSTR("MCLFeatureState"), f, kDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSetValue(CFSTR("mclLimitValue"), t, kDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFRelease(f); CFRelease(t);
    if (!CFPreferencesSynchronize(kDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)) return -1;
    return notify_post("com.apple.smartcharging.defaultschanged") == NOTIFY_STATUS_OK ? 0 : -2;
}

// Active manual limit registered with powerd (pmset -g battlimit). 0 = none, -1 = unreadable.
static int registered_limit(void) {
    FILE *p = popen("LC_ALL=C /usr/bin/pmset -g battlimit 2>/dev/null", "r");
    if (!p) return -1;
    char buf[8192] = {0}; size_t n = fread(buf, 1, sizeof buf - 1, p); pclose(p);
    buf[n] = 0;
    int found = 0;
    for (char *r = strchr(buf, '{'); r; r = strchr(r + 1, '{')) {
        char *end = strchr(r, '}'); if (!end) break;
        char row[1024]; size_t len = (size_t)(end - r) < sizeof row - 1 ? (size_t)(end - r) : sizeof row - 1;
        memcpy(row, r, len); row[len] = 0;
        if (!strstr(row, "manualChargeLimit")) continue;
        char *term = strstr(row, "Terminated"), *soc = strstr(row, "chargeSocLimitSoc");
        int tv = 0;
        if (term && sscanf(term, "Terminated = %d", &tv) == 1 && tv == 1) continue;
        int v; if (soc && sscanf(soc, "chargeSocLimitSoc = %d", &v) == 1) found = v;
    }
    return found;
}

// Set the target. 0: registered, 1: accepted but not applied yet, <0: error.
static int set_target(int target) {
    int al, ae;
    if (agent_state(&al, &ae)) return -1;
    if (!ae) {
        // Re-engaging after a previous disable. enableMCL alone makes macOS register its own
        // 80% default for a moment (seen on 26A428: ~1 min of draining when above 80%).
        // Write our target first so the agent finds it when it comes back, then enable.
        if (pref_write(target)) return -3;
        if (agent_call("enableMCL:")) return -2;
        usleep(200000);
    }
    if (pref_write(target)) return -3;
    int pl, pe; pref_read(&pl, &pe);
    if (!pe || pl != target) return -4;
    for (int i = 0; i < 20; i++) {
        if (i) usleep(100000);
        int reg = registered_limit();
        if (reg == target) return 0;
        // A stale default (e.g. 80) got registered: nudge the agent to reload our target.
        if (reg > 0 && (i == 5 || i == 12)) pref_write(target);
    }
    return 1;
}

// Release the macOS limit (back to default charging).
static int release_limit(void) {
    int al, ae;
    if (agent_state(&al, &ae)) return -1;
    if (!ae) {
        int pl, pe; pref_read(&pl, &pe);
        if (!pe && registered_limit() == 0) return 0;
        if (agent_call("enableMCL:")) return -2;   // the agent only disables while enabled
    }
    return agent_call("disableMCL:");
}

// ---- Daemon -------------------------------------------------------------------------

static void status_write(int pct, int ac, double t, const char *mode, int target, int registered, const Config *c) {
    FILE *f = fopen(STATUS_PATH ".tmp", "w"); if (!f) return;
    char z[32]; time_t now = time(NULL);
    strftime(z, sizeof z, "%Y-%m-%d %H:%M:%S", localtime(&now));
    fprintf(f, "time=%s\npercent=%d\nadapter=%d\ntemperature=%.1f\nmode=%s\ntarget_limit=%d\nmacos_limit=%d\n",
            z, pct, ac, t, mode, target, registered);
    fprintf(f, "lower=%d\nupper=%d\nheat_protection=%d\nheat_stop=%.1f\nheat_resume=%.1f\nfull_charge=%d\ndisabled=%d\n",
            c->lower, c->upper, c->heat_enabled, c->heat_stop, c->heat_resume, c->full_charge, c->disabled);
    fclose(f);
    rename(STATUS_PATH ".tmp", STATUS_PATH);
}

static int run_daemon(void) {
    signal(SIGTERM, on_signal); signal(SIGINT, on_signal); signal(SIGHUP, on_signal);
    if (!macos_supported()) { log_msg("ERROR: macOS 27 or later is required"); return 2; }
    if (!powerui_client()) { log_msg("ERROR: PowerUI charge-limit client unavailable on this macOS"); return 2; }

    Config c = config_read();
    int pct = 0, ac = 0, charging = 0; battery_read(&pct, &ac, &charging);
    int mode = MODE_SAIL, sail_target = 0;
    time_t sail_since = time(NULL);
    // macOS applies a new limit with a delay (up to a few minutes while charging). Right after
    // entering SAIL, let the target follow an overshoot upward so nothing gets drained.
    const int SAIL_GRACE = 300;
    // Note: when a limit is re-applied after it was released (disable or top-up turned off
    // while charging), macOS runs from the battery for ~40-60 s whatever the target is
    // (seen on 26A428, ~0.6 A). That transient is macOS behavior and cannot be avoided here.
#define CEIL_OF(p) ((p) > 100 ? 100 : (p))
#define RESET_SURF() do { mode = pct < c.lower ? MODE_CHARGE : MODE_SAIL; \
                          sail_target = CEIL_OF(pct); sail_since = time(NULL); \
                          if (sail_target < c.lower) sail_target = c.lower; } while (0)
    RESET_SURF();
    int hot = 0, heat_target = 0, last_written = -1, interference = 0;
    int prev_full = c.full_charge, prev_disabled = c.disabled;
    time_t last_summary = 0, window = time(NULL);
    int token = 0; notify_register_check(CONFIG_NOTIFICATION, &token);
    log_msg("started: percent=%d adapter=%d mode=%s%s%s", pct, ac, mode == MODE_CHARGE ? "charging" : "sailing",
            c.full_charge ? " +full_charge" : "", c.disabled ? " +disabled" : "");

    while (!stop_requested) @autoreleasepool {
        c = config_read();
        if (battery_read(&pct, &ac, &charging)) { sleep(c.interval); continue; }
        double t = battery_temp();

        // Top-up turns itself off once the battery reaches 100%.
        if (c.full_charge && pct >= 100) {
            c.full_charge = 0; config_write(&c);
            log_msg("top-up complete at %d%%", pct);
        }
        if (c.full_charge != prev_full) {
            if (c.full_charge) log_msg("full charge requested: releasing limit");
            else { log_msg("top-up off, sailing from %d%%", pct); RESET_SURF(); }
        }
        if (c.disabled != prev_disabled) {
            if (c.disabled) log_msg("disabled: handing charging back to macOS defaults");
            else { log_msg("enabled again"); RESET_SURF(); }
        }
        prev_full = c.full_charge; prev_disabled = c.disabled;

        // Surfing state machine
        if (pct < c.lower && mode != MODE_CHARGE) { mode = MODE_CHARGE; log_msg("percent %d < %d: CHARGE up to %d%%", pct, c.lower, c.upper); }
        else if (mode == MODE_CHARGE && pct >= c.upper) {
            mode = MODE_SAIL; sail_target = pct > 100 ? 100 : pct; sail_since = time(NULL);   // macOS stopped at the limit itself
            log_msg("percent %d: SAIL", pct);
        }
        if (mode == MODE_SAIL) {
            if (pct > sail_target && charging && time(NULL) - sail_since < SAIL_GRACE) {
                sail_target = CEIL_OF(pct);   // macOS applied the limit late: follow, don't drain
                log_msg("sail target raised to %d%% (macOS applied the limit late)", sail_target);
            }
            if (sail_target > CEIL_OF(pct)) sail_target = CEIL_OF(pct);   // follow the battery down
            if (sail_target > 100) sail_target = 100;   // 100 = release the limit (macOS limits stop at 99)
            if (sail_target < c.lower) sail_target = c.lower;
        }
        int target = mode == MODE_CHARGE ? c.upper : sail_target;
        if (c.full_charge) target = 100;

        // Heat protection (also applies during full charge)
        if (!c.heat_enabled || c.disabled) {
            if (hot) { hot = 0; log_msg("heat protection turned off"); }
        } else if (!isnan(t)) {
            if (!hot && t >= c.heat_stop && pct > 10) {
                hot = 1; heat_target = pct;
                log_msg("HEAT PROTECTION: %.1f C >= %.1f C, charging paused at %d%%", t, c.heat_stop, pct);
            } else if (hot && (t <= c.heat_resume || pct <= 10)) {
                hot = 0; log_msg("temperature back to normal (%.1f C)", t);
            }
        }
        if (hot) {
            if (pct < heat_target) heat_target = pct;
            int h = heat_target > 99 ? 99 : heat_target;   // a released limit would let macOS top up
            if (h < target) target = h;
        }
        if (c.disabled) target = 100;
        if (target < 10) target = 10;

        // Apply / repair. 100 = macOS limit released.
        int pl = 0, pe = 0, al = 0, ae = 0;
        int readable = pref_read(&pl, &pe) == 0 && agent_state(&al, &ae) == 0;
        int registered = registered_limit();
        if (readable && target >= 100) {
            if (pe || ae || registered > 0) {
                if (last_written == 100) { interference++; log_msg("WARNING: limit was re-enabled from outside"); }
                int r = release_limit();
                if (r) log_msg("ERROR: could not release macOS limit (code %d)", r);
                else log_msg("macOS limit released (%s)", c.disabled ? "disabled" : c.full_charge ? "top-up" : "sailing at 100%");
                last_written = 100;
                registered = registered_limit();
            }
        } else if (readable && !(pe && ae && pl == target)) {
            if (last_written == target) {
                interference++;
                log_msg("WARNING: limit changed from outside (pref=%d enabled=%d agent=%d). System Settings > Battery or another tool?", pl, pe, ae);
            }
            int r = set_target(target);
            if (r < 0) log_msg("ERROR: could not set target %d%% (code %d)", target, r);
            else log_msg("limit %d%%%s (percent=%d, %.1f C, %s)", target, r == 1 ? " accepted, macOS will apply it shortly" : " applied",
                         pct, t, hot ? "heat" : mode == MODE_CHARGE ? "charging" : "sailing");
            last_written = target;
            registered = registered_limit();
        }
        if (time(NULL) - window > 600) { window = time(NULL); interference = 0; }
        else if (interference > 3) { log_msg("WARNING: limit keeps being overridden, backing off for 10 minutes"); sleep(600); interference = 0; window = time(NULL); }

        const char *mode_name = c.disabled ? "disabled" : hot ? "heat_protection" : c.full_charge ? "full_charge"
                              : mode == MODE_CHARGE ? "charging" : "sailing";
        status_write(pct, ac, t, mode_name, target, registered, &c);
        if (time(NULL) - last_summary >= 1800) {
            log_msg("summary: percent=%d adapter=%d %.1f C mode=%s target=%d macos=%d", pct, ac, t, mode_name, target, registered);
            last_summary = time(NULL);
        }
        // The app posts a notification after changing settings; wake up right away.
        for (int i = 0; i < c.interval && !stop_requested; i++) {
            sleep(1);
            int changed = 0;
            if (token && notify_check(token, &changed) == NOTIFY_STATUS_OK && changed) break;
        }
    }
    // Do not leave a low heat-protection limit behind.
    if (hot) { Config d = config_read(); if (!d.full_charge && !d.disabled) set_target(mode == MODE_CHARGE ? d.upper : sail_target); }
    log_msg("stopped (macOS limit left in place)");
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *cmd = argc > 1 ? argv[1] : "status";
        smc_open();
        if (strcmp(cmd, "run") && strcmp(cmd, "status") && strcmp(cmd, "reset")) {
            fprintf(stderr, "usage: %s run | status | reset\n", argv[0]); return 64;
        }
        if (geteuid() != 0 && strcmp(cmd, "status")) { fprintf(stderr, "root required: sudo %s %s\n", argv[0], cmd); return 1; }
        if (!strcmp(cmd, "run")) return run_daemon();
        if (!strcmp(cmd, "reset")) {
            int r = release_limit();
            printf(r ? "ERROR: could not release macOS charge limit (code %d)\n" : "macOS charge limit released\n", r);
            return r ? 1 : 0;
        }
        // status
        Config c = config_read(); int pct = -1, ac = 0; battery_read(&pct, &ac, NULL);
        printf("battery    : %d%% (%s)\ntemperature: %.1f C\n", pct, ac ? "adapter" : "battery", battery_temp());
        NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
        printf("macOS      : %ld.%ld%s\n", (long)v.majorVersion, (long)v.minorVersion, macos_supported() ? "" : "  (UNSUPPORTED: macOS 27+ required)");
        if (!powerui_client()) { printf("PowerUI    : UNAVAILABLE, this macOS is not supported\n"); return 2; }
        int al, ae, pl, pe;
        int r1 = agent_state(&al, &ae), r2 = geteuid() == 0 ? pref_read(&pl, &pe) : -9, reg = registered_limit();
        if (r1) printf("PowerUI    : unreadable (code %d)\n", r1); else printf("PowerUI    : %s, limit %d%%\n", ae ? "on" : "off", al);
        if (r2) printf("preference : %s\n", r2 == -9 ? "needs root" : "unreadable"); else printf("preference : %s, %d%%\n", pe ? "on" : "off", pl);
        if (reg > 0) printf("registered : %d%%\n", reg); else printf("registered : %s\n", reg == 0 ? "no limit" : "unreadable");
        printf("config     : surf %d-%d%%, heat protection %s (stop %.0f C, resume %.0f C)%s%s\n",
               c.lower, c.upper, c.heat_enabled ? "on" : "off", c.heat_stop, c.heat_resume,
               c.full_charge ? ", FULL CHARGE" : "", c.disabled ? ", DISABLED" : "");
        return (r1 || !macos_supported()) ? 2 : 0;
    }
}
