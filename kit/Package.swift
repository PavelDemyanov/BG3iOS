// swift-tools-version: 6.0
// MacportKit — подготовка Mac-игры к запуску на iOS прямо на телефоне. MachOSign — подпись Mach-O (как codesign:
// CodeDirectory SHA-256, CMS с цепочкой Apple, ключ из .p12 через Security.framework); MacportPrep — переделка
// Mac-бинарников и приложения целиком. Утилиты — для проверки на Mac.
import PackageDescription

let package = Package(
    name: "MacportKit",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        .library(name: "MachOSign", targets: ["MachOSign"]),
        .library(name: "MacportPrep", targets: ["MacportPrep"]),
    ],
    targets: [
        .target(name: "MachOSign"),
        .target(name: "MacportPrep", dependencies: ["MachOSign"]),
        .executableTarget(name: "PrepTool", dependencies: ["MachOSign", "MacportPrep"]),
        .executableTarget(name: "SignTool", dependencies: ["MachOSign"]),
        .executableTarget(name: "ExportIdentity"),
    ]
)
