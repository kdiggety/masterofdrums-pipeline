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
        .library(name: "PipelineHTTP", targets: ["PipelineHTTP"]),
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
            path: "Sources/PipelineInfrastructure"
        ),
        .target(
            name: "PipelineHTTP",
            dependencies: ["PipelineDomain", "PipelineApplication"],
            path: "Sources/PipelineHTTP"
        ),
        .target(
            name: "PipelineRuntime",
            dependencies: ["PipelineDomain", "PipelineApplication", "PipelineInfrastructure"],
            path: "Sources/PipelineRuntime"
        ),
        .executableTarget(
            name: "PipelineService",
            dependencies: ["PipelineRuntime", "PipelineHTTP", "PipelineInfrastructure"],
            path: "Sources/PipelineService"
        )
    ]
)
