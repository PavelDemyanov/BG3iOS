// SPDX-License-Identifier: GPL-3.0-or-later
// Steam в приложении: вход (логин, пароль и Steam Guard), проверка лицензии Mac-версии BG3, установка macOS-депо
// (клиент Steam из Playport, vendor/playport), подготовка к запуску на телефоне (MacportPrep) и запуск.
// Уже лежащую копию игры (Documents/MacApps, перенесённую с Mac) можно принять: манифесты берутся из Steam, файлы
// сверяются, докачиваются только отличающиеся (TitleInstaller.adopt + repair) — без повторных 156 ГБ.
// Установка — Documents/Games/<папка Steam>/<имя>.app; состояние Steam — Library/Application Support/Macport;
// журнал — Documents/steam.log.

import ContentKit
import CryptoKit
import Foundation
import MachOSign
import MacportPrep
import SteamClientKit
import SwiftUI
import UIKit

@MainActor
final class SteamCenter: ObservableObject {
    static let shared = SteamCenter()
    static let bg3: UInt32 = 1086940
    static let legacyName = "Baldur's Gate 3"  // копия, перенесённая с Mac: Documents/MacApps/<имя>.app

    enum GameState: Equatable {
        case unknown, notInstalled, legacyCopy, installed, ready
    }

    enum SignInStep: Equatable {
        case idle, working, approveOnPhone, code(String), failed(String)
    }

    @Published var account: SteamService.AccountState = .unknown
    @Published var persona: String?
    @Published var owned: Bool?
    @Published var game: GameState = .unknown
    @Published var busy: String?          // что сейчас делается (скачивание, проверка, подготовка)
    @Published var progress: Double?      // 0…1
    @Published var detail = ""            // последняя строка хода
    @Published var signIn: SignInStep = .idle
    @Published var cloud: CloudState = .idle
    @Published var cloudDetail = ""  // какой сейв скачивается
    @Published var downloadPaused = false  // начатая загрузка лежит на диске — её можно продолжить

    enum CloudState: Equatable {
        case idle, syncing
        case synced(Date, down: Int, up: Int)
        case conflicts([SteamService.CloudConflict])
        case failed(String)
    }

    nonisolated let service: SteamService
    nonisolated let layout: InstallLayout
    nonisolated let log: Logger
    private var codes: GuardCodeInbox?
    private var work: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var bytesDone: UInt64 = 0  // сколько игры уже на диске — по последнему отчёту загрузки

    // Начатая пользователем загрузка (Download / Resume, без Stop) — пережить выгрузку приложения из памяти.
    private static let downloadWantedKey = "MacportDownloadWanted"
    private var wantsDownload: Bool {
        get { UserDefaults.standard.bool(forKey: Self.downloadWantedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.downloadWantedKey) }
    }

    private init() {
        let fm = FileManager.default
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        layout = InstallLayout(stagingRoot: library.appendingPathComponent("Macport/staging", isDirectory: true),
                               gamesRoot: documents.appendingPathComponent("Games", isDirectory: true),
                               stateRoot: library.appendingPathComponent("Application Support/Macport", isDirectory: true))
        try? fm.createDirectory(at: layout.stateRoot.appendingPathComponent("steam"), withIntermediateDirectories: true)
        let file = SteamLogFile(url: documents.appendingPathComponent("steam.log"))
        log = Logger(verbose: false) { file.write($0) }
        let session = SteamSession(store: KeychainSecretStore(service: "com.redpax.macport.steam"), log: log)
        service = SteamService(backend: session, log: log, stateDirectory: layout.stateRoot.appendingPathComponent("steam"))
        let service = service
        Task { @MainActor in
            for await state in await service.observe() {
                self.account = state
                switch state {
                case .signedIn, .offline: await self.refreshLibrary()
                case .signedOut, .expired: self.owned = nil
                default: break
                }
            }
        }
        // Докачка. Пока BG3iOS на экране, загрузка идёт; ушли в другое приложение — ещё около 30 с (фоновая задача),
        // потом iOS приложение усыпляет, соединения рвутся, а то и выгружает его из памяти. Скачанное остаётся
        // в staging с журналом частей (ContentKit), так что по возвращении загрузка продолжается с того же места.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { SteamCenter.shared.keepWorkingInBackground() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated {
                let center = SteamCenter.shared
                center.endBackgroundTask()
                center.resumeDownloadIfWanted()
            }
        }
        // Пришёл новый сертификат (AltStore переустановили или он сменил сертификат) — игру переподписать им:
        // библиотеки, подписанные отозванным, не загрузятся. Скачанная без сертификата игра готовится тут же.
        NotificationCenter.default.addObserver(forName: CertificateStore.changed, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let center = SteamCenter.shared
                if center.receipt != nil, CertificateStore.identity != nil { center.prepare() }
            }
        }
        Task { @MainActor in
            await service.restoreIfPossible()
            self.refreshGame()
        }
    }

    // Языковое депо BG3 — только файл language.lsx, тексты всех языков — в основном депо; язык игры ставит
    // BG3Language перед запуском. Депо всегда английское: смена языка не должна менять установку (её депо).
    var language: String { "english" }
    var installer: TitleInstaller { TitleInstaller(layout: layout, session: nil, log: log) }
    var receipt: InstallReceipt? { installer.loadReceipt(Self.bg3) }
    var gameFolder: URL? { receipt.map { layout.gamesRoot.appendingPathComponent($0.installDir, isDirectory: true) } }
    var preparedMarker: URL? { gameFolder?.appendingPathComponent(".macport-prepared") }
    // Содержимое метки: сборка игры из Steam и отпечаток заменителей в бандле. Подготовка кладёт заменители в игру
    // один раз, а новая версия BG3iOS могла привезти другие (например, MPMetal) — по метке видно, что пора заново.
    var preparedStamp: String { (receipt?.buildID.map(String.init) ?? "") + " shims " + Self.shimsFingerprint }

    static let shimsFingerprint: String = {
        guard let dir = Bundle.main.url(forResource: "shims", withExtension: nil),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() else { return "-" }
        var hash = SHA256()
        for name in names {
            hash.update(data: Data(name.utf8))
            if let data = try? Data(contentsOf: dir.appendingPathComponent(name)) { hash.update(data: data) }
        }
        return hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }()
    var legacyApp: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacApps/\(Self.legacyName).app")
    }

    // Приложение в папке установки (у BG3 — «Baldur's Gate 3.app»).
    var appURL: URL? {
        guard let folder = gameFolder,
              let name = try? FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
                  .first(where: { $0.hasSuffix(".app") }) else { return nil }
        return folder.appendingPathComponent(name)
    }

    func refreshGame() {
        let fm = FileManager.default
        downloadPaused = receipt == nil && hasDownloadedChunks()
        if receipt != nil {
            game = preparedMarker.map { fm.fileExists(atPath: $0.path) } == true ? .ready : .installed
        } else {
            #if MACPORT_DEVELOPER
            game = fm.fileExists(atPath: legacyApp.path) ? .legacyCopy : .notInstalled
            #else
            game = .notInstalled
            #endif
        }
    }

    // Играть можно только с лицензией: аккаунт Steam (на связи или без неё, но уже входивший), игра в его
    // библиотеке и установка из Steam через приложение (квитанция установки) — подготовленная.
    var canPlay: Bool { account.account != nil && owned == true && receipt != nil && game == .ready }

    // MARK: сейвы в Steam Cloud (BG3Cloud.swift)

    var cloudBackups: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Steam Cloud Backups", isDirectory: true)
    }

    // Синхронизация сейвов; resolve — выбор игрока для различающихся. Без лицензии и установки — не нужна.
    func syncSaves(resolve: [String: SteamService.CloudChoice] = [:]) async {
        guard owned == true, receipt != nil, cloud != .syncing else { return }
        cloud = .syncing
        cloudDetail = ""
        do {
            let sync = { [self] in
                try await service.syncCloud(appID: Self.bg3, roots: BG3CloudLocations.standard,
                                            backups: cloudBackups, resolve: resolve,
                                            progress: { name, done, total in
                    Task { @MainActor in
                        self.cloudDetail = "Downloaded \(done) of \(total): \(BG3CloudLocations.title(name))"
                    }
                })
            }
            let result: SteamService.CloudSync
            do {
                result = try await sync()
            } catch ClientError.transport, ClientError.timeout {
                // Соединение со Steam оборвалось (iOS рвёт сокеты, пока приложение в фоне) — войти заново и ещё раз.
                await service.restoreIfPossible()
                result = try await sync()
            }
            if !result.failed.isEmpty { log.warn("cloud", "failed: \(result.failed)") }
            // Превью для сейвов из облака (там только .lsv) — из самих .lsv.
            let profiles = BG3CloudLocations.standard.profiles
            let thumbnails = await Task.detached(priority: .utility) { BG3SaveThumbnails.fill(profiles: profiles) }.value
            if thumbnails > 0 { say("save previews restored: \(thumbnails)") }
            cloud = result.conflicts.isEmpty ? .synced(result.at, down: result.downloaded.count, up: result.uploaded.count)
                                             : .conflicts(result.conflicts)
        } catch ClientError.transport, ClientError.timeout {
            cloud = .failed("no connection to Steam")
        } catch {
            cloud = .failed("\(error)")
        }
    }

    // «Keep iPhone's» — копии телефона уходят в Steam. «Keep Steam's» — телефон как в Steam: различающиеся
    // заменяются копиями Steam, а сейвы, которых в Steam нет, переносятся (папкой, с миниатюрой) в Steam Cloud
    // Backups — из игры пропадают, но 30 дней их можно вернуть.
    func settleConflicts(_ choice: SteamService.CloudChoice) {
        guard case .conflicts(let list) = cloud else { return }
        Task { @MainActor in
            if choice == .steam { movePhoneOnlySaves(list) }
            await syncSaves(resolve: SteamService.resolveAll(list, choice))
        }
    }

    private func movePhoneOnlySaves(_ list: [SteamService.CloudConflict]) {
        let fm = FileManager.default
        let target = cloudBackups.appendingPathComponent("\(Self.bg3)/\(Cloud.Backups.folderName(for: Date())) removed",
                                                         isDirectory: true)
        let story = BG3CloudLocations.standard.profiles.appendingPathComponent("Public/Savegames/Story").standardizedFileURL.path
        for conflict in list where conflict.phoneSize != nil && conflict.steamSize == nil {
            guard let file = BG3CloudLocations.standard.file(conflict.name) else { continue }
            let folder = file.deletingLastPathComponent().standardizedFileURL
            guard folder.deletingLastPathComponent().path == story else { continue }  // только папка сейва в Story
            do {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try fm.moveItem(at: folder, to: target.appendingPathComponent(folder.lastPathComponent))
                say("moved to Steam Cloud Backups: \(folder.lastPathComponent)")
            } catch {
                say("Error: can't move \(folder.lastPathComponent): \(error)")
            }
        }
    }

    func refreshLibrary() async {
        persona = try? await service.backend.personaName()
        if let games = try? await service.ownedGames(refresh: owned == nil) {
            owned = games.contains { $0.info.appID == Self.bg3 }
        } else if let cached = await service.cachedGames() {
            owned = cached.games.contains { $0.info.appID == Self.bg3 }  // без связи — последний список аккаунта
        }
        refreshGame()
        if case .signedIn = account, game == .ready, cloud == .idle { await syncSaves() }  // при запуске приложения
        resumeDownloadIfWanted()  // приложение выгружали посреди загрузки
    }

    // MARK: вход

    func signIn(login: String, password: String) {
        let inbox = GuardCodeInbox()
        codes = inbox
        signIn = .working
        let stream = service.signIn(method: .credentials(CredentialLogin(accountName: login, password: Secret(password),
                                                                          codes: inbox)))
        work = Task { @MainActor in
            do {
                for try await event in stream {
                    switch event {
                    case .confirm(let allowed):
                        let types = Set(allowed.map(\.type))
                        if types.contains(.deviceCode) && types.contains(.deviceConfirmation) {
                            signIn = .code("Approve the sign-in in the Steam app, or enter the Steam Guard code from it")
                        } else if types.contains(.deviceCode) {
                            signIn = .code("Steam Guard code from the Steam app")
                        } else if types.contains(.emailCode) {
                            let domain = allowed.first { $0.type == .emailCode }?.message.map { " (\($0))" } ?? ""
                            signIn = .code("Code from the Steam email\(domain)")
                        } else {
                            signIn = .approveOnPhone
                        }
                    case .codeRejected:
                        if case .code(let prompt) = signIn { signIn = .code(prompt + " (wrong code, try again)") }
                    case .codeAccepted:
                        signIn = .working
                    case .signedIn:
                        signIn = .idle
                    default:
                        break
                    }
                }
            } catch {
                signIn = .failed(Self.describe(error))
            }
        }
    }

    func submit(code: String) {
        codes?.submit(code.trimmingCharacters(in: .whitespacesAndNewlines))
        signIn = .working
    }

    func cancelSignIn() {
        work?.cancel()
        signIn = .idle
    }

    func signOut() {
        Task { @MainActor in
            _ = try? await service.signOut()
            owned = nil
            persona = nil
        }
    }

    static func describe(_ error: Error) -> String {
        switch error as? SignInFailure {
        case .wrongPassword?: "Wrong account name or password."
        case .throttled?: "Too many attempts. Please wait and try again."
        case .expired?: "The sign-in timed out."
        case .denied?: "The sign-in was denied."
        case .network(let why)?: "Can't reach Steam: \(why)"
        default: "\(error)"
        }
    }

    // MARK: установка, принятие копии, подготовка

    private func run(_ title: String, _ body: @escaping @MainActor (SteamCenter) async throws -> Void) {
        guard busy == nil else { return }
        busy = title
        progress = nil
        detail = ""
        // Пока идёт работа, экран не гаснет: в фоне iOS её приостановит.
        UIApplication.shared.isIdleTimerDisabled = true
        work = Task { @MainActor in
            do {
                try await body(self)
            } catch let ClientError.unsupported(message) {
                self.say(message)  // наши сообщения для пользователя (нет места, нет сертификата) — как есть
            } catch {
                self.say("Error: \(error)")
            }
            UIApplication.shared.isIdleTimerDisabled = false
            self.busy = nil
            self.progress = nil
            self.refreshGame()
            self.endBackgroundTask()
        }
    }

    nonisolated func say(_ line: String) {
        Task { @MainActor in self.detail = line }
        log.info("macport", line)
    }

    private func onProgress(_ p: InstallEngine.Progress) {
        bytesDone = p.bytesDone
        progress = p.bytesTotal > 0 ? Double(p.bytesDone) / Double(p.bytesTotal) : nil
        let speed = p.seconds > 0 ? Double(p.downloadedBytes) / p.seconds / 1e6 : 0
        detail = String(format: "%.1f of %.1f GB, %.0f MB/s", Double(p.bytesDone) / 1e9, Double(p.bytesTotal) / 1e9, speed)
    }

    static let downloading = "Downloading from Steam"

    // Скачать или докачать: начатая загрузка продолжается с того же места (stage и журнал на диске).
    func install() {
        let request = TitleInstaller.Request(appID: Self.bg3, selection: .init(language: language, platform: "macos"))
        wantsDownload = true
        run(Self.downloading) { center in
            // Обрыв (связь порвалась, пока приложение спало в фоне; серверы Steam не отдают куски) — ещё раз через
            // 10 с в той же работе, кнопка не мигает. Три обрыва подряд без продвижения — ошибка и Resume Download.
            var failures = 0
            while true {
                let before = center.bytesDone
                do {
                    let installer = try await center.service.titleInstaller(layout: center.layout)
                    _ = try await installer.install(request, progress: { p in Task { @MainActor in center.onProgress(p) } },
                                                    say: { center.say($0) })
                    break
                } catch let ClientError.insufficientSpace(needed, available) {
                    // Места не хватает — повторять бесполезно: ждём, пока пользователь освободит место (Resume Download).
                    center.wantsDownload = false
                    throw SteamError.unsupported(String(
                        format: "Not enough free space: %.1f GB needed (the rest of the game plus a 5%% reserve), %.1f GB free. "
                            + "Free up %.1f GB, then tap Resume Download.",
                        Double(needed) / 1e9, Double(available) / 1e9, Double(needed - min(needed, available)) / 1e9))
                } catch {
                    switch error {
                    case is CancellationError, ClientError.cancelled, ClientError.unsupported: throw error
                    default: break
                    }
                    failures = center.bytesDone > before ? 1 : failures + 1
                    guard failures <= 3 else { throw error }
                    center.say("Steam didn't answer (\(error)). Trying again in 10 s…")
                    try await Task.sleep(for: .seconds(10))
                }
            }
            center.wantsDownload = false
            try await center.prepareNow()
        }
    }

    // Начатая загрузка, в которой уже что-то скачано: в журнале есть записи (заголовок — 32 байта, запись — 32).
    // Попытка, оборвавшаяся до первого куска (нет места, нет связи), оставляет пустой журнал — это не «Resume».
    private func hasDownloadedChunks() -> Bool {
        let staging = layout.stagingRoot
        let names = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        return names.contains { name in
            guard name.hasPrefix("\(Self.bg3)_"), name.hasSuffix(".journal"), !name.hasSuffix(".repair.journal") else {
                return false
            }
            return (InstallFS.fileSize(staging.appendingPathComponent(name)) ?? 0) > 32
        }
    }

    // Продолжить загрузку, которую пользователь начал и не останавливал, — когда приложение снова на экране
    // и Steam на связи.
    func resumeDownloadIfWanted() {
        guard wantsDownload, busy == nil, receipt == nil, owned == true, UIApplication.shared.applicationState == .active
        else { return }
        guard case .signedIn = account else { return }
        install()
    }

    // Ушли из приложения посреди работы — попросить у iOS ещё немного времени (около 30 с), чтобы она шла и в фоне.
    private func keepWorkingInBackground() {
        guard busy != nil, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "BG3iOS download") {
            MainActor.assumeIsolated { SteamCenter.shared.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // Копия с Mac → папка установки, манифесты из Steam, сверка и докачка отличающегося, подготовка.
    func adoptLegacy() {
        let request = TitleInstaller.Request(appID: Self.bg3, selection: .init(language: language, platform: "macos"))
        run("Verifying with Steam") { center in
            let info = try await center.service.appInfo(Self.bg3)
            let folder = info.installDir ?? "Baldurs Gate 3"
            let fm = FileManager.default
            let target = center.layout.gamesRoot.appendingPathComponent(folder, isDirectory: true)
            let legacy = center.legacyApp
            if fm.fileExists(atPath: legacy.path) {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try fm.moveItem(at: legacy, to: target.appendingPathComponent(legacy.lastPathComponent))
                center.say("Mac copy moved to Games/\(folder)")
            }
            let installer = try await center.service.titleInstaller(layout: center.layout)
            _ = try await installer.adopt(request, folder: folder, say: { center.say($0) })
            let report = try await installer.repair(appID: Self.bg3, progress: { p in Task { @MainActor in center.onProgress(p) } },
                                                    checked: { files, total, bytes, all in
                                                        Task { @MainActor in
                                                            center.progress = all > 0 ? Double(bytes) / Double(all) : nil
                                                            center.detail = String(format: "Verified %.0f of %.0f GB (%d of %d files)",
                                                                                   Double(bytes) / 1e9, Double(all) / 1e9, files, total)
                                                        }
                                                    }, say: { center.say($0) })
            center.say("Verified \(report.files) files, replaced \(report.repaired ?? 0), still bad: \(report.bad.count)")
            if let marker = center.preparedMarker { try? fm.removeItem(at: marker) }
            try await center.prepareNow()
        }
    }

    func prepare() {
        run("Preparing for iPhone") { center in try await center.prepareNow() }
    }

    // Перед Play: игру готовила другая версия приложения — подготовить заново (несколько секунд: AppPreparer
    // повторно безопасен, уже переделанные файлы только переподписываются). false — не вышло, причина — в detail.
    func prepareIfStale() async -> Bool {
        guard let marker = preparedMarker else { return false }
        if (try? String(contentsOf: marker, encoding: .utf8)) == preparedStamp { return true }
        run("Updating the game for this version of BG3iOS") { center in try await center.prepareNow() }
        await work?.value
        return (try? String(contentsOf: marker, encoding: .utf8)) == preparedStamp
    }

    // Переделка и подпись Mac-бинарников на телефоне сертификатом из AltStore/SideStore.
    private func prepareNow() async throws {
        guard let app = appURL, let marker = preparedMarker else { throw SteamError.notFound("the game is not installed") }
        busy = "Preparing for iPhone"
        #if MACPORT_DEVELOPER
        let fallback = Self.testIdentity()
        #else
        let fallback: SigningIdentity? = nil
        #endif
        guard let identity = CertificateStore.identity ?? fallback else {
            throw SteamError.unsupported("No signing certificate. Get it from AltStore or SideStore under Signing Certificate.")
        }
        guard let shims = Bundle.main.url(forResource: "shims", withExtension: nil) else {
            throw SteamError.notFound("the app has no shims")
        }
        let started = Date()
        try await Task.detached(priority: .userInitiated) {
            try AppPreparer(app: app, shims: shims, identity: identity, log: { self.say($0) }).prepare()
        }.value
        try Data(preparedStamp.utf8).write(to: marker)
        say(String(format: "Prepared in %.1f s. Ready to play.", Date().timeIntervalSince(started)))
    }

    // Проверочный сертификат разработчика (Documents/sign-test), пока нет из AltStore.
    nonisolated static func testIdentity() -> SigningIdentity? {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("sign-test")
        guard let p12 = try? Data(contentsOf: dir.appendingPathComponent("identity.p12")),
              let password = try? String(contentsOf: dir.appendingPathComponent("password.txt"), encoding: .utf8) else { return nil }
        return try? SigningIdentity.pkcs12(p12, password: password.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // Разведка облака (сборка разработчика): файлы BG3 в Steam Cloud аккаунта — в журнал (имена, размеры, время).
    func listCloudToLog() async {
        await service.restoreIfPossible()
        do {
            let list = try await service.backend.cloudChangelist(appID: Self.bg3)
            say("cloud: change \(list.currentChangeNumber), \(list.files.count) files, prefixes \(list.pathPrefixes)")
            for f in list.files.sorted(by: { $0.name < $1.name }) {
                let time = Date(timeIntervalSince1970: TimeInterval(f.timeStamp)).formatted(.iso8601)
                say("cloud: \(f.prefixIndex.map { "[\($0)] " } ?? "")\(f.name) \(f.rawSize) B \(time) persist \(f.persistState)")
            }
        } catch {
            say("cloud: error \(error)")
        }
    }

    // Stop: работа прерывается; начатая загрузка остаётся на диске, но сама уже не продолжится — Resume Download.
    func cancelWork() {
        wantsDownload = false
        work?.cancel()
    }

    // Перед игрой — свежие сейвы из Steam Cloud (и туда — сделанные на телефоне в прошлый раз), затем закрыть
    // соединение со Steam: игре оно не нужно. Без связи синхронизация не держит запуск дольше 45 с.
    func beforePlay() async {
        if case .signedIn = account {
            let sync = Task { @MainActor in await self.syncSaves() }
            let timeout = Task { try? await Task.sleep(for: .seconds(45)); sync.cancel() }
            await sync.value
            timeout.cancel()
        }
        await service.backend.disconnect()
    }
}

// Журнал Steam в файл: строки приходят из разных потоков.
final class SteamLogFile: @unchecked Sendable {
    private let queue = DispatchQueue(label: "macport.steam.log")
    private let url: URL

    init(url: URL) {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    func write(_ line: String) {
        queue.async {
            guard let handle = try? FileHandle(forWritingTo: self.url) else { return }
            handle.seekToEndOfFile()
            handle.write(Data((Date().formatted(date: .omitted, time: .standard) + " " + line + "\n").utf8))
            try? handle.close()
        }
    }
}
