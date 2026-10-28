// --prepare ИМЯ: подготовка Documents/MacApps/ИМЯ.app прямо на телефоне (MacportPrep.AppPreparer): переделка
// Mac-бинарников, заменители из бандла (папка shims), metallib, подпись сертификатом из AltStore/SideStore
// (CertificateStore) или проверочным из Documents/sign-test. Ход — на экране и в Documents/prepare.log.

import Foundation
import MachOSign
import MacportPrep

enum PrepareRun {
    static func run(name: String, show: @escaping @MainActor (String) -> Void) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logURL = documents.appendingPathComponent("prepare.log")
        nonisolated(unsafe) var lines: [String] = []
        @Sendable func say(_ line: String) {
            lines.append(line)
            try? lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async { MainActor.assumeIsolated { show(text) } }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Сертификат из AltStore/SideStore (CertificateStore), иначе — проверочный из Documents/sign-test.
                let saved = DispatchQueue.main.sync { MainActor.assumeIsolated { CertificateStore.identity } }
                let identity: SigningIdentity
                if let saved {
                    identity = saved
                } else {
                    let signTest = documents.appendingPathComponent("sign-test")
                    let password = try String(contentsOf: signTest.appendingPathComponent("password.txt"), encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    identity = try SigningIdentity.pkcs12(
                        try Data(contentsOf: signTest.appendingPathComponent("identity.p12")), password: password)
                }
                guard let shims = Bundle.main.url(forResource: "shims", withExtension: nil) else {
                    say("в бандле нет папки shims")
                    return
                }
                let start = Date()
                say("подготовка \(name).app, команда \(identity.teamID)")
                try AppPreparer(app: documents.appendingPathComponent("MacApps/\(name).app"), shims: shims,
                                identity: identity, log: { say($0) }).prepare()
                say(String(format: "готово за %.1f с", Date().timeIntervalSince(start)))
            } catch {
                say("ошибка: \(error)")
            }
        }
    }
}
