import Foundation
import IOKit.pwr_mgt

/// Abstraction over IOKit power assertions so the controller can be unit-tested.
protocol PowerAssertionProvider {
    func create(_ type: String, reason: String) -> IOPMAssertionID?
    func release(_ id: IOPMAssertionID)
    /// Tells macOS the user is active: resets the idle timer behind the screen saver, the idle lock
    /// and "away" status in chat apps. Returns the short-lived assertion it creates, if any.
    func declareUserActivity(reason: String) -> IOPMAssertionID?
}

struct IOKitPowerAssertions: PowerAssertionProvider {
    func create(_ type: String, reason: String) -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        return status == kIOReturnSuccess ? id : nil
    }

    func release(_ id: IOPMAssertionID) {
        IOPMAssertionRelease(id)
    }

    func declareUserActivity(reason: String) -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let status = IOPMAssertionDeclareUserActivity(reason as CFString, kIOPMUserActiveLocal, &id)
        return status == kIOReturnSuccess ? id : nil
    }
}

/// Keeps the Mac awake with power assertions, optionally for a limited time. Like Vorssaint it holds
/// `PreventUserIdleSystemSleep` for the whole session and, unless the display may sleep, also
/// `PreventUserIdleDisplaySleep`. Optionally it declares user activity periodically so the screen saver,
/// the idle lock and chat "away" status never kick in. Listed by `pmset -g assertions` under `reason`.
final class KeepAwakeController {
    static let reason = "Nexo keep awake"
    static let displayReason = "Nexo keep the display on"

    enum Duration: Int, CaseIterable {
        case minutes15 = 900
        case minutes30 = 1800
        case hour1 = 3600
        case hours2 = 7200
        case hours4 = 14400
        case hours8 = 28800
        case indefinitely = 0

        var title: String {
            switch self {
            case .minutes15: return "15 minutes"
            case .minutes30: return "30 minutes"
            case .hour1: return "1 hour"
            case .hours2: return "2 hours"
            case .hours4: return "4 hours"
            case .hours8: return "8 hours"
            case .indefinitely: return "Indefinitely"
            }
        }

        var interval: TimeInterval? { self == .indefinitely ? nil : TimeInterval(rawValue) }
    }

    private let provider: PowerAssertionProvider
    private let now: () -> Date
    private var systemAssertion: IOPMAssertionID?
    private var displayAssertion: IOPMAssertionID?
    private var timer: Timer?
    private var activityTimer: Timer?
    private(set) var isActive = false
    /// Assertions released while the screen is locked; the session (and its end time) continues.
    private(set) var isPaused = false
    private(set) var endDate: Date?
    private(set) var keepsDisplayAwake = false
    /// Seconds between user-activity declarations; 0 = off.
    private(set) var activityInterval: TimeInterval = 0
    var onChange: (() -> Void)?

    init(provider: PowerAssertionProvider = IOKitPowerAssertions(), now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.now = now
    }

    /// Seconds left before the session ends, nil when active indefinitely or inactive.
    var remaining: TimeInterval? {
        guard isActive, let endDate else { return nil }
        return max(0, endDate.timeIntervalSince(now()))
    }

    @discardableResult
    func activate(_ duration: Duration, keepDisplayAwake: Bool, activityEvery minutes: Int = 0) -> Bool {
        activate(for: duration.interval, keepDisplayAwake: keepDisplayAwake, activityEvery: minutes)
    }

    /// `interval` nil = until turned off. Used directly to resume a saved session with the time it had left.
    @discardableResult
    func activate(for interval: TimeInterval?, keepDisplayAwake: Bool, activityEvery minutes: Int = 0) -> Bool {
        deactivate(notify: false)
        keepsDisplayAwake = keepDisplayAwake
        guard acquireAssertions() else {
            releaseAssertions()
            onChange?()
            return false
        }
        isActive = true
        scheduleExpiry(interval)
        setActivityInterval(minutes)
        onChange?()
        return true
    }

    func deactivate() {
        deactivate(notify: true)
    }

    /// Adds or drops the display assertion of a running session without restarting its timer.
    func setKeepDisplayAwake(_ on: Bool) {
        keepsDisplayAwake = on
        guard isActive, !isPaused else { return }
        if on, displayAssertion == nil {
            displayAssertion = provider.create(kIOPMAssertionTypePreventUserIdleDisplaySleep as String, reason: Self.displayReason)
        } else if !on, let displayAssertion {
            provider.release(displayAssertion)
            self.displayAssertion = nil
        }
        onChange?()
    }

    /// Starts or stops the periodic user-activity declaration (0 = off) for a running session.
    func setActivityInterval(_ minutes: Int) {
        activityTimer?.invalidate()
        activityTimer = nil
        activityInterval = TimeInterval(max(0, minutes) * 60)
        guard isActive, !isPaused, activityInterval > 0 else { return }
        declareActivity()
        let timer = Timer(timeInterval: activityInterval, repeats: true) { [weak self] _ in self?.declareActivity() }
        timer.tolerance = min(10, activityInterval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        activityTimer = timer
    }

    /// Screen locked: let the Mac sleep as usual until it is unlocked again (the end time keeps running).
    func pause() {
        guard isActive, !isPaused else { return }
        isPaused = true
        releaseAssertions()
        activityTimer?.invalidate()
        activityTimer = nil
        onChange?()
    }

    func resume() {
        guard isActive, isPaused else { return }
        isPaused = false
        guard acquireAssertions() else {
            // Never claim to be on without an assertion.
            deactivate()
            return
        }
        setActivityInterval(Int(activityInterval / 60))
        onChange?()
    }

    /// Called by the timer; exposed so tests can expire without waiting.
    func expireIfDue() {
        guard let remaining, remaining <= 0 else { return }
        deactivate()
    }

    /// Exposed for tests; the activity timer calls it.
    func declareActivity() {
        guard isActive, !isPaused, let id = provider.declareUserActivity(reason: Self.reason) else { return }
        // The declaration only needs to reset the idle timer; don't keep the assertion around.
        provider.release(id)
    }

    private func acquireAssertions() -> Bool {
        if systemAssertion == nil {
            systemAssertion = provider.create(kIOPMAssertionTypePreventUserIdleSystemSleep as String, reason: Self.reason)
        }
        if keepsDisplayAwake, displayAssertion == nil {
            displayAssertion = provider.create(kIOPMAssertionTypePreventUserIdleDisplaySleep as String, reason: Self.displayReason)
        }
        return systemAssertion != nil && (!keepsDisplayAwake || displayAssertion != nil)
    }

    private func releaseAssertions() {
        if let systemAssertion { provider.release(systemAssertion) }
        if let displayAssertion { provider.release(displayAssertion) }
        systemAssertion = nil
        displayAssertion = nil
    }

    private func deactivate(notify: Bool) {
        timer?.invalidate()
        timer = nil
        activityTimer?.invalidate()
        activityTimer = nil
        endDate = nil
        releaseAssertions()
        let wasActive = isActive
        isActive = false
        isPaused = false
        if notify && wasActive { onChange?() }
    }

    private func scheduleExpiry(_ interval: TimeInterval?) {
        guard let interval else { return }
        endDate = now().addingTimeInterval(interval)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in self?.deactivate() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
