// Подготовка Mac-приложения к запуску на iOS прямо на месте (на телефоне — в папке, куда его скачали): то же, что
// tools/stage_mac_app.sh и stage_data.sh, без копирования данных.
// - каждый Mach-O в Contents/MacOS и Contents/Frameworks переделывается (MachOConvert, rpath — от файла до
//   Contents/Frameworks) и правится (BinaryPatches); libsteam_api.dylib заменяется нашей;
// - заменители (MP*.dylib) кладутся в Contents/Frameworks;
// - у .metallib сбрасывается бит macOS в заголовке;
// - каждый Mach-O подписывается удостоверением хоста (MachOSigner): iOS загружает только библиотеки той же команды.
// Повторный запуск безопасен: уже переделанный файл (MH_DYLIB с платформой iOS) только переподписывается.

import Foundation
import MachOSign

public struct AppPreparer {
    public let app: URL       // …/Имя.app
    public let shims: URL     // папка с MP*.dylib и libsteam_api.dylib
    public let identity: SigningIdentity?
    public var log: (String) -> Void = { _ in }

    public init(app: URL, shims: URL, identity: SigningIdentity?, log: @escaping (String) -> Void = { _ in }) {
        self.app = app
        self.shims = shims
        self.identity = identity
        self.log = log
    }

    var contents: URL { app.appendingPathComponent("Contents") }
    var frameworks: URL { contents.appendingPathComponent("Frameworks") }

    public func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: frameworks, withIntermediateDirectories: true)
        var machOs: [URL] = []
        for dir in [contents.appendingPathComponent("MacOS"), frameworks] {
            for file in try regularFiles(in: dir) where try isMachO(file) { machOs.append(file) }
        }
        for file in machOs {
            if file.lastPathComponent == "libsteam_api.dylib" {
                try replace(file, with: shims.appendingPathComponent("libsteam_api.dylib"))
                log("steam_api replaced: \(relative(file))")
                continue
            }
            var data = [UInt8](try Data(contentsOf: file))
            if !(try isConverted(data)) {
                let result = try MachOConvert.convert(data, rpath: rpath(for: file))
                data = result.data
                let patches = BinaryPatches.apply(to: &data, fileName: file.lastPathComponent)
                log("converted: \(relative(file)) (shims: \(result.shims.sorted().joined(separator: " ")))"
                    + (patches.isEmpty ? "" : "; " + patches.joined(separator: "; ")))
            }
            try write(data, to: file)
        }
        for shim in try fm.contentsOfDirectory(at: shims, includingPropertiesForKeys: nil)
        where shim.lastPathComponent.hasPrefix("MP") && shim.pathExtension == "dylib" {
            try replace(frameworks.appendingPathComponent(shim.lastPathComponent), with: shim)
        }
        var metallibs = 0
        if let walker = fm.enumerator(at: contents, includingPropertiesForKeys: nil) {
            for case let file as URL in walker where file.pathExtension == "metallib" {
                if try patchMetallib(file) { metallibs += 1 }
            }
        }
        try? fm.removeItem(at: contents.appendingPathComponent("_CodeSignature"))
        log("metallib → iOS: \(metallibs)")
    }

    // Записать (и подписать) Mach-O на месте.
    func write(_ data: [UInt8], to file: URL) throws {
        var bytes = data
        let signed = try identity.map {
            try MachOSigner.sign(&bytes, identifier: file.deletingPathExtension().lastPathComponent, identity: $0)
        } ?? bytes
        try Data(signed).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    func replace(_ file: URL, with source: URL) throws {
        try write([UInt8](try Data(contentsOf: source)), to: file)
    }

    // rpath от каталога файла до Contents/Frameworks.
    func rpath(for file: URL) -> String {
        let from = file.deletingLastPathComponent().standardizedFileURL.pathComponents
        let to = frameworks.standardizedFileURL.pathComponents
        var common = 0
        while common < min(from.count, to.count) && from[common] == to[common] { common += 1 }
        let parts = Array(repeating: "..", count: from.count - common) + to[common...]
        return parts.isEmpty ? "@loader_path" : "@loader_path/" + parts.joined(separator: "/")
    }

    func regularFiles(in dir: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey,
                                                                                                .isSymbolicLinkKey])
        else { return [] }
        var files: [URL] = []
        for case let file as URL in walker {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true && values.isSymbolicLink != true { files.append(file) }
        }
        return files.sorted { $0.path < $1.path }
    }

    func isMachO(_ file: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let head = [UInt8](try handle.read(upToCount: 4) ?? Data())
        return head == [0xcf, 0xfa, 0xed, 0xfe] || head == [0xca, 0xfe, 0xba, 0xbe] || head == [0xca, 0xfe, 0xba, 0xbf]
    }

    // Уже переделан: тонкий MH_DYLIB, у которого LC_BUILD_VERSION — iOS.
    func isConverted(_ data: [UInt8]) throws -> Bool {
        guard data.count > 32, MachOConvert.le32(data, 0) == 0xfeedfacf, MachOConvert.le32(data, 12) == 0x6 else {
            return false
        }
        var off = 32
        for _ in 0..<Int(MachOConvert.le32(data, 16)) {
            if MachOConvert.le32(data, off) == 0x32 { return MachOConvert.le32(data, off + 8) == 2 }
            off += Int(MachOConvert.le32(data, off + 4))
        }
        return false
    }

    // metallib: u16 по смещению 4 — 0x8001 у macOS, 0x0001 у iOS.
    func patchMetallib(_ file: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let head = [UInt8](try handle.read(upToCount: 6) ?? Data())
        guard head.count == 6, head[0..<4] == [0x4d, 0x54, 0x4c, 0x42], head[5] == 0x80 else { return false }
        try handle.seek(toOffset: 5)
        try handle.write(contentsOf: Data([0]))
        return true
    }

    func relative(_ file: URL) -> String {
        String(file.standardizedFileURL.path.dropFirst(app.standardizedFileURL.path.count + 1))
    }
}
