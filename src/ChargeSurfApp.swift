// ChargeSurf menu bar app.
// The root daemon (chargesurfd) does the actual work. This app writes the config file,
// wakes the daemon with a Darwin notification, and shows the daemon's status file.
// Protection keeps running while the app is closed.
//
// Localization: English is the base language; translations live in
// resources/<lang>.lproj/Localizable.strings (keys are the English strings).

import AppKit
import Charts
import Darwin
import IOKit
import IOKit.ps
import SwiftUI
import UserNotifications

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
    static let tab = "panel.tab"
    static let notifyFull = "devices.notifyFull"
}

// MARK: - Notifications

/// "Fully charged" notifications for devices on the USB-C ports.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static var enabled: Bool { UserDefaults.standard.object(forKey: Pref.notifyFull) as? Bool ?? true }

    func setUp() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        if Notifier.enabled { c.requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    }

    func deviceFull(_ name: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = L("%@ is fully charged", name)
        content.body = L("You can unplug it from your Mac.")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "full-\(id)", content: content, trigger: nil))
    }

    // Show the banner even if ChargeSurf's panel happens to be open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

// MARK: - Power: charger, consumption and history

/// Locale-aware number with a unit: "9.5 W", "24 W".
func fmt(_ v: Double, _ unit: String, digits: Int? = nil) -> String {
    let d = digits ?? (abs(v) < 10 ? 1 : 0)
    return v.formatted(.number.precision(.fractionLength(d))) + " " + unit
}
func fmtV(_ mv: Int) -> String { mv % 1000 == 0 ? "\(mv / 1000) V" : fmt(Double(mv) / 1000, "V", digits: 2) }

struct PDProfile: Equatable { var mv: Int, ma: Int }

/// What the connected charger reports (AppleSmartBattery > AdapterDetails).
struct ChargerInfo: Equatable {
    var watts: Int
    var name: String?, manufacturer: String?, firmware: String?
    var voltageMV: Int, currentMA: Int          // negotiated
    var profiles: [PDProfile]                   // USB-PD fixed supplies, low to high

    var title: String {
        if let n = name, !n.isEmpty { return n }
        return profiles.isEmpty ? L("%d W charger", watts) : L("%d W USB-C PD charger", watts)
    }
}

/// Live power flow from macOS's power telemetry (updated about once a minute).
struct PowerNow: Equatable {
    var loadMW: Int          // everything the Mac uses
    var inMW: Int            // drawn from the adapter
    var voltageMV: Int       // input voltage at the Mac
    var batteryMW: Int { inMW - loadMW }    // > 0: battery charging, < 0: battery helping
}

/// One reading of macOS's running energy counters. AccumulatedSystemLoad adds the
/// system load (mW) once per second since boot, so the difference between two
/// readings gives the exact average over that time, even while the app was closed.
struct PowerSample: Equatable {
    var ts: Double, boot: Int, acc: Int, count: Int
    var loadMW: Int, inMW: Int, voltMV: Int, adapterW: Int, adapterMV: Int

    var line: String { "\(Int(ts)),\(boot),\(acc),\(count),\(loadMW),\(inMW),\(voltMV),\(adapterW),\(adapterMV)" }
    init(ts: Double, boot: Int, acc: Int, count: Int, loadMW: Int, inMW: Int, voltMV: Int, adapterW: Int, adapterMV: Int) {
        self.ts = ts; self.boot = boot; self.acc = acc; self.count = count
        self.loadMW = loadMW; self.inMW = inMW; self.voltMV = voltMV; self.adapterW = adapterW; self.adapterMV = adapterMV
    }
    init?(line: Substring) {
        let p = line.split(separator: ",").compactMap { Int($0) }
        guard p.count == 9 else { return nil }
        self.init(ts: Double(p[0]), boot: p[1], acc: p[2], count: p[3], loadMW: p[4], inMW: p[5], voltMV: p[6], adapterW: p[7], adapterMV: p[8])
    }
}

struct Usage { var avgW: Double, wh: Double, covered: Double }
struct UsageBar: Identifiable { var id: Double { start.timeIntervalSince1970 }; var start: Date, end: Date, watts: Double }

extension Array where Element == PowerSample {
    /// Consecutive readings from the same boot (the counters restart at boot), with the
    /// share of each interval that falls after `start`.
    func intervals(after start: Double) -> [(a: PowerSample, b: PowerSample, f: Double)] {
        zip(self, dropFirst()).compactMap { a, b in
            guard b.ts > start, b.ts > a.ts, abs(b.boot - a.boot) < 60, b.count > a.count, b.acc >= a.acc else { return nil }
            return (a, b, a.ts >= start ? 1 : (b.ts - start) / (b.ts - a.ts))
        }
    }

    func usage(last window: Double, now: Double) -> Usage? {
        var e = 0.0, n = 0.0, covered = 0.0
        for (a, b, f) in intervals(after: now - window) {
            e += Double(b.acc - a.acc) * f
            n += Double(b.count - a.count) * f
            covered += Swift.min(Double(b.count - a.count), b.ts - a.ts) * f
        }
        guard n > 0 else { return nil }
        let w = e / n / 1000
        return Usage(avgW: w, wh: w * covered / 3600, covered: covered)
    }

    /// Highest one-minute average in the window (from readings about a minute apart).
    func peakW(last window: Double, now: Double) -> Double? {
        intervals(after: now - window).filter { $0.b.ts - $0.a.ts <= 180 }
            .map { Double($0.b.acc - $0.a.acc) / Double($0.b.count - $0.a.count) / 1000 }.max()
    }

    func minVoltage(watts: Int, nominalMV: Int, last window: Double, now: Double) -> Int? {
        filter { $0.ts > now - window && $0.adapterW == watts && $0.adapterMV == nominalMV && $0.inMW > 0 && $0.voltMV > 0 }
            .map(\.voltMV).min()
    }

    /// Average use in 10-minute bins for the chart; long gaps are left empty.
    func bars(last window: Double, now: Double, bin: Double = 600) -> [UsageBar] {
        let start = now - window
        var e: [Int: Double] = [:], n: [Int: Double] = [:]
        for (a, b, _) in intervals(after: start) where b.ts - a.ts <= 900 {
            let k = Int((b.ts - start) / bin)
            e[k, default: 0] += Double(b.acc - a.acc); n[k, default: 0] += Double(b.count - a.count)
        }
        return e.keys.sorted().map { k in
            let s = start + Double(k) * bin
            return UsageBar(start: Date(timeIntervalSince1970: s + 40), end: Date(timeIntervalSince1970: s + bin - 40),
                            watts: e[k]! / n[k]! / 1000)
        }
    }
}

/// Readings are kept per user for 24 hours, recorded while the menu bar app runs.
enum PowerLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ChargeSurf/power-history.csv")
    static let keep: Double = 24 * 3600

    static func load() -> [PowerSample] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let cutoff = Date().timeIntervalSince1970 - keep
        return s.split(separator: "\n").compactMap(PowerSample.init(line:)).filter { $0.ts > cutoff }.sorted { $0.ts < $1.ts }
    }

    static func append(_ x: PowerSample) {
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile(); fh.write(Data((x.line + "\n").utf8)); try? fh.close()
        } else {
            rewrite([x])
        }
    }

    static func rewrite(_ list: [PowerSample]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(list.map { $0.line + "\n" }.joined().utf8).write(to: url, options: .atomic)
    }
}

func bootTime() -> Int {
    var tv = timeval(), size = MemoryLayout<timeval>.stride
    return sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 ? tv.tv_sec : 0
}

// MARK: - Devices: what the Mac powers over USB-C

/// Power going out of one USB-C port (AppleSmartBattery > PowerOutDetails, about once a minute).
struct PortPower: Equatable { var port: Int, mw: Int, mv: Int, ma: Int }

/// A USB device and the USB-C port it hangs off (from the port's usb-c-port-number).
struct USBDevice: Equatable {
    var name: String, vendor: String?, vendorID: Int, serial: String?, deviceClass: Int, port: Int
    var isAccessory: Bool {   // hubs, billboard (display adapters), docks: they have no battery
        deviceClass == 9 || deviceClass == 17 || ["adapter", "hub", "dock"].contains { name.lowercased().contains($0) }
    }
    var isAppleCase: Bool { vendorID == 0x05ac && name.lowercased().contains("case") }
}

func readPortPower() -> [PortPower] {
    let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard s != 0 else { return [] }
    defer { IOObjectRelease(s) }
    let list = IORegistryEntryCreateCFProperty(s, "PowerOutDetails" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]] ?? []
    func i(_ d: [String: Any], _ k: String) -> Int { (d[k] as? NSNumber)?.intValue ?? 0 }
    return list.map { PortPower(port: i($0, "PortIndex"), mw: i($0, "Watts"), mv: i($0, "AdapterVoltage"), ma: i($0, "Current")) }
        .filter { $0.port > 0 }
}

func readUSBDevices() -> [USBDevice] {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(it) }
    var r: [USBDevice] = []
    while case let s = IOIteratorNext(it), s != 0 {
        defer { IOObjectRelease(s) }
        func p(_ k: String) -> Any? { IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
        // Walk up to the controller port that knows which USB-C receptacle it is.
        var port = 0, e = s
        IOObjectRetain(e)
        for _ in 0..<10 {
            if let d = IORegistryEntryCreateCFProperty(e, "usb-c-port-number" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data, d.count >= 4 {
                port = Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }); break
            }
            var parent: io_registry_entry_t = 0
            let ok = IORegistryEntryGetParentEntry(e, kIOServicePlane, &parent) == KERN_SUCCESS
            IOObjectRelease(e)
            guard ok else { e = 0; break }
            e = parent
        }
        if e != 0 { IOObjectRelease(e) }
        guard port > 0 else { continue }
        let name = (p("kUSBProductString") ?? p("USB Product Name")) as? String ?? L("USB device")
        r.append(USBDevice(name: name, vendor: p("kUSBVendorString") as? String, vendorID: (p("idVendor") as? NSNumber)?.intValue ?? 0,
                           serial: p("kUSBSerialNumberString") as? String, deviceClass: (p("bDeviceClass") as? NSNumber)?.intValue ?? 0, port: port))
    }
    return r
}

/// An iPhone or iPad on USB, read through Apple's MobileDevice framework (the one Finder uses).
/// Battery details need the device to trust this Mac; nothing here asks it to.
struct PhoneInfo: Equatable {
    var serial: String                 // device identifier without "-": the USB serial number
    var model: String, isTablet: Bool
    var trusted: Bool
    var percent: Int?, charging = false, full = false
    var batteryMV: Int?, batteryMA: Int?           // into the battery
    var mAh: Int?, maxMAh: Int?, nominalMAh: Int?, designMAh: Int?, cycles: Int?
}

/// AirPods levels from Bluetooth (only while the AirPods are connected to this Mac).
struct BudsInfo: Equatable { var caseLevel: Int?, left: Int?, right: Int? }

/// Function table for the private MobileDevice framework, loaded at run time.
private struct MobileDeviceAPI {
    typealias Dev = UnsafeMutableRawPointer
    typealias Callback = @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void
    let subscribe: @convention(c) (Callback, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
    let connect, validate, startSession, stopSession, disconnect, interface: @convention(c) (Dev) -> Int32
    let identifier: @convention(c) (Dev) -> Unmanaged<CFString>?
    let copyValue: @convention(c) (Dev, CFString?, CFString) -> Unmanaged<CFTypeRef>?
    let startService: @convention(c) (Dev, CFString, CFDictionary?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
    let send: @convention(c) (UnsafeMutableRawPointer, CFPropertyList, Int) -> Int32
    let receive: @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Unmanaged<CFPropertyList>?>, UnsafeMutablePointer<Int>?) -> Int32
    let invalidate: @convention(c) (UnsafeMutableRawPointer) -> Void

    init?() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW) else { return nil }
        func f<T>(_ n: String) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: T.self) } }
        guard let a: @convention(c) (Callback, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32 = f("AMDeviceNotificationSubscribe"),
              let b: @convention(c) (Dev) -> Int32 = f("AMDeviceConnect"), let c: @convention(c) (Dev) -> Int32 = f("AMDeviceValidatePairing"),
              let d: @convention(c) (Dev) -> Int32 = f("AMDeviceStartSession"), let e: @convention(c) (Dev) -> Int32 = f("AMDeviceStopSession"),
              let g: @convention(c) (Dev) -> Int32 = f("AMDeviceDisconnect"), let i: @convention(c) (Dev) -> Int32 = f("AMDeviceGetInterfaceType"),
              let j: @convention(c) (Dev) -> Unmanaged<CFString>? = f("AMDeviceCopyDeviceIdentifier"),
              let k: @convention(c) (Dev, CFString?, CFString) -> Unmanaged<CFTypeRef>? = f("AMDeviceCopyValue"),
              let l: @convention(c) (Dev, CFString, CFDictionary?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32 = f("AMDeviceSecureStartService"),
              let m: @convention(c) (UnsafeMutableRawPointer, CFPropertyList, Int) -> Int32 = f("AMDServiceConnectionSendMessage"),
              let n: @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Unmanaged<CFPropertyList>?>, UnsafeMutablePointer<Int>?) -> Int32 = f("AMDServiceConnectionReceiveMessage"),
              let o: @convention(c) (UnsafeMutableRawPointer) -> Void = f("AMDServiceConnectionInvalidate")
        else { return nil }
        subscribe = a; connect = b; validate = c; startSession = d; stopSession = e; disconnect = g; interface = i
        identifier = j; copyValue = k; startService = l; send = m; receive = n; invalidate = o
    }
}

/// Watches iPhones/iPads (MobileDevice) and AirPods levels (Bluetooth) off the main thread.
final class DeviceMonitor: @unchecked Sendable {
    private let api = MobileDeviceAPI()
    private let q = DispatchQueue(label: "io.github.mirakoz.chargesurf.devices", qos: .utility)
    private let lock = NSLock()
    private var handles: [String: UnsafeMutableRawPointer] = [:]   // serial -> retained AMDevice (on q)
    private var _phones: [String: PhoneInfo] = [:]
    private var _buds: BudsInfo?
    private var lastPhoneRead = 0.0, lastBudsRead = 0.0, busy = false
    private var note: UnsafeMutableRawPointer?

    var phones: [String: PhoneInfo] { lock.lock(); defer { lock.unlock() }; return _phones }
    var buds: BudsInfo? { lock.lock(); defer { lock.unlock() }; return _buds }

    init() {
        guard let api else { return }
        let cb: MobileDeviceAPI.Callback = { info, ctx in
            guard let info, let ctx, let dev = info.load(as: UnsafeMutableRawPointer?.self) else { return }
            let msg = info.load(fromByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UInt32.self)
            Unmanaged<DeviceMonitor>.fromOpaque(ctx).takeUnretainedValue().deviceEvent(dev, msg)
        }
        _ = api.subscribe(cb, 0, 0, Unmanaged.passUnretained(self).toOpaque(), &note)
    }

    private func deviceEvent(_ dev: UnsafeMutableRawPointer, _ msg: UInt32) {
        guard let api, api.interface(dev) == 1, let id = api.identifier(dev)?.takeRetainedValue() else { return }   // 1 = USB
        let serial = (id as String).replacingOccurrences(of: "-", with: "")
        if msg == 1 {
            let retained = Unmanaged<AnyObject>.fromOpaque(dev).retain().toOpaque()
            q.async { [self] in
                if let old = handles[serial] { Unmanaged<AnyObject>.fromOpaque(old).release() }
                handles[serial] = retained
                lastPhoneRead = 0
            }
        } else if msg == 2 {
            q.async { [self] in
                if let old = handles.removeValue(forKey: serial) { Unmanaged<AnyObject>.fromOpaque(old).release() }
                lock.lock(); _phones[serial] = nil; lock.unlock()
            }
        }
    }

    /// Called every few seconds; reads phones about once a minute and AirPods only when a case is plugged in.
    func tick(wantBuds: Bool) {
        q.async { [self] in
            guard !busy else { return }
            let now = Date().timeIntervalSince1970
            let phonesDue = !handles.isEmpty && now - lastPhoneRead > 60
            let budsDue = wantBuds && now - lastBudsRead > 60
            if !wantBuds && _buds != nil { lock.lock(); _buds = nil; lock.unlock() }
            guard phonesDue || budsDue else { return }
            busy = true
            if phonesDue {
                lastPhoneRead = now
                var result: [String: PhoneInfo] = [:]
                for (serial, dev) in handles { result[serial] = readPhone(dev, serial: serial) }
                lock.lock(); _phones = result; lock.unlock()
            }
            if budsDue {
                lastBudsRead = now
                let b = DeviceMonitor.readBuds()
                lock.lock(); _buds = b; lock.unlock()
            }
            busy = false
        }
    }

    /// For --preview: lets the USB connect events arrive, then reads everything once.
    func readNow(wantBuds: Bool) {
        let end = Date().addingTimeInterval(2.5)
        while Date() < end { CFRunLoopRunInMode(.defaultMode, 0.1, false) }
        q.sync { lastPhoneRead = 0; lastBudsRead = 0 }
        tick(wantBuds: wantBuds)
        q.sync {}
    }

    private func readPhone(_ d: UnsafeMutableRawPointer, serial: String) -> PhoneInfo? {
        guard let api, api.connect(d) == 0 else { return nil }
        func value(_ domain: String?, _ key: String) -> Any? { api.copyValue(d, domain as CFString?, key as CFString)?.takeRetainedValue() }
        let cls = value(nil, "DeviceClass") as? String ?? "iPhone"
        var info = PhoneInfo(serial: serial, model: value(nil, "MarketingName") as? String ?? cls, isTablet: cls == "iPad", trusted: false)
        var service: UnsafeMutableRawPointer?
        if api.validate(d) == 0, api.startSession(d) == 0 {
            info.trusted = true
            info.percent = (value("com.apple.mobile.battery", "BatteryCurrentCapacity") as? NSNumber)?.intValue
            info.charging = value("com.apple.mobile.battery", "BatteryIsCharging") as? Bool ?? false
            info.full = value("com.apple.mobile.battery", "FullyCharged") as? Bool ?? false
            if api.startService(d, "com.apple.mobile.diagnostics_relay" as CFString, nil, &service) != 0 { service = nil }
            _ = api.stopSession(d)
        }
        _ = api.disconnect(d)
        guard let c = service else { return info }
        defer { _ = api.send(c, ["Request": "Goodbye"] as CFDictionary, 100); api.invalidate(c) }   // 100 = XML plist
        guard api.send(c, ["Request": "IORegistry", "EntryClass": "AppleSmartBattery"] as CFDictionary, 100) == 0 else { return info }
        var out: Unmanaged<CFPropertyList>?
        guard api.receive(c, &out, nil) == 0, let reply = out?.takeRetainedValue() as? [String: Any],
              let io = (reply["Diagnostics"] as? [String: Any])?["IORegistry"] as? [String: Any] else { return info }
        func n(_ d: [String: Any]?, _ k: String) -> Int? { (d?[k] as? NSNumber)?.intValue }
        let bd = io["BatteryData"] as? [String: Any]
        info.batteryMV = n(io, "Voltage"); info.batteryMA = n(io, "InstantAmperage") ?? n(io, "Amperage")
        info.cycles = n(io, "CycleCount")
        info.mAh = n(bd, "AppleRawCurrentCapacity"); info.maxMAh = n(bd, "AppleRawMaxCapacity")
        info.nominalMAh = n(bd, "NominalChargeCapacity"); info.designMAh = n(bd, "DesignCapacity")
        if info.percent == nil { info.percent = n(io, "CurrentCapacity") }
        return info
    }

    /// system_profiler is the one way to get AirPods levels without a Bluetooth permission prompt.
    private static func readBuds() -> BudsInfo? {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        func level(_ v: Any?) -> Int? { (v as? String).flatMap { Int($0.filter(\.isNumber)) } }
        for s in sections {
            for entry in s["device_connected"] as? [[String: Any]] ?? [] {
                for case let d as [String: Any] in entry.values {
                    let b = BudsInfo(caseLevel: level(d["device_batteryLevelCase"]), left: level(d["device_batteryLevelLeft"]),
                                     right: level(d["device_batteryLevelRight"]))
                    if b.caseLevel != nil || b.left != nil || b.right != nil { return b }
                }
            }
        }
        return nil
    }
}

enum DeviceKind: Equatable { case phone, tablet, buds, accessory, unknown, other }

/// One row in the Devices tab: a device on a USB-C port, with whatever its port and battery report.
struct ChargedDevice: Identifiable, Equatable {
    struct Level: Equatable { var label: String, value: Int }
    var id: String
    var kind: DeviceKind
    var name: String
    var subtitle: String?
    var port: Int
    var power: PortPower?
    var percent: Int?
    var levels: [Level] = []        // AirPods: case, left, right
    var charging: Bool?
    var full = false
    var batteryMW: Int?             // into the device's battery
    var health: Int?, cycles: Int?
    var minutesToFull: Int?
    var note: String?
}

/// Minutes to 100% from how fast the level rose recently (needs a few minutes of readings).
func minutesToFull(_ history: [(t: Double, p: Int)], now: Double) -> Int? {
    guard let cur = history.last?.p, cur < 100,
          let old = history.first(where: { now - $0.t <= 45 * 60 && $0.p < cur - 1 }), now - old.t >= 240 else { return nil }
    let perMin = Double(cur - old.p) / ((now - old.t) / 60)
    guard perMin > 0 else { return nil }
    return Int((Double(100 - cur) / perMin).rounded())
}

/// Phone: time to full from the battery's own mAh and charge current. Charging slows above
/// 80%, so that part is counted at about half the current rate.
func phoneMinutesToFull(_ p: PhoneInfo) -> Int? {
    guard p.charging, !p.full, let ma = p.batteryMA, ma > 50, let cur = p.mAh, let max = p.maxMAh, max > cur else { return nil }
    let pct = Double(p.percent ?? cur * 100 / max)
    let knee = Double(max) * 0.8
    let fast = pct < 80 ? Swift.max(0, knee - Double(cur)) : 0
    let slow = Double(max) - Swift.max(Double(cur), knee)
    let rate = Double(ma)
    let hours = fast / rate + slow / (rate * (pct < 80 ? 0.45 : 0.6))
    return Int((hours * 60).rounded())
}

/// Puts ports, USB devices, phones and AirPods together. One row per port with power or a
/// device on it; accessories (adapters, hubs) are listed but never treated as charging.
func composeDevices(ports: [PortPower], usb: [USBDevice], phones: [String: PhoneInfo], buds: BudsInfo?,
                    history: [String: [(t: Double, p: Int)]], now: Double) -> [ChargedDevice] {
    var rows: [ChargedDevice] = []
    let portNumbers = Set(ports.filter { $0.mw >= 250 }.map(\.port)).union(usb.map(\.port)).sorted()
    for n in portNumbers {
        let power = ports.first { $0.port == n }
        let here = usb.filter { $0.port == n }
        let phone = here.compactMap { d in d.serial.flatMap { phones[$0] } }.first
        let budsCase = here.first(where: \.isAppleCase)
        let main = here.first { d in d.serial.flatMap { phones[$0] } != nil } ?? budsCase ?? here.first { !$0.isAccessory } ?? here.first
        var row = ChargedDevice(id: "port\(n)", kind: .other, name: main?.name ?? L("Device without data connection"),
                                subtitle: nil, port: n, power: power)
        if let p = phone {
            row.id = p.serial; row.kind = p.isTablet ? .tablet : .phone; row.name = p.model
            row.percent = p.percent; row.charging = p.charging; row.full = p.full
            if let mv = p.batteryMV, let ma = p.batteryMA, ma > 0 { row.batteryMW = mv * ma / 1000 }
            if let nom = p.nominalMAh, let des = p.designMAh, des > 0 { row.health = Int((Double(nom) * 100 / Double(des)).rounded()) }
            row.cycles = p.cycles
            row.minutesToFull = phoneMinutesToFull(p) ?? history[p.serial].flatMap { minutesToFull($0, now: now) }
            if !p.trusted { row.note = L("Unlock it and tap Trust to see its battery.") }
            else if !p.charging && !p.full && (p.percent ?? 0) < 100 { row.note = L("Not charging right now (the device may be holding its charge).") }
        } else if let c = budsCase {
            row.id = "buds\(n)"; row.kind = .buds; row.name = L("AirPods charging case")
            _ = c
            if let b = buds {
                row.percent = b.caseLevel
                row.levels = [(L("Case"), b.caseLevel), (L("Left"), b.left), (L("Right"), b.right)]
                    .compactMap { l, v in v.map { ChargedDevice.Level(label: l, value: $0) } }
                row.full = (b.caseLevel ?? 0) >= 100
                row.minutesToFull = history[row.id].flatMap { minutesToFull($0, now: now) }
            } else {
                row.note = L("Levels show while the AirPods are connected to this Mac.")
            }
        } else if let d = main {
            row.kind = d.isAccessory ? .accessory : .other
            row.subtitle = d.vendor.flatMap { $0.allSatisfy { $0 == "x" || $0 == " " } ? nil : $0 }
            if !d.isAccessory { row.note = L("It does not report a battery level.") }
        } else {
            row.kind = .unknown
            row.note = L("Charging only, so it cannot report its battery.")
        }
        rows.append(row)
    }
    return rows
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
    @Published var charger: ChargerInfo?
    @Published var powerNow: PowerNow?
    @Published var samples: [PowerSample] = []
    @Published var devices: [ChargedDevice] = []
    var editing = false
    private let live: Bool
    private var monitor: DeviceMonitor?
    private var levelHistory: [String: [(t: Double, p: Int)]] = [:]
    private var fullArmed: Set<String> = []      // devices seen below 98%, to notify once when full
    private var lastSave = Date.distantPast
    private var timer: Timer?

    init(live: Bool = true) {
        self.live = live
        monitor = live ? DeviceMonitor() : nil
        if live { Notifier.shared.setUp() }
        samples = PowerLog.load()          // read-only in --preview; recording needs live
        refresh()
        guard live else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        status = readKeyValues(statusPath)
        readBattery()
        readDevices()
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
        readPower()
        // Remember a smoothed charging current, so estimates also work while not charging.
        if power == .charging && amps > 300 && percent < 80 {
            let old = UserDefaults.standard.double(forKey: Pref.chargeRate)
            UserDefaults.standard.set(old > 0 ? old * 0.8 + Double(amps) * 0.2 : Double(amps), forKey: Pref.chargeRate)
        }
    }

    private func readPower() {
        func i(_ d: [String: Any], _ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
        let t = Model.smartBattery("PowerTelemetryData") as? [String: Any] ?? [:]
        if let load = i(t, "SystemLoad"), let pin = i(t, "SystemPowerIn") {
            powerNow = PowerNow(loadMW: load, inMW: pin, voltageMV: i(t, "SystemVoltageIn") ?? 0)
        } else {
            powerNow = nil
        }
        var c: ChargerInfo?
        if power != .battery, let ad = Model.smartBattery("AdapterDetails") as? [String: Any], let w = i(ad, "Watts"), w > 0 {
            let menu = (ad["UsbHvcMenu"] as? [[String: Any]] ?? []).compactMap { d -> PDProfile? in
                guard let v = i(d, "MaxVoltage"), let a = i(d, "MaxCurrent"), v > 0 else { return nil }
                return PDProfile(mv: v, ma: a)
            }
            c = ChargerInfo(watts: w, name: ad["Name"] as? String, manufacturer: ad["Manufacturer"] as? String,
                            firmware: ad["FwVersion"] as? String,
                            voltageMV: i(ad, "AdapterVoltage") ?? 0, currentMA: i(ad, "Current") ?? 0,
                            profiles: menu.sorted { $0.mv < $1.mv })
        }
        if c != charger { charger = c }

        // Record a reading whenever macOS updates its counters (about once a minute).
        guard live, let acc = i(t, "AccumulatedSystemLoad"), let n = i(t, "SystemLoadAccumulatorCount"), n > 0,
              let p = powerNow else { return }
        let boot = bootTime()
        if let last = samples.last, abs(last.boot - boot) < 60, last.acc == acc, last.count == n { return }
        let x = PowerSample(ts: Date().timeIntervalSince1970, boot: boot, acc: acc, count: n, loadMW: p.loadMW, inMW: p.inMW,
                            voltMV: p.voltageMV, adapterW: c?.watts ?? 0, adapterMV: c?.voltageMV ?? 0)
        samples.append(x)
        if let first = samples.first, first.ts < x.ts - PowerLog.keep - 3600 {
            samples.removeAll { $0.ts < x.ts - PowerLog.keep }
            PowerLog.rewrite(samples)
        } else {
            PowerLog.append(x)
        }
    }

    /// --preview --live-devices: render the Devices tab from what is plugged in now.
    func loadDevicesNow() {
        let mon = DeviceMonitor()
        monitor = mon
        mon.readNow(wantBuds: readUSBDevices().contains(where: \.isAppleCase))
        readDevices()
    }

    private func readDevices() {
        guard let monitor else { return }
        let usb = readUSBDevices()
        monitor.tick(wantBuds: usb.contains(where: \.isAppleCase))
        let now = Date().timeIntervalSince1970
        let rows = composeDevices(ports: readPortPower(), usb: usb, phones: monitor.phones, buds: monitor.buds,
                                  history: levelHistory, now: now)
        for r in rows {
            guard let p = r.percent else { continue }
            var h = levelHistory[r.id] ?? []
            if h.last?.p != p { h.append((now, p)) }
            h.removeAll { now - $0.t > 3600 }
            levelHistory[r.id] = h
        }
        levelHistory = levelHistory.filter { id, _ in rows.contains { $0.id == id } }
        // Notify once when a device that was charging below 98% reaches full. Plugging in an
        // already full device does not notify; unplugging resets.
        for r in rows {
            guard let p = r.percent else { continue }
            let full = r.full || p >= 100
            if !full && p < 98 {
                fullArmed.insert(r.id)
            } else if full, fullArmed.remove(r.id) != nil, live, Notifier.enabled {
                Notifier.shared.deviceFull(r.name, id: r.id)
            }
        }
        fullArmed = fullArmed.filter { id in rows.contains { $0.id == id } }
        if rows != devices { devices = rows }
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

    /// Fixed sample states for README screenshots (--preview ... --demo NAME).
    func applyDemo(_ name: String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        settings = Settings()
        capacity = 6091; adapterRate = 3600; timeToEmpty = nil; timeToFull = nil
        var s = ["time": f.string(from: Date()), "temperature": "30.6"]
        switch name {
        case "charging":
            percent = 54; power = .charging; amps = 3700
            s["mode"] = "charging"; s["macos_limit"] = "80"; s["target_limit"] = "80"; s["temperature"] = "31.4"
        case "heat":
            percent = 67; power = .idle; amps = 0
            s["mode"] = "heat_protection"; s["macos_limit"] = "67"; s["target_limit"] = "67"; s["temperature"] = "35.8"
        case "battery":
            percent = 71; power = .battery; amps = -1400; timeToEmpty = 205
            s["mode"] = "sailing"; s["macos_limit"] = "72"; s["target_limit"] = "72"
        default:
            percent = 74; power = .idle; amps = 0
            s["mode"] = "sailing"; s["macos_limit"] = "74"; s["target_limit"] = "74"
        }
        status = s

        // Sample power data: a 65 W third-party USB-C PD charger and 12 hours of use.
        charger = power == .battery ? nil : ChargerInfo(
            watts: 65, name: nil, manufacturer: nil, firmware: nil, voltageMV: 20000, currentMA: 3250,
            profiles: [PDProfile(mv: 5000, ma: 3000), PDProfile(mv: 9000, ma: 3000), PDProfile(mv: 12000, ma: 3000),
                       PDProfile(mv: 15000, ma: 3000), PDProfile(mv: 20000, ma: 3250)])
        let load = name == "charging" ? 11_800 : 8_600
        let input = power == .battery ? 0 : load + (power == .charging ? 46_000 : 0)
        powerNow = PowerNow(loadMW: load, inMW: input, voltageMV: power == .battery ? 12_480 : 19_960)
        let now = Date().timeIntervalSince1970
        var acc = 0, n = 0, list: [PowerSample] = []
        for k in 0...720 {
            let h = Double(k) / 60
            var w = 5.2 + 1.8 * sin(h * 2.1) + 6.5 * pow(max(0, sin(h * 0.62 - 0.4)), 3) + 2.2 * max(0, sin(h * 7.3))
            if (250..<268).contains(k) { w += 13 }     // a heavy build
            if (420..<470).contains(k) { w = 1.1 }     // lunch, display off
            acc += Int(w * 1000) * 60; n += 60
            list.append(PowerSample(ts: now - Double(720 - k) * 60, boot: 1, acc: acc, count: n, loadMW: Int(w * 1000),
                                    inMW: Int(w * 1000), voltMV: 19_960 - Int(w * 9), adapterW: 65, adapterMV: 20000))
        }
        samples = list

        // Sample devices on the USB-C ports.
        devices = [
            ChargedDevice(id: "phone", kind: .phone, name: "iPhone 16 Pro", port: 1,
                          power: PortPower(port: 1, mw: 7400, mv: 5180, ma: 1430), percent: 64, charging: true,
                          batteryMW: 5600, health: 94, cycles: 286, minutesToFull: 74),
            ChargedDevice(id: "adapter", kind: .accessory, name: "USB-C Digital AV Multiport Adapter", port: 2,
                          power: PortPower(port: 2, mw: 450, mv: 5200, ma: 87)),
            ChargedDevice(id: "buds", kind: .buds, name: L("AirPods charging case"), port: 3,
                          power: PortPower(port: 3, mw: 1100, mv: 5220, ma: 210), percent: 58,
                          levels: [.init(label: L("Case"), value: 58), .init(label: L("Left"), value: 100), .init(label: L("Right"), value: 100)],
                          charging: true, minutesToFull: 41),
        ]
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

let isPreview = CommandLine.arguments.contains("--preview")

/// The system switch; in --preview it is drawn in SwiftUI, because offscreen renders
/// show AppKit switches in their inactive (grey) state.
struct AppSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        if isPreview {
            HStack(spacing: 8) {
                configuration.label
                Capsule().fill(configuration.isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.12)))
                    .frame(width: 32, height: 18)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
                            .frame(width: 16, height: 16).padding(1)
                    }
            }
        } else {
            Toggle(configuration).toggleStyle(.switch)
        }
    }
}

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
                .toggleStyle(AppSwitchStyle()).controlSize(.small)
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

            PanelFooter(openSettings: openSettings) {
                Text(m.macosLimit > 0 ? L("macOS limit %@", pct(m.macosLimit)) : L("No macOS limit"))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
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
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(AppSwitchStyle()).controlSize(.small)
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
    @AppStorage(Pref.notifyFull) private var notifyFull = true

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
            .toggleStyle(AppSwitchStyle()).controlSize(.small)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Notifications")).font(.callout.weight(.semibold))
                SwitchRow(title: L("When a device is fully charged"), isOn: $notifyFull)
                    .onChange(of: notifyFull) { _, on in if on { Notifier.shared.setUp() } }
                Text(L("For iPhone, iPad and AirPods charging from this Mac."))
                    .font(.caption).foregroundStyle(.secondary)
            }

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

// MARK: - Power page

struct StatTile: View {
    let title: String, usage: Usage?, window: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if let u = usage {
                Text(fmt(u.avgW, "W")).font(.title3.weight(.semibold)).monospacedDigit()
                Text(L("%@ used", fmt(u.wh, "Wh"))).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if u.covered < window * 0.9 {
                    Text(L("over %@", duration(Int(u.covered / 60)))).font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text(L("Collecting data…")).font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct UsageChart: View {
    let bars: [UsageBar], start: Date, end: Date

    /// Every third full hour, away from the edges so labels are not clipped.
    var ticks: [Date] {
        let cal = Calendar.current
        guard var t = cal.nextDate(after: start.addingTimeInterval(1800), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) else { return [] }
        while cal.component(.hour, from: t) % 3 != 0 { t.addTimeInterval(3600) }
        var r: [Date] = []
        while t < end.addingTimeInterval(-2700) { r.append(t); t.addTimeInterval(3 * 3600) }
        return r
    }

    var body: some View {
        Chart(bars) { b in
            BarMark(xStart: .value("Start", b.start), xEnd: .value("End", b.end), y: .value("W", b.watts))
                .foregroundStyle(Color.accentColor.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
        }
        .chartXScale(domain: start...end)
        .chartXAxis {
            AxisMarks(values: ticks) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine()
                AxisValueLabel { if let w = v.as(Double.self) { Text("\(Int(w)) W") } }
            }
        }
        .frame(height: 78)
    }
}

struct Check: Identifiable {
    var id: String { title }
    let ok: Bool?            // true: fine, false: worth a look, nil: information
    let title: String, detail: String
}

struct CheckRow: View {
    let c: Check
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: c.ok == true ? "checkmark.circle.fill" : c.ok == false ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(c.ok == true ? Color.green : c.ok == false ? Color.orange : Color.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.title).font(.caption.weight(.semibold))
                Text(c.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PowerPage: View {
    @EnvironmentObject var m: Model
    var openSettings: () -> Void

    func flow(_ p: PowerNow) -> (String, String) {
        if p.inMW <= 0 || m.power == .battery { return (L("From the battery"), "battery.75percent") }
        let adapter = fmt(Double(p.inMW) / 1000, "W")
        if p.batteryMW > 300 { return (L("Adapter %@, battery charging %@", adapter, fmt(Double(p.batteryMW) / 1000, "W")), "bolt.fill") }
        if p.batteryMW < -300 { return (L("Adapter %@, battery adding %@", adapter, fmt(Double(-p.batteryMW) / 1000, "W")), "battery.50percent") }
        return (L("All from the adapter"), "powerplug")
    }

    func checks(_ c: ChargerInfo, now: Double) -> [Check] {
        var r: [Check] = []
        if let top = c.profiles.last, let low = c.profiles.first {
            let range = low.mv == top.mv ? fmtV(top.mv) : "\(low.mv / 1000)–\(fmtV(top.mv))"
            let using = L("%@, up to %@", fmtV(c.voltageMV), fmt(Double(c.currentMA) / 1000, "A", digits: 2))
            r.append(c.voltageMV >= top.mv
                ? Check(ok: true, title: L("USB Power Delivery"), detail: L("Offers %@. Your Mac uses %@.", range, using))
                : Check(ok: false, title: L("Not using its highest voltage"),
                        detail: L("Your Mac uses %@ of the charger's %@. Try another cable or port.", fmtV(c.voltageMV), fmtV(top.mv))))
        } else {
            r.append(Check(ok: nil, title: L("No USB-PD details"), detail: L("The charger reports %d W at %@.", c.watts, fmtV(c.voltageMV))))
        }
        let peak = max(m.samples.peakW(last: 12 * 3600, now: now) ?? 0, Double(m.powerNow?.loadMW ?? 0) / 1000)
        if peak <= 0 {
            r.append(Check(ok: nil, title: L("Power headroom"), detail: L("Shown once some use has been recorded.")))
        } else if peak <= Double(c.watts) * 0.8 {
            r.append(Check(ok: true, title: L("Enough power for your use"),
                           detail: L("Highest 1-minute use in 12 h: %@ of %d W.", fmt(peak, "W"), c.watts)))
        } else {
            r.append(Check(ok: false, title: L("Close to its limit"),
                           detail: L("Highest 1-minute use in 12 h: %@ of %d W. Under heavy load the battery may have to help.", fmt(peak, "W"), c.watts)))
        }
        if let v = m.powerNow?.voltageMV, v > 0, (m.powerNow?.inMW ?? 0) > 0, c.voltageMV > 0 {
            let low = min(v, m.samples.minVoltage(watts: c.watts, nominalMV: c.voltageMV, last: 12 * 3600, now: now) ?? v)
            r.append(Double(low) >= Double(c.voltageMV) * 0.93
                ? Check(ok: true, title: L("Steady voltage"), detail: L("At the Mac: %@ now, lowest %@ (nominal %@).", fmtV(v), fmtV(low), fmtV(c.voltageMV)))
                : Check(ok: false, title: L("Voltage drops"), detail: L("Lowest %@ at the Mac against %@ nominal. A worn cable or a weak charger can cause this.", fmtV(low), fmtV(c.voltageMV))))
        }
        if let maker = c.manufacturer, !maker.isEmpty {
            r.append(Check(ok: true, title: L("Identifies itself"),
                           detail: c.firmware.map { L("%@, firmware %@", maker, $0) } ?? maker))
        } else {
            r.append(Check(ok: nil, title: L("No brand information"), detail: L("Normal for non-Apple chargers; it does not mean a problem.")))
        }
        return r
    }

    var body: some View {
        let now = Date().timeIntervalSince1970
        VStack(alignment: .leading, spacing: 14) {
            // Now
            HStack(alignment: .center) {
                Text(m.powerNow.map { fmt(Double($0.loadMW) / 1000, "W") } ?? "–")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Mac is using now")).font(.callout.weight(.medium))
                    if let p = m.powerNow {
                        let (text, icon) = flow(p)
                        Label(text, systemImage: icon).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            // Averages
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Average use")).font(.callout.weight(.semibold))
                HStack(spacing: 8) {
                    StatTile(title: L("Last hour"), usage: m.samples.usage(last: 3600, now: now), window: 3600)
                    StatTile(title: L("Last 12 hours"), usage: m.samples.usage(last: 12 * 3600, now: now), window: 12 * 3600)
                }
                let bars = m.samples.bars(last: 12 * 3600, now: now)
                if bars.count >= 2 {
                    UsageChart(bars: bars, start: Date(timeIntervalSince1970: now - 12 * 3600), end: Date(timeIntervalSince1970: now))
                }
                Text(L("macOS updates these figures about once a minute. History is kept while ChargeSurf runs."))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Charger
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("Charger")).font(.callout.weight(.semibold))
                    Spacer()
                    if let c = m.charger { Text(c.title).font(.callout).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8) }
                }
                if let c = m.charger {
                    ForEach(checks(c, now: now)) { CheckRow(c: $0) }
                    Text(L("These checks use what the charger reports and how steady it is. They cannot test safety or build quality."))
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(L("No charger connected.")).font(.callout).foregroundStyle(.secondary)
                }
            }

            PanelFooter(openSettings: openSettings) { EmptyView() }
        }
    }
}

// MARK: - Devices page

/// The first SF Symbol that exists on this macOS.
func symbol(_ names: String...) -> String { names.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? "circle" }

/// Charge level bar, drawn in SwiftUI so it looks the same in the menu and in README renders.
struct LevelBar: View {
    let value: Int
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(value <= 20 ? Color.orange : Color.green)
                    .frame(width: max(6, g.size.width * CGFloat(min(max(value, 0), 100)) / 100))
            }
        }
        .frame(height: 6)
    }
}

struct DeviceCard: View {
    let d: ChargedDevice

    var icon: String {
        switch d.kind {
        case .phone: return symbol("iphone", "iphone.gen3")
        case .tablet: return symbol("ipad", "ipad.landscape")
        case .buds: return symbol("airpods.chargingcase.fill", "airpodspro.chargingcase.wireless.fill", "airpods")
        case .accessory: return symbol("cable.connector", "powerplug")
        case .unknown: return symbol("powerplug.fill", "bolt.fill")
        case .other: return symbol("externaldrive.connected.to.line.below", "cable.connector")
        }
    }

    var watts: String { d.power.map { fmt(Double($0.mw) / 1000, "W") } ?? "–" }

    var voltage: String? {
        guard let p = d.power, p.mw >= 250, d.kind != .accessory else { return nil }
        return p.mv > 5600 ? L("%@ fast charging", fmtV(Int((Double(p.mv) / 1000).rounded()) * 1000)) : L("5 V standard")
    }

    var status: String? {
        if d.full { return L("Full") }
        if let m = d.minutesToFull { return L("≈ %@ to full", duration(m)) }
        if d.charging == true { return L("Charging now") }
        return nil
    }

    var details: String? {
        var parts: [String] = []
        if let w = d.batteryMW, d.charging == true { parts.append(L("Battery gets %@", fmt(Double(w) / 1000, "W"))) }
        if let h = d.health { parts.append(L("Health %@", pct(h))) }
        if let c = d.cycles { parts.append(L("%d cycles", c)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: icon).font(.title2)
                    .foregroundStyle(d.kind == .accessory ? Color.secondary : Color.accentColor)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text([L("Port %d", d.port), d.kind == .accessory ? L("accessory") : voltage, d.subtitle].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 4)
                Text(watts).font(.callout.weight(.semibold)).monospacedDigit().fixedSize()
            }
            if let p = d.percent {
                HStack(spacing: 8) {
                    LevelBar(value: p)
                    Text(pct(p)).font(.caption.weight(.semibold)).monospacedDigit()
                }
                if d.levels.count > 1 {
                    Text(d.levels.map { "\($0.label) \(pct($0.value))" }.joined(separator: "  ·  "))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                if let s = status { Text(s).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1) }
            }
            if let x = details { Text(x).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8) }
            if let n = d.note { Text(n).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct DevicesPage: View {
    @EnvironmentObject var m: Model
    var openSettings: () -> Void

    var body: some View {
        let total = m.devices.compactMap { $0.power?.mw }.reduce(0, +)
        let charging = m.devices.filter { $0.kind != .accessory && ($0.power?.mw ?? 0) >= 250 }.count
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text(fmt(Double(total) / 1000, "W"))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Mac is giving out")).font(.callout.weight(.medium))
                    Text(charging == 1 ? L("to 1 device over USB-C") : L("to %d devices over USB-C", charging))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if m.devices.isEmpty {
                Text(L("Nothing is plugged into the USB-C ports."))
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(m.devices) { DeviceCard(d: $0) }
            Text(L("Port power comes from macOS and updates about once a minute. iPhone and iPad details need Trust This Computer on the device."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            PanelFooter(openSettings: openSettings) { EmptyView() }
        }
    }
}

struct PanelFooter<Leading: View>: View {
    var openSettings: () -> Void
    @ViewBuilder var leading: Leading
    var body: some View {
        HStack(spacing: 10) {
            leading
            Spacer()
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help(L("Settings"))
            Button(L("Quit")) { NSApp.terminate(nil) }
                .buttonStyle(.link).font(.caption)
        }
    }
}

struct Panel: View {
    @EnvironmentObject var m: Model
    @State var showSettings = false
    @State var tab = UserDefaults.standard.string(forKey: Pref.tab) ?? "battery"

    var body: some View {
        Group {
            if showSettings {
                SettingsPage(back: { showSettings = false })
            } else {
                VStack(spacing: 14) {
                    Picker("", selection: $tab) {
                        Text(L("Battery")).tag("battery")
                        Text(L("Power")).tag("power")
                        Text(L("Devices")).tag("devices")
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .onChange(of: tab) { _, t in UserDefaults.standard.set(t, forKey: Pref.tab) }
                    if tab == "power" {
                        PowerPage(openSettings: { showSettings = true })
                    } else if tab == "devices" {
                        DevicesPage(openSettings: { showSettings = true })
                    } else {
                        MainPage(openSettings: { showSettings = true })
                    }
                }
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

/// Offscreen window that draws its controls in the active (key) state, for --preview.
final class PreviewWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

@main
struct ChargeSurfApp: App {
    @StateObject private var m = Model(live: !CommandLine.arguments.contains("--preview"))

    init() {
        // --preview out.png [--page main|power|devices|settings|onboarding|menubar] [--dark] [--demo sailing|charging|heat|battery]: render to PNG and exit.
        let args = CommandLine.arguments
        // --notify-test: ask for permission if needed and show a sample "fully charged" notification.
        if args.contains("--notify-test") {
            Notifier.shared.setUp()
            Notifier.shared.deviceFull("iPhone", id: "test")
            RunLoop.main.run(until: Date().addingTimeInterval(4))
            exit(0)
        }
        if let i = args.firstIndex(of: "--preview"), i + 1 < args.count {
            let path = args[i + 1]
            let dark = args.contains("--dark")
            let page = args.firstIndex(of: "--page").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "main"
            MainActor.assumeIsolated {
                let model = Model(live: false)
                if let d = args.firstIndex(of: "--demo"), d + 1 < args.count { model.applyDemo(args[d + 1]) }
                if args.contains("--live-devices") { model.loadDevicesNow() }
                let content: AnyView
                switch page {
                case "menubar": content = AnyView(MenuBarLabel().font(.system(size: 13)).padding(.horizontal, 8).padding(.vertical, 3))
                case "settings": content = AnyView(Panel(showSettings: true))
                case "power": content = AnyView(Panel(tab: "power"))
                case "devices": content = AnyView(Panel(tab: "devices"))
                case "onboarding": content = AnyView(OnboardingView())
                default: content = AnyView(Panel(tab: "battery"))
                }
                let v = content.environmentObject(model)
                    .background(page == "menubar" ? Color.clear : Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.controlActiveState, .key)
                // Render through a real (offscreen) window so AppKit-backed controls
                // (switches, icon buttons) are drawn; ImageRenderer leaves placeholders.
                _ = NSApplication.shared
                let host = NSHostingView(rootView: v)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = host.fittingSize
                let win = PreviewWindow(contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                                   styleMask: .borderless, backing: .buffered, defer: false)
                win.appearance = host.appearance
                win.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                host.display()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
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
