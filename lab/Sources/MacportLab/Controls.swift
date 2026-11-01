// SPDX-License-Identifier: GPL-3.0-or-later
// Чем управлять игрой — выбор в BG3iOS (Controls под кнопками Play): экранный геймпад (TouchGamepad) или
// подключённый контроллер (DualSense, DualShock 4, Xbox, MFi). Mac-версия BG3 сама работает с GameController: значки
// кнопок PlayStation или Xbox — по productCategory, тачпад DualSense (touchpadButton), подсветка, «Меню» —
// controllerPausedHandler. Подключённому контроллеру переводить ничего не нужно (у Playport перевод в XInput — для
// Windows-игр), достаточно не мешать ему своим: с контроллером экранные кнопки спрятаны, а наш контроллер к игре
// не подключается. Отключился последний контроллер — кнопки появляются, подключился снова — прячутся (TouchGamepad).

import GameController

@MainActor
enum Controls {
    enum Mode: String { case touch, controller }

    static let key = "MacportControls"

    static var mode: Mode {
        get { UserDefaults.standard.string(forKey: key).flatMap(Mode.init(rawValue:)) ?? .touch }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    // Подключённые контроллеры, кроме нашего экранного; gone — тот, что как раз отключается (уведомление об
    // отключении может прийти, пока он ещё в списке).
    static func connected(except gone: GCController? = nil) -> [GCController] {
        GCController.controllers().filter { $0 !== TouchGamepad.controller && $0 !== gone && $0.extendedGamepad != nil }
    }

    // «DualSense Wireless Controller», иначе — категория («DualSense», «Xbox One»).
    static func name(_ controller: GCController) -> String {
        controller.vendorName ?? controller.productCategory
    }
}
