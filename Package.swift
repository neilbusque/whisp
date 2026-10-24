// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Whisp",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "WhispCore", dependencies: ["CSQLite"]),
        .target(name: "WhispAudio"),
        // Vendored whisper.cpp + ggml (v1.7.4), CPU backend only.
        // CLT-only Macs have no `metal` compiler, so the Metal backend is omitted;
        // the CPU backend (Accelerate-accelerated) is used and the model is kept
        // warm in RAM by WhisperTranscriber. See scripts/fetch-whisper.sh.
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            exclude: ["LICENSE"],
            publicHeadersPath: "include",
            cSettings: [
                .define("GGML_USE_CPU"),
                .define("GGML_USE_ACCELERATE"),
                .define("ACCELERATE_NEW_LAPACK"),
                .define("ACCELERATE_LAPACK_ILP64"),
                .define("NDEBUG"),
                .headerSearchPath("include"),
                .headerSearchPath("ggml/include"),
                .headerSearchPath("ggml/src"),
                .headerSearchPath("ggml/src/ggml-cpu"),
            ],
            cxxSettings: [
                .define("GGML_USE_CPU"),
                .define("GGML_USE_ACCELERATE"),
                .define("ACCELERATE_NEW_LAPACK"),
                .define("ACCELERATE_LAPACK_ILP64"),
                .define("NDEBUG"),
                .headerSearchPath("include"),
                .headerSearchPath("ggml/include"),
                .headerSearchPath("ggml/src"),
                .headerSearchPath("ggml/src/ggml-cpu"),
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .executableTarget(
            name: "Whisp",
            dependencies: ["WhispCore", "WhispAudio", "CWhisper"],
            path: "Sources/Whisp"
        ),
        .testTarget(name: "WhispCoreTests", dependencies: ["WhispCore"]),
        .testTarget(name: "WhispAudioTests", dependencies: ["WhispAudio"]),
        .testTarget(name: "WhispAppTests", dependencies: ["Whisp", "WhispCore"]),
    ],
    cxxLanguageStandard: .cxx17
)
