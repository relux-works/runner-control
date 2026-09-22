import Foundation
import Testing
@testable import RunnerControlCore

private func bridgeSuite() -> UserDefaults {
    // swiftlint:disable:next force_unwrapping
    UserDefaults(suiteName: "works.relux.runnercontrol.test.bridge." + UUID().uuidString)!
}

@Test func bridgeStartsUnknown() {
    let defaults = bridgeSuite()
    let status = LoginItemBridge.read(defaults: defaults)
    #expect(status.applied == nil && status.desired == nil && status.appliedAt == nil)
    #expect(!status.pending)
    #expect(LoginItemBridge.effective(status) == .unknown)
}

@Test func bridgeRequestIsPendingUntilMirrored() {
    let defaults = bridgeSuite()
    LoginItemBridge.request(true, defaults: defaults)
    var status = LoginItemBridge.read(defaults: defaults)
    #expect(status.pending)
    #expect(LoginItemBridge.effective(status) == .pending(desired: true))
    // GUI applies: clears the request, mirrors actual.
    LoginItemBridge.clearRequest(defaults: defaults)
    LoginItemBridge.mirror(applied: true, defaults: defaults)
    status = LoginItemBridge.read(defaults: defaults)
    #expect(!status.pending)
    #expect(status.appliedAt != nil)
    guard case .on = LoginItemBridge.effective(status) else {
        Issue.record("expected on, got \(LoginItemBridge.effective(status))"); return
    }
}

@Test func bridgeGuiToggleConvergesWithoutRequest() {
    // Toggled in the GUI (or System Settings + GUI refresh): no outstanding
    // request, mirror carries the state.
    let defaults = bridgeSuite()
    LoginItemBridge.mirror(applied: false, defaults: defaults)
    let status = LoginItemBridge.read(defaults: defaults)
    #expect(!status.pending)
    guard case .off = LoginItemBridge.effective(status) else {
        Issue.record("expected off, got \(LoginItemBridge.effective(status))"); return
    }
}

@Test func bridgeInFlightChangeStaysPending() {
    // Applied on, then CLI requests off: pending until the GUI applies.
    let defaults = bridgeSuite()
    LoginItemBridge.mirror(applied: true, defaults: defaults)
    LoginItemBridge.request(false, defaults: defaults)
    let status = LoginItemBridge.read(defaults: defaults)
    #expect(status.pending)
    #expect(LoginItemBridge.effective(status) == .pending(desired: false))
}

@Test func bridgeNotificationNameIsStable() {
    #expect(LoginItemBridge.applyNotification.rawValue == "works.relux.runnercontrol.applyLoginItem")
}
