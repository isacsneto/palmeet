import AppKit
import ImageIO
import PalMeetCore
import SessionKit
import SwiftUI

enum SessionPalette {
    static let colors: [Color] = [.blue, .orange, .purple, .teal, .pink, .green, .indigo]

    static func color(_ index: Int) -> Color {
        colors[abs(index) % colors.count]
    }

    static func speakerColor(_ speakerID: String) -> Color {
        if speakerID == Speaker.meID { return .accentColor }
        let digits = Int(speakerID.filter(\.isNumber)) ?? speakerID.hashValue
        return colors[(abs(digits) + 2) % colors.count]
    }
}

/// A small horizontal audio level meter.
struct LevelMeter: View {
    var level: Float
    var tint: Color = .green

    var body: some View {
        GeometryReader { proxy in
            let normalized = CGFloat(min(1, sqrt(Double(level)) * 3))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint.gradient).frame(width: proxy.size.width * normalized)
            }
        }
        .frame(width: 44, height: 5)
        .animation(.linear(duration: 0.15), value: level)
        .accessibilityLabel("Audio level")
    }
}

/// Live-updating elapsed time for a session.
struct ElapsedText: View {
    let session: MeetingSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(Timecode.format(session.elapsed))
                .monospacedDigit()
        }
    }
}

/// `NSVisualEffectView` background whose opacity follows the window-appearance settings.
struct GlassBackground: NSViewRepresentable {
    var opacity: Double
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.alphaValue = opacity
    }
}

/// Minimal block-level Markdown renderer for summaries: headings, bullets, tables, quotes, images, paragraphs.
struct MarkdownView: View {
    let markdown: String
    var baseURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum Block {
        case heading(Int, String)
        case bullet(String)
        case quote(String)
        case table([[String]])
        case image(String, String)
        case paragraph(String)
        case rule
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var table: [[String]] = []
        func flushTable() {
            if !table.isEmpty { result.append(.table(table)); table.removeAll() }
        }
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") {
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { table.append(cells) }
                continue
            }
            flushTable()
            if line.isEmpty { continue }
            if line == "---" { result.append(.rule); continue }
            if let match = line.firstMatch(of: /^!\[(.*)\]\((.*)\)$/) {
                result.append(.image(String(match.1), String(match.2).removingPercentEncoding ?? String(match.2)))
            } else if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                result.append(.heading(level, String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                result.append(.bullet(String(line.dropFirst(2))))
            } else if line.hasPrefix(">") {
                result.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                result.append(.paragraph(line))
            }
        }
        flushTable()
        return result
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(level == 1 ? .title.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level <= 2 ? 10 : 4)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inline(text)
            }
        case .quote(let text):
            inline(text)
                .italic()
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            inline(cell).fontWeight(index == 0 ? .semibold : .regular)
                        }
                    }
                    if index == 0 { Divider() }
                }
            }
            .padding(10)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        case .image(let alt, let path):
            if let baseURL {
                ThumbnailImage(url: baseURL.appending(path: path), maxPixel: 1040)
                    .frame(maxWidth: 520)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .help(alt)
            }
        case .paragraph(let text):
            inline(text)
        case .rule:
            Divider()
        }
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}

struct WarningBanner: View {
    let messages: [String]

    var body: some View {
        if let last = messages.last {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(last).font(.callout).lineLimit(2)
                Spacer()
                if messages.count > 1 {
                    Text("+\(messages.count - 1)").font(.caption).foregroundStyle(.secondary)
                        .help(messages.dropLast().joined(separator: "\n"))
                }
            }
            .padding(8)
            .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Downsampled image loaded off the main thread (screenshots are large JPEGs).
struct ThumbnailImage: View {
    let url: URL
    var maxPixel: Int = 640
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 4).fill(.quinary).aspectRatio(16 / 10, contentMode: .fit)
            }
        }
        .task(id: url) { image = await Self.load(url, maxPixel: maxPixel)?.value }
    }

    private struct Box: @unchecked Sendable { let value: NSImage }

    private static func load(_ url: URL, maxPixel: Int) async -> Box? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary)
            else { return nil }
            return Box(value: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
        }.value
    }
}

/// Comma-separated list editor that only commits on Return or when focus leaves, so typing "a, b" works.
struct CommaListField: View {
    let title: String
    let values: [String]
    let commit: ([String]) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $draft)
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { if !focused { save() } }
            .onAppear { draft = values.joined(separator: ", ") }
            .onDisappear(perform: save)
    }

    private func save() {
        let parsed = draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parsed != values { commit(parsed) }
    }
}
