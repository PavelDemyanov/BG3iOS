// Минимальный DER: кодирование узлов (для CMS) и разбор сертификата (издатель, серийный номер, OU — идентификатор
// команды). Только то, что нужно подписи.

import Foundation

enum DER {
    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 {
            bytes.insert(UInt8(v & 0xff), at: 0)
            v >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func node(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }
    static func sequence(_ items: [[UInt8]]) -> [UInt8] { node(0x30, items.flatMap { $0 }) }
    // SET OF в DER — элементы по возрастанию их кодировок.
    static func set(_ items: [[UInt8]]) -> [UInt8] { node(0x31, items.sorted { $0.lexicographicallyPrecedes($1) }.flatMap { $0 }) }
    static func integer(_ v: Int) -> [UInt8] { node(0x02, [UInt8(v)]) }
    static func octets(_ bytes: [UInt8]) -> [UInt8] { node(0x04, bytes) }
    static let null: [UInt8] = [0x05, 0x00]

    static func oid(_ dotted: String) -> [UInt8] {
        let parts = dotted.split(separator: ".").map { UInt64($0)! }
        var out: [UInt8] = [UInt8(parts[0] * 40 + parts[1])]
        for var p in parts.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(p & 0x7f)]
            p >>= 7
            while p > 0 {
                chunk.insert(UInt8(p & 0x7f) | 0x80, at: 0)
                p >>= 7
            }
            out += chunk
        }
        return node(0x06, out)
    }

    static func utcTime(_ date: Date) -> [UInt8] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyMMddHHmmss'Z'"
        return node(0x17, Array(f.string(from: date).utf8))
    }

    // Узел в разбираемых данных: тег, содержимое и весь узел целиком.
    struct Item {
        let tag: UInt8
        let content: ArraySlice<UInt8>
        let whole: ArraySlice<UInt8>
    }

    static func read(_ bytes: ArraySlice<UInt8>) throws -> Item {
        var i = bytes.startIndex
        guard i < bytes.endIndex else { throw SignError.badCertificate }
        let tag = bytes[i]
        i += 1
        guard i < bytes.endIndex else { throw SignError.badCertificate }
        var len = Int(bytes[i])
        i += 1
        if len & 0x80 != 0 {
            let n = len & 0x7f
            guard n <= 4, i + n <= bytes.endIndex else { throw SignError.badCertificate }
            len = 0
            for _ in 0..<n {
                len = len << 8 | Int(bytes[i])
                i += 1
            }
        }
        guard i + len <= bytes.endIndex else { throw SignError.badCertificate }
        return Item(tag: tag, content: bytes[i..<i + len], whole: bytes[bytes.startIndex..<i + len])
    }

    static func children(_ bytes: ArraySlice<UInt8>) throws -> [Item] {
        var items: [Item] = []
        var rest = bytes
        while !rest.isEmpty {
            let item = try read(rest)
            items.append(item)
            rest = rest[item.whole.endIndex...]
        }
        return items
    }
}

// Нужное из сертификата разработчика: издатель и серийный номер (для SignerInfo) и OU субъекта — команда.
struct CertificateInfo {
    let issuer: [UInt8]
    let serial: [UInt8]
    let teamID: String?
    let commonName: String?
    let notAfter: Date?

    init(der: [UInt8]) throws {
        let cert = try DER.read(der[...])
        let tbs = try DER.read(cert.content)
        var fields = try DER.children(tbs.content)
        if fields.first?.tag == 0xa0 { fields.removeFirst() }  // [0] version
        guard fields.count >= 5 else { throw SignError.badCertificate }
        serial = Array(fields[0].whole)
        issuer = Array(fields[2].whole)
        var team: String?, name: String?
        for rdn in try DER.children(fields[4].content) {
            for attribute in try DER.children(rdn.content) {
                let parts = try DER.children(attribute.content)
                guard parts.count == 2 else { continue }
                let value = String(decoding: parts[1].content, as: UTF8.self)
                if Array(parts[0].whole) == DER.oid("2.5.4.11") { team = value }
                if Array(parts[0].whole) == DER.oid("2.5.4.3") { name = value }
            }
        }
        teamID = team
        commonName = name
        // Срок: validity — SEQUENCE { notBefore, notAfter }, UTCTime (ГГММДДччммссZ) или GeneralizedTime.
        let validity = try DER.children(fields[3].content)
        if validity.count == 2 {
            let text = String(decoding: validity[1].content, as: UTF8.self)
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = validity[1].tag == 0x17 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
            notAfter = f.date(from: text)
        } else {
            notAfter = nil
        }
    }
}
