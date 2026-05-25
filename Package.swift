// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NoteFlow",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NoteFlow",
            path: "Sources/NoteFlow",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
