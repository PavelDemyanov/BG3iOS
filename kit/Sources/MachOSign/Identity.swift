// Удостоверение для подписи: сертификат разработчика и его закрытый ключ из .p12 (так их отдают AltStore и
// SideStore), плюс цепочка Apple. Подпись — RSA PKCS#1 v1.5 с SHA-256 через SecKeyCreateSignature.

import Foundation
import Security

public enum SignError: Error, CustomStringConvertible {
    case pkcs12(OSStatus)
    case badCertificate
    case noTeam
    case signature(String)
    case badMachO(String)

    public var description: String {
        switch self {
        case .pkcs12(let status): "can't open the .p12 (wrong password?) (OSStatus \(status))"
        case .badCertificate: "can't parse the certificate"
        case .noTeam: "the certificate has no team (OU)"
        case .signature(let why): "signing: \(why)"
        case .badMachO(let why): "Mach-O: \(why)"
        }
    }
}

public struct SigningIdentity: @unchecked Sendable {  // SecKey потокобезопасен
    public let certificate: [UInt8]  // DER сертификата разработчика
    public let chain: [[UInt8]]      // промежуточный и корневой
    public let teamID: String
    public var commonName: String? { info.commonName }
    public var expires: Date? { info.notAfter }
    let info: CertificateInfo
    let key: SecKey

    public static func pkcs12(_ data: Data, password: String) throws -> SigningIdentity {
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        #if os(macOS)
        options[kSecImportToMemoryOnly as String] = true  // на Mac — не класть ключ в связку ключей
        #endif
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let list = items as? [[String: Any]], let first = list.first,
              let identityRef = first[kSecImportItemIdentity as String] else { throw SignError.pkcs12(status) }
        let identity = identityRef as! SecIdentity
        var certificate: SecCertificate?
        var key: SecKey?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
              SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key else { throw SignError.pkcs12(-1) }
        let der = [UInt8](SecCertificateCopyData(certificate) as Data)
        let info = try CertificateInfo(der: der)
        guard let team = info.teamID else { throw SignError.noTeam }
        return SigningIdentity(certificate: der,
                               chain: [[UInt8](AppleCertificates.wwdrG3), [UInt8](AppleCertificates.root)],
                               teamID: team, info: info, key: key)
    }

    func sign(_ message: [UInt8]) throws -> [UInt8] {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(message) as CFData,
                                                    &error) else {
            throw SignError.signature(error.map { String(describing: $0.takeRetainedValue()) } ?? "?")
        }
        return [UInt8](signature as Data)
    }
}
