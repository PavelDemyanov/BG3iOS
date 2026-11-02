// SPDX-License-Identifier: GPL-3.0-or-later
// Оптимальные настройки графики BG3 для iPhone (подобраны на 17 Pro Max в Нижнем городе: 14–15 → 21–22 кадра/с,
// картинка заметно не хуже): разрешение — 7/12 родного окна игры с FSR 1.0, низкие детализация моделей, дальность
// объектов и деталей, тени и LOD анимации, средние текстуры, облака и туман, ограничение кадров игры — 30. Пишутся в
// graphicSettings.lsx при первом запуске (файла ещё нет) и кнопкой Reset Graphics to Optimal; дальше игрок меняет их
// в самой игре. У перечислений игры меньше число — выше качество (2 — Low; 3 — низшее у четырёхступенчатых).
// Ограничение кадров — собственная настройка игры («Ограничение FPS» в меню, шаг 1 кадр): FrameCapEnabled и
// FrameCapFPS, int32; выключенное игра в файл не пишет. Без него iOS на бегу в новые места отнимает у игры
// производительные ядра, и кадры тянутся по 50–150 мс; с 30 кадров — ровно по 33 мс (замер 02.11.2026,
// macport/CLAUDE.md).

import Metal
import UIKit

@MainActor
enum BG3Graphics {
    static var file: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Larian Studios/Baldur's Gate 3/graphicSettings.lsx")
    }

    // Первый запуск: настроек ещё нет — кладём оптимальные (без файла игра сама выбрала бы полное разрешение
    // экрана и средние настройки).
    static func applyIfMissing() {
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        try? reset()
    }

    static func reset() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(settings().utf8).write(to: file, options: .atomic)
    }

    // Версии до 1.2 писали настройки без ограничения кадров. У кого файл уже есть, оно включается один раз — перед
    // первым Play новой версии; выключит его игрок в меню игры — больше не трогаем.
    static let frameCapKey = "MacportFrameCap30.v1"

    static func enableFrameCapOnce() {
        guard !UserDefaults.standard.bool(forKey: frameCapKey) else { return }
        UserDefaults.standard.set(true, forKey: frameCapKey)
        guard let xml = try? String(contentsOf: file, encoding: .utf8), let capped = withFrameCap(xml) else { return }
        try? Data(capped.utf8).write(to: file, options: .atomic)
    }

    // Записи FrameCapEnabled = 1 и FrameCapFPS = 30 — на своё место по алфавиту, как пишет игра; nil — уже есть
    // или файл не того вида.
    static func withFrameCap(_ xml: String) -> String? {
        guard !xml.contains("value=\"FrameCapEnabled\""), let children = xml.range(of: "</children>") else { return nil }
        let entry = /( *)<node id="ConfigEntry">\s*<attribute id="MapKey" type="FixedString" value="([^"]*)"/
        var indent = "                "
        var at = xml[..<children.lowerBound].lastIndex(of: "\n").map { xml.index(after: $0) } ?? children.lowerBound
        for match in xml.matches(of: entry) {
            indent = String(match.output.1)
            if String(match.output.2) > "FrameCapFPS" {
                at = match.range.lowerBound
                break
            }
        }
        let nodes = [("FrameCapEnabled", "1"), ("FrameCapFPS", "30")].map { key, value in
            "\(indent)<node id=\"ConfigEntry\">\n"
                + "\(indent)    <attribute id=\"MapKey\" type=\"FixedString\" value=\"\(key)\"/>\n"
                + "\(indent)    <attribute id=\"Type\" type=\"int32\" value=\"0\"/>\n"
                + "\(indent)    <attribute id=\"Value\" type=\"int32\" value=\"\(value)\"/>\n"
                + "\(indent)</node>\n"
        }
        var result = xml
        result.insert(contentsOf: nodes.joined(), at: at)
        return result
    }

    // Разрешение — ступень 7/12 из списка режимов MPCoreGraphics: окно игры (сцена без левого и правого отступов
    // безопасной области, как в MPAppKit) в пикселях, округлённое до чётного. 17 Pro Max — 1456×770, 17 Pro — 1312×704.
    // Размер не из списка игра не примет и вернёт родной.
    static func resolution() -> (width: Int, height: Int) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let bounds = scene?.coordinateSpace.bounds ?? UIScreen.main.bounds
        let insets = scene?.windows.map(\.safeAreaInsets).first { $0.left > 0 || $0.right > 0 } ?? .zero
        let scale = scene?.screen.scale ?? UIScreen.main.scale
        let long = max(bounds.width, bounds.height), short = min(bounds.width, bounds.height)
        let width = (long - insets.left - insets.right) * scale, height = (short - insets.top) * scale
        func step(_ v: CGFloat) -> Int { Int((v * 7 / 12 / 2).rounded()) * 2 }
        return (step(width), step(height))
    }

    static func settings() -> String {
        let (width, height) = resolution()
        let rate = (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
            ?? UIScreen.main).maximumFramesPerSecond
        let gpu = MTLCreateSystemDefaultDevice()?.name ?? "Apple GPU"
        // Ключ, тип записи (0 — int32, 1 — строка, 2 — float), значение; по алфавиту, как пишет сама игра.
        let entries: [(String, Int, String)] = [
            ("AnimationLODDetail", 0, "2"),
            ("CASEnabled", 0, "0"),
            ("CloudsQuality", 0, "2"),
            ("DOF", 0, "1"),
            ("DetailDistance", 0, "2"),
            ("DeviceName", 1, gpu),
            ("FSR1Mode", 0, "2"),
            ("FogQuality", 0, "2"),
            ("FrameCapEnabled", 0, "1"),
            ("FrameCapFPS", 0, "30"),
            ("GraphicSettingsVersion", 0, "5"),
            ("InstanceDistance", 0, "2"),
            ("ModelDetail", 0, "2"),
            ("RefreshRateDenominator", 0, "1"),
            ("RefreshRateNumerator", 0, String(rate > 0 ? rate : 60)),
            ("ResolutionUpscaleType", 0, "1"),
            ("SSSS", 0, "0"),
            ("ScreenHeight", 0, String(height)),
            ("ScreenWidth", 0, String(width)),
            ("ShadowQuality", 0, "2"),
            ("ShowGammaCalibration", 0, "0"),
            ("TerrainTextureDetail", 0, "2"),
            ("TextureDetail", 0, "2"),
            ("TextureFiltering", 0, "3"),
            ("UpscaleSharpness", 2, "0.80000001"),
        ]
        let valueType = [0: "int32", 1: "LSString", 2: "float"]
        var xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <save>
                <version major="4" minor="8" revision="0" build="700"/>
                <region id="Config">
                    <node id="root">
                        <attribute id="Version64" type="int64" value="36169534507319298"/>
                        <children>

            """
        for (key, type, value) in entries {
            xml += """
                                <node id="ConfigEntry">
                                    <attribute id="MapKey" type="FixedString" value="\(key)"/>
                                    <attribute id="Type" type="int32" value="\(type)"/>
                                    <attribute id="Value" type="\(valueType[type]!)" value="\(escape(value))"/>
                                </node>

                """
        }
        xml += """
                        </children>
                    </node>
                </region>
            </save>

            """
        return xml
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
