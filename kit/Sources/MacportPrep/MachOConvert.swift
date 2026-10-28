// Mac-бинарник arm64 → библиотека для загрузки на iOS через dlopen (то же, что tools/macport_convert.py, байт
// в байт):
// - универсальный файл сужается до arm64;
// - LC_BUILD_VERSION: платформа macOS → iOS, minos 17.0, sdk 26.0 (LC_VERSION_MIN_MACOSX → …_IPHONEOS);
// - главный файл (MH_EXECUTE) становится MH_DYLIB, как у LiveContainer: __PAGEZERO — одна страница,
//   LC_LOAD_DYLINKER → LC_ID_DYLIB; LC_MAIN остаётся — по нему хост находит main;
// - пути зависимостей: /System/Library/Frameworks/X.framework/… → путь X в iOS (IOSFrameworks), фреймворки,
//   которых в iOS нет или где не хватает символов, и libSystem — на наши заменители (@rpath/MPX.dylib);
//   у системных путей compatibility_version обнуляется;
// - первый LC_RPATH — на Contents/Frameworks (нет своего — добавляется в запас после команд загрузки).
// Подпись после правок недействительна — подписывать заново (MachOSigner).

import Foundation

public enum MachOConvert {
    // Заменители фреймворков macOS (см. shims/): у каждого убранного — свой, два LC_LOAD_DYLIB с одним путём
    // dyld отвергает.
    static let shims = [
        "AppKit": "MPAppKit", "Cocoa": "MPCocoa", "Carbon": "MPCarbon", "OpenGL": "MPOpenGL",
        "ForceFeedback": "MPForceFeedback", "CoreGraphics": "MPCoreGraphics", "CoreVideo": "MPCoreVideo",
        "Security": "MPSecurity", "CoreServices": "MPCoreServices", "AudioUnit": "MPAudioUnit", "Metal": "MPMetal",
        "AudioToolbox": "MPAudioToolbox", "CoreAudio": "MPCoreAudio",
    ]
    static let libShims = ["/usr/lib/libSystem.B.dylib": "MPSystem"]

    public struct Result {
        public var data: [UInt8]
        public var report: [String]
        public var shims: Set<String>
    }

    public enum Failure: Error, CustomStringConvertible {
        case notMachO, noArm64, missingFramework(String), noRoom(String)
        public var description: String {
            switch self {
            case .notMachO: "not a 64-bit Mach-O"
            case .noArm64: "no arm64 slice"
            case .missingFramework(let name): "iOS has no \(name) framework; a shim is needed"
            case .noRoom(let what): "no room: \(what)"
            }
        }
    }

    static func version(_ major: UInt32, _ minor: UInt32 = 0) -> UInt32 { major << 16 | minor << 8 }

    // Срез arm64 из универсального файла (или сам файл, если он тонкий).
    public static func thinArm64(_ file: [UInt8]) throws -> [UInt8] {
        guard file.count >= 8 else { throw Failure.notMachO }
        let magic = UInt32(file[0]) << 24 | UInt32(file[1]) << 16 | UInt32(file[2]) << 8 | UInt32(file[3])
        guard magic == 0xcafebabe || magic == 0xcafebabf else { return file }
        let wide = magic == 0xcafebabf
        let count = Int(be32(file, 4))
        var at = 8
        for _ in 0..<count {
            let cputype = be32(file, at)
            let offset = wide ? Int(be64(file, at + 8)) : Int(be32(file, at + 8))
            let size = wide ? Int(be64(file, at + 16)) : Int(be32(file, at + 12))
            if cputype == 0x0100000c { return Array(file[offset..<offset + size]) }
            at += wide ? 32 : 20
        }
        throw Failure.noArm64
    }

    static func newPath(_ path: String, shimsUsed: inout Set<String>) throws -> (String, Bool) {
        if let name = libShims[path] {
            shimsUsed.insert(name)
            return ("@rpath/\(name).dylib", true)
        }
        let prefix = "/System/Library/Frameworks/"
        guard path.hasPrefix(prefix) else { return (path, false) }
        let name = String(path.dropFirst(prefix.count).split(separator: ".framework", maxSplits: 1)
            .first.map(String.init) ?? "")
        if let shim = shims[name] {
            shimsUsed.insert(shim)
            return ("@rpath/\(shim).dylib", true)
        }
        guard let ios = IOSFrameworks.installNames[name] else { throw Failure.missingFramework(name) }
        return (ios, true)
    }

    public static func convert(_ file: [UInt8], rpath: String = "@loader_path/../Frameworks") throws -> Result {
        var data = try thinArm64(file)
        guard data.count > 32, le32(data, 0) == 0xfeedfacf else { throw Failure.notMachO }
        var report: [String] = []
        var shimsUsed = Set<String>()
        let wasExec = le32(data, 12) == 0x2
        var ncmds = Int(le32(data, 16)), sizeofcmds = Int(le32(data, 20))
        let flags = le32(data, 24)
        var hasRpath = false
        var firstSection = data.count
        var off = 32
        let dylibCmds: Set<UInt32> = [0xc, 0x80000018, 0x8000001f, 0x20, 0x80000023]
        for _ in 0..<ncmds {
            let cmd = le32(data, off), cmdsize = Int(le32(data, off + 4))
            switch cmd {
            case 0x32:  // LC_BUILD_VERSION
                let platform = le32(data, off + 8)
                put32(&data, off + 8, 2)
                put32(&data, off + 12, version(17))
                put32(&data, off + 16, version(26))
                report.append("LC_BUILD_VERSION: platform \(platform) → iOS, minos 17.0, sdk 26.0")
            case 0x24:  // LC_VERSION_MIN_MACOSX
                put32(&data, off, 0x25)
                put32(&data, off + 8, version(17))
                put32(&data, off + 12, version(26))
                report.append("LC_VERSION_MIN_MACOSX → LC_VERSION_MIN_IPHONEOS")
            case let c where dylibCmds.contains(c):
                let nameOff = Int(le32(data, off + 8))
                let raw = data[(off + nameOff)..<(off + cmdsize)]
                let path = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                let (new, system) = try newPath(path, shimsUsed: &shimsUsed)
                if new != path {
                    let encoded = Array(new.utf8) + [0]
                    let room = cmdsize - nameOff
                    guard encoded.count <= room else { throw Failure.noRoom("path \(new) in place of \(path)") }
                    data.replaceSubrange((off + nameOff)..<(off + cmdsize),
                                         with: encoded + [UInt8](repeating: 0, count: room - encoded.count))
                    report.append("dylib: \(path) → \(new)")
                }
                if system { put32(&data, off + 20, 0) }  // compatibility_version: любая
            case 0x8000001c:  // LC_RPATH
                // Первый — на Contents/Frameworks; остальные остаются (пути macOS безвредны), совпавший с новым
                // получает уникальное имя: одинаковые LC_RPATH dyld отвергает.
                let nameOff = Int(le32(data, off + 8))
                let room = cmdsize - nameOff
                let old = String(decoding: data[(off + nameOff)..<(off + cmdsize)].prefix { $0 != 0 }, as: UTF8.self)
                let target = !hasRpath ? rpath : (old == rpath ? "@loader_path/.mp\(off)" : nil)
                hasRpath = true
                if let target, target.utf8.count + 1 <= room {
                    let encoded = Array(target.utf8) + [0]
                    data.replaceSubrange((off + nameOff)..<(off + cmdsize),
                                         with: encoded + [UInt8](repeating: 0, count: room - encoded.count))
                    report.append("rpath: \(old) → \(target)")
                }
            default:
                break
            }
            if cmd == 0x19 {  // LC_SEGMENT_64
                let nsects = Int(le32(data, off + 64))
                for s in 0..<nsects {
                    let sectOff = Int(le32(data, off + 72 + s * 80 + 48))
                    if sectOff != 0 { firstSection = min(firstSection, sectOff) }
                }
                if wasExec {
                    let name = String(decoding: data[(off + 8)..<(off + 24)].prefix { $0 != 0 }, as: UTF8.self)
                    let vmaddr = le64(data, off + 24), vmsize = le64(data, off + 32)
                    if name == "__PAGEZERO" && vmaddr == 0 {
                        put64(&data, off + 24, vmsize - 0x4000)
                        put64(&data, off + 32, 0x4000)
                        report.append("__PAGEZERO: 0x\(String(vmsize, radix: 16)) → one page at 0x\(String(vmsize - 0x4000, radix: 16))")
                    }
                }
            }
            if cmd == 0xe && wasExec {  // LC_LOAD_DYLINKER → LC_ID_DYLIB: dylib_command (24 байта) + короткое имя
                let name: [UInt8] = Array("mp".utf8) + [0]
                guard 24 + name.count <= cmdsize else { throw Failure.noRoom("LC_ID_DYLIB in LC_LOAD_DYLINKER") }
                var body: [UInt8] = []
                for v in [UInt32(0xd), UInt32(cmdsize), 24, 2, version(1), version(1)] { body += le32bytes(v) }
                body += name
                data.replaceSubrange(off..<(off + cmdsize), with: body + [UInt8](repeating: 0, count: cmdsize - body.count))
                report.append("LC_LOAD_DYLINKER → LC_ID_DYLIB")
            }
            off += cmdsize
        }
        if !hasRpath {
            let path = Array(rpath.utf8) + [0]
            let size = (12 + path.count + 7) & ~7
            let end = 32 + sizeofcmds
            guard end + size <= firstSection else { throw Failure.noRoom("LC_RPATH (\(firstSection - end) bytes)") }
            let cmd = le32bytes(0x8000001c) + le32bytes(UInt32(size)) + le32bytes(12) + path
            data.replaceSubrange(end..<(end + size), with: cmd + [UInt8](repeating: 0, count: size - cmd.count))
            ncmds += 1
            sizeofcmds += size
            put32(&data, 16, UInt32(ncmds))
            put32(&data, 20, UInt32(sizeofcmds))
            report.append("rpath: added \(rpath)")
        }
        if wasExec {
            put32(&data, 12, 0x6)  // MH_DYLIB
            put32(&data, 16, UInt32(ncmds))
            put32(&data, 24, (flags & ~0x200000) | 0x100000)  // без MH_PIE, MH_NO_REEXPORTED_DYLIBS
            report.append("MH_EXECUTE → MH_DYLIB")
        }
        return Result(data: data, report: report, shims: shimsUsed)
    }

    static func be32(_ d: [UInt8], _ o: Int) -> UInt32 {
        UInt32(d[o]) << 24 | UInt32(d[o + 1]) << 16 | UInt32(d[o + 2]) << 8 | UInt32(d[o + 3])
    }
    static func be64(_ d: [UInt8], _ o: Int) -> UInt64 { UInt64(be32(d, o)) << 32 | UInt64(be32(d, o + 4)) }
    static func le32(_ d: [UInt8], _ o: Int) -> UInt32 {
        UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }
    static func le64(_ d: [UInt8], _ o: Int) -> UInt64 { UInt64(le32(d, o)) | UInt64(le32(d, o + 4)) << 32 }
    static func le32bytes(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(v >> (8 * $0) & 0xff) } }
    static func put32(_ d: inout [UInt8], _ o: Int, _ v: UInt32) { d.replaceSubrange(o..<(o + 4), with: le32bytes(v)) }
    static func put64(_ d: inout [UInt8], _ o: Int, _ v: UInt64) {
        put32(&d, o, UInt32(v & 0xffff_ffff))
        put32(&d, o + 4, UInt32(v >> 32))
    }
}
