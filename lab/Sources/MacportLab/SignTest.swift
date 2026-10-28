// --sign-test: подпись на телефоне. Documents/sign-test/identity.p12 и password.txt (удостоверение — как его отдаёт
// AltStore), probe-unsigned.dylib (неподписанная библиотека с macport_probe() → 42). Подписанная копия — probe.dylib,
// затем dlopen и вызов. В конце — dlopen неподписанной: она не должна загрузиться (значит, дело именно в подписи).
// Ход — в Documents/sign-test/log.txt построчно (если процесс убьют, начало останется).

import Foundation
import MachOSign

enum SignTest {
    static func run() -> String {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sign-test")
        let logURL = dir.appendingPathComponent("log.txt")
        try? FileManager.default.removeItem(at: logURL)
        var lines: [String] = []
        func say(_ line: String) {
            lines.append(line)
            try? lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
        }
        do {
            let p12 = try Data(contentsOf: dir.appendingPathComponent("identity.p12"))
            let password = try String(contentsOf: dir.appendingPathComponent("password.txt"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let identity = try SigningIdentity.pkcs12(p12, password: password)
            say("удостоверение: команда \(identity.teamID)")
            let unsigned = dir.appendingPathComponent("probe-unsigned.dylib")
            let signed = dir.appendingPathComponent("probe.dylib")
            try? FileManager.default.removeItem(at: signed)
            try FileManager.default.copyItem(at: unsigned, to: signed)
            let start = Date()
            try MachOSigner.sign(file: signed, identifier: "probe", identity: identity)
            say(String(format: "подписано на телефоне за %.0f мс", Date().timeIntervalSince(start) * 1000))
            guard let handle = dlopen(signed.path, RTLD_NOW) else {
                say("dlopen подписанной: \(String(cString: dlerror()))")
                return lines.joined(separator: "\n")
            }
            typealias Probe = @convention(c) () -> Int32
            if let symbol = dlsym(handle, "macport_probe") {
                say("dlopen подписанной: да, macport_probe() = \(unsafeBitCast(symbol, to: Probe.self)())")
            } else {
                say("dlopen подписанной: да, но macport_probe нет")
            }
            if dlopen(unsigned.path, RTLD_NOW) == nil {
                say("dlopen неподписанной: нет (\(String(cString: dlerror())))")
            } else {
                say("dlopen неподписанной: загрузилась (подпись не проверяется?)")
            }
        } catch {
            say("ошибка: \(error)")
        }
        return lines.joined(separator: "\n")
    }
}
