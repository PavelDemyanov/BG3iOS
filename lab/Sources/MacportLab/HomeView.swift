// SPDX-License-Identifier: GPL-3.0-or-later
// Главный экран (интерфейс приложения — на английском, по решению владельца): дисклеймер при первом запуске,
// затем Baldur's Gate 3 — вход в Steam, проверка лицензии, скачивание из Steam, подготовка, Play / Play with FPS
// Counter, под ними — чем играть (Controls: экранный геймпад или контроллер). Играть можно только с лицензией: вход
// в Steam, игра в библиотеке аккаунта, установка из Steam через приложение (SteamCenter.canPlay). Ниже — язык игры
// (BG3Language), сброс графики на оптимальную (BG3Graphics), сейвы в Steam Cloud, сертификат подписи, аккаунт Steam
// и (в сборке разработчика) прежний список.

import GameController
import SteamClientKit
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @ObservedObject var steam = SteamCenter.shared
    let openLab: (() -> Void)?
    let play: (URL, Bool) -> Void

    @AppStorage(DisclaimerView.acceptedKey) private var disclaimerAccepted = false
    @State private var showSignIn = false
    @State private var confirmSignOut = false
    @State private var confirmGraphicsReset = false
    @State private var graphicsMessage: String?
    @State private var gameLanguage = BG3Language.current
    @State private var controls = Controls.mode
    @State private var controllers: [String] = []
    @State private var certificateText = ""
    @State private var certificateMessage: String?
    @State private var choosingCertificate = false
    @State private var importingP12 = false
    @State private var p12Data: Data?
    @State private var p12Password = ""

    var body: some View {
        List {
            Section { gameCard } header: {
                Text("Baldur's Gate 3").font(.title2.bold()).foregroundStyle(.primary).textCase(nil)
            } footer: {
                Text("A Steam license for Baldur's Gate 3 is required. BG3iOS is not affiliated with Larian Studios, Valve or Apple.")
            }
            if steam.owned == true, steam.game == .ready, steam.busy == nil {
                Section {
                    Picker("Language", selection: $gameLanguage) {
                        ForEach(BG3Language.all, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .onChange(of: gameLanguage) { _, id in BG3Language.current = id }
                } header: {
                    Text("Game Language")
                } footer: {
                    Text("The game's text language; voices are in English. Your iPhone's language is used unless you choose another.")
                }
                Section {
                    Button("Reset Graphics to Optimal") { confirmGraphicsReset = true }
                        .confirmationDialog("Reset graphics settings to optimal?", isPresented: $confirmGraphicsReset,
                                            titleVisibility: .visible) {
                            Button("Reset Graphics") {
                                do {
                                    try BG3Graphics.reset()
                                    graphicsMessage = "Optimal graphics settings will be used the next time you play."
                                } catch {
                                    graphicsMessage = "Couldn't reset graphics settings: \(error.localizedDescription)"
                                }
                            }
                        } message: {
                            Text("Your in-game graphics settings will be replaced.")
                        }
                } header: {
                    Text("Graphics")
                } footer: {
                    Text("Settings tuned for iPhone are applied on first launch: lower render resolution with FSR "
                         + "upscaling, low model detail, view distance and shadows. You can change them in the game's "
                         + "Options; this button brings them back.")
                }
                Section { cloudRows } header: {
                    Text("Steam Cloud Saves")
                } footer: {
                    Text("Saves sync with Steam Cloud when BG3iOS opens and before you play, so you can continue on "
                         + "your PC or Mac. Copies a sync replaces are kept for 30 days in Files › BG3iOS › Steam Cloud Backups.")
                }
            }
            Section {
                Button { choosingCertificate = true } label: {
                    LabeledContent("Signing Certificate", value: certificateText)
                }
            } footer: {
                Text("Required to play. BG3iOS signs the game on this iPhone with the same certificate AltStore or SideStore "
                     + "used to install BG3iOS: tap Signing Certificate and get it from the store you used.")
            }
            if let account = steam.account.account {
                Section("Steam Account") {
                    LabeledContent("Signed in as", value: steam.persona ?? account.accountTag)
                    // Выход отзывает сессию в Steam — только после подтверждения (случайное касание не разлогинит).
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                        .confirmationDialog("Sign out of Steam?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                            Button("Sign Out", role: .destructive) { steam.signOut() }
                        } message: {
                            Text("You'll need to sign in again to play.")
                        }
                }
            }
            if let openLab {
                Section { Button("Developer", action: openLab) }
            }
        }
        .navigationTitle("BG3iOS")
        .fullScreenCover(isPresented: Binding(get: { !disclaimerAccepted }, set: { _ in })) {
            DisclaimerView { disclaimerAccepted = true }
        }
        .sheet(isPresented: $showSignIn) { SignInView(steam: steam) }
        .onChange(of: steam.account) { _, state in if case .signedIn = state { showSignIn = false } }
        .onAppear(perform: refreshCertificate)
        .onReceive(NotificationCenter.default.publisher(for: CertificateStore.changed)) { _ in refreshCertificate() }
        .onAppear { refreshControllers(gone: nil) }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in refreshControllers(gone: nil) }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) {
            refreshControllers(gone: $0.object as? GCController)
        }
        .confirmationDialog("Signing Certificate", isPresented: $choosingCertificate) {
            ForEach([CertificateStore.Store.altStore, .sideStore], id: \.rawValue) { store in
                Button("Get from \(store.title)") {
                    Task { @MainActor in
                        if !(await CertificateStore.request(from: store)) {
                            certificateMessage = "\(store.title) didn't open. Is it installed?"
                        }
                    }
                }
            }
            Button("Import .p12 File…") { importingP12 = true }
            if CertificateStore.identity != nil {
                Button("Remove", role: .destructive) {
                    CertificateStore.remove()
                    refreshCertificate()
                }
            }
        } message: {
            // AltStore отдаёт сертификат, только когда в нём выполнен вход (он хранит его после входа).
            Text("Sign in to your Apple ID in AltStore or SideStore first, then keep it open in the background.")
        }
        .fileImporter(isPresented: $importingP12, allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            p12Data = try? Data(contentsOf: url)
            p12Password = ""
        }
        .alert(".p12 Password", isPresented: Binding(get: { p12Data != nil }, set: { if !$0 { p12Data = nil } })) {
            SecureField("Password", text: $p12Password)
            Button("Save") {
                if let data = p12Data { certificateMessage = CertificateStore.save(p12: data, password: p12Password) }
                p12Data = nil
            }
            Button("Cancel", role: .cancel) { p12Data = nil }
        }
        .alert("Graphics", isPresented: Binding(get: { graphicsMessage != nil }, set: { if !$0 { graphicsMessage = nil } })) {
            Button("OK") { graphicsMessage = nil }
        } message: {
            Text(graphicsMessage ?? "")
        }
        .alert("Signing Certificate", isPresented: Binding(get: { certificateMessage != nil },
                                                          set: { if !$0 { certificateMessage = nil } })) {
            Button("OK") { certificateMessage = nil }
        } message: {
            Text(certificateMessage ?? "")
        }
    }

    // Главное: что можно сделать с игрой сейчас.
    @ViewBuilder private var gameCard: some View {
        if let busy = steam.busy {
            VStack(alignment: .leading, spacing: 8) {
                Text(busy).font(.headline)
                if let progress = steam.progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
                Text(steam.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                if busy == SteamCenter.downloading {
                    Text("Keep BG3iOS open while it downloads: iOS pauses it in the background. If you leave, "
                         + "the download continues from where it stopped when you come back.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button("Stop", role: .destructive) { steam.cancelWork() }
        } else {
            switch steam.account {
            case .unknown, .restoring:
                HStack { ProgressView(); Text("Connecting to Steam…").foregroundStyle(.secondary) }
            case .signedOut, .expired, .pairing:
                Text("Sign in with the Steam account that owns Baldur's Gate 3. The game is downloaded from Steam.")
                    .foregroundStyle(.secondary)
                primaryButton("Sign In to Steam", systemImage: "person.crop.circle") { showSignIn = true }
            case .signedIn, .offline:
                licensedCard
            }
            if !steam.detail.isEmpty {
                Text(steam.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }

    @ViewBuilder private var licensedCard: some View {
        if case .offline(_, let reason) = steam.account {
            Text("Steam is unreachable (\(reason)).").font(.footnote).foregroundStyle(.orange)
        }
        switch steam.owned {
        case nil:
            HStack { ProgressView(); Text("Checking your Steam library…").foregroundStyle(.secondary) }
        case false?:
            Label("Baldur's Gate 3 is not in this Steam library. A Steam license is required to play.",
                  systemImage: "xmark.octagon").foregroundStyle(.red)
        case true?:
            switch steam.game {
            case .unknown:
                ProgressView()
            case .notInstalled:
                if steam.downloadPaused {
                    primaryButton("Resume Download", systemImage: "arrow.down.circle") { steam.install() }
                    Text("The download continues from where it stopped.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    primaryButton("Download from Steam (156 GB)", systemImage: "arrow.down.circle") { steam.install() }
                    Text("Needs about 165 GB of free space: the game plus a 5% reserve.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                LabeledContent("Free space on this iPhone", value: freeSpace)
            case .legacyCopy:
                primaryButton("Verify Mac Copy with Steam", systemImage: "checkmark.shield") { steam.adoptLegacy() }
                Text("Files are checked against Steam's manifests; only the ones that differ are downloaded.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .installed:
                primaryButton("Prepare for iPhone", systemImage: "hammer") { steam.prepare() }
            case .ready:
                VStack(alignment: .leading, spacing: 8) {
                    // Две кнопки рядом, одной ширины. У каждой свой стиль кнопки — тогда в List нажатие строки не
                    // срабатывает за обе сразу.
                    HStack(spacing: 12) {
                        primaryButton("Play", systemImage: "play.fill") { if let app = steam.appURL { play(app, false) } }
                        Button { if let app = steam.appURL { play(app, true) } } label: {
                            Label("Play with FPS Counter", systemImage: "speedometer").font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    Text("Hold three fingers on the screen for about a second to show or hide the FPS counter.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                // Разделитель List равняется по первому тексту строки — здесь это «Play» внутри кнопки, и линия
                // начиналась с середины. Ровняем по краю строки, как у остальных.
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                // Чем играть (Controls): экранный геймпад или подключённый контроллер.
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Controls", selection: $controls) {
                        Text("Touch Gamepad").tag(Controls.Mode.touch)
                        Text("Game Controller").tag(Controls.Mode.controller)
                    }
                    .onChange(of: controls) { _, mode in Controls.mode = mode }
                    Text(controlsNote).font(.footnote).foregroundStyle(.secondary)
                }
                Button("Prepare Again") { steam.prepare() }.font(.footnote)
            }
        }
    }

    @ViewBuilder private var cloudRows: some View {
        switch steam.cloud {
        case .idle:
            Button("Sync Now") { Task { await steam.syncSaves() } }
        case .syncing:
            HStack { ProgressView(); Text("Syncing saves…").foregroundStyle(.secondary) }
            if !steam.cloudDetail.isEmpty {
                Text(steam.cloudDetail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        case .synced(let at, let down, let up):
            LabeledContent("Up to date", value: at.formatted(date: .omitted, time: .shortened))
            if down + up > 0 {
                Text("Downloaded \(down), uploaded \(up) save\(down + up == 1 ? "" : "s").")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("Sync Now") { Task { await steam.syncSaves() } }
        case .failed(let why):
            Label("Couldn't sync saves: \(why)", systemImage: "exclamationmark.icloud").foregroundStyle(.orange)
            Button("Try Again") { Task { await steam.syncSaves() } }
        case .conflicts(let list):
            Text("\(list.count) save\(list.count == 1 ? "" : "s") differ between this iPhone and Steam Cloud. "
                 + "Choose which copies to keep.")
            ForEach(list.prefix(8), id: \.name) { conflict in
                VStack(alignment: .leading, spacing: 2) {
                    Text(BG3CloudLocations.title(conflict.name)).font(.subheadline.weight(.semibold))
                    Text(Self.sides(conflict)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if list.count > 8 {
                Text("and \(list.count - 8) more").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { steam.settleConflicts(.phone) } label: {
                    Label("Keep iPhone's", systemImage: "iphone").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { steam.settleConflicts(.steam) } label: {
                    Label("Keep Steam's", systemImage: "icloud").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Text("Keep iPhone's uploads these copies to Steam Cloud. Keep Steam's makes this iPhone match Steam Cloud: "
                 + "saves that exist only on this iPhone are moved to Steam Cloud Backups.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    // «iPhone: 26 Oct 18:02 · Steam: 23 Feb 2024» / «only on iPhone» / «only on Steam».
    private static func sides(_ c: SteamService.CloudConflict) -> String {
        func when(_ d: Date?) -> String { d?.formatted(date: .abbreviated, time: .shortened) ?? "?" }
        switch (c.phoneSize, c.steamSize) {
        case (_?, nil): return "Only on this iPhone · \(when(c.phoneTime))"
        case (nil, _?): return "Only in Steam Cloud · \(when(c.steamTime))"
        default: return "iPhone: \(when(c.phoneTime)) · Steam: \(when(c.steamTime))"
        }
    }

    private func primaryButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).font(.headline).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }

    private var freeSpace: String {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return String(format: "%.0f GB", Double(free) / 1e9)
    }

    private var controlsNote: String {
        let names = controllers.joined(separator: ", ")
        switch (controls, controllers.isEmpty) {
        case (.touch, true):
            return "On-screen buttons in the black bars; sticks appear under your fingers."
        case (.touch, false):
            return "On-screen buttons in the black bars; sticks appear under your fingers. \(names) works too."
        case (.controller, true):
            return "No controller connected. Pair a DualSense, DualShock 4 or Xbox controller in Settings › Bluetooth "
                + "(DualSense: hold PS and Create until the light bar blinks). Until then, the on-screen buttons are shown."
        case (.controller, false):
            return "\(names) connected. The on-screen buttons appear only if it disconnects."
        }
    }

    private func refreshControllers(gone: GCController?) {
        controllers = Controls.connected(except: gone).map(Controls.name)
    }

    private func refreshCertificate() {
        certificateText = CertificateStore.identity.map { "team \($0.teamID)" } ?? "Not set — tap to get"
    }
}

// Отказ от ответственности — до первого использования, во весь экран; без согласия дальше не пройти.
struct DisclaimerView: View {
    static let acceptedKey = "MacportDisclaimerAccepted.v1"
    let accept: () -> Void
    @State private var owns = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Important — Please Read", systemImage: "exclamationmark.triangle.fill")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.orange)
                Text("BG3iOS is an independent, unofficial compatibility tool. It is not affiliated with, endorsed by "
                     + "or sponsored by Larian Studios, Valve Corporation or Apple Inc. Baldur's Gate 3 and all related "
                     + "trademarks belong to their respective owners.")
                Text("You may use BG3iOS only with a game you legally own. Baldur's Gate 3 can be launched only after "
                     + "you sign in to your own Steam account that holds a valid license for the game and download the "
                     + "game from Steam through this app.")
                    .font(.headline)
                Text("Any illegal use is strictly prohibited, including piracy, sharing or distributing game files and "
                     + "circumventing copy protection. The author does not condone or encourage unlawful use of the "
                     + "game or infringement of its developers' copyrights.")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text("The software is provided \"as is\", without warranty of any kind. The author accepts no liability "
                     + "for any damage, data loss, account restrictions or other consequences arising from its use. "
                     + "You use it entirely at your own risk.")
                Toggle("I own Baldur's Gate 3 on Steam and agree to these terms.", isOn: $owns)
                    .font(.headline)
                Button(action: accept) {
                    Text("Agree and Continue").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!owns)
            }
            .padding(32)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .interactiveDismissDisabled()
    }
}

// Вход в Steam: логин и пароль, затем подтверждение в приложении Steam или код Steam Guard.
struct SignInView: View {
    @ObservedObject var steam: SteamCenter
    @Environment(\.dismiss) private var dismiss
    @State private var login = ""
    @State private var password = ""
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                switch steam.signIn {
                case .idle, .failed:
                    Section {
                        TextField("Steam Account Name", text: $login)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                    } footer: {
                        Text("Your password goes only to Steam, encrypted, and is never stored. BG3iOS keeps a Steam "
                             + "session token in this iPhone's keychain.")
                    }
                    if case .failed(let why) = steam.signIn {
                        Text(why).foregroundStyle(.red)
                    }
                    Button("Sign In") { steam.signIn(login: login, password: password) }
                        .disabled(login.isEmpty || password.isEmpty)
                case .working:
                    HStack { ProgressView(); Text("Signing in…") }
                case .approveOnPhone:
                    HStack { ProgressView(); Text("Approve the sign-in in the Steam app.") }
                case .code(let prompt):
                    Section(prompt) {
                        TextField("Code", text: $code)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .textContentType(.oneTimeCode)
                        Button("Submit") {
                            steam.submit(code: code)
                            code = ""
                        }
                        .disabled(code.isEmpty)
                    }
                }
            }
            .navigationTitle("Sign In to Steam")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if steam.signIn != .idle { steam.cancelSignIn() }
                        dismiss()
                    }
                }
            }
        }
    }
}
