// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
// Steam для macport: клиент Steam из Playport (vendor/playport/SteamClient) с выбором macOS-депо. SteamTool — проверка
// на Mac (анонимный вход: какие депо у приложения и какие выбираются для macOS).
import PackageDescription

let package = Package(
    name: "MacportSteam",
    platforms: [.iOS(.v18), .macOS(.v15)],
    dependencies: [.package(path: "../vendor/playport/SteamClient")],
    targets: [
        .executableTarget(name: "SteamTool", dependencies: [.product(name: "SteamClientKit", package: "SteamClient")]),
    ]
)
