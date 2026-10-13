import Testing
@testable import PalMeetCore

@Suite struct HideCoordinatorTests {
    typealias Coordinator = HideCoordinator<String>

    @Test func panicHidesAndRestoresExactlyWhatWasVisible() {
        var c = Coordinator()
        #expect(c.togglePanic(visible: ["main", "copilot"]) == .init(hide: ["main", "copilot"]))
        #expect(!c.allowsShowing)
        #expect(c.togglePanic(visible: []) == .init(show: ["main", "copilot"]))
        #expect(c.allowsShowing)
    }

    @Test func autoHideWhilePresenting() {
        var c = Coordinator()
        #expect(c.presentingChanged(true, visible: ["main", "copilot", "settings"]).hide == ["main", "copilot", "settings"])
        #expect(c.presentingChanged(true, visible: []) == .init(), "repeated presenting=true is a no-op")
        #expect(c.presentingChanged(false, visible: []).show == ["main", "copilot", "settings"])
    }

    /// The reviewed bug: panic during presenting, then presenting ends → panic-hidden windows must stay hidden,
    /// and un-panicking later restores everything.
    @Test func panicDuringPresentingKeepsEverythingHiddenUntilBothEnd() {
        var c = Coordinator()
        _ = c.presentingChanged(true, visible: ["main", "copilot"])
        #expect(c.togglePanic(visible: ["cheatsheet"]).hide == ["cheatsheet"])
        #expect(c.presentingChanged(false, visible: []) == .init(), "panic still active: show nothing")
        #expect(!c.allowsShowing)
        #expect(c.togglePanic(visible: []).show == ["main", "copilot", "cheatsheet"])
        #expect(c.allowsShowing)
    }

    @Test func unpanicWhilePresentingDefersRestore() {
        var c = Coordinator()
        _ = c.togglePanic(visible: ["main"])
        _ = c.presentingChanged(true, visible: [])
        #expect(c.togglePanic(visible: []) == .init(), "still presenting: don't flash windows onto the share")
        #expect(c.presentingChanged(false, visible: []).show == ["main"])
    }

    @Test func windowsShownDuringHidingAreTracked() {
        var c = Coordinator()
        _ = c.togglePanic(visible: ["main"])
        c.adopt("quicknote")
        #expect(c.togglePanic(visible: []).show == ["main", "quicknote"])
        _ = c.togglePanic(visible: ["main"])
        c.forget("main")
        #expect(c.togglePanic(visible: []).show == [])
    }
}
