// SPDX-License-Identifier: GPL-3.0-or-later
// Язык BG3. Своего выбора языка в игре нет: на Mac и PC его выбирают в свойствах игры в Steam, а приходит он одним
// файлом — языковое депо (у английского 1419661) несёт только Data/Localization/language.lsx (574 байта), тексты
// всех языков лежат в основном депо. Поэтому выбор — в BG3iOS: по умолчанию язык iPhone, language.lsx пишется перед
// каждым запуском (скачивать ничего не нужно). Интерфейс BG3iOS — английский, и Locale.current у приложения тоже
// английский, поэтому язык iPhone — из Locale.preferredLanguages.

import Foundation

@MainActor
enum BG3Language {
    // Имя у Larian (папка в Data/Localization и значение в language.lsx) и название на самом языке.
    static let all: [(id: String, name: String)] = [
        ("English", "English"),
        ("Russian", "Русский"),
        ("Ukrainian", "Українська"),
        ("French", "Français"),
        ("German", "Deutsch"),
        ("Polish", "Polski"),
        ("Spanish", "Español (España)"),
        ("LatinSpanish", "Español (Latinoamérica)"),
        ("Italian", "Italiano"),
        ("Turkish", "Türkçe"),
        ("BrazilianPortuguese", "Português (Brasil)"),
        ("Chinese", "简体中文"),
        ("ChineseTraditional", "繁體中文"),
        ("Japanese", "日本語"),
        ("Korean", "한국어"),
    ]

    static let key = "MacportGameLanguage"

    // Выбранный в BG3iOS, иначе — первый из языков iPhone, который есть у BG3.
    static var current: String {
        get {
            UserDefaults.standard.string(forKey: key).flatMap { id in all.contains { $0.id == id } ? id : nil }
                ?? preferred
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var preferred: String {
        for tag in Locale.preferredLanguages {
            if let id = larian(Locale.Language(identifier: tag)) { return id }
        }
        return "English"
    }

    static func larian(_ language: Locale.Language) -> String? {
        let region = language.region?.identifier
        switch language.languageCode?.identifier {
        case "en": return "English"
        case "ru": return "Russian"
        case "uk": return "Ukrainian"
        case "fr": return "French"
        case "de": return "German"
        case "pl": return "Polish"
        case "es": return region == nil || region == "ES" ? "Spanish" : "LatinSpanish"
        case "it": return "Italian"
        case "tr": return "Turkish"
        case "pt": return "BrazilianPortuguese"
        case "zh": return language.script?.identifier == "Hant" || ["TW", "HK", "MO"].contains(region ?? "")
            ? "ChineseTraditional" : "Chinese"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        default: return nil
        }
    }

    // Перед запуском: language.lsx игры — на выбранный язык (файл трогается, только если язык в нём другой).
    static func apply(to app: URL) {
        let file = app.appendingPathComponent("Contents/Data/Localization/language.lsx")
        let text = lsx(current)
        if let old = try? String(contentsOf: file, encoding: .utf8), old == text { return }
        try? Data(text.utf8).write(to: file, options: .atomic)
    }

    // Как пишет Steam (тот же формат у файла из языкового депо).
    static func lsx(_ id: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" ?>
        <save>
            <header version="2" time="1442303468" />
            <version major="2" minor="0" revision="0" build="0" />
            <region id="Config">
                <node id="root">
                    <children>
                        <node id="ConfigEntry">
                            <attribute id="MapKey" value="Language" type="22" />
                            <attribute id="Type" value="1" type="5" />
                            <attribute id="Value" value="\(id)" type="20" />
                        </node>
                    </children>
                </node>
            </region>
        </save>

        """
    }
}
