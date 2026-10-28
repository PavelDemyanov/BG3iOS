// Свой экранный геймпад вместо системного GCVirtualController: тот не умеет «Меню» и «Вид», не даёт левый стик
// вместе с крестовиной и рисует всё поверх картинки. Здесь все кнопки — в чёрных полосах по бокам (безопасная
// область, остров камеры — слева):
// - слева: LT (в углу, по скруглению экрана), LB, «Вид» и «Меню» над островом, X и Y под ним;
// - справа: RT, RB, крестовина четырьмя кнопками в столбик (↑ ← → ↓), A и B.
// Стики появляются там, где палец повели по картинке (левая половина — левый стик, правая — правый), и исчезают,
// когда палец убран. Быстрое двойное касание — нажатие стика (L3 слева, R3 справа; повести вторым касанием —
// стик с нажатием). Щелчок мыши (mp_appkit_tap в MPAppKit) — только короткое касание в верхней трети картинки,
// поодаль от кнопок: иначе BG3 от случайного касания переключает интерфейс на мышь.
//
// Для игры это обычный контроллер GameController: GCController.withExtendedGamepad(), значения — setValue у
// элементов. Такой контроллер не попадает в GCController.controllers() и сам о себе не объявляет — список
// дополняется подменой метода, подключение объявляется уведомлением. «Меню» BG3 ловит устаревшим
// controllerPausedHandler (buttonMenu игра не читает), «Вид» — buttonOptions.

import GameController
import ObjectiveC
import UIKit

@MainActor
enum TouchGamepad {
    nonisolated(unsafe) static var controller: GCController?
    // setValue у контроллера из withExtendedGamepad() может не звать обработчики — тогда зовём их сами.
    private static var manualHandlers = false
    private static var window: UIWindow?
    private static var waiting: NSObjectProtocol?
    private static let haptic = UIImpactFeedbackGenerator(style: .light)
    private static var arrows: Set<Button> = []  // нажатые стрелки крестовины

    enum Button { case a, b, x, y, lb, rb, lt, rt, view, menu, up, down, left, right, l3, r3 }

    // Игра ищет контроллеры, когда её окно уже на экране: подключаем, когда ключевым станет окно игры
    // (уровень выше окна хоста).
    static func startWhenGameWindowIsKey(host: UIWindow?, log: @escaping (String) -> Void) {
        nonisolated(unsafe) let log = log
        nonisolated(unsafe) let host = host
        waiting = NotificationCenter.default.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil,
                                                         queue: .main) { note in
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                guard let window = object as? UIWindow, window !== host, window.windowLevel.rawValue > 0,
                      controller == nil else { return }
                if let waiting { NotificationCenter.default.removeObserver(waiting) }
                waiting = nil
                start(scene: window.windowScene, log: log)
            }
        }
    }

    static func start(scene: UIWindowScene?, log: @escaping (String) -> Void) {
        guard controller == nil, let scene else { return }
        let gamepad = GCController.withExtendedGamepad()
        guard let pad = gamepad.extendedGamepad else {
            log("геймпад: нет профиля extendedGamepad")
            return
        }
        // Самопроверка: зовёт ли setValue обработчик профиля. Обработчики идут в handlerQueue — главная очередь
        // выполнит их раньше нашего блока, поставленного после.
        nonisolated(unsafe) var fired = false
        gamepad.handlerQueue = .main
        pad.valueChangedHandler = { _, _ in fired = true }
        pad.buttonA.setValue(1)
        pad.buttonA.setValue(0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                pad.valueChangedHandler = nil
                manualHandlers = !fired
                // Ввод — сразу, не дожидаясь, пока игра разберёт главную очередь (она крутит её раз в кадр).
                gamepad.handlerQueue = DispatchQueue(label: "macport.gamepad", qos: .userInteractive)
                controller = gamepad
                addToControllerList()
                NotificationCenter.default.post(name: .GCControllerDidConnect, object: gamepad)
                let overlay = UIWindow(windowScene: scene)
                overlay.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 50)
                overlay.backgroundColor = .clear
                overlay.rootViewController = GamepadController()
                overlay.isHidden = false
                window = overlay
                haptic.prepare()
                log("геймпад подключён (свой), обработчики \(manualHandlers ? "зовём сами" : "зовёт GameController")")
                // Приняла ли игра контроллер: она вешает обработчики на профиль и паузу («Меню»).
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    MainActor.assumeIsolated {
                        log("геймпад у игры: обработчик профиля \(pad.valueChangedHandler != nil ? "есть" : "нет"), " +
                            "кнопки A \(pad.buttonA.valueChangedHandler != nil ? "есть" : "нет"), " +
                            "паузы \(gamepad.controllerPausedHandler != nil ? "есть" : "нет")")
                    }
                }
            }
        }
    }

    // GCController.controllers() — со своим контроллером.
    private static func addToControllerList() {
        guard let original = class_getClassMethod(GCController.self, #selector(GCController.controllers)),
              let ours = class_getClassMethod(GCController.self, #selector(GCController.macport_controllers))
        else { return }
        method_exchangeImplementations(original, ours)
    }

    static func set(_ button: Button, pressed: Bool) {
        guard let controller, let pad = controller.extendedGamepad else { return }
        if pressed { haptic.impactOccurred() }
        let input: GCControllerButtonInput?
        switch button {
        case .a: input = pad.buttonA
        case .b: input = pad.buttonB
        case .x: input = pad.buttonX
        case .y: input = pad.buttonY
        case .lb: input = pad.leftShoulder
        case .rb: input = pad.rightShoulder
        case .lt: input = pad.leftTrigger
        case .rt: input = pad.rightTrigger
        case .view: input = pad.buttonOptions
        case .l3: input = pad.leftThumbstickButton
        case .r3: input = pad.rightThumbstickButton
        case .menu:
            if pressed { controller.controllerPausedHandler?(controller) }
            input = nil
        case .up, .down, .left, .right:
            if pressed { arrows.insert(button) } else { arrows.remove(button) }
            // Две стрелки сразу — диагональ.
            setDpad(x: (arrows.contains(.right) ? 1 : 0) - (arrows.contains(.left) ? 1 : 0),
                    y: (arrows.contains(.up) ? 1 : 0) - (arrows.contains(.down) ? 1 : 0))
            input = nil
        }
        guard let input else { return }
        let value: Float = pressed ? 1 : 0
        input.setValue(value)
        if manualHandlers {
            input.valueChangedHandler?(input, value, pressed)
            input.pressedChangedHandler?(input, value, pressed)
            pad.valueChangedHandler?(pad, input)
        }
    }

    // Dynamic Island в альбомной ориентации (LandscapeRight: верх телефона слева) — у всех iPhone с островом
    // (14 Pro … 17 Pro Max) 126 × 37 точек, в 11 точках от края, посередине по высоте.
    static func island(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + 11, y: bounds.midY - 63, width: 37, height: 126)
    }

    static func setStick(left: Bool, x: Float, y: Float) {
        guard let pad = controller?.extendedGamepad else { return }
        let stick = left ? pad.leftThumbstick : pad.rightThumbstick
        stick.setValueForXAxis(x, yAxis: y)
        if manualHandlers {
            stick.valueChangedHandler?(stick, x, y)
            pad.valueChangedHandler?(pad, stick)
        }
    }

    private static func setDpad(x: Float, y: Float) {
        guard let pad = controller?.extendedGamepad else { return }
        pad.dpad.setValueForXAxis(x, yAxis: y)
        if manualHandlers {
            pad.dpad.valueChangedHandler?(pad.dpad, x, y)
            pad.valueChangedHandler?(pad, pad.dpad)
        }
    }

    static func tap(at point: CGPoint, clicks: Int) {
        typealias Tap = @convention(c) (Double, Double, Int) -> Void
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "mp_appkit_tap") else { return }
        unsafeBitCast(symbol, to: Tap.self)(point.x, point.y, clicks)
    }
}

extension GCController {
    // После обмена реализациями здесь — исходный controllers(), а этот метод отвечает за него.
    @objc dynamic class func macport_controllers() -> [GCController] {
        var list = macport_controllers()
        if let ours = TouchGamepad.controller, !list.contains(ours) { list.append(ours) }
        return list
    }
}

// Как у окна игры: без полоски «домой», жесты у краёв — со второго свайпа, без строки состояния, остров слева.
private final class GamepadController: UIViewController {
    override func loadView() { view = GamepadView() }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscapeRight }
}

// Весь экран: кнопки в боковых полосах, стики под пальцами. Касания мимо кнопок приходят сюда: по картинке —
// стик, нажатие стика или щелчок, по полосам — никуда.
private final class GamepadView: UIView {
    @MainActor private final class Stick {
        let left: Bool
        let origin: CGPoint
        var thumb = false  // стик нажат (L3/R3): второе касание двойного
        let base = UIView()
        let knob = UIView()
        init(left: Bool, origin: CGPoint) {
            self.left = left
            self.origin = origin
        }
    }

    private var stickRadius: CGFloat = 58  // 58 точек на 17 Pro Max, дальше — по масштабу раскладки
    private static let startDistance: CGFloat = 10  // палец сдвинулся дальше — уже стик, а не щелчок
    private static let doubleTapSeconds = 0.3, doubleTapDistance: CGFloat = 70
    private static let mouseInset: CGFloat = 44  // зона щелчков — дальше от боковых полос

    private let buttons: [(PadButton, TouchGamepad.Button)]
    private var pending: [ObjectIdentifier: CGPoint] = [:]
    private var sticks: [ObjectIdentifier: Stick] = [:]
    private var lastTap: (time: TimeInterval, point: CGPoint)?  // первое касание возможного двойного
    private var gameRect = CGRect.zero
    private var mouseRect = CGRect.zero  // верхняя треть картинки без краёв у полос

    init() {
        buttons = [
            (PadButton(text: "LT", shape: .corner(left: true)), .lt), (PadButton(text: "LB", shape: .bumper), .lb),
            (PadButton(symbol: "rectangle.on.rectangle"), .view), (PadButton(symbol: "line.3.horizontal"), .menu),
            (PadButton(text: "X", color: UIColor(red: 0.35, green: 0.6, blue: 1, alpha: 1)), .x),
            (PadButton(text: "Y", color: UIColor(red: 1, green: 0.8, blue: 0.2, alpha: 1)), .y),
            (PadButton(text: "RT", shape: .corner(left: false)), .rt), (PadButton(text: "RB", shape: .bumper), .rb),
            (PadButton(symbol: "arrowtriangle.up.fill", shape: .key), .up),
            (PadButton(symbol: "arrowtriangle.left.fill", shape: .key), .left),
            (PadButton(symbol: "arrowtriangle.right.fill", shape: .key), .right),
            (PadButton(symbol: "arrowtriangle.down.fill", shape: .key), .down),
            (PadButton(text: "A", color: UIColor(red: 0.45, green: 0.85, blue: 0.3, alpha: 1)), .a),
            (PadButton(text: "B", color: UIColor(red: 1, green: 0.35, blue: 0.35, alpha: 1)), .b),
        ]
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        for (view, button) in buttons {
            view.onChange = { TouchGamepad.set(button, pressed: $0) }
            addSubview(view)
        }
        FPSOverlay.shared.attachToggle(to: self, target: self, action: #selector(statsGesture(_:)))
    }

    // Три пальца держат экран — показать или спрятать строку статистики; эти касания ни щелчком, ни двойным
    // касанием не становятся.
    @objc private func statsGesture(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        pending.removeAll()
        lastTap = nil
        FPSOverlay.shared.toggle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    // Полосы — отступы безопасной области слева и справа (снизу картинка идёт до края). Остров камеры — посередине
    // левой полосы: над ним LT, LB, «Вид», «Меню», под ним X и Y. Справа на том же месте — стрелки крестовины.
    // Размеры подобраны на iPhone 17 Pro Max (высота 440 точек); на экранах ниже (17 Pro — 402) всё уменьшается
    // в масштабе: по высоте экрана и так, чтобы блок над островом (148 точек при масштабе 1) кончался не ближе
    // 6 точек к нему. Ширина полос (62 точки) у обоих одна — ширина кнопок от неё и идёт.
    override func layoutSubviews() {
        super.layoutSubviews()
        let left = max(safeAreaInsets.left, 50), right = max(safeAreaInsets.right, 50)
        let w = bounds.width, h = bounds.height
        let island = TouchGamepad.island(in: bounds)
        let s = min(1, h / 440, (island.minY - 6) / 148)
        stickRadius = 58 * s
        gameRect = CGRect(x: left, y: 0, width: w - left - right, height: h)
        mouseRect = CGRect(x: gameRect.minX + Self.mouseInset, y: 0, width: gameRect.width - 2 * Self.mouseInset,
                           height: h / 3)
        let lx = left / 2, rx = w - right / 2
        let screenRadius = Self.displayCornerRadius(window?.windowScene?.screen)
        let edge: CGFloat = 4  // зазор от края экрана у угловых курков
        let face = 46 * s, small = 30 * s, key = 44 * s, gap = 6 * s
        let xCenter = h - 114 * s, yCenter = h - 58 * s
        var frames: [TouchGamepad.Button: CGRect] = [
            .lt: CGRect(x: edge, y: edge, width: left - 2 * edge, height: 44 * s),
            .rt: CGRect(x: w - right + edge, y: edge, width: right - 2 * edge, height: 44 * s),
            .lb: CGRect(x: lx - (left - 14) / 2, y: 54 * s, width: left - 14, height: 22 * s),
            .rb: CGRect(x: rx - (right - 14) / 2, y: 54 * s, width: right - 14, height: 22 * s),
            .view: CGRect(x: lx - small / 2, y: 84 * s, width: small, height: small),
            .menu: CGRect(x: lx - small / 2, y: 84 * s + small + 4 * s, width: small, height: small),
            .x: CGRect(x: lx - face / 2, y: xCenter - face / 2, width: face, height: face),
            .y: CGRect(x: lx - face / 2, y: yCenter - face / 2, width: face, height: face),
            .a: CGRect(x: rx - face / 2, y: xCenter - face / 2, width: face, height: face),
            .b: CGRect(x: rx - face / 2, y: yCenter - face / 2, width: face, height: face),
        ]
        // Стрелки — столбиком посередине между RB и A.
        let column = 4 * key + 3 * gap, top = (76 * s + (xCenter - face / 2)) / 2 - column / 2
        for (i, arrow) in [TouchGamepad.Button.up, .left, .right, .down].enumerated() {
            frames[arrow] = CGRect(x: rx - key / 2, y: top + CGFloat(i) * (key + gap), width: key, height: key)
        }
        for (view, button) in buttons {
            guard let frame = frames[button] else { continue }
            view.frame = frame
            view.scale = s
            view.cornerRadius = screenRadius - edge  // для угловых: дуга концентрична скруглению экрана
        }
    }

    // Радиус скругления экрана (закрытое свойство UIScreen); у iPhone 17 Pro Max около 62 точек.
    private static func displayCornerRadius(_ screen: UIScreen?) -> CGFloat {
        let key = "_displayCornerRadius"
        guard let screen, screen.responds(to: NSSelectorFromString(key)),
              let radius = screen.value(forKey: key) as? CGFloat, radius > 0 else { return 55 }
        return radius
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let p = touch.location(in: self)
            guard gameRect.contains(p) else { continue }
            let left = p.x < gameRect.midX
            // Второе касание двойного: стик сразу, с нажатием (L3/R3), пока палец на экране.
            if let last = lastTap, touch.timestamp - last.time < Self.doubleTapSeconds,
               hypot(p.x - last.point.x, p.y - last.point.y) < Self.doubleTapDistance,
               (last.point.x < gameRect.midX) == left, !sticks.values.contains(where: { $0.left == left }) {
                lastTap = nil
                let stick = makeStick(left: left, at: p)
                stick.thumb = true
                stick.base.layer.borderColor = UIColor(red: 0.11, green: 0.62, blue: 0.46, alpha: 1).cgColor
                stick.base.layer.borderWidth = 3
                sticks[ObjectIdentifier(touch)] = stick
                TouchGamepad.set(left ? .l3 : .r3, pressed: true)
            } else {
                pending[ObjectIdentifier(touch)] = p
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch), p = touch.location(in: self)
            if let stick = sticks[id] {
                move(stick, to: p)
            } else if let start = pending[id], hypot(p.x - start.x, p.y - start.y) > Self.startDistance {
                pending[id] = nil
                let left = start.x < gameRect.midX
                // Этот стик уже держит другой палец — касание ни во что не превращается.
                guard !sticks.values.contains(where: { $0.left == left }) else { continue }
                let stick = makeStick(left: left, at: start)
                sticks[id] = stick
                move(stick, to: p)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, tap: true)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, tap: false)
    }

    private func finish(_ touches: Set<UITouch>, tap: Bool) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            if let stick = sticks.removeValue(forKey: id) {
                stick.base.removeFromSuperview()
                TouchGamepad.setStick(left: stick.left, x: 0, y: 0)
                if stick.thumb { TouchGamepad.set(stick.left ? .l3 : .r3, pressed: false) }
            } else if let start = pending.removeValue(forKey: id), tap {
                if mouseRect.contains(start) {
                    TouchGamepad.tap(at: start, clicks: max(touch.tapCount, 1))
                    showClick(at: start)
                } else {
                    lastTap = (touch.timestamp, start)
                }
            }
        }
    }

    // Отметка щелчка: кольцо, которое расходится и гаснет.
    private func showClick(at point: CGPoint) {
        let ring = UIView(frame: CGRect(x: point.x - 14, y: point.y - 14, width: 28, height: 28))
        ring.layer.cornerRadius = 14
        ring.layer.borderColor = UIColor(red: 0.94, green: 0.62, blue: 0.15, alpha: 1).cgColor
        ring.layer.borderWidth = 2
        ring.isUserInteractionEnabled = false
        addSubview(ring)
        UIView.animate(withDuration: 0.4, animations: {
            ring.transform = CGAffineTransform(scaleX: 1.8, y: 1.8)
            ring.alpha = 0
        }, completion: { _ in ring.removeFromSuperview() })
    }

    private func makeStick(left: Bool, at origin: CGPoint) -> Stick {
        let stick = Stick(left: left, origin: origin)
        let r = stickRadius, kr = r * 0.42
        stick.base.frame = CGRect(x: origin.x - r, y: origin.y - r, width: 2 * r, height: 2 * r)
        stick.base.layer.cornerRadius = r
        stick.base.backgroundColor = UIColor(white: 1, alpha: 0.08)
        stick.base.layer.borderColor = UIColor(white: 1, alpha: 0.45).cgColor
        stick.base.layer.borderWidth = 1.5
        stick.base.isUserInteractionEnabled = false
        stick.knob.frame = CGRect(x: r - kr, y: r - kr, width: 2 * kr, height: 2 * kr)
        stick.knob.layer.cornerRadius = kr
        stick.knob.backgroundColor = UIColor(white: 1, alpha: 0.55)
        stick.base.addSubview(stick.knob)
        addSubview(stick.base)
        return stick
    }

    private func move(_ stick: Stick, to p: CGPoint) {
        let r = stickRadius
        var dx = p.x - stick.origin.x, dy = p.y - stick.origin.y
        let d = hypot(dx, dy)
        if d > r {
            dx *= r / d
            dy *= r / d
        }
        stick.knob.transform = CGAffineTransform(translationX: dx, y: dy)
        TouchGamepad.setStick(left: stick.left, x: Float(dx / r), y: Float(-dy / r))  // вверх — плюс
    }
}

// Кнопка в боковой полосе: нажата, пока на ней палец.
private final class PadButton: UIView {
    enum Shape: Equatable {
        case round, bumper, key
        case corner(left: Bool)  // курок в верхнем углу: внешняя сторона — дуга вдоль скругления экрана
    }

    var onChange: ((Bool) -> Void)?
    var cornerRadius: CGFloat = 55 { didSet { setNeedsLayout() } }
    var scale: CGFloat = 1 { didSet { if scale != oldValue { applyScale() } } }  // подписи — вместе с кнопками
    private var symbol: String?
    private let shape: Shape
    private let label = UILabel()
    private let image = UIImageView()
    private let outline = CAShapeLayer()
    private static let idle = UIColor(white: 0.24, alpha: 1)
    private static let active = UIColor(red: 0.11, green: 0.62, blue: 0.46, alpha: 1)

    init(text: String, color: UIColor = .white, shape: Shape = .round) {
        self.shape = shape
        super.init(frame: .zero)
        label.text = text
        label.textColor = color
        label.textAlignment = .center
        addSubview(label)
        setUp()
    }

    init(symbol: String, shape: Shape = .round) {
        self.shape = shape
        super.init(frame: .zero)
        self.symbol = symbol
        image.tintColor = .white
        image.contentMode = .center
        addSubview(image)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        isMultipleTouchEnabled = false
        applyScale()
        if case .corner = shape {
            outline.fillColor = Self.idle.cgColor
            layer.insertSublayer(outline, at: 0)
        } else {
            backgroundColor = Self.idle
        }
    }

    private func applyScale() {
        label.font = .systemFont(ofSize: (shape == .round ? 17 : 13) * scale, weight: .bold)
        if let symbol {
            image.image = UIImage(systemName: symbol,
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 13 * scale, weight: .bold))
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
        image.frame = bounds
        switch shape {
        case .round: layer.cornerRadius = bounds.height / 2
        case .bumper: layer.cornerRadius = 6
        case .key: layer.cornerRadius = 10
        case .corner(let left):
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            outline.frame = bounds
            outline.path = cornerPath(left: left)
            CATransaction.commit()
            // Подпись — ближе к внутреннему углу, где у фигуры больше места.
            label.frame = bounds.offsetBy(dx: left ? bounds.width * 0.12 : -bounds.width * 0.12, dy: bounds.height * 0.12)
        }
    }

    // Пересечение прямоугольника кнопки (скругления 8) с экраном у угла: круг радиуса cornerRadius с центром
    // в (R, R) от угла плюс всё, что дальше R по любой оси.
    private func cornerPath(left: Bool) -> CGPath {
        let r = cornerRadius, w = bounds.width, h = bounds.height
        let cx = left ? r : w - r
        let screen = CGMutablePath()
        screen.addEllipse(in: CGRect(x: cx - r, y: 0, width: 2 * r, height: 2 * r))
        let inner = CGPath(rect: left ? CGRect(x: r, y: 0, width: 2000, height: 1000)
                                      : CGRect(x: -1000, y: 0, width: 1000 + w - r, height: 1000), transform: nil)
        let below = CGPath(rect: CGRect(x: -1000, y: r, width: 2000, height: 1000), transform: nil)
        let area = screen.union(inner).union(below)
        let box = CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
        return box.intersection(area)
    }

    private func setPressed(_ pressed: Bool) {
        let color = pressed ? Self.active : Self.idle
        if case .corner = shape {
            CATransaction.begin()
            CATransaction.setDisableActions(true)  // без плавной смены цвета, как у остальных кнопок
            outline.fillColor = color.cgColor
            CATransaction.commit()
        } else {
            backgroundColor = color
        }
        onChange?(pressed)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { setPressed(true) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { setPressed(false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { setPressed(false) }
}
