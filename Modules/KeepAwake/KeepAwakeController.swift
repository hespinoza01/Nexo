import Foundation
import IOKit.pwr_mgt

/// Abstraction over IOKit power assertions so the controller can be unit-tested.
protocol PowerAssertionProvider {
    func create(_ type: String, reason: String) -> IOPMAssertionID?
    func release(_ id: IOPMAssertionID)
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
}

/// Keeps the Mac awake with a power assertion, optionally for a limited time.
/// `PreventUserIdleSystemSleep` keeps the machine running with the display allowed to sleep;
/// `PreventUserIdleDisplaySleep` also keeps the display on (and therefore the system too).
/// Visible in `pmset -g assertions` under the reason below.
final class KeepAwakeController {
    static let reason = "Nexo keep awake"

    enum Duration: Int, CaseIterable {
        case minutes30 = 1800
        case hour1 = 3600
        case hours2 = 7200
        case indefinitely = 0

        var title: String {
            switch self {
            case .minutes30: return "30 minutes"
            case .hour1: return "1 hour"
            case .hours2: return "2 hours"
            case .indefinitely: return "Indefinitely"
            }
        }

        var interval: TimeInterval? { self == .indefinitely ? nil : TimeInterval(rawValue) }
    }

    private let provider: PowerAssertionProvider
    private let now: () -> Date
    private var assertionId: IOPMAssertionID?
    private var timer: Timer?
    private(set) var endDate: Date?
    private(set) var keepsDisplayAwake = false
    var onChange: (() -> Void)?

    init(provider: PowerAssertionProvider = IOKitPowerAssertions(), now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.now = now
    }

    var isActive: Bool { assertionId != nil }

    /// Seconds left before the assertion is released, nil when active indefinitely or inactive.
    var remaining: TimeInterval? {
        guard isActive, let endDate else { return nil }
        return max(0, endDate.timeIntervalSince(now()))
    }

    @discardableResult
    func activate(_ duration: Duration, keepDisplayAwake: Bool) -> Bool {
        deactivate(notify: false)
        let type = keepDisplayAwake ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        guard let id = provider.create(type as String, reason: Self.reason) else {
            onChange?()
            return false
        }
        assertionId = id
        keepsDisplayAwake = keepDisplayAwake
        scheduleExpiry(duration.interval)
        onChange?()
        return true
    }

    func deactivate() {
        deactivate(notify: true)
    }

    /// Called by the timer; exposed so tests can expire without waiting.
    func expireIfDue() {
        guard let remaining, remaining <= 0 else { return }
        deactivate()
    }

    private func deactivate(notify: Bool) {
        timer?.invalidate()
        timer = nil
        endDate = nil
        if let assertionId { provider.release(assertionId) }
        let wasActive = assertionId != nil
        assertionId = nil
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
