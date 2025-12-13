// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TabletPenMac",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "TabletPenMac",
            path: "TabletPenMac"
        )
    ]
)
