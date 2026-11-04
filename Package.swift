// swift-tools-version: 6.1
import PackageDescription
import Foundation
let chainLibrary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".build/ChainCore").path

let package = Package(
    name: "VeilWallet",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VeilWallet", targets: ["VeilWallet"]),
        .library(name: "WalletCore", targets: ["WalletCore"]),
        .executable(name: "TorSmoke", targets: ["TorSmoke"])
    ],
    dependencies: [
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.24.0", traits: ["recovery"]),
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", exact: "1.10.0"),
        .package(url: "https://github.com/attaswift/BigInt.git", exact: "5.7.0")
    ],
    targets: [
        .target(name: "CChainCore", linkerSettings: [.unsafeFlags(["-L", chainLibrary]), .linkedLibrary("VeilChainCore"), .linkedFramework("CoreFoundation"), .linkedFramework("Security"), .linkedLibrary("resolv")]),
        .target(name: "CPrivacyTransport", linkerSettings: [.linkedLibrary("curl")]),
        .target(name: "WalletCore", dependencies: [
            "CPrivacyTransport", "CChainCore",
            .product(name: "libsecp256k1", package: "swift-secp256k1"),
            .product(name: "CryptoSwift", package: "CryptoSwift"),
            .product(name: "BigInt", package: "BigInt")
        ], resources: [.process("Resources")]),
        .executableTarget(name: "VeilWallet", dependencies: ["WalletCore", .product(name: "BigInt", package: "BigInt")]),
        .executableTarget(name: "TorSmoke", dependencies: ["WalletCore"], path: "Tools/TorSmoke"),
        .testTarget(name: "WalletCoreTests", dependencies: ["WalletCore", "CPrivacyTransport", .product(name: "BigInt", package: "BigInt")], resources: [.process("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
