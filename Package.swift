// swift-tools-version: 6.2
import PackageDescription

/// PulseDock is a single Swift package with one library target per architectural module.
/// See docs/decisions/0001-swiftpm-modular-layout.md for why this replaces the
/// `Packages/<Module>` layout sketched in the product brief.
let mainActorByDefault: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "PulseDock",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "PulseDock", targets: ["PulseDock"]),
        .executable(name: "pulsedock-hook", targets: ["PulseDockHook"]),
        .executable(name: "pulsedockctl", targets: ["PulseDockCtl"]),
    ],
    targets: [
        // MARK: Foundation-only core (no AppKit); safe to link into the hook helper.
        .target(name: "Diagnostics"),
        .target(name: "AgentCore"),
        .target(name: "AgentBridge"),
        .target(name: "AdapterSupport", dependencies: ["AgentCore", "AgentBridge"]),
        .target(name: "Persistence", dependencies: ["AgentCore", "Diagnostics"]),
        .target(name: "ClaudeCodeAdapter", dependencies: ["AgentCore", "AgentBridge", "AdapterSupport", "Diagnostics"]),
        .target(name: "CodexAdapter", dependencies: ["AgentCore", "AgentBridge", "AdapterSupport", "Diagnostics"]),

        // MARK: macOS UI layers.
        .target(name: "DockRendering", swiftSettings: mainActorByDefault),
        .target(name: "DockCore", dependencies: ["Diagnostics"], swiftSettings: mainActorByDefault),
        .target(name: "WidgetCore", dependencies: ["Diagnostics", "DockCore"], swiftSettings: mainActorByDefault),
        .target(
            name: "PulseDockApp",
            dependencies: [
                "Diagnostics", "AgentCore", "AgentBridge", "AdapterSupport", "Persistence",
                "ClaudeCodeAdapter", "CodexAdapter", "DockRendering", "DockCore", "WidgetCore",
            ],
            swiftSettings: mainActorByDefault
        ),

        // MARK: Executables.
        .executableTarget(name: "PulseDock", dependencies: ["PulseDockApp"], swiftSettings: mainActorByDefault),
        .executableTarget(name: "PulseDockHook", dependencies: ["AgentBridge"]),
        .executableTarget(name: "PulseDockCtl", dependencies: ["AgentBridge", "AgentCore", "ClaudeCodeAdapter", "CodexAdapter", "AdapterSupport"]),

        // MARK: Tests.
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"]),
        .testTarget(name: "AgentBridgeTests", dependencies: ["AgentBridge"]),
        .testTarget(
            name: "ClaudeCodeAdapterTests",
            dependencies: ["ClaudeCodeAdapter", "AdapterSupport", "AgentBridge", "AgentCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "CodexAdapterTests", dependencies: ["CodexAdapter", "AdapterSupport", "AgentBridge", "AgentCore"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "AgentCore"]),
        .testTarget(name: "DockRenderingTests", dependencies: ["DockRendering"]),
    ]
)
