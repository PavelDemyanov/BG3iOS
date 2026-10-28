// MacportLab: запуск Mac-программ на iPhone (MacRunner) и проверки этапа 1.
// С иконки — список программ из Documents/MacApps и MacApps в бандле; `--mac <имя>` (devicectl) — сразу
// программа; пункт «Проверка шейдеров» — шейдеры Mac-версии BG3 (metallib с целью air64-apple-macosx11),
// результат на экране и в Documents/lab.log.

import Metal
import SwiftUI
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

// iOS 27 требует жизненный цикл сцен: окно создаётся для сцены.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: scene)
        window?.makeKeyAndVisible()
        // Ответ AltStore/SideStore с сертификатом мог и запустить приложение.
        if let url = options.urlContexts.first?.url {
            DispatchQueue.main.async { self.open(url) }
        }
        // Служебные запуски (devicectl: --mac, --sign-test, --prepare, --gamepad-preview) и список «Developer» —
        // только в сборке разработчика (MACPORT_DEVELOPER, Debug): в публичной игра запускается лишь с главного
        // экрана, с лицензией Steam.
        let arguments = ProcessInfo.processInfo.arguments
        #if MACPORT_DEVELOPER
        let developer = true
        #else
        let developer = false
        #endif
        // --mac <имя>: сразу Mac-программа (так запускает tools/run_on_phone.sh).
        if developer, let index = arguments.firstIndex(of: "--mac"), index + 1 < arguments.count {
            start(.mac(arguments[index + 1], fps: arguments.contains("--fps")))
        } else if developer, arguments.contains("--sign-test") {
            // Подпись Mach-O на телефоне (SignTest.swift): итог — на экране и в Documents/sign-test/log.txt.
            let text = UITextView()
            text.isEditable = false
            text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            text.text = SignTest.run()
            let controller = UIViewController()
            controller.view = text
            window?.rootViewController = controller
        } else if developer, let index = arguments.firstIndex(of: "--prepare"), index + 1 < arguments.count {
            // Подготовка Mac-игры на телефоне (PrepareRun.swift).
            let text = UITextView()
            text.isEditable = false
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            let controller = UIViewController()
            controller.view = text
            window?.rootViewController = controller
            PrepareRun.run(name: arguments[index + 1]) { text.text = $0 }
        } else if developer, arguments.contains("--cloud-list") {
            // Список файлов BG3 в Steam Cloud — в Documents/steam.log (SteamCenter.listCloudToLog).
            let text = UITextView()
            text.isEditable = false
            text.text = "Steam Cloud: see steam.log"
            let controller = UIViewController()
            controller.view = text
            window?.rootViewController = controller
            Task { @MainActor in await SteamCenter.shared.listCloudToLog() }
        } else if developer, arguments.contains("--gamepad-preview") {
            // Раскладка экранного геймпада без игры (проверка в симуляторе): серый экран, кнопки и красный контур
            // Dynamic Island — симулятор его на снимках не рисует.
            let controller = IslandOutlineController()
            controller.view.backgroundColor = UIColor(white: 0.17, alpha: 1)
            window?.rootViewController = controller
            TouchGamepad.start(scene: scene) { print($0) }
        } else {
            // Главный экран: Steam, сертификат, BG3 (HomeView); прежний список — «Для разработки».
            let navigation = UINavigationController()
            let openLab: (() -> Void)? = developer ? { [weak self, weak navigation] in
                navigation?.pushViewController(PickerController { self?.start($0) }, animated: true)
            } : nil
            let home = UIHostingController(rootView: HomeView(openLab: openLab, play: { [weak self] app, fps in
                // Ещё раз у самого запуска: без лицензии Steam игра не стартует.
                guard SteamCenter.shared.canPlay else { return }
                Task { @MainActor in
                    await SteamCenter.shared.beforePlay()
                    BG3Graphics.applyIfMissing()
                    BG3Language.apply(to: app)
                    self?.start(.game(app, fps: fps))
                }
            }))
            navigation.viewControllers = [home]
            navigation.navigationBar.prefersLargeTitles = true
            window?.rootViewController = navigation
        }
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        contexts.forEach { open($0.url) }
    }

    // macport://certificate?… — сертификат от AltStore/SideStore (CertificateStore).
    private func open(_ url: URL) {
        guard let message = CertificateStore.handle(url: url) else { return }
        let alert = UIAlertController(title: "Signing Certificate", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        window?.rootViewController?.present(alert, animated: true)
        (window?.rootViewController as? UINavigationController)?.viewControllers.compactMap { $0 as? PickerController }
            .forEach { $0.tableView.reloadData() }
    }

    func start(_ item: PickerController.Item) {
        let text = UITextView()
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let controller = UIViewController()
        controller.view = text
        window?.rootViewController = controller
        switch item {
        case .mac(let name, let fps):
            text.text = "Starting \(name)…\n"
            MacRunner.run(name: name, fps: fps)
        case .shaders:
            Lab.output = { line in DispatchQueue.main.async { text.text += line + "\n" } }
            DispatchQueue.global(qos: .userInitiated).async { Lab.run() }
        case .signing:
            break
        case .game(let app, let fps):
            text.text = "\(app.lastPathComponent)\n"
            MacRunner.run(name: app.deletingPathExtension().lastPathComponent, fps: fps, app: app)
        }
    }
}

// Экран с иконки: Mac-программы (Documents/MacApps — туда их кладёт devicectl — и MacApps в бандле)
// и проверка шейдеров.
final class PickerController: UITableViewController {
    enum Item {
        case mac(String, fps: Bool)
        case shaders
        case signing  // сертификат для подписи игры на телефоне
        case game(URL, fps: Bool)  // игра из Steam (HomeView)
    }

    private let items: [Item]
    private let choose: (Item) -> Void

    init(choose: @escaping (Item) -> Void) {
        self.choose = choose
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var names: [String] = []
        for folder in [documents.appendingPathComponent("MacApps"), Bundle.main.bundleURL.appendingPathComponent("MacApps")] {
            let found = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for file in found.sorted() where file.hasSuffix(".app") {
                let name = String(file.dropLast(4))
                if !names.contains(name) { names.append(name) }
            }
        }
        items = [.signing] + names.flatMap { [Item.mac($0, fps: false), .mac($0, fps: true)] } + [.shaders]
        super.init(style: .insetGrouped)
        title = "Developer"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        switch items[indexPath.row] {
        case .mac(let name, let fps):
            content.text = fps ? "\(name) with FPS Counter" : name
            content.secondaryText = fps ? "FPS in the top right corner" : "Mac app"
            content.image = UIImage(systemName: fps ? "speedometer" : "macwindow")
        case .shaders:
            content.text = "Shader Check"
            content.secondaryText = "stage 1.1"
            content.image = UIImage(systemName: "cpu")
        case .game(let app, _):
            content.text = app.lastPathComponent
        case .signing:
            content.text = "Signing Certificate"
            content.secondaryText = CertificateStore.identity.map(CertificateStore.describe) ?? "none — get it from AltStore"
            content.image = UIImage(systemName: "signature")
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard case .signing = items[indexPath.row] else { return choose(items[indexPath.row]) }
        tableView.deselectRow(at: indexPath, animated: true)
        let sheet = UIAlertController(title: "Signing Certificate",
                                      message: "BG3iOS signs the game on this iPhone with the certificate AltStore " +
                                          "or SideStore used to install BG3iOS.", preferredStyle: .actionSheet)
        for store in [CertificateStore.Store.altStore, .sideStore] {
            sheet.addAction(UIAlertAction(title: "Get from \(store.title)", style: .default) { _ in
                Task { @MainActor in
                    if !(await CertificateStore.request(from: store)) { self.show("\(store.title) didn't open. Is it installed?") }
                }
            })
        }
        sheet.addAction(UIAlertAction(title: "Import .p12 File…", style: .default) { _ in self.pickP12() })
        if CertificateStore.identity != nil {
            sheet.addAction(UIAlertAction(title: "Remove", style: .destructive) { _ in
                CertificateStore.remove()
                self.tableView.reloadData()
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
        present(sheet, animated: true)
    }

    private func show(_ message: String) {
        let alert = UIAlertController(title: "Signing Certificate", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
        tableView.reloadData()
    }

    private func pickP12() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.init(filenameExtension: "p12") ?? .data])
        picker.delegate = self
        present(picker, animated: true)
    }
}

extension PickerController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return show("Can't read the file.") }
        let ask = UIAlertController(title: ".p12 Password", message: url.lastPathComponent, preferredStyle: .alert)
        ask.addTextField { $0.isSecureTextEntry = true }
        ask.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        ask.addAction(UIAlertAction(title: "Save", style: .default) { _ in
            self.show(CertificateStore.save(p12: data, password: ask.textFields?.first?.text ?? ""))
        })
        present(ask, animated: true)
    }
}

enum Lab {
    nonisolated(unsafe) static var output: (String) -> Void = { _ in }
    static let logURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("lab.log")

    static func log(_ line: String) {
        output(line)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    static func run() {
        try? FileManager.default.removeItem(at: logURL)
        log("MacportLab \(Date())")
        guard let device = MTLCreateSystemDefaultDevice() else { log("нет Metal-устройства"); return }
        deviceInfo(device)
        for name in ["granite", "Core", "Materials"] {
            library(device, name)
        }
        log("готово")
    }

    static func deviceInfo(_ device: MTLDevice) {
        log("устройство: \(device.name)")
        let families = (1001...1012).compactMap { raw -> String? in
            guard let family = MTLGPUFamily(rawValue: raw) else { return nil }
            return device.supportsFamily(family) ? "apple\(raw - 1000)" : nil
        }
        log("семейства: \(families.joined(separator: " ")), mac2: \(device.supportsFamily(.mac2)), metal3: \(device.supportsFamily(.metal3))")
        log("BC-сжатие: \(device.supportsBCTextureCompression), общая память: \(device.hasUnifiedMemory), " +
            "рабочий набор: \(device.recommendedMaxWorkingSetSize / 1_048_576) МБ, " +
            "буфер до: \(device.maxBufferLength / 1_048_576) МБ")
        log("argument buffers tier: \(device.argumentBuffersSupport.rawValue), " +
            "raster order groups: \(device.areRasterOrderGroupsSupported)")
    }

    static func library(_ device: MTLDevice, _ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "metallib", subdirectory: "GameFiles") else {
            log("\(name): нет файла в приложении")
            return
        }
        let started = Date()
        var library: MTLLibrary
        do {
            library = try device.makeLibrary(URL: url)
        } catch {
            log("\(name): как есть не загружена — \(error.localizedDescription)")
            // Заголовок metallib: платформа — u16 по смещению 4 (0x8001 macOS). Пробуем iOS (0x8002).
            guard var data = try? Data(contentsOf: url), data.count > 16 else { return }
            log("  заголовок: " + data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))
            // Заголовок: u16 по смещению 4 — 0x8001 у macOS, 0x0001 у iOS (старший бит — macOS);
            // байт 11 — целевая ОС (0x81 macOS, 0x82 iOS), у шейдеров BG3 он нулевой.
            var loaded: MTLLibrary?
            for (label, patch) in [("бит macOS сброшен", { (d: inout Data) in d[5] = 0x00 }),
                                   ("и целевая ОС iOS", { (d: inout Data) in d[5] = 0x00; d[11] = 0x82 })] {
                var patched = data
                patch(&patched)
                do {
                    loaded = try patched.withUnsafeBytes { raw in try device.makeLibrary(data: DispatchData(bytes: raw)) }
                    log("\(name): загружена (\(label)) за \(ms(started)) мс")
                    break
                } catch {
                    log("\(name): \(label) — НЕ загружена: \(error.localizedDescription)")
                }
            }
            guard let patchedLibrary = loaded else { return }
            library = patchedLibrary
        }
        let names = library.functionNames
        log("\(name): загружена за \(ms(started)) мс, функций \(names.count)")

        var kinds: [String: Int] = [:]
        var made = 0, needConstants = 0, failed: [String] = []
        var functions: [MTLFunction] = []
        for function in names {
            if let f = library.makeFunction(name: function) {
                made += 1
                functions.append(f)
                kinds[kindName(f.functionType), default: 0] += 1
            } else {
                // Функции с обязательными function constants без значений не создаются.
                do {
                    let f = try library.makeFunction(name: function, constantValues: MTLFunctionConstantValues())
                    made += 1
                    functions.append(f)
                    kinds[kindName(f.functionType), default: 0] += 1
                } catch {
                    needConstants += 1
                    if failed.count < 3 { failed.append("\(function): \(error.localizedDescription)") }
                }
            }
        }
        log("  функции созданы: \(made), нужны константы: \(needConstants), по типам: \(kinds)")
        for f in failed { log("    \(f)") }

        // Компиляция под видеокарту — при создании конвейера. Берём до 40 вычислительных
        // и до 40 вершинных (без растеризации) из каждой библиотеки.
        var computeOK = 0, computeFail = 0, vertexOK = 0, vertexFail = 0
        var errors: [String] = []
        let compileStart = Date()
        for f in functions where f.functionType == .kernel && computeOK + computeFail < 40 {
            do {
                _ = try device.makeComputePipelineState(function: f)
                computeOK += 1
            } catch {
                computeFail += 1
                if errors.count < 4 { errors.append("kernel \(f.name): \(error.localizedDescription)") }
            }
        }
        // Вершинные: описание вершин из рефлексии функции (все атрибуты в буфере 30).
        // Пары вершинный + фрагментный: по имени (…vertexMain / …fragmentMain, …VS / …PS).
        let byName = Dictionary(functions.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var pairOK = 0, pairFail = 0
        for f in functions where f.functionType == .vertex && vertexOK + vertexFail < 40 {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = f
            descriptor.vertexDescriptor = vertexDescriptor(for: f)
            descriptor.isRasterizationEnabled = false
            do {
                _ = try device.makeRenderPipelineState(descriptor: descriptor)
                vertexOK += 1
            } catch {
                vertexFail += 1
                if errors.count < 6 { errors.append("vertex \(f.name): \(error.localizedDescription)") }
            }
            let fragmentName = f.name.hasSuffix("vertexMain") ? String(f.name.dropLast(10)) + "fragmentMain"
                : f.name.hasSuffix("VS") ? String(f.name.dropLast(2)) + "PS" : ""
            guard let fragment = byName[fragmentName], pairOK + pairFail < 40 else { continue }
            let pair = MTLRenderPipelineDescriptor()
            pair.vertexFunction = f
            pair.fragmentFunction = fragment
            pair.vertexDescriptor = vertexDescriptor(for: f)
            for i in 0..<4 { pair.colorAttachments[i].pixelFormat = .rgba16Float }
            pair.depthAttachmentPixelFormat = .depth32Float
            do {
                _ = try device.makeRenderPipelineState(descriptor: pair)
                pairOK += 1
            } catch {
                pairFail += 1
                if errors.count < 10 { errors.append("pair \(f.name)+\(fragment.name): \(error.localizedDescription)") }
            }
        }
        log("  пары вершинный+фрагментный: \(pairOK) ок / \(pairFail) ошибок")
        log("  конвейеры за \(ms(compileStart)) мс: compute \(computeOK) ок / \(computeFail) ошибок, " +
            "vertex \(vertexOK) ок / \(vertexFail) ошибок")
        for e in errors { log("    \(e)") }
    }

    static func vertexDescriptor(for function: MTLFunction) -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        var offset = 0
        for attribute in function.vertexAttributes ?? [] where attribute.isActive {
            let (format, size): (MTLVertexFormat, Int) = switch attribute.attributeType {
            case .float: (.float, 4)
            case .float2: (.float2, 8)
            case .float3: (.float3, 12)
            case .float4: (.float4, 16)
            case .half2: (.half2, 4)
            case .half4: (.half4, 8)
            case .int, .uint: (attribute.attributeType == .int ? .int : .uint, 4)
            case .int2, .uint2: (attribute.attributeType == .int2 ? .int2 : .uint2, 8)
            case .int4, .uint4: (attribute.attributeType == .int4 ? .int4 : .uint4, 16)
            case .uchar4: (.uchar4, 4)
            default: (.float4, 16)
            }
            descriptor.attributes[attribute.attributeIndex].format = format
            descriptor.attributes[attribute.attributeIndex].offset = offset
            descriptor.attributes[attribute.attributeIndex].bufferIndex = 30
            offset += size
        }
        descriptor.layouts[30].stride = max(offset, 4)
        return descriptor
    }

    static func kindName(_ type: MTLFunctionType) -> String {
        switch type {
        case .vertex: "vertex"
        case .fragment: "fragment"
        case .kernel: "kernel"
        default: "other(\(type.rawValue))"
        }
    }

    static func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }
}

// Контур Dynamic Island для --gamepad-preview.
final class IslandOutlineController: UIViewController {
    private let island = UIView()

    override func viewDidLoad() {
        super.viewDidLoad()
        island.layer.borderColor = UIColor.red.cgColor
        island.layer.borderWidth = 1
        island.layer.cornerRadius = 18
        view.addSubview(island)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        island.frame = TouchGamepad.island(in: view.bounds)
    }
}
