// Запуск Mac-программы, подготовленной macport_convert.py, внутри этого приложения.
//
// Программа лежит в MacApps/<имя>.app со структурой бандла macOS: исполняемый файл (уже библиотека)
// в Contents/MacOS, заменители и библиотеки — в Contents/Frameworks. Главный бандл подменяется на
// бандл программы (как в LiveContainer), чтобы она находила свои ресурсы; stderr идёт в
// Documents/mac.log. main берётся из LC_MAIN и вызывается в главном потоке блоком run loop, а не
// главной очереди GCD: вложенный цикл NSApplication тогда может её выполнять.

import AVFAudio
import Foundation
import MachO
import ObjectiveC
import UIKit

enum MacRunner {
    nonisolated(unsafe) static var memoryTimer: DispatchSourceTimer?
    // Кадры, которые программа показала (MPMetal считает drawable у CAMetalLayer); 0, пока MPMetal не загружен.
    static func frames() -> UInt64 {
        typealias Frames = @convention(c) () -> UInt64
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "mp_metal_frames") else { return 0 }
        return unsafeBitCast(symbol, to: Frames.self)()
    }

    // Сколько секунд видеокарта выполняла команды программы (MPMetal); 0, пока MPMetal не загружен.
    static func gpuSeconds() -> Double {
        typealias Seconds = @convention(c) () -> Double
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "mp_metal_gpu_seconds") else { return 0 }
        return unsafeBitCast(symbol, to: Seconds.self)()
    }

    // Сколько секунд видеокарта была занята хоть чем-то (объединение интервалов, MPMetal).
    static func gpuBusySeconds() -> Double {
        typealias Seconds = @convention(c) () -> Double
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "mp_metal_gpu_busy_seconds") else { return 0 }
        return unsafeBitCast(symbol, to: Seconds.self)()
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "норма"
        case .fair: "тёплый"
        case .serious: "горячий"
        case .critical: "перегрев"
        @unknown default: "?"
        }
    }

    // app — путь к приложению (игра из Steam: Documents/Games/<папка>/<имя>.app); без него — по имени.
    static func run(name: String, fps: Bool = false, app explicit: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logPath = documents.appendingPathComponent("mac.log").path
        try? FileManager.default.removeItem(atPath: logPath)
        freopen(logPath, "a", stderr)
        setvbuf(stderr, nil, _IONBF, 0)
        dup2(fileno(stderr), fileno(stdout))
        setvbuf(stdout, nil, _IOLBF, 0)
        func say(_ line: String) { fputs("MacRunner: \(line)\n", stderr) }
        if let free = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            say("свободно на телефоне: \(free / 1_000_000_000) ГБ")
        }
        // Лаунчер BG3 (веб-страница в WKWebView поверх AppKit) не поддержан: с ключом NoLauncher игра
        // сразу запускает движок. Область регистрации — в памяти процесса, на чужие настройки не влияет.
        UserDefaults.standard.register(defaults: ["NoLauncher": true])
        // Память — каждые 10 с: занято (phys_footprint) и лимит (занято + os_proc_available_memory).
        // Превысит лимит — iOS убьёт процесс без отчёта о падении (jetsam per-process-limit).
        let memory = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        memory.schedule(deadline: .now(), repeating: 10)
        var lastFrames: UInt64 = 0
        var lastGPU = 0.0, lastBusy = 0.0
        memory.setEventHandler {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            let used = kr == KERN_SUCCESS ? Int(info.phys_footprint >> 20) : -1
            let available = Int(os_proc_available_memory() >> 20)
            let frames = MacRunner.frames(), gpu = MacRunner.gpuSeconds(), busy = MacRunner.gpuBusySeconds()
            let shown = Double(frames &- lastFrames)
            let gpuPerFrame = shown > 0 ? (gpu - lastGPU) / shown * 1000 : 0
            say("память: занято \(used) МБ, лимит \(used + available) МБ; кадров/с \(shown / 10); " +
                String(format: "видеокарта %.0f мс/кадр (сумма буферов), занята %.0f%% по времени; телефон: %@%@",
                       gpuPerFrame, (busy - lastBusy) / 10 * 100, MacRunner.thermal(),
                       ProcessInfo.processInfo.isLowPowerModeEnabled ? ", энергосбережение" : ""))
            lastFrames = frames
            lastGPU = gpu
            lastBusy = busy
        }
        memory.resume()
        memoryTimer = memory
        // Звук: категория «воспроизведение», как у игр, — иначе в беззвучном режиме iOS его глушит.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            say("аудиосессия: воспроизведение, \(AVAudioSession.sharedInstance().sampleRate) Гц")
        } catch {
            say("аудиосессия: \(error.localizedDescription)")
        }
        // run(name:) зовётся из сцены, в главном потоке.
        MainActor.assumeIsolated {
            // Строка статистики: видна с --fps или если её оставили включённой; три пальца — показать/спрятать.
            let noGamepad = ProcessInfo.processInfo.arguments.contains("--no-gamepad")
            FPSOverlay.shared.start(visible: fps, gestureOnGameWindow: noGamepad)
            // Экранный геймпад — всегда (без него в BG3 не повернуть камеру), а если играют подключённым контроллером
            // (Controls.mode), — без кнопок, пока контроллер подключён. --no-gamepad — без него совсем, тогда касания
            // идут в игру мышью напрямую.
            if !noGamepad {
                let host = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
                TouchGamepad.startWhenGameWindowIsKey(host: host, log: say)
            }
        }
        // Переходы приложения — в журнал: по ним видно, ушёл ли пользователь с экрана перед завершением.
        for (name, label) in [(UIApplication.didEnterBackgroundNotification, "в фоне"),
                              (UIApplication.willEnterForegroundNotification, "на экране"),
                              (UIApplication.didReceiveMemoryWarningNotification, "предупреждение о памяти"),
                              (UIApplication.willTerminateNotification, "завершается")] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                say("приложение: \(label)")
            }
        }

        // Сначала Documents/MacApps (туда большие программы кладутся через devicectl), затем бандл.
        let inDocuments = documents.appendingPathComponent("MacApps/\(name).app")
        let app = explicit ?? (FileManager.default.fileExists(atPath: inDocuments.path) ? inDocuments
            : Bundle.main.bundleURL.appendingPathComponent("MacApps/\(name).app"))
        say("путь \(app.path), есть: \(FileManager.default.fileExists(atPath: app.path))")
        guard let bundle = Bundle(url: app) else {
            say("Bundle(url:) — nil")
            return
        }
        say("Bundle: id \(bundle.bundleIdentifier ?? "-"), info \(bundle.infoDictionary?.count ?? -1) ключей, " +
            "executable \(bundle.executableURL?.path ?? "-"), resources \(bundle.resourcePath ?? "-")")
        // iOS читает Mac-раскладку бандла (Contents/Info.plist, Contents/Resources), но исполняемый файл
        // в Contents/MacOS не находит: путь — по CFBundleExecutable.
        guard let exeName = bundle.infoDictionary?["CFBundleExecutable"] as? String else {
            say("нет CFBundleExecutable")
            return
        }
        let executable = app.appendingPathComponent("Contents/MacOS/\(exeName)")
        say("бандл \(app.path)")
        replaceMainBundle(with: bundle)
        say("главный бандл теперь \(Bundle.main.bundlePath), ресурсы \(Bundle.main.resourcePath ?? "-")")

        guard let handle = dlopen(executable.path, RTLD_NOW | RTLD_GLOBAL) else {
            say("dlopen: \(String(cString: dlerror()))")
            return
        }
        guard let entry = mainEntry(path: executable.path) else {
            say("нет LC_MAIN")
            return
        }
        say("загружено, handle \(handle), main \(entry)")
        typealias Main = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                                         UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                                         UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        let main = unsafeBitCast(entry, to: Main.self)
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable.path), nil]
            var env: [UnsafeMutablePointer<CChar>?] = [nil]
            var apple: [UnsafeMutablePointer<CChar>?] = [strdup("executable_path=" + executable.path), nil]
            say("вызываю main")
            let code = main(1, &argv, &env, &apple)
            say("main вернул \(code)")
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    // +[NSBundle mainBundle] → бандл программы.
    static func replaceMainBundle(with bundle: Bundle) {
        guard let method = class_getClassMethod(Bundle.self, NSSelectorFromString("mainBundle")) else { return }
        let block: @convention(block) (AnyObject) -> Bundle = { _ in bundle }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    // Адрес main: заголовок загруженного образа + entryoff из LC_MAIN.
    static func mainEntry(path: String) -> UnsafeRawPointer? {
        // dyld называет образ настоящим путём (/private/var/…), а путь контейнера начинается с /var.
        let real: (String) -> String = { p in
            guard let r = realpath(p, nil) else { return p }
            defer { free(r) }
            return String(cString: r)
        }
        let target = real(path)
        for i in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(i), real(String(cString: name)) == target,
                  let header = _dyld_get_image_header(i) else { continue }
            var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
            for _ in 0..<header.pointee.ncmds {
                let command = cursor.load(as: load_command.self)
                if command.cmd == UInt32(LC_MAIN) {
                    let entry = cursor.load(as: entry_point_command.self)
                    return UnsafeRawPointer(header).advanced(by: Int(entry.entryoff))
                }
                cursor = cursor.advanced(by: Int(command.cmdsize))
            }
        }
        return nil
    }
}
