// SPDX-License-Identifier: GPL-3.0-or-later
// Оптимальные настройки графики BG3 для iPhone (подобраны на 17 Pro Max в Нижнем городе: 14–15 → 21–22 кадра/с,
// картинка заметно не хуже): разрешение — 7/12 родного окна игры с FSR 1.0, низкие детализация моделей, дальность
// объектов и деталей, тени и LOD анимации, средние текстуры, облака и туман. Пишутся в graphicSettings.lsx при первом
// запуске (файла ещё нет) и кнопкой Reset Graphics to Optimal; дальше игрок меняет их в самой игре.
// У перечислений игры меньше число — выше качество (2 — Low; 3 — низшее у четырёхступенчатых).

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
