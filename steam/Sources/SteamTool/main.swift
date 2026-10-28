// SPDX-License-Identifier: GPL-3.0-or-later
// SteamTool depots APPID — анонимный вход в Steam: депо приложения (ОС, размер) и выбор для macOS и Windows.

import ContentKit
import Foundation
import SteamClientKit

let args = CommandLine.arguments
guard args.count == 3, ["depots", "ufs"].contains(args[1]), let appID = UInt32(args[2]) else {
    print("SteamTool depots|ufs APPID")
    exit(2)
}
let log = Logger(verbose: false) { FileHandle.standardError.write(($0 + "\n").data(using: .utf8)!) }
let session = SteamSession(store: MemorySecretStore(), log: log)
do {
    _ = try await session.logOnAnonymous()
    if args[1] == "ufs" {
        // Правила облака: PICS ufs (savefiles, rootoverrides, квота).
        func dump(_ kv: KeyValue, _ indent: String) {
            if let value = kv.value {
                print("\(indent)\(kv.name) = \(value)")
            } else {
                print("\(indent)\(kv.name)")
                for child in kv.children { dump(child, indent + "  ") }
            }
        }
        if let app = try await session.appRecords([appID])[appID], let ufs = app.path("ufs") { dump(ufs, "") }
        await session.disconnect()
        exit(0)
    }
    let app = try await Library(session: session).depots(appID: appID)
    print("\(app.appID) \(app.name), installdir \(app.installDir ?? "-"), сборка \(app.publicBuildID.map(String.init) ?? "?")")
    for d in app.depots {
        let size = d.publicManifestSize.map { String(format: "%.1f ГБ", Double($0) / 1e9) } ?? "-"
        print("  депо \(d.depotID) \(d.name ?? "") ОС [\(d.osList.joined(separator: ","))] \(d.osArch ?? "") \(size)"
              + (d.language.map { " язык \($0)" } ?? "") + (d.dlcAppID.map { " DLC \($0)" } ?? "")
              + (d.depotFromApp.map { " из приложения \($0)" } ?? ""))
    }
    for platform in ["macos", "windows"] {
        let s = try DepotSelection.select(app, .init(platform: platform))
        print("\(platform): " + s.depots.map { String($0.depotID) }.joined(separator: " ")
              + String(format: " — %.1f ГБ", Double(s.depots.compactMap(\.publicManifestSize).reduce(0, +)) / 1e9))
    }
} catch {
    print("ошибка: \(error)")
    exit(1)
}
await session.disconnect()
