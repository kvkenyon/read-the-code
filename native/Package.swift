// swift-tools-version: 6.0
import PackageDescription

let libraryTargets = [
    "RTCContracts",
    "RTCDomain",
    "RTCStore",
    "RTCIPC",
    "RTCGit",
    "RTCSyntax",
    "RTCDiffCanvas",
    "RTCDiagram",
    "RTCTour",
    "RTCTourIntegration",
    "TourWorkspace",
    "RTCModelAdapters",
    "RTCAgentChat",
    "RTCReview",
    "RTCDesign",
    "RTCLifecycle",
    "RTCSettings",
    "RTCIngest",
    "RTCInboxFeature",
    "RTCWorkspaceShell",
    "RTCReviewWorkspace",
    "RTCCLI",
    "GitWorker",
    "ModelWorker",
    "RTCTestSupport",
]

let package = Package(
    name: "ReadTheCodeNative",
    platforms: [.macOS(.v14)],
    products: libraryTargets.map { .library(name: $0, targets: [$0]) } + [
        .executable(name: "ReadTheCode", targets: ["ReadTheCode"]),
        .executable(name: "rtc", targets: ["rtc"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.6.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.6.0"),
    ],
    targets: [
        .target(name: "RTCContracts"),
        .target(name: "RTCDomain", dependencies: ["RTCContracts"]),
        .target(
            name: "RTCStore",
            dependencies: [
                "RTCContracts",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [.copy("Resources")]
        ),
        .target(name: "RTCIPC", dependencies: ["RTCContracts"]),
        .target(name: "RTCGit", dependencies: ["RTCContracts"]),
        .target(name: "RTCSyntax", dependencies: ["RTCContracts"]),
        .target(name: "RTCDiffCanvas", dependencies: ["RTCContracts"]),
        .target(name: "RTCDiagram", dependencies: ["RTCContracts"]),
        .target(name: "RTCTour", dependencies: ["RTCContracts", "RTCDiagram"]),
        .target(
            name: "RTCTourIntegration",
            dependencies: [
                "RTCContracts",
                "RTCDiagram",
                "RTCGit",
                "RTCModelAdapters",
                "RTCStore",
                "RTCSyntax",
                "RTCTour",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "TourWorkspace",
            dependencies: ["RTCContracts", "RTCDesign", "RTCDiagram", "RTCTourIntegration"],
            path: "Features/TourWorkspace"
        ),
        .target(name: "RTCModelAdapters", dependencies: ["RTCContracts"]),
        .target(name: "RTCAgentChat", dependencies: ["RTCContracts", "RTCIPC"]),
        .target(name: "RTCReview", dependencies: ["RTCContracts", "RTCDomain"]),
        .target(name: "RTCDesign"),
        .target(name: "RTCLifecycle", dependencies: ["RTCContracts"]),
        .target(name: "RTCSettings", dependencies: ["RTCContracts", "RTCModelAdapters", "RTCLifecycle"]),
        .target(
            name: "RTCIngest",
            dependencies: [
                "RTCContracts",
                "RTCGit",
                "RTCIPC",
                "RTCLifecycle",
                "RTCStore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "RTCInboxFeature",
            dependencies: ["RTCContracts", "RTCDesign", "RTCIngest"],
            path: "Features/Inbox"
        ),
        .target(name: "RTCWorkspaceShell", dependencies: ["RTCDesign", "RTCContracts", "RTCAgentChat"]),
        .target(name: "RTCReviewWorkspace", dependencies: ["RTCContracts", "RTCDomain", "RTCReview", "RTCSyntax", "RTCDiffCanvas", "RTCDesign", "RTCWorkspaceShell"]),
        .target(
            name: "RTCCLI",
            dependencies: ["RTCContracts", "RTCIngest", "RTCIPC"],
            path: "CLI/rtc",
            exclude: ["main.swift"],
            sources: ["RTCCLI.swift"]
        ),
        .target(
            name: "GitWorker",
            dependencies: ["RTCContracts", "RTCGit"],
            path: "Services/GitWorker"
        ),
        .target(
            name: "ModelWorker",
            dependencies: ["RTCContracts", "RTCModelAdapters"],
            path: "Services/ModelWorker"
        ),
        .target(
            name: "RTCTestSupport",
            dependencies: ["RTCContracts"],
            path: "Tests/RTCTestSupport"
        ),
        .executableTarget(
            name: "ReadTheCode",
            dependencies: [
                "RTCContracts",
                "RTCDomain",
                "RTCStore",
                "RTCIPC",
                "RTCReview",
                "RTCDesign",
                "RTCInboxFeature",
                "RTCIngest",
                "RTCLifecycle",
                "RTCSettings",
            ],
            path: "App/ReadTheCodeApp"
        ),
        .executableTarget(
            name: "rtc",
            dependencies: ["RTCCLI"],
            path: "CLI/rtc",
            exclude: ["RTCCLI.swift"],
            sources: ["main.swift"]
        ),

        // XCTest modules run when a full Xcode toolchain provides XCTest.
        .testTarget(name: "RTCAgentChatTests", dependencies: ["RTCContracts", "RTCAgentChat"]),
        .testTarget(name: "RTCDesignTests", dependencies: ["RTCDesign"]),
        .testTarget(name: "RTCGitTests", dependencies: ["RTCContracts", "RTCGit"]),
        .testTarget(name: "RTCModelAdapterTests", dependencies: ["RTCContracts", "RTCModelAdapters"]),
        .testTarget(name: "RTCStoreTests", dependencies: ["RTCStore"]),
        .testTarget(name: "RTCWorkspaceShellTests", dependencies: ["RTCWorkspaceShell"]),
        .testTarget(name: "RTCSettingsTests", dependencies: ["RTCSettings"]),
        .testTarget(name: "TourWorkspaceUITests", dependencies: []),
        // The landed smoke modules intentionally own their entry points. The native gate
        // runs every one after building the graph.
        .executableTarget(name: "RTCCLITests", dependencies: ["RTCCLI"], path: "Tests/RTCCLITests"),
        .executableTarget(
            name: "RTCContractTests",
            dependencies: ["RTCContracts", "RTCTestSupport"],
            path: "Tests/RTCContractTests"
        ),
        .executableTarget(name: "RTCDiagramTests", dependencies: ["RTCContracts", "RTCDiagram"], path: "Tests/RTCDiagramTests"),
        .executableTarget(name: "RTCDiffCanvasTests", dependencies: ["RTCContracts", "RTCDiffCanvas"], path: "Tests/RTCDiffCanvasTests"),
        .executableTarget(name: "RTCDomainTests", dependencies: ["RTCContracts", "RTCDomain"], path: "Tests/RTCDomainTests"),
        .executableTarget(name: "RTCIPCTests", dependencies: ["RTCContracts", "RTCIPC"], path: "Tests/RTCIPCTests"),
        .executableTarget(name: "RTCAgentChatSmokeTests", dependencies: ["RTCContracts", "RTCStore", "RTCIPC", "RTCAgentChat"], path: "Tests/RTCAgentChatSmokeTests"),
        .executableTarget(name: "RTCLifecycleTests", dependencies: ["RTCContracts", "RTCLifecycle"], path: "Tests/RTCLifecycleTests"),
        .executableTarget(name: "RTCReviewTests", dependencies: ["RTCContracts", "RTCDomain", "RTCReview"], path: "Tests/RTCReviewTests"),
        .executableTarget(name: "RTCReviewPersistenceTests", dependencies: ["RTCContracts", "RTCDomain", "RTCReview", "RTCStore"], path: "Tests/RTCReviewPersistenceTests"),
        .executableTarget(name: "RTCSyntaxTests", dependencies: ["RTCContracts", "RTCSyntax"], path: "Tests/RTCSyntaxTests"),
        .executableTarget(name: "RTCTourTests", dependencies: ["RTCContracts", "RTCTour"], path: "Tests/RTCTourTests"),
        .executableTarget(
            name: "TourWorkspaceFeatureTests",
            dependencies: [
                "RTCContracts", "RTCDiagram", "RTCModelAdapters", "RTCStore", "RTCSyntax",
                "RTCTour", "RTCTourIntegration", "TourWorkspace",
            ],
            path: "Tests/TourWorkspaceFeatureTests"
        ),
        .executableTarget(name: "RTCReviewWorkspaceFeatureTests", dependencies: ["RTCContracts", "RTCDomain", "RTCReview", "RTCDiffCanvas", "RTCReviewWorkspace"], path: "Tests/RTCReviewWorkspaceFeatureTests"),
        .executableTarget(
            name: "RTCIngestTests",
            dependencies: ["RTCCLI", "RTCContracts", "RTCGit", "RTCIngest", "RTCIPC", "RTCLifecycle", "RTCStore"],
            path: "Tests/RTCIngestTests"
        ),
        .executableTarget(
            name: "RTCInboxFeatureTests",
            dependencies: ["RTCContracts", "RTCInboxFeature", "RTCIngest"],
            path: "Tests/RTCInboxFeatureTests"
        ),
    ]
)
