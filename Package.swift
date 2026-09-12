// swift-tools-version: 6.1
// 6.1, not 6.2: nothing here needs 6.2, and GitHub's macos-15 runners ship 6.1.
// Raising this floor would break CI on the default runner image.
import PackageDescription

let package = Package(
    name: "AgentPetRuntime",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentPetCore", targets: ["AgentPetCore"]),
        .executable(name: "AgentPet", targets: ["AgentPetApp"]),
        .executable(name: "agentpet-hook", targets: ["agentpet-hook"]),
    ],
    targets: [
        // Pure logic. Must not import AppKit — keeps the whole core testable headlessly.
        .target(name: "AgentPetCore"),

        .executableTarget(
            name: "AgentPetApp",
            dependencies: ["AgentPetCore"]
        ),

        // Invoked by agents as a hook. Must stay fast and must always exit 0.
        .executableTarget(
            name: "agentpet-hook",
            dependencies: ["AgentPetCore"]
        ),

        .testTarget(
            name: "AgentPetCoreTests",
            dependencies: ["AgentPetCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
