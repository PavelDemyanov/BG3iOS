// Подпись тонкого arm64 Mach-O (библиотеки или исполняемого файла) — то же, что codesign для iOS:
// SuperBlob { CodeDirectory v0x20400 (SHA-256, страницы 16 КБ, идентификатор, команда, исполняемый сегмент),
// пустые требования, CMS }. Старая подпись заменяется (LC_CODE_SIGNATURE остаётся на своём месте); нет её —
// команда добавляется в запас после команд загрузки. Подпись — в конце __LINKEDIT.

import CryptoKit
import Foundation

public enum MachOSigner {
    static let pageShift: UInt8 = 14  // 16 КБ, как у codesign для iOS
    static let cmsReserve = 12 * 1024  // место под CMS: три сертификата и подпись RSA — около 5 КБ

    public static func sign(file url: URL, identifier: String, identity: SigningIdentity) throws {
        var data = [UInt8](try Data(contentsOf: url))
        let signed = try sign(&data, identifier: identifier, identity: identity)
        try Data(signed).write(to: url, options: .atomic)
    }

    // Подписанная копия: data — содержимое файла.
    public static func sign(_ data: inout [UInt8], identifier: String, identity: SigningIdentity) throws -> [UInt8] {
        guard data.count > 32, read32(data, 0) == 0xfeedfacf else { throw SignError.badMachO("not a thin 64-bit file") }
        let filetype = read32(data, 12)
        let ncmds = Int(read32(data, 16)), sizeofcmds = Int(read32(data, 20))
        var linkedit = -1, text = -1, signature = -1, firstSection = Int.max
        var offset = 32
        for _ in 0..<ncmds {
            let cmd = read32(data, offset), size = Int(read32(data, offset + 4))
            if cmd == 0x19 {  // LC_SEGMENT_64
                let name = segmentName(data, offset + 8)
                if name == "__LINKEDIT" { linkedit = offset }
                if name == "__TEXT" { text = offset }
                let nsects = Int(read32(data, offset + 64))
                for s in 0..<nsects {
                    let sectOffset = Int(read32(data, offset + 72 + s * 80 + 48))
                    if sectOffset > 0 { firstSection = min(firstSection, sectOffset) }
                }
            } else if cmd == 0x1d {  // LC_CODE_SIGNATURE
                signature = offset
            }
            offset += size
        }
        guard linkedit >= 0, text >= 0 else { throw SignError.badMachO("no __LINKEDIT or __TEXT") }
        let linkeditOff = Int(read64(data, linkedit + 40))
        // Где начинается подпись (= граница хешируемого): старая подпись — на её месте, иначе после __LINKEDIT.
        let codeLimit: Int
        if signature >= 0 {
            codeLimit = Int(read32(data, signature + 8))
        } else {
            guard 32 + sizeofcmds + 16 <= firstSection else { throw SignError.badMachO("no room for LC_CODE_SIGNATURE") }
            codeLimit = (linkeditOff + Int(read64(data, linkedit + 48)) + 15) & ~15
            signature = 32 + sizeofcmds
            write32(&data, signature, 0x1d)
            write32(&data, signature + 4, 16)
            write32(&data, 16, UInt32(ncmds + 1))
            write32(&data, 20, UInt32(sizeofcmds + 16))
        }
        if data.count < codeLimit { data += [UInt8](repeating: 0, count: codeLimit - data.count) }
        data.removeSubrange(codeLimit...)

        let pageSize = 1 << Int(pageShift)
        let codeSlots = (codeLimit + pageSize - 1) / pageSize
        let ident = Array(identifier.utf8) + [0], team = Array(identity.teamID.utf8) + [0]
        let specialSlots = 2  // −1 Info.plist (нет), −2 требования
        let cdHeader = 88
        let hashOffset = cdHeader + ident.count + team.count + specialSlots * 32
        let cdSize = hashOffset + codeSlots * 32
        let requirements: [UInt8] = be32(0xfade0c01) + be32(12) + be32(0)
        let superHeader = 12 + 3 * 8
        let total = (superHeader + cdSize + requirements.count + 8 + cmsReserve + 15) & ~15

        // Заголовок файла — до хеширования: размеры подписи и __LINKEDIT входят в первую страницу.
        write32(&data, signature + 8, UInt32(codeLimit))
        write32(&data, signature + 12, UInt32(total))
        let linkeditSize = codeLimit + total - linkeditOff
        write64(&data, linkedit + 48, UInt64(linkeditSize))
        write64(&data, linkedit + 32, UInt64((linkeditSize + 0x3fff) & ~0x3fff))

        var cd = be32(0xfade0c02) + be32(UInt32(cdSize)) + be32(0x20400) + be32(0)
        cd += be32(UInt32(hashOffset)) + be32(UInt32(cdHeader)) + be32(UInt32(specialSlots)) + be32(UInt32(codeSlots))
        cd += be32(UInt32(codeLimit)) + [32, 2, 0, pageShift] + be32(0)                       // SHA-256, страница
        cd += be32(0) + be32(UInt32(cdHeader + ident.count)) + be32(0) + be64(0)              // scatter, team, codeLimit64
        let execFlags: UInt64 = filetype == 2 ? 1 : 0  // CS_EXECSEG_MAIN_BINARY у исполняемого
        cd += be64(read64(data, text + 40)) + be64(read64(data, text + 48)) + be64(execFlags)
        cd += ident + team
        cd += [UInt8](repeating: 0, count: 32)                                                // −2… заполняется ниже
        cd += [UInt8](repeating: 0, count: 32)                                                // −1 Info.plist
        cd.replaceSubrange(hashOffset - 64..<hashOffset - 32, with: [UInt8](SHA256.hash(data: requirements)))
        for page in 0..<codeSlots {
            let start = page * pageSize
            cd += [UInt8](SHA256.hash(data: data[start..<min(start + pageSize, codeLimit)]))
        }
        guard cd.count == cdSize else { throw SignError.badMachO("CodeDirectory size") }

        let cms = try CMS.signature(codeDirectory: cd, identity: identity)
        let cmsBlob = be32(0xfade0b01) + be32(UInt32(8 + cms.count)) + cms
        guard superHeader + cd.count + requirements.count + cmsBlob.count <= total else {
            throw SignError.signature("CMS larger than reserved")
        }
        var blob = be32(0xfade0cc0) + be32(0) + be32(3)
        var at = superHeader
        for (type, part) in [(UInt32(0), cd), (2, requirements), (0x10000, cmsBlob)] {
            blob += be32(type) + be32(UInt32(at))
            at += part.count
        }
        blob += cd + requirements + cmsBlob
        blob.replaceSubrange(4..<8, with: be32(UInt32(blob.count)))
        blob += [UInt8](repeating: 0, count: total - blob.count)
        return data + blob
    }

    static func read32(_ d: [UInt8], _ o: Int) -> UInt32 {
        UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }
    static func read64(_ d: [UInt8], _ o: Int) -> UInt64 { UInt64(read32(d, o)) | UInt64(read32(d, o + 4)) << 32 }
    static func write32(_ d: inout [UInt8], _ o: Int, _ v: UInt32) {
        for i in 0..<4 { d[o + i] = UInt8(v >> (8 * i) & 0xff) }
    }
    static func write64(_ d: inout [UInt8], _ o: Int, _ v: UInt64) {
        write32(&d, o, UInt32(v & 0xffff_ffff))
        write32(&d, o + 4, UInt32(v >> 32))
    }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    static func be64(_ v: UInt64) -> [UInt8] { be32(UInt32(v >> 32)) + be32(UInt32(v & 0xffff_ffff)) }
    static func segmentName(_ d: [UInt8], _ o: Int) -> String {
        String(decoding: d[o..<o + 16].prefix { $0 != 0 }, as: UTF8.self)
    }
}
