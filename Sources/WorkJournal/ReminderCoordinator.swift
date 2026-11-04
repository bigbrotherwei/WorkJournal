import Foundation
import UserNotifications
import Combine
import JournalCore

enum ReminderAuthorizationStatus: Equatable {
    case unknown, notDetermined, authorized, denied, unavailable
    var message: String {
        switch self {
        case .unknown: return "正在检查通知权限"
        case .notDetermined: return "保存启用提醒的记录时，将请求通知权限"
        case .authorized: return "已允许通知，将在截止时间提醒"
        case .denied: return "通知未获允许，记录仍会保存；可在系统设置 → 通知中允许工作随记"
        case .unavailable: return "当前无法使用通知，记录仍会保存"
        }
    }
}

@MainActor final class ReminderCoordinator: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var status: ReminderAuthorizationStatus = .unknown
    @Published private(set) var schedulingError: String?
    @Published private(set) var testFeedback: String?
    @Published private(set) var sendingTest = false
    var onOpenEntry: ((UUID) -> Void)?
    private var latestEntries: [Entry] = []
    private var revision = 0
    private var processing = false
    private var authorizationRequest: Task<Void, Never>?
    private var deliveryCheck: Task<Void, Never>?
    private var center: UNUserNotificationCenter? {
        // SwiftPM command line fixtures have no bundle identity and cannot use this API.
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }
    override init() {
        super.init()
        center?.delegate = self
        Task { await refreshAuthorization() }
    }
    func refreshAuthorization() async {
        guard let center else { status = .unavailable; return }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: status = .authorized
        case .denied: status = .denied
        case .notDetermined: status = .notDetermined
        @unknown default: status = .unavailable
        }
    }
    // Call only following an explicit reminder toggle/save or a settings button.
    func requestAuthorization() async {
        if let authorizationRequest { await authorizationRequest.value; return }
        let task = Task { [weak self] in
            guard let self, let center = self.center else { self?.status = .unavailable; return }
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
            catch { self.schedulingError = error.localizedDescription }
            await self.refreshAuthorization()
            self.reconcile(entries: self.latestEntries)
        }
        authorizationRequest = task
        await task.value
        authorizationRequest = nil
    }
    // Explicit settings-button action only; never run during startup or reconciliation.
    func sendTestNotification() async {
        guard !sendingTest else { return }
        deliveryCheck?.cancel()
        sendingTest = true
        defer { sendingTest = false }
        await refreshAuthorization()
        guard status == .authorized, let center else {
            testFeedback = "测试未发送：请先允许通知。记录和提醒设置不受影响。"
            return
        }
        center.removeDeliveredNotifications(withIdentifiers: ["workjournal.notification-test"])
        let content = UNMutableNotificationContent()
        content.title = "工作随记 · 通知测试"
        content.body = "这是一条测试通知，你的待办记录没有变化。"
        content.sound = .default
        // Separate namespace prevents task reconciliation from removing this test.
        let request = UNNotificationRequest(identifier: "workjournal.notification-test",
            content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false))
        do {
            try await center.add(request)
            testFeedback = "已安排测试，约 5 秒后显示；若未出现，请检查系统通知设置或专注模式。"
            deliveryCheck = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 6_000_000_000) } catch { return }
                await self?.refreshTestDelivery()
            }
        } catch {
            testFeedback = "测试通知未能安排：" + error.localizedDescription
        }
    }
    func refreshTestDelivery() async {
        guard let center else { return }
        let delivered = await center.deliveredNotifications()
        if delivered.contains(where: { $0.request.identifier == "workjournal.notification-test" }) {
            testFeedback = "系统已投递测试通知（可在通知中心查看）"
        }
    }
    func reconcile(entries: [Entry]) {
        latestEntries = entries; revision += 1
        guard !processing else { return }
        processing = true
        Task { await drain() }
    }
    private func drain() async {
        defer { processing = false }
        guard let center else { status = .unavailable; return }
        while true {
            let version = revision
            let entries = latestEntries
            await refreshAuthorization()
            let pending = await center.pendingNotificationRequests()
            let delivered = await center.deliveredNotifications()
            guard version == revision else { continue }
            let activeEntries = entries.filter(ReminderPolicy.isActive)
            let byIdentifier = Dictionary(uniqueKeysWithValues: activeEntries.map { (ReminderPolicy.identifier(for: $0.id), $0) })
            let own = pending.filter { $0.identifier.hasPrefix(ReminderPolicy.identifierPrefix) }
            let preserved = Set(own.filter { request in
                guard let entry = byIdentifier[request.identifier] else { return false }
                let timestamp = (request.content.userInfo["dueTimestamp"] as? NSNumber)?.doubleValue
                return ReminderPolicy.matchesPending(entry, dueTimestamp: timestamp, body: request.content.body)
            }.map(\.identifier))
            center.removePendingNotificationRequests(withIdentifiers: own.map(\.identifier).filter { !preserved.contains($0) })
            center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }.filter {
                $0.hasPrefix(ReminderPolicy.identifierPrefix) && byIdentifier[$0] == nil
            })
            schedulingError = nil
            if status == .authorized {
                for entry in entries where ReminderPolicy.shouldSchedule(entry) && !preserved.contains(ReminderPolicy.identifier(for: entry.id)) {
                    guard version == revision else { break }
                    let content = UNMutableNotificationContent()
                    content.title = "待处理事项到期"
                    content.body = ReminderPolicy.notificationBody(for: entry)
                    content.sound = .default
                    content.userInfo = ["entryID": entry.id.uuidString, "dueTimestamp": entry.dueAt!.timeIntervalSince1970]
                    guard let due = entry.dueAt, due > Date() else { continue }
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, due.timeIntervalSinceNow), repeats: false)
                    do { try await center.add(UNNotificationRequest(identifier: ReminderPolicy.identifier(for: entry.id), content: content, trigger: trigger)) }
                    catch { schedulingError = "提醒未能安排：" + error.localizedDescription }
                }
            }
            if revision == version { return }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let value = response.notification.request.content.userInfo["entryID"] as? String
        Task { @MainActor [weak self] in
            if let value, let id = UUID(uuidString: value) { self?.onOpenEntry?(id) }
        }
        completionHandler()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.identifier == "workjournal.notification-test" {
            Task { @MainActor [weak self] in
                self?.testFeedback = "系统已投递测试通知（可在通知中心查看）"
            }
        }
        completionHandler([.banner, .sound])
    }
}
