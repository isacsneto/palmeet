import ApplicationServices
import Foundation

/// Reads mute / screen-sharing state from desktop meeting apps through the Accessibility API (best effort).
///
/// Browser meetings get this from the extension instead. Requires the Accessibility permission; returns unknown
/// (nil) for anything it can't determine.
public enum MeetingStateInspector {
    public struct State: Sendable, Equatable {
        public var muted: Bool?
        public var presenting: Bool?
    }

    public static var isAvailable: Bool { AXIsProcessTrusted() }

    public static func state(bundleID: String?, pid: pid_t) -> State {
        guard isAvailable else { return State() }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        switch bundleID {
        case "us.zoom.xos":
            // Zoom mirrors its controls in the menu bar ("Meeting" menu): "Mute Audio"/"Unmute Audio", "Stop Share".
            let titles = menuItemTitles(app, maxNodes: 600)
            return State(
                muted: titles.contains { $0.hasPrefix("unmute audio") } ? true : (titles.contains { $0.hasPrefix("mute audio") } ? false : nil),
                presenting: titles.contains { $0.hasPrefix("stop share") } ? true : (titles.contains { $0.hasPrefix("start share") } ? false : nil)
            )
        case let id? where id.hasPrefix("com.microsoft.teams"):
            // Teams labels its call buttons "Mute (⌘⇧M)" / "Unmute (⌘⇧M)" and "Stop sharing".
            let labels = buttonLabels(app, maxNodes: 2_500)
            let muted: Bool? = labels.contains { $0.hasPrefix("unmute") } ? true : (labels.contains { $0.hasPrefix("mute") } ? false : nil)
            let presenting: Bool? = labels.contains { $0.contains("stop sharing") || $0.contains("stop presenting") } ? true : nil
            return State(muted: muted, presenting: presenting)
        default:
            return State()
        }
    }

    // MARK: - Tree walking

    private static func menuItemTitles(_ app: AXUIElement, maxNodes: Int) -> [String] {
        guard let menuBar = elementAttribute(app, kAXMenuBarAttribute) else { return [] }
        var titles: [String] = []
        walk(menuBar, maxNodes: maxNodes) { element in
            if let title: String = attribute(element, kAXTitleAttribute), !title.isEmpty {
                titles.append(title.lowercased())
            }
        }
        return titles
    }

    private static func buttonLabels(_ app: AXUIElement, maxNodes: Int) -> [String] {
        guard let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) else { return [] }
        var labels: [String] = []
        for window in windows {
            walk(window, maxNodes: maxNodes) { element in
                guard let role: String = attribute(element, kAXRoleAttribute), role == kAXButtonRole as String else { return }
                for key in [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute] {
                    if let label: String = attribute(element, key), !label.isEmpty { labels.append(label.lowercased()) }
                }
            }
        }
        return labels
    }

    private static func walk(_ root: AXUIElement, maxNodes: Int, visit: (AXUIElement) -> Void) {
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < maxNodes {
            let element = queue.removeFirst()
            visited += 1
            visit(element)
            if let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) {
                queue.append(contentsOf: children)
            }
        }
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
