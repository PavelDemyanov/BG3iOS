// SignTool ФАЙЛ P12 ПАРОЛЬ [ИДЕНТИФИКАТОР] — подписать Mach-O на Mac тем же кодом, что в приложении
// (проверка: codesign -dvvv, codesign --verify, openssl cms -verify).

import Foundation
import MachOSign

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("SignTool ФАЙЛ P12 ПАРОЛЬ [ИДЕНТИФИКАТОР]\n".data(using: .utf8)!)
    exit(2)
}
do {
    let identity = try SigningIdentity.pkcs12(try Data(contentsOf: URL(fileURLWithPath: args[2])), password: args[3])
    let file = URL(fileURLWithPath: args[1])
    let identifier = args.count > 4 ? args[4] : file.deletingPathExtension().lastPathComponent
    try MachOSigner.sign(file: file, identifier: identifier, identity: identity)
    print("подписано: \(file.lastPathComponent), команда \(identity.teamID)")
} catch {
    FileHandle.standardError.write("ошибка: \(error)\n".data(using: .utf8)!)
    exit(1)
}
