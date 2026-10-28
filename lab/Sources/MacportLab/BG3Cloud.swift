// SPDX-License-Identifier: GPL-3.0-or-later
// Сейвы BG3 в Steam Cloud. Игра (ПК, Mac) кладёт их сама через Steam API под именами
// `_SAVE_Public/Savegames/Story/<папка>/<имя>.lsv`; на телефоне — `Documents/Larian Studios/Baldur's Gate 3/
// PlayerProfiles/Public/Savegames/Story/…`. Синхронизируются только сейвы (.lsv); профиль (`_PROFILE_…`: настройки,
// раскладка интерфейса с ПК) — нет. Имена папок — с кириллицей: сравниваются в одной нормализации Unicode (NFC),
// чтобы «й» из облака и с телефона не стали разными сейвами.

import Compression
import ContentKit
import Foundation
import SteamClientKit

struct BG3CloudLocations: CloudLocations {
    static let prefix = "_SAVE_"
    let profiles: URL  // …/PlayerProfiles

    static var standard: BG3CloudLocations {
        BG3CloudLocations(profiles: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Larian Studios/Baldur's Gate 3/PlayerProfiles", isDirectory: true))
    }

    func syncs(_ name: String) -> Bool { name.hasPrefix(Self.prefix) && name.lowercased().hasSuffix(".lsv") }

    func file(_ name: String) -> URL? {
        guard syncs(name) else { return nil }
        let parts = name.dropFirst(Self.prefix.count).split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts.contains(".."), !parts.contains(".") else { return nil }
        return Self.resolve(parts, in: profiles)
    }

    func localFiles(rules: [Cloud.SaveRule], steamID: UInt64) -> [String: URL] {
        let story = profiles.appendingPathComponent("Public/Savegames/Story", isDirectory: true)
        let fm = FileManager.default
        var out: [String: URL] = [:]
        for folder in (try? fm.contentsOfDirectory(atPath: story.path)) ?? [] {
            let dir = story.appendingPathComponent(folder, isDirectory: true)
            for file in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where file.lowercased().hasSuffix(".lsv") {
                out[Self.nfc("\(Self.prefix)Public/Savegames/Story/\(folder)/\(file)")] = dir.appendingPathComponent(file)
            }
        }
        return out
    }

    static func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    // Компоненты пути — по тому, что уже лежит на диске (в любой нормализации и регистре), остальные — как даны.
    static func resolve(_ parts: [String], in base: URL) -> URL {
        var at = base
        for part in parts {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: at.path)) ?? []
            let match = names.first { nfc($0) == nfc(part) } ?? names.first { nfc($0).lowercased() == nfc(part).lowercased() }
            at = at.appendingPathComponent(match ?? part)
        }
        return at
    }

    // «Карлах-412512615922__Нижний город - 95ч 58м/Нижний город - 95ч 58м.lsv» → «Нижний город - 95ч 58м».
    static func title(_ name: String) -> String {
        let file = (name as NSString).lastPathComponent
        return (file as NSString).deletingPathExtension
    }
}

// Миниатюры сейвов: в Steam Cloud — только .lsv, а превью (<имя>.WebP рядом) игра берёт из отдельного файла.
// Оно есть и внутри .lsv — его и кладём рядом, если нет. Архив LSPK: оглавление — блок LZ4; запись v18 — 272 байта
// (смещение 48 бит), v15/16 (сейвы 2023 года) — 296 байт (64-битные поля); сжатие записи: 0 — нет, 1 — zlib,
// 2 — LZ4, 3 — zstd (новые сейвы; распаковщик — ContentKit).
enum BG3SaveThumbnails {
    // Для всех сейвов без превью; возвращает, сколько добавлено.
    static func fill(profiles: URL) -> Int {
        let fm = FileManager.default
        let story = profiles.appendingPathComponent("Public/Savegames/Story", isDirectory: true)
        var made = 0
        for folder in (try? fm.contentsOfDirectory(atPath: story.path)) ?? [] {
            let dir = story.appendingPathComponent(folder, isDirectory: true)
            let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for lsv in files where lsv.lowercased().hasSuffix(".lsv") {
                let base = (lsv as NSString).deletingPathExtension
                guard !files.contains(where: { $0.lowercased() == (base + ".webp").lowercased() }),
                      let image = extract(dir.appendingPathComponent(lsv)) else { continue }
                if (try? image.data.write(to: dir.appendingPathComponent(image.name), options: .atomic)) != nil { made += 1 }
            }
        }
        return made
    }

    // Превью из .lsv: имя записи (…WebP верхнего уровня) и содержимое.
    static func extract(_ lsv: URL) -> (name: String, data: Data)? {
        guard let handle = try? FileHandle(forReadingFrom: lsv) else { return nil }
        defer { try? handle.close() }
        func read(_ offset: UInt64, _ count: Int) -> [UInt8]? {
            guard (try? handle.seek(toOffset: offset)) != nil, let d = try? handle.read(upToCount: count), d.count == count
            else { return nil }
            return [UInt8](d)
        }
        func u32(_ b: [UInt8], _ o: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[o + $1]) << (8 * $1) } }
        func u64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(u32(b, o)) | UInt64(u32(b, o + 4)) << 32 }
        guard let head = read(0, 20), head[0..<4] == [0x4c, 0x53, 0x50, 0x4b] else { return nil }
        let version = u32(head, 4)
        guard [15, 16, 18].contains(version) else { return nil }
        let entrySize = version == 18 ? 272 : 296
        guard let list = read(u64(head, 8), 8) else { return nil }
        let count = Int(u32(list, 0)), packed = Int(u32(list, 4))
        guard count > 0, count < 10_000, let compressed = read(u64(head, 8) + 8, packed),
              let table = decompress(compressed, size: count * entrySize, algorithm: COMPRESSION_LZ4_RAW) else { return nil }
        for n in 0..<count {
            let e = Array(table[(n * entrySize)..<((n + 1) * entrySize)])
            let name = String(decoding: e[0..<256].prefix { $0 != 0 }, as: UTF8.self)
            guard name.lowercased().hasSuffix(".webp"), !name.contains("/") else { continue }
            let offset: UInt64, method: UInt8, disk: Int, stated: Int
            if version == 18 {
                offset = UInt64(u32(e, 256)) | UInt64(UInt16(e[260]) | UInt16(e[261]) << 8) << 32
                method = e[263] & 0xf
                disk = Int(u32(e, 264))
                stated = Int(u32(e, 268))
            } else {
                offset = u64(e, 256)
                disk = Int(u64(e, 264))
                stated = Int(u64(e, 272))
                method = UInt8(u32(e, 284) & 0xf)
            }
            let size = method == 0 ? disk : stated  // несжатая запись: размер — на диске
            guard size > 0, size < 16 << 20, disk < 16 << 20, let raw = read(offset, disk) else { return nil }
            switch method {
            case 0: return (name, Data(raw))
            case 1 where raw.count > 2:  // zlib: двухбайтовый заголовок, дальше — DEFLATE
                return decompress(Array(raw.dropFirst(2)), size: size, algorithm: COMPRESSION_ZLIB).map { (name, Data($0)) }
            case 2: return decompress(raw, size: size, algorithm: COMPRESSION_LZ4_RAW).map { (name, Data($0)) }
            case 3:
                guard let out = try? Zstd.decompress(raw[...], limit: size), out.count == size else { return nil }
                return (name, Data(out))
            default: return nil
            }
        }
        return nil
    }

    static func decompress(_ src: [UInt8], size: Int, algorithm: compression_algorithm) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: size)
        let written = out.withUnsafeMutableBufferPointer { dst in
            src.withUnsafeBufferPointer { s in
                compression_decode_buffer(dst.baseAddress!, size, s.baseAddress!, s.count, nil, algorithm)
            }
        }
        return written == size ? out : nil
    }
}
