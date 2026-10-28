// ExportIdentity SHA1 ФАЙЛ.p12 — выгрузить из связки ключей одно удостоверение (сертификат и закрытый ключ) по
// SHA-1 сертификата (security find-identity -v -p codesigning) в .p12. Пароль файла — случайный, печатается в
// stdout: так тестовый .p12 для проверки подписи на телефоне получается без чужих паролей. macOS спросит
// разрешение на выгрузку ключа — это решает владелец связки.

import CryptoKit
import Foundation
import Security

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("ExportIdentity SHA1 ФАЙЛ.p12\n".data(using: .utf8)!)
    exit(2)
}
let wanted = args[1].uppercased()
var result: CFTypeRef?
let query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecMatchLimit as String: kSecMatchLimitAll,
                            kSecReturnRef as String: true]
guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let identities = result as? [SecIdentity] else {
    FileHandle.standardError.write("удостоверений нет\n".data(using: .utf8)!)
    exit(1)
}
for identity in identities {
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { continue }
    let sha1 = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
    guard sha1.map({ String(format: "%02X", $0) }).joined() == wanted else { continue }
    var bytes = [UInt8](repeating: 0, count: 18)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let password = Data(bytes).base64EncodedString().replacingOccurrences(of: "/", with: "_")
    var params = SecItemImportExportKeyParameters()
    params.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    params.passphrase = Unmanaged.passRetained(password as CFString)
    var exported: CFData?
    let status = SecItemExport(identity, .formatPKCS12, [], &params, &exported)
    guard status == errSecSuccess, let exported else {
        FileHandle.standardError.write("выгрузка не удалась: OSStatus \(status)\n".data(using: .utf8)!)
        exit(1)
    }
    try (exported as Data).write(to: URL(fileURLWithPath: args[2]))
    print(password)
    exit(0)
}
FileHandle.standardError.write("удостоверение \(wanted) не найдено\n".data(using: .utf8)!)
exit(1)
