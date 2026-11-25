// ChargeSurf menu bar app.
// The root daemon (chargesurfd) does the actual work. This app writes the config file,
// wakes the daemon with a Darwin notification, and shows the daemon's status file.
// Protection keeps running while the app is closed.
//
// Localization: English is the base language; translations live in
// resources/<lang>.lproj/Localizable.strings (keys are the English strings).

import AppKit
import Darwin
import IOKit
import IOKit.ps
import SwiftUI

let configPath = "/Library/Application Support/ChargeSurf/config"
let statusPath = "/Library/Application Support/ChargeSurf/status"
let logPath = "/Library/Logs/ChargeSurf.log"
let configNotification = "io.github.mirakoz.chargesurf.config"

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
func L(_ key: String, _ args: CVarArg...) -> String { String(format: NSLocalizedString(key, comment: ""), arguments: args) }
let isTurkish = Bundle.main.preferredLocalizations.first == "tr"
func pct(_ n: Int) -> String { isTurkish ? "%\(n)" : "\(n)%" }

/// "≈ 1 h 5 min" / "≈ 25 min" (localized).
func duration(_ minutes: Int) -> String {
    let m = max(minutes, 1)
    return m >= 60 ? L("%d h %d min", m / 60, m % 60) : L("%d min", m)
}
/// Compact form for the menu bar: "3:05".
func compactDuration(_ minutes: Int) -> String { String(format: "%d:%02d", max(minutes, 0) / 60, max(minutes, 0) % 60) }

// MARK: - Settings file (shared with the daemon)

struct Settings: Equatable {
    var lower = 60, upper = 80
    var heatEnabled = true
    var heatStop = 35
    var interval = 30
    var fullCharge = false, disabled = false
    var heatResume: Int { heatStop - 3 }

    init() {}
    init(_ d: [String: String]) {
        func i(_ k: String, _ v: Int) -> Int { d[k].flatMap { Double($0) }.map { Int($0) } ?? v }
        lower = i("lower", 60); upper = i("upper", 80)
        heatEnabled = i("heat_protection", 1) != 0
        heatStop = i("heat_stop", 35)
        interval = i("interval", 30)
        fullCharge = i("full_charge", 0) != 0
        disabled = i("disabled", 0) != 0
    }

    var fileText: String {
        """
        # ChargeSurf settings (the menu bar app writes this file too)
        lower=\(lower)
        upper=\(upper)
        heat_protection=\(heatEnabled ? 1 : 0)
        heat_stop=\(heatStop)
        heat_resume=\(heatResume)
        interval=\(interval)
        full_charge=\(fullCharge ? 1 : 0)
        disabled=\(disabled ? 1 : 0)

        """
    }
}

func readKeyValues(_ path: String) -> [String: String] {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var d: [String: String] = [:]
    for line in s.split(separator: "\n") where !line.hasPrefix("#") {
        let p = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if p.count == 2 { d[p[0]] = p[1] }
    }
    return d
}

// MARK: - Menu bar display preferences (per user, app only)

enum Pref {
    static let icon = "menubar.icon"
    static let percent = "menubar.percent"
    static let timeOnBattery = "menubar.timeOnBattery"
    static let timeCharging = "menubar.timeCharging"
    static let onboardingDone = "onboarding.done"
    static let chargeRate = "battery.chargeRateMA"
}

// MARK: - Model

enum PowerState { case charging, idle, draining, battery }

@MainActor
final class Model: ObservableObject {
    @Published var settings = Settings()
    @Published var status: [String: String] = [:]
    @Published var percent = 0
    @Published var power = PowerState.idle
    @Published var amps = 0                 // mA, positive = charging
    @Published var capacity = 0             // full-charge capacity, mAh
    @Published var timeToEmpty: Int?        // minutes, on battery
    @Published var timeToFull: Int?         // minutes to 100%, from macOS, while charging
    @Published var adapterRate: Double?     // estimated charge current from adapter power, mA
    @Published var error: String?
    var editing = false
    private var lastSave = Date.distantPast
    private var timer: Timer?

    init(live: Bool = true) {
        refresh()
        guard live else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        status = readKeyValues(statusPath)
        readBattery()
        if !editing && Date().timeIntervalSince(lastSave) > 4 {
            let d = readKeyValues(configPath)
            if !d.isEmpty { settings = Settings(d) }
        }
    }

    private static func smartBattery(_ key: String) -> Any? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard s != 0 else { return nil }
        defer { IOObjectRelease(s) }
        return IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private func readBattery() {
        if let v = Model.smartBattery("InstantAmperage") as? NSNumber { amps = v.intValue }
        if let d = Model.smartBattery("BatteryData") as? [String: Any], let fcc = d["FullChargeCapacity"] as? Int, fcc > 0 {
            capacity = fcc
        }
        // Fallback charge-current estimate when no charge has been observed yet:
        // (adapter watts x ~85% efficiency - current system load) / battery voltage.
        adapterRate = nil
        if let ad = Model.smartBattery("AdapterDetails") as? [String: Any], let watts = ad["Watts"] as? Int, watts > 0,
           let mv = (Model.smartBattery("Voltage") as? NSNumber)?.doubleValue, mv > 0 {
            let loadMW = ((Model.smartBattery("PowerTelemetryData") as? [String: Any])?["SystemLoad"] as? Int).map(Double.init) ?? 10_000
            let ma = (Double(watts) * 1000 * 0.85 - loadMW) / mv * 1000
            let cap = capacity > 0 ? 0.7 * Double(capacity) : 4000
            if ma > 300 { adapterRate = min(ma, cap) }
        }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            percent = max > 0 ? Int((Double(cur) * 100 / Double(max)).rounded()) : cur
            let onAdapter = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            power = charging ? .charging : !onAdapter ? .battery : amps < -150 ? .draining : .idle
            let tte = d[kIOPSTimeToEmptyKey] as? Int ?? -1
            timeToEmpty = !onAdapter && tte > 0 ? tte : nil
            let ttf = d[kIOPSTimeToFullChargeKey] as? Int ?? -1
            timeToFull = charging && ttf > 0 ? ttf : nil
        }
        // Remember a smoothed charging current, so estimates also work while not charging.
        if power == .charging && amps > 300 && percent < 80 {
            let old = UserDefaults.standard.double(forKey: Pref.chargeRate)
            UserDefaults.standard.set(old > 0 ? old * 0.8 + Double(amps) * 0.2 : Double(amps), forKey: Pref.chargeRate)
        }
    }

    /// Minutes to charge from the current percentage to `target`, or nil if unknown.
    /// Linear up to 80%; the constant-voltage phase above 80% is slower (factor 1.6).
    func minutesToCharge(to target: Int) -> Int? {
        guard target > percent, capacity > 0 else { return nil }
        if target >= 100, let t = timeToFull { return t }
        let remembered = UserDefaults.standard.double(forKey: Pref.chargeRate)
        let rate = power == .charging && amps > 300 && percent < 80 ? Double(amps)
                 : remembered > 300 ? remembered : (adapterRate ?? 0)
        guard rate > 300 else { return nil }
        let knee = 80
        let fast = Double(max(0, min(target, knee) - percent))
        let slow = Double(max(0, target - max(percent, knee)))
        let mAh = (fast + slow * 1.6) / 100 * Double(capacity)
        return Int((mAh / rate * 60).rounded())
    }

    /// The level the Mac is charging toward right now, if any.
    var chargeTarget: Int? {
        guard power == .charging else { return nil }
        switch mode {
        case "full_charge", "disabled": return 100
        case "charging": return settings.upper
        default: return Int(status["target_limit"] ?? "").flatMap { $0 > percent ? $0 : nil }
        }
    }

    func save() {
        var s = settings
        s.upper = min(max(s.upper, 20), 99)
        s.lower = min(max(s.lower, 10), s.upper - 5)
        s.heatStop = min(max(s.heatStop, 28), 45)
        settings = s
        // The directory is root-owned; the file is admin-group writable. Write in place.
        guard let fh = FileHandle(forUpdatingAtPath: configPath) else {
            error = L("Cannot write settings. Re-run the installer: sudo ./install.sh")
            return
        }
        fh.truncateFile(atOffset: 0)
        fh.write(Data(s.fileText.utf8))
        try? fh.close()
        error = nil
        lastSave = Date()
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(configNotification as CFString), nil, nil, true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
    }

    var mode: String { status["mode"] ?? "?" }
    var macosLimit: Int { Int(status["macos_limit"] ?? "") ?? -1 }
    var temperature: Double? { Double(status["temperature"] ?? "") }

    var daemonAlive: Bool {
        guard let z = status["time"] else { return false }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let t = f.date(from: z) else { return false }
        return Date().timeIntervalSince(t) < Double(max(settings.interval, 30) * 3)
    }

    var icon: String {
        if !daemonAlive { return "exclamationmark.triangle" }
        switch mode {
        case "sailing": return "sailboat.fill"
        case "charging": return "bolt.fill"
        case "heat_protection": return "thermometer.high"
        case "full_charge": return "battery.100percent.bolt"
        case "disabled": return "pause.circle"
        default: return "battery.75percent"
        }
    }

    var modeName: String {
        switch mode {
        case "sailing": return L("Sailing")
        case "charging": return L("Charging")
        case "heat_protection": return L("Heat protection")
        case "full_charge": return L("Full charge")
        case "disabled": return L("Disabled")
        default: return L("Unknown")
        }
    }

    var modeDetail: String {
        switch mode {
        case "sailing": return L("Won't charge until below %@", pct(settings.lower))
        case "charging": return L("Charging up to %@", pct(settings.upper))
        case "heat_protection": return L("Battery is hot, charging paused")
        case "full_charge": return L("Charging to 100%, then back to surfing")
        case "disabled": return L("macOS default charging")
        default: return ""
        }
    }

    var powerText: String {
        switch power {
        case .charging: return L("Battery charging")
        case .idle: return L("Running on adapter")
        case .draining: return L("Plugged in, draining to limit")
        case .battery: return L("Running on battery")
        }
    }

    /// Second header line: time left on battery, or time to the current charge target.
    var timeText: String? {
        if let t = timeToEmpty { return L("%@ left", duration(t)) }
        if let target = chargeTarget, let m = minutesToCharge(to: target) { return L("≈ %@ to %@", duration(m), pct(target)) }
        return nil
    }
}

// MARK: - Views

struct RangeBar: View {
    let lower: Int, upper: Int, percent: Int, color: Color

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let x = w * CGFloat(min(max(percent, 0), 100)) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08)).frame(height: 8)
                Capsule().fill(color.opacity(0.35))
                    .frame(width: w * CGFloat(upper - lower) / 100, height: 8)
                    .offset(x: w * CGFloat(lower) / 100)
                Circle().fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(Circle().strokeBorder(color, lineWidth: 3))
                    .frame(width: 14, height: 14)
                    .offset(x: min(max(x - 7, 0), w - 14))
            }
            .frame(height: 14)
        }
        .frame(height: 14)
    }
}

struct Row<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            trailing
        }
        .font(.callout)
    }
}

struct MainPage: View {
    @EnvironmentObject var m: Model
    var openSettings: () -> Void

    var accent: Color {
        switch m.mode {
        case "heat_protection": return .orange
        case "disabled": return .gray
        case "full_charge", "charging": return .green
        default: return .accentColor
        }
    }

    func slider(_ value: Binding<Int>, _ range: ClosedRange<Int>, clamp: @escaping (Int) -> Int = { $0 }) -> some View {
        Slider(
            value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = clamp(Int($0.rounded())) }),
            in: Double(range.lowerBound)...Double(range.upperBound)
        ) { isEditing in
            m.editing = isEditing
            if !isEditing { m.save() }
        }
        .controlSize(.small)
        .tint(accent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(alignment: .center) {
                Text(pct(m.percent))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.powerText).font(.callout.weight(.medium))
                    if let tt = m.timeText {
                        Label(tt, systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                    }
                    if let t = m.temperature {
                        Label(String(format: "%.1f °C", t), systemImage: "thermometer.medium")
                            .font(.caption).foregroundStyle(t >= Double(m.settings.heatStop) ? .orange : .secondary)
                    }
                }
                Spacer()
            }

            // Mode card
            HStack(spacing: 10) {
                Image(systemName: m.icon)
                    .font(.title3).foregroundStyle(accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.modeName).font(.callout.weight(.semibold))
                    Text(m.modeDetail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

            if !m.daemonAlive {
                Label(L("Background service is not responding. Protection may be off."), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            if let e = m.error {
                Label(e, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
            }

            // Surfing range
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("Surfing range")).font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(pct(m.settings.lower)) – \(pct(m.settings.upper))")
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                RangeBar(lower: m.settings.lower, upper: m.settings.upper, percent: m.percent, color: accent)
                Row(title: L("Lower limit")) { Text(pct(m.settings.lower)).monospacedDigit() }
                slider($m.settings.lower, 0...100) { min(max($0, 10), m.settings.upper - 5) }
                Row(title: L("Upper limit")) { Text(pct(m.settings.upper)).monospacedDigit() }
                slider($m.settings.upper, 0...100) { min(max($0, m.settings.lower + 5, 20), 99) }
                if let mins = m.minutesToCharge(to: m.settings.upper) {
                    Text(L("From %@ to %@: ≈ %@", pct(m.percent), pct(m.settings.upper), duration(mins)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(m.settings.disabled)

            Divider()

            // Heat protection
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(get: { m.settings.heatEnabled }, set: { m.settings.heatEnabled = $0; m.save() })) {
                    Text(L("Heat protection")).font(.callout.weight(.semibold))
                }
                .toggleStyle(.switch).controlSize(.small)
                if m.settings.heatEnabled {
                    Row(title: L("Stop charging at")) { Text("\(m.settings.heatStop) °C").monospacedDigit() }
                    slider($m.settings.heatStop, 28...45)
                    Text(L("Resumes at %d °C", m.settings.heatResume))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(m.settings.disabled)

            Divider()

            // Actions
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button {
                        m.settings.fullCharge.toggle(); m.save()
                    } label: {
                        Label(m.settings.fullCharge ? L("Stop top-up") : L("Top up to 100%"), systemImage: "battery.100percent.bolt")
                            .lineLimit(1).minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(m.settings.disabled)
                    Button {
                        m.settings.disabled.toggle(); m.save()
                    } label: {
                        Label(m.settings.disabled ? L("Enable") : L("Disable"),
                              systemImage: m.settings.disabled ? "play.circle" : "pause.circle")
                            .lineLimit(1).minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity)
                    }
                }
                .controlSize(.regular)
                if m.percent < 100, let mins = m.minutesToCharge(to: 100) {
                    Text(L("Top-up from %@ to 100%%: ≈ %@", pct(m.percent), duration(mins)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // Footer
            HStack(spacing: 10) {
                Text(m.macosLimit > 0 ? L("macOS limit %@", pct(m.macosLimit)) : L("No macOS limit"))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help(L("Settings"))
                Button(L("Quit")) { NSApp.terminate(nil) }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }
}

struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

struct SettingsPage: View {
    @EnvironmentObject var m: Model
    @Environment(\.openWindow) private var openWindow
    var back: () -> Void
    @AppStorage(Pref.icon) private var showIcon = true
    @AppStorage(Pref.percent) private var showPercent = true
    @AppStorage(Pref.timeOnBattery) private var showTimeOnBattery = true
    @AppStorage(Pref.timeCharging) private var showTimeCharging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(action: back) { Label(L("Back"), systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Text(L("Settings")).font(.headline)
                Spacer()
                Color.clear.frame(width: 50, height: 1)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Menu bar")).font(.callout.weight(.semibold))
                SwitchRow(title: L("Mode icon"), isOn: $showIcon)
                SwitchRow(title: L("Battery percentage"), isOn: $showPercent)
                SwitchRow(title: L("Time left on battery"), isOn: $showTimeOnBattery)
                SwitchRow(title: L("Time to target while charging"), isOn: $showTimeCharging)
                HStack(spacing: 6) {
                    Text(L("Preview:")).foregroundStyle(.secondary)
                    MenuBarLabel(previewOnBattery: true)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .font(.caption)
            }
            .toggleStyle(.switch).controlSize(.small)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Help")).font(.callout.weight(.semibold))
                Button {
                    openWindow(id: "onboarding"); NSApp.activate(ignoringOtherApps: true)
                } label: { Label(L("Setup guide"), systemImage: "list.bullet.clipboard") }
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
                } label: { Label(L("Open log"), systemImage: "doc.text") }
                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/mirakoz/ChargeSurf")!)
                } label: { Label(L("Project page and bug reports"), systemImage: "link") }
            }
            .buttonStyle(.link)
        }
    }
}

struct Panel: View {
    @EnvironmentObject var m: Model
    @State var showSettings = false

    var body: some View {
        Group {
            if showSettings {
                SettingsPage(back: { showSettings = false })
            } else {
                MainPage(openSettings: { showSettings = true })
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// What the menu bar shows, according to the user's preferences.
struct MenuBarLabel: View {
    @EnvironmentObject var m: Model
    var previewOnBattery = false
    @AppStorage(Pref.icon) private var showIcon = true
    @AppStorage(Pref.percent) private var showPercent = true
    @AppStorage(Pref.timeOnBattery) private var showTimeOnBattery = true
    @AppStorage(Pref.timeCharging) private var showTimeCharging = false

    var text: String {
        var parts: [String] = []
        if showPercent { parts.append(pct(m.percent)) }
        if showTimeOnBattery {
            if let t = m.timeToEmpty { parts.append(compactDuration(t)) }
            else if previewOnBattery { parts.append("3:25") }
        }
        if showTimeCharging, let target = m.chargeTarget, let mins = m.minutesToCharge(to: target) {
            parts.append("→" + compactDuration(mins))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 3) {
            if showIcon || text.isEmpty { Image(systemName: m.icon) }
            if !text.isEmpty { Text(text).monospacedDigit() }
        }
    }
}

// MARK: - Setup guide

struct GuideStep: View {
    let number: Int, icon: String, title: String, text: String
    var button: (String, String)? = nil   // (label, System Settings URL)

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 30, height: 30)
                Image(systemName: icon).foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(number). \(title)").font(.callout.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let (label, url) = button {
                    Button(label) { NSWorkspace.shared.open(URL(string: url)!) }
                        .controlSize(.small).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct OnboardingView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(Pref.onboardingDone) private var done = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "sailboat.fill").font(.system(size: 30)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Welcome to ChargeSurf")).font(.title2.weight(.semibold))
                    Text(L("A few macOS settings to check once. It takes about a minute."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            GuideStep(number: 1, icon: "checkmark.shield", title: L("Allow it in the background"),
                      text: L("After installing, macOS may show \"Background Items Added\". Keep ChargeSurf and chargesurfd switched on under Login Items & Extensions > Allow in the Background, or protection stops."),
                      button: (L("Open Login Items"), "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"))
            GuideStep(number: 2, icon: "battery.75percent", title: L("Leave macOS's Charge Limit alone"),
                      text: L("ChargeSurf drives the Charge Limit in Battery settings itself. Changing it there fights ChargeSurf; use this app instead. If your Mac sometimes charges to 100% on its own, try turning off Optimized Battery Charging."),
                      button: (L("Open Battery settings"), "x-apple.systempreferences:com.apple.Battery-Settings.extension"))
            GuideStep(number: 3, icon: "xmark.app", title: L("Quit other charge limiters"),
                      text: L("AlDente, batt and similar tools change the same limit. Quit them and remove them (including their helper) before using ChargeSurf."))
            GuideStep(number: 4, icon: "globe", title: L("Language"),
                      text: L("ChargeSurf follows your system language (English or Turkish). You can pick a language for ChargeSurf alone under Language & Region > Applications."),
                      button: (L("Open Language & Region"), "x-apple.systempreferences:com.apple.Localization-Settings.extension"))
            GuideStep(number: 5, icon: "checkmark.circle", title: L("Check that it works"),
                      text: L("Click the icon in the menu bar. The panel should show a mode (for example Sailing) and \"macOS limit\" at the bottom. If it says the background service is not responding, run sudo ./install.sh again."))
            HStack {
                Text(L("You can open this guide again from Settings.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Done")) { done = true; dismissWindow(id: "onboarding") }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}

// MARK: - App

@main
struct ChargeSurfApp: App {
    @StateObject private var m = Model(live: !CommandLine.arguments.contains("--preview"))

    init() {
        // --preview out.png [--page main|settings|onboarding] [--dark]: render to PNG and exit.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--preview"), i + 1 < args.count {
            let path = args[i + 1]
            let dark = args.contains("--dark")
            let page = args.firstIndex(of: "--page").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "main"
            MainActor.assumeIsolated {
                let model = Model(live: false)
                let content: AnyView
                switch page {
                case "settings": content = AnyView(Panel(showSettings: true))
                case "onboarding": content = AnyView(OnboardingView())
                default: content = AnyView(Panel())
                }
                let v = content.environmentObject(model)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light)
                let r = ImageRenderer(content: v)
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
            }
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Panel().environmentObject(m)
        } label: {
            FirstLaunch { MenuBarLabel().environmentObject(m) }
        }
        .menuBarExtraStyle(.window)

        Window(L("ChargeSurf Setup"), id: "onboarding") {
            OnboardingView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// Opens the setup guide once, the first time the app runs.
struct FirstLaunch<Content: View>: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Pref.onboardingDone) private var done = false
    @ViewBuilder var content: Content

    var body: some View {
        content.task {
            guard !done else { return }
            try? await Task.sleep(nanoseconds: 800_000_000)
            openWindow(id: "onboarding")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
