// swift-tools-version: 6.0
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "TorrentFlow",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "TorrentFlow", targets: ["TorrentFlow"])],
    targets: [
        .target(name: "TorrentBridge", path: "Sources/TorrentBridge", publicHeadersPath: "include",
                cxxSettings: [.unsafeFlags(["-std=c++17", "-fobjc-arc", "-I\(root)/Vendor/include", "-DTORRENT_USE_LIBCRYPTO=1", "-DTORRENT_USE_OPENSSL=1", "-DBOOST_ASIO_ENABLE_CANCELIO", "-DTORRENT_ABI_VERSION=2", "-DTORRENT_USE_RTC=0", "-DTORRENT_SSL_PEERS=1"])],
                linkerSettings: [.unsafeFlags(["-L\(root)/Vendor/lib"]), .linkedLibrary("torrent-rasterbar"), .linkedLibrary("ssl"), .linkedLibrary("crypto"), .linkedLibrary("c++"), .linkedFramework("Foundation"), .linkedFramework("SystemConfiguration"), .linkedFramework("Security")]),
        .executableTarget(name: "TorrentFlow", dependencies: ["TorrentBridge"], path: "Sources/TorrentFlow", linkerSettings: [.linkedFramework("IOKit")])
    ],
    swiftLanguageModes: [.v6], cxxLanguageStandard: .cxx17
)
