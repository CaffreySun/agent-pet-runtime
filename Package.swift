// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentPetRuntime",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentPetCore", targets: ["AgentPetCore"]),
        .executable(name: "AgentPet", targets: ["AgentPetApp"]),
    ],
    targets: [
        // Pure logic. Must not import AppKit — keeps the whole core testable headlessly.
        .target(name: "AgentPetCore"),

        .executableTarget(
            name: "AgentPetApp",
            dependencies: ["AgentPetCore"]
        ),

        .testTarget(
            name: "AgentPetCoreTests",
            dependencies: ["AgentPetCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
