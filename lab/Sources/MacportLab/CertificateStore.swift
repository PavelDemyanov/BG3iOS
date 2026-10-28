// Сертификат для подписи игры на телефоне — тот, которым AltStore (или SideStore) подписал само приложение: iOS
// загружает в приложение только библиотеки той же команды. Как у LiveContainer: приложение открывает
// altstore-classic://certificate (sidestore://certificate) с шаблоном ответа, магазин спрашивает пользователя и
// возвращается по macport://certificate?cert=<p12 в base64>&password=<пароль>. Запасной путь — файл .p12 и пароль.
// Хранится в связке ключей приложения (только на этом устройстве).

import Foundation
import MachOSign
import Security
import UIKit

@MainActor
enum CertificateStore {
    static let callbackScheme = "macport"
    static let changed = Notification.Name("MacportCertificateChanged")
    private static let service = "com.redpax.macport.signing"

    enum Store: String {
        case altStore = "altstore-classic", sideStore = "sidestore"
        var title: String { self == .altStore ? "AltStore" : "SideStore" }
    }

    // Запросить сертификат у магазина: ответ придёт в handle(url:).
    static func request(from store: Store) async -> Bool {
        let template = "\(callbackScheme)://certificate?cert=$(BASE64_CERT)&password=$(PASSWORD)"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = template.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "\(store.rawValue)://certificate?callback_template=\(encoded)") else { return false }
        return await UIApplication.shared.open(url)
    }

    // Ответ магазина: macport://certificate?cert=…&password=… Возвращает текст для пользователя.
    static func handle(url: URL) -> String? {
        guard url.scheme == callbackScheme, url.host == "certificate",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let query = Dictionary(items.map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        // base64 в запросе: «+» мог прийти как пробел.
        // base64 в запросе: «+» мог прийти как пробел, а сам сертификат — закодированным ещё раз.
        let raw = query["cert"] ?? ""
        guard let data = [raw, raw.removingPercentEncoding ?? raw].lazy
            .compactMap({ Data(base64Encoded: $0.replacingOccurrences(of: " ", with: "+"), options: .ignoreUnknownCharacters) })
            .first(where: { !$0.isEmpty }) else {
            return "The reply has no certificate."
        }
        return save(p12: data, password: query["password"] ?? "")
    }

    // Проверить и сохранить; текст — итог для пользователя.
    static func save(p12: Data, password: String) -> String {
        let identity: SigningIdentity
        do {
            identity = try SigningIdentity.pkcs12(p12, password: password)
        } catch {
            return "This certificate can't be used: \(error)"
        }
        if let host = hostTeamID, host != identity.teamID {
            return "This certificate belongs to team \(identity.teamID), but BG3iOS is signed by team \(host). The game couldn't be loaded with it."
        }
        store(p12, account: "p12")
        store(Data(password.utf8), account: "password")
        NotificationCenter.default.post(name: changed, object: nil)
        return "Certificate saved: \(describe(identity))"
    }

    static func remove() {
        for account in ["p12", "password"] {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                           kSecAttrAccount as String: account] as CFDictionary)
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    // Сохранённое удостоверение (nil — нет или не открывается).
    static var identity: SigningIdentity? {
        guard let p12 = load(account: "p12"), let password = load(account: "password") else { return nil }
        return try? SigningIdentity.pkcs12(p12, password: String(decoding: password, as: UTF8.self))
    }

    static func describe(_ identity: SigningIdentity) -> String {
        var text = "\(identity.commonName ?? "?"), team \(identity.teamID)"
        if let expires = identity.expires {
            text += ", expires " + expires.formatted(date: .abbreviated, time: .omitted)
        }
        return text
    }

    // Команда, которой подписано само приложение: из embedded.mobileprovision (plist внутри подписи CMS).
    static var hostTeamID: String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8)),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let teams = plist["TeamIdentifier"] as? [String] else { return nil }
        return teams.first
    }

    private static func store(_ data: Data, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func load(account: String) -> Data? {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
