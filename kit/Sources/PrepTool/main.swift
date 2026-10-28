// PrepTool convert ВХОД ВЫХОД [RPATH] — переделать один Mach-O (без подписи): сверка с tools/macport_convert.py.
// PrepTool prepare ПРИЛОЖЕНИЕ.app ЗАМЕНИТЕЛИ [P12 ПАРОЛЬ] — подготовить копию Mac-приложения на месте, как на
// телефоне (с подписью, если дан .p12).

import Foundation
import MachOSign
import MacportPrep

let args = CommandLine.arguments
func fail(_ text: String) -> Never {
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
    exit(1)
}
do {
    switch args.count > 1 ? args[1] : "" {
    case "convert" where args.count >= 4:
        let input = [UInt8](try Data(contentsOf: URL(fileURLWithPath: args[2])))
        var result = try MachOConvert.convert(input, rpath: args.count > 4 ? args[4] : "@loader_path/../Frameworks")
        let patches = BinaryPatches.apply(to: &result.data, fileName: URL(fileURLWithPath: args[2]).lastPathComponent)
        try Data(result.data).write(to: URL(fileURLWithPath: args[3]))
        (result.report + patches).forEach { print($0) }
        print("заменители:", result.shims.sorted().joined(separator: " "))
    case "prepare" where args.count >= 4:
        var identity: SigningIdentity?
        if args.count >= 6 {
            identity = try SigningIdentity.pkcs12(try Data(contentsOf: URL(fileURLWithPath: args[4])), password: args[5])
        }
        let start = Date()
        try AppPreparer(app: URL(fileURLWithPath: args[2]), shims: URL(fileURLWithPath: args[3]), identity: identity,
                        log: { print($0) }).prepare()
        print(String(format: "готово за %.1f с", Date().timeIntervalSince(start)))
    default:
        fail("PrepTool convert ВХОД ВЫХОД [RPATH] | prepare ПРИЛОЖЕНИЕ.app ЗАМЕНИТЕЛИ [P12 ПАРОЛЬ]")
    }
} catch {
    fail("ошибка: \(error)")
}
