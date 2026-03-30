// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MasterOfDrumsPipeline",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MasterOfDrumsPipeline", targets: ["PipelineService"]),
        .library(name: "PipelineDomain", targets: ["PipelineDomain"]),
        .library(name: "PipelineApplication", targets: ["PipelineApplication"]),
        .library(name: "PipelineInfrastructure", targets: ["PipelineInfrastructure"]),
        .library(name: "PipelineRuntime", targets: ["PipelineRuntime"])
    ],
    targets: [
        .target(
            name: "PipelineDomain",
            path: "Sources/PipelineDomain"
        ),
        .target(
            name: "PipelineApplication",
            dependencies: ["PipelineDomain"],
            path: "Sources/PipelineApplication"
        ),
        .target(
            name: "PipelineInfrastructure",
            dependencies: ["PipelineDomain", "PipelineApplication"],
            path: "Sources/PipelineInfrastructure",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "PipelineRuntime",
            dependencies: ["PipelineDomain", "PipelineApplication", "PipelineInfrastructure"],
            path: "Sources/PipelineRuntime",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia")
            ]
        ),
        .executableTarget(
            name: "PipelineService",
            dependencies: ["PipelineRuntime"],
            path: "Sources/PipelineService"
        )
    ]
)
