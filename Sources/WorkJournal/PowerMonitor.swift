import AppKit
import IOKit.ps
import JournalCore

/// Event-driven: no polling or background wake-up timer.
@MainActor final class PowerMonitor {
    private var runLoopSource: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []
    private var wakeObserver: NSObjectProtocol?
    private let onChange: (PowerSnapshot) -> Void
    init(onChange: @escaping (PowerSnapshot) -> Void) { self.onChange = onChange }
    func start() {
        stop()
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in monitor.refresh() }
        }, context)?.takeRetainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification, NSApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }
    func refresh() {
        var source: PowerSource = .unknown
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() {
            switch type as String {
            case kIOPSACPowerValue: source = .external
            case kIOPSBatteryPowerValue: source = .battery
            default: source = .unknown
            }
        }
        let process = ProcessInfo.processInfo
        onChange(PowerSnapshot(source: source, lowPower: process.isLowPowerModeEnabled,
                               hot: process.thermalState == .serious || process.thermalState == .critical))
    }
    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        runLoopSource = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }
}
