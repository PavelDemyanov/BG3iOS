// Подпись CMS (SignedData без содержимого) над CodeDirectory, как у codesign: подписанные атрибуты — тип
// содержимого, время, хеш CodeDirectory и два атрибута Apple с хешами CodeDirectory (plist и SHA-256 целиком);
// сертификаты — разработчика, WWDR, корневой.

import CryptoKit
import Foundation

enum CMS {
    static let sha256 = "2.16.840.1.101.3.4.2.1"

    static func signature(codeDirectory: [UInt8], identity: SigningIdentity, date: Date = Date()) throws -> [UInt8] {
        let cdHash = [UInt8](SHA256.hash(data: codeDirectory))
        // Список хешей CodeDirectory: plist с первыми 20 байтами (1.2.840.113635.100.9.1) и последовательность
        // «алгоритм, хеш» (…100.9.2).
        let plist = try PropertyListSerialization.data(fromPropertyList: ["cdhashes": [Data(cdHash.prefix(20))]],
                                                       format: .xml, options: 0)
        func attribute(_ oid: String, _ value: [UInt8]) -> [UInt8] { DER.sequence([DER.oid(oid), DER.set([value])]) }
        let attributes = [
            attribute("1.2.840.113549.1.9.3", DER.oid("1.2.840.113549.1.7.1")),
            attribute("1.2.840.113549.1.9.5", DER.utcTime(date)),
            attribute("1.2.840.113549.1.9.4", DER.octets(cdHash)),
            attribute("1.2.840.113635.100.9.1", DER.octets([UInt8](plist))),
            attribute("1.2.840.113635.100.9.2", DER.sequence([DER.oid(sha256), DER.octets(cdHash)])),
        ]
        // Подписывается DER-кодировка SET OF атрибутов; в SignerInfo тот же набор — с тегом [0].
        let signedSet = DER.set(attributes)
        let signature = try identity.sign(signedSet)
        let signerInfo = DER.sequence([
            DER.integer(1),
            DER.sequence([identity.info.issuer, identity.info.serial]),
            DER.sequence([DER.oid(sha256), DER.null]),
            [0xa0] + Array(signedSet.dropFirst()),
            DER.sequence([DER.oid("1.2.840.113549.1.1.1"), DER.null]),
            DER.octets(signature),
        ])
        let certificates = DER.node(0xa0, ([identity.certificate] + identity.chain).flatMap { $0 })
        let signedData = DER.sequence([
            DER.integer(1),
            DER.set([DER.sequence([DER.oid(sha256), DER.null])]),
            DER.sequence([DER.oid("1.2.840.113549.1.7.1")]),
            certificates,
            DER.set([signerInfo]),
        ])
        return DER.sequence([DER.oid("1.2.840.113549.1.7.2"), DER.node(0xa0, signedData)])
    }
}
