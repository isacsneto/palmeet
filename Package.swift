// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PalMeet",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "PalMeet", targets: ["PalMeet"]),
        // Everything the app target links; the Xcode project (project.yml) builds the app from this.
        .library(name: "PalMeetKit", targets: [
            "SessionKit", "VisionContext", "CaptureKit", "BrowserBridge",
            "TranscriptKit", "LLMKit", "CopilotKit", "PalMeetCore",
        ]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.4.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.17.7"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // Session models, on-disk layout, Markdown/JSON exporters.
        .target(name: "SessionKit"),
        // OCR and frame change detection for screenshots.
        .target(name: "VisionContext"),
        // Window/app discovery, Core Audio process taps, microphone, window sampling.
        .target(name: "CaptureKit"),
        // Localhost bridge to the companion Chromium extension (per-tab audio/video).
        .target(name: "BrowserBridge"),
        // Speech-to-text, diarization and transcript assembly.
        .target(name: "TranscriptKit", dependencies: [
            "SessionKit",
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        // LLM providers: HTTP APIs and locally logged-in CLIs.
        .target(name: "LLMKit"),
        // Live suggestions: triggers, context building, playbooks.
        .target(name: "CopilotKit", dependencies: ["LLMKit", "SessionKit"]),
        // Session orchestration: SessionManager, MeetingSession, MicRouter, summarizer.
        .target(name: "PalMeetCore", dependencies: [
            "SessionKit", "VisionContext", "CaptureKit", "BrowserBridge",
            "TranscriptKit", "LLMKit", "CopilotKit",
        ]),
        .executableTarget(name: "PalMeet", dependencies: [
            "PalMeetCore",
            .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            .product(name: "Sparkle", package: "Sparkle"),
        ]),

        .testTarget(name: "SessionKitTests", dependencies: ["SessionKit"]),
        .testTarget(name: "VisionContextTests", dependencies: ["VisionContext"]),
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit", "TranscriptKit", "SessionKit"]),
        .testTarget(name: "TranscriptKitTests", dependencies: ["TranscriptKit"]),
        .testTarget(name: "LLMKitTests", dependencies: ["LLMKit"]),
        .testTarget(name: "CopilotKitTests", dependencies: ["CopilotKit"]),
        .testTarget(name: "BrowserBridgeTests", dependencies: ["BrowserBridge"]),
        .testTarget(name: "PalMeetCoreTests", dependencies: ["PalMeetCore", "SessionKit", "LLMKit", "CaptureKit", "TranscriptKit", "BrowserBridge", "CopilotKit", "VisionContext"]),
    ]
)
