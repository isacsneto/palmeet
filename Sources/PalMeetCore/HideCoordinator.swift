import Foundation

/// Decides which windows to hide/show for panic hide and auto-hide-while-presenting, independently of AppKit.
///
/// Rules:
/// - While either mode is active, nothing PalMeet shows may appear (`allowsShowing == false`).
/// - Each mode remembers what *it* hid; ending one mode never reveals windows the other still wants hidden.
/// - Ending both restores exactly the windows that were visible before.
public struct HideCoordinator<ID: Hashable & Sendable>: Sendable {
    public private(set) var isPanicActive = false
    public private(set) var isAutoHideActive = false
    private var panicHidden: Set<ID> = []
    private var autoHidden: Set<ID> = []

    public init() {}

    public struct Actions: Equatable, Sendable {
        public var hide: Set<ID> = []
        public var show: Set<ID> = []

        public init(hide: Set<ID> = [], show: Set<ID> = []) {
            self.hide = hide
            self.show = show
        }

        public var isEmpty: Bool { hide.isEmpty && show.isEmpty }
    }

    public var allowsShowing: Bool { !isPanicActive && !isAutoHideActive }

    /// Toggles panic hide. `visible` = windows currently on screen.
    public mutating func togglePanic(visible: Set<ID>) -> Actions {
        if isPanicActive {
            isPanicActive = false
            defer { panicHidden = [] }
            if isAutoHideActive {
                // Still presenting: keep them hidden until presenting ends.
                autoHidden.formUnion(panicHidden)
                return Actions()
            }
            return Actions(show: panicHidden)
        }
        isPanicActive = true
        panicHidden = visible
        return Actions(hide: visible)
    }

    /// Presenting state changed (auto-hide enabled). `visible` = windows currently on screen.
    public mutating func presentingChanged(_ presenting: Bool, visible: Set<ID>) -> Actions {
        if presenting, !isAutoHideActive {
            isAutoHideActive = true
            autoHidden = visible
            return Actions(hide: visible)
        }
        if !presenting, isAutoHideActive {
            isAutoHideActive = false
            defer { autoHidden = [] }
            if isPanicActive {
                panicHidden.formUnion(autoHidden)
                return Actions()
            }
            return Actions(show: autoHidden)
        }
        return Actions()
    }

    /// A window that should have stayed hidden was shown (e.g. by a hotkey) while hiding is active: track it.
    public mutating func adopt(_ id: ID) {
        if isPanicActive { panicHidden.insert(id) } else if isAutoHideActive { autoHidden.insert(id) }
    }

    /// A tracked window was closed for good.
    public mutating func forget(_ id: ID) {
        panicHidden.remove(id)
        autoHidden.remove(id)
    }
}
