// Строка статистики поверх Mac-программы — небольшая плашка в правом верхнем углу:
// «17 FPS · GPU 45 ms · Thermal Hot». Кадры считает MPMetal (mp_metal_frames — каждый drawable у CAMetalLayer),
// GPU — время видеокарты на кадр (сумма буферов команд), Thermal — температурное состояние iOS. Обновляется дважды
// в секунду. Цвета: FPS ниже 20 — красный, 20–30 — жёлтый, выше 30 — зелёный; Thermal: Normal — зелёный,
// Warm — белый, Hot (serious) — жёлтый, Critical — красный.
// Показать и спрятать — удержание тремя пальцами около секунды (жест вешает экранный геймпад или, без него,
// окно игры). С «Play with FPS Counter» (--fps) строка видна с запуска, с «Play» — скрыта.

import UIKit

@MainActor
final class FPSOverlay: NSObject {
    static let shared = FPSOverlay()

    private var window: UIWindow?
    private let label = PaddedLabel()
    private var timer: Timer?
    private var lastFrames: UInt64 = 0
    private var lastGPU = 0.0
    private var lastTime = CACurrentMediaTime()
    private var waiting: NSObjectProtocol?

    // gestureOnGameWindow — без экранного геймпада касания идут прямо в окно игры: жест вешается на него.
    func start(visible: Bool, gestureOnGameWindow: Bool) {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let controller = OverlayController()
        controller.view.isUserInteractionEnabled = false
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        label.layer.cornerRadius = 6
        label.layer.masksToBounds = true
        label.text = "— FPS"
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(label)
        let guide = controller.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: guide.topAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -6),
        ])
        // Окно над окном игры и экранным геймпадом, без касаний: они уходят в игру.
        let overlay = UIWindow(windowScene: scene)
        overlay.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 100)
        overlay.isUserInteractionEnabled = false
        overlay.backgroundColor = .clear
        overlay.rootViewController = controller
        overlay.isHidden = !visible  // «Play with FPS Counter» — виден с запуска, «Play» — скрыт
        window = overlay
        lastFrames = MacRunner.frames()
        lastTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { self.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if gestureOnGameWindow { attachToGameWindow() }
    }

    func toggle() {
        guard let window else { return }
        window.isHidden.toggle()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // Жест «три пальца» на виде, который получает касания (экранный геймпад или окно игры); action зовётся
    // у target, когда жест начался.
    func attachToggle(to view: UIView, target: Any, action: Selector) {
        let gesture = UILongPressGestureRecognizer(target: target, action: action)
        gesture.numberOfTouchesRequired = 3
        gesture.minimumPressDuration = 0.9
        // Касания идут своим путём (кнопки, стики, мышь) — жест только наблюдает.
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        view.addGestureRecognizer(gesture)
    }

    private func attachToGameWindow() {
        waiting = NotificationCenter.default.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil,
                                                         queue: .main) { note in
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                guard let game = object as? UIWindow, game !== self.window, game.windowLevel.rawValue > 0 else { return }
                if let waiting = self.waiting { NotificationCenter.default.removeObserver(waiting) }
                self.waiting = nil
                self.attachToggle(to: game, target: self, action: #selector(self.gesture(_:)))
            }
        }
    }

    @objc private func gesture(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began { toggle() }
    }

    private func tick() {
        let frames = MacRunner.frames(), gpu = MacRunner.gpuSeconds(), now = CACurrentMediaTime()
        let count = Double(frames &- lastFrames)
        let fps = count / max(now - lastTime, 0.001)
        // Время видеокарты на кадр: близко к длине кадра (1000/FPS) — упор в видеокарту, заметно меньше — в процессор.
        let gpuMs = count > 0 ? (gpu - lastGPU) / count * 1000 : 0
        lastFrames = frames
        lastGPU = gpu
        lastTime = now
        guard window?.isHidden == false else { return }
        let (thermal, thermalColor): (String, UIColor) = switch ProcessInfo.processInfo.thermalState {
        case .nominal: ("Normal", .systemGreen)
        case .fair: ("Warm", .white)
        case .serious: ("Hot", .systemYellow)
        case .critical: ("Critical", .systemRed)
        @unknown default: ("?", .white)
        }
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: String(format: "%.0f FPS", fps), attributes: [
            .foregroundColor: fps < 20 ? UIColor.systemRed : fps <= 30 ? UIColor.systemYellow : UIColor.systemGreen,
        ]))
        text.append(NSAttributedString(string: String(format: " · GPU %.0f ms · Thermal ", gpuMs),
                                       attributes: [.foregroundColor: UIColor.white]))
        text.append(NSAttributedString(string: thermal, attributes: [.foregroundColor: thermalColor]))
        label.attributedText = text
    }
}

// Как у окна игры: без полоски «домой», жесты у краёв — со второго свайпа, без строки состояния.
private final class OverlayController: UIViewController {
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscapeRight }
}

private final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 6, dy: 2)) }
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 12, height: size.height + 4)
    }
}
