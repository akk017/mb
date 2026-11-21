// swift-tools-version:6.2
import Foundation
import PackageDescription

// KeyboardShortcuts uses the #Preview macro, whose plugin ships only with Xcode.
// Command-Line-Tools builds (see Makefile) set MB_NO_KEYBOARDSHORTCUTS=1 and
// fall back to a Carbon RegisterEventHotKey implementation with the same API.
let useKeyboardShortcuts = ProcessInfo.processInfo.environment["MB_NO_KEYBOARDSHORTCUTS"] == nil
let uiDependencies: [Target.Dependency] = useKeyboardShortcuts
    ? ["MiniBrainCore", .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")]
    : ["MiniBrainCore"]
// MLX Swift (Qwen2.5-VL 3B image tagging) needs the Metal toolchain, i.e. Xcode.
// Opt in with MB_WITH_MLX=1; otherwise image tagging uses Vision's classifier.
let useMLX = ProcessInfo.processInfo.environment["MB_WITH_MLX"] == "1"
let packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
] + (useKeyboardShortcuts
    ? [.package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0")]
    : [])
  + (useMLX ? [.package(url: "https://github.com/ml-explore/mlx-swift-examples.git", from: "2.21.0")] : [])
let coreDependencies: [Target.Dependency] = [
    .product(name: "GRDB", package: "GRDB.swift"),
    "CSQLiteVec",
] + (useMLX
    ? [.product(name: "MLXVLM", package: "mlx-swift-examples"),
       .product(name: "MLXLMCommon", package: "mlx-swift-examples")]
    : [])

let package = Package(
    name: "MiniBrain",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "MiniBrain", targets: ["MiniBrainApp"]),
        .library(name: "MiniBrainCore", targets: ["MiniBrainCore"]),
    ],
    dependencies: packageDependencies,
    targets: [
        // sqlite-vec v0.1.6 amalgamation, compiled into the app (SQLITE_CORE).
        .target(
            name: "CSQLiteVec",
            cSettings: [
                .define("SQLITE_CORE"),
                .define("SQLITE_VEC_STATIC"),
                .unsafeFlags(["-w"]),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // libwebp 1.4.0 (BSD), vendored: macOS can decode WebP but not encode it.
        .target(
            name: "CWebP",
            exclude: ["libwebp/COPYING", "libwebp/PATENTS"],
            cSettings: [
                .headerSearchPath("libwebp"),
                .unsafeFlags(["-w", "-O2"]),
            ]
        ),
        .target(
            name: "MiniBrainCore",
            dependencies: coreDependencies + ["CWebP"]
        ),
        .target(
            name: "MiniBrainUI",
            dependencies: uiDependencies,
            // Lucide icons (ISC), rendered as template images.
            resources: [.copy("Resources/Icons")]
        ),
        .executableTarget(
            name: "MiniBrainApp",
            dependencies: ["MiniBrainUI", "MiniBrainCore"]
        ),
        .executableTarget(
            name: "mbtool",
            dependencies: ["MiniBrainCore"]
        ),
        .testTarget(
            name: "MiniBrainTests",
            dependencies: [
                "MiniBrainCore",
                "MiniBrainUI",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests",
            sources: ["MiniBrainTests"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
