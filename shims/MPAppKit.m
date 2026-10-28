// MPAppKit: заменитель AppKit поверх UIKit для Mac-программ, загруженных на iOS.
//
// Классы называются как в AppKit (NSApplication, NSWindow, NSView...), потому что Mac-программа
// ищет их по именам и наследует от них. NSView — не UIView, а обёртка над своим MPHostView: так
// методы AppKit (frame, layer, window, subviews) не спорят с одноимёнными у UIKit. Окно — UIWindow
// на сцене хост-приложения поверх его собственных окон.
//
// Цикл приложения: -[NSApplication run] крутит главный run loop вложенно (CFRunLoopRunInMode), так
// что UIKit продолжает получать касания, а главная очередь GCD — выполняться. Касания превращаются в
// события мыши (левая кнопка), координаты — в систему окна AppKit (начало слева снизу).
// Растёт по мере надобности: сначала то, что нужно примерам, затем BG3.

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

typedef CGPoint NSPoint;
typedef CGSize NSSize;
typedef CGRect NSRect;

typedef NS_ENUM(NSUInteger, NSEventType) {
    NSEventTypeLeftMouseDown = 1, NSEventTypeLeftMouseUp = 2, NSEventTypeRightMouseDown = 3,
    NSEventTypeRightMouseUp = 4, NSEventTypeMouseMoved = 5, NSEventTypeLeftMouseDragged = 6,
    NSEventTypeRightMouseDragged = 7, NSEventTypeKeyDown = 10, NSEventTypeKeyUp = 11,
    NSEventTypeFlagsChanged = 12, NSEventTypeScrollWheel = 22,
};

static void mp_log(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(stderr, "MPAppKit: %s\n", line.UTF8String);
}

@class NSWindow, NSView, NSEvent;

// Нереализованный метод не роняет программу: пишется в журнал и возвращает nil/0. respondsToSelector:
// при этом честный (NO) — пересылка не добавляет методов в класс.
static NSMutableSet *mp_missing;
static void mp_missing_call(id target, SEL sel, BOOL isClass)
{
    NSString *key = [NSString stringWithFormat:@"%c[%@ %@]", isClass ? '+' : '-',
                     NSStringFromClass(isClass ? (Class)target : [target class]), NSStringFromSelector(sel)];
    @synchronized(NSNull.class) {
        if (!mp_missing) mp_missing = [NSMutableSet set];
        if ([mp_missing containsObject:key]) return;
        [mp_missing addObject:key];
    }
    mp_log(@"не реализован %@", key);
}
#define MP_FORWARDING \
    - (NSMethodSignature *)methodSignatureForSelector:(SEL)sel \
    { return [super methodSignatureForSelector:sel] ?: [NSMethodSignature signatureWithObjCTypes:"@@:"]; } \
    - (void)forwardInvocation:(NSInvocation *)invocation \
    { mp_missing_call(self, invocation.selector, NO); id none = nil; [invocation setReturnValue:&none]; } \
    + (NSMethodSignature *)methodSignatureForSelector:(SEL)sel \
    { return [super methodSignatureForSelector:sel] ?: [NSMethodSignature signatureWithObjCTypes:"@@:"]; } \
    + (void)forwardInvocation:(NSInvocation *)invocation \
    { mp_missing_call(self, invocation.selector, YES); id none = nil; [invocation setReturnValue:&none]; }

// Глобальное NSApp и константы, которые Mac-программы берут из AppKit.
id NSApp = nil;
NSString *const NSApplicationDidBecomeActiveNotification = @"NSApplicationDidBecomeActiveNotification";
NSString *const NSApplicationDidResignActiveNotification = @"NSApplicationDidResignActiveNotification";
NSString *const NSApplicationWillFinishLaunchingNotification = @"NSApplicationWillFinishLaunchingNotification";
NSString *const NSApplicationDidFinishLaunchingNotification = @"NSApplicationDidFinishLaunchingNotification";
NSString *const NSApplicationWillTerminateNotification = @"NSApplicationWillTerminateNotification";
NSString *const NSWindowDidResizeNotification = @"NSWindowDidResizeNotification";
NSString *const NSWindowDidBecomeKeyNotification = @"NSWindowDidBecomeKeyNotification";
NSString *const NSWindowWillCloseNotification = @"NSWindowWillCloseNotification";

static UIWindowScene *mp_scene(void)
{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)scene;
    }
    return nil;
}

// Безопасная область сцены: без Dynamic Island и скруглённых углов — там игра не рисует (по бокам чёрные поля,
// в них кнопки экранного геймпада хоста), иначе туда попадают её кнопки. Снизу картинка идёт до края: полоска
// «домой» спрятана, жест — со второго свайпа. Берётся у окна хоста, оно на экране с запуска.
// MPFullScreen YES (аргумент -MPFullScreen YES) — во весь экран, как раньше.
static UIEdgeInsets mp_safe_insets(void)
{
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"MPFullScreen"]) return UIEdgeInsetsZero;
    static UIEdgeInsets cached;
    static BOOL known;
    if (known) return cached;
    // Окно, ещё не прошедшее раскладку, отдаёт нулевые отступы — раскладываем принудительно.
    UIWindowScene *scene = mp_scene();
    for (UIWindow *window in scene.windows) {
        [window setNeedsLayout];
        [window layoutIfNeeded];
        UIEdgeInsets i = window.safeAreaInsets;
        if (i.left || i.right || i.bottom) {
            cached = i;
            cached.bottom = 0;
            known = YES;
            break;
        }
    }
    mp_log(@"безопасная область: слева %.0f, справа %.0f, сверху %.0f, снизу %.0f%@", cached.left, cached.right,
           cached.top, cached.bottom, known ? @"" : @" (отступов нет)");
    return cached;
}

// Прямоугольник игры в координатах сцены.
static CGRect mp_game_rect(void)
{
    UIWindowScene *scene = mp_scene();
    CGRect bounds = scene ? scene.coordinateSpace.bounds : CGRectMake(0, 0, 932, 430);
    return UIEdgeInsetsInsetRect(bounds, mp_safe_insets());
}

#pragma mark - NSResponder

@interface NSResponder : NSObject
@property(nonatomic, weak) NSResponder *nextResponder;
@end

@implementation NSResponder
MP_FORWARDING
- (BOOL)acceptsFirstResponder { return NO; }
- (BOOL)becomeFirstResponder { return YES; }
- (BOOL)resignFirstResponder { return YES; }
- (void)mouseDown:(NSEvent *)event { [self.nextResponder mouseDown:event]; }
- (void)mouseUp:(NSEvent *)event { [self.nextResponder mouseUp:event]; }
- (void)mouseDragged:(NSEvent *)event { [self.nextResponder mouseDragged:event]; }
- (void)mouseMoved:(NSEvent *)event { [self.nextResponder mouseMoved:event]; }
- (void)rightMouseDown:(NSEvent *)event { [self.nextResponder rightMouseDown:event]; }
- (void)rightMouseUp:(NSEvent *)event { [self.nextResponder rightMouseUp:event]; }
- (void)rightMouseDragged:(NSEvent *)event { [self.nextResponder rightMouseDragged:event]; }
- (void)scrollWheel:(NSEvent *)event { [self.nextResponder scrollWheel:event]; }
- (void)keyDown:(NSEvent *)event { [self.nextResponder keyDown:event]; }
- (void)keyUp:(NSEvent *)event { [self.nextResponder keyUp:event]; }
- (void)flagsChanged:(NSEvent *)event { [self.nextResponder flagsChanged:event]; }
@end

#pragma mark - NSEvent

@interface NSEvent : NSObject
@property(nonatomic) NSEventType type;
@property(nonatomic) NSPoint locationInWindow;
@property(nonatomic) NSUInteger modifierFlags;
@property(nonatomic) NSTimeInterval timestamp;
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic, copy) NSString *characters;
@property(nonatomic, copy) NSString *charactersIgnoringModifiers;
@property(nonatomic) unsigned short keyCode;
@property(nonatomic) NSInteger clickCount;
@property(nonatomic) NSInteger buttonNumber;
@property(nonatomic) CGFloat deltaX, deltaY;
@property(nonatomic, getter=isARepeat) BOOL ARepeat;
@property(nonatomic, weak) NSView *mp_view;  // вид под пальцем: ему и мышь
@end

static NSPoint mp_mouse_location;  // в координатах экрана AppKit

@implementation NSEvent
MP_FORWARDING
+ (NSPoint)mouseLocation { return mp_mouse_location; }
+ (NSUInteger)modifierFlags { return 0; }
+ (NSUInteger)pressedMouseButtons { return 0; }
- (CGFloat)scrollingDeltaX { return self.deltaX; }
- (CGFloat)scrollingDeltaY { return self.deltaY; }
- (BOOL)hasPreciseScrollingDeltas { return YES; }
- (NSInteger)windowNumber { return 1; }
@end

#pragma mark - NSScreen

@interface NSScreen : NSObject
@end

@implementation NSScreen
MP_FORWARDING
+ (instancetype)mainScreen
{
    static NSScreen *screen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ screen = [NSScreen new]; });
    return screen;
}
+ (NSArray *)screens { return @[ [self mainScreen] ]; }
// Размер в точках, по сцене (в альбомной ориентации ширина больше высоты).
- (NSRect)frame
{
    CGRect game = mp_game_rect();
    return CGRectMake(0, 0, game.size.width, game.size.height);
}
- (NSRect)visibleFrame { return self.frame; }
- (CGFloat)backingScaleFactor { return mp_scene().screen.scale ?: 3; }
- (NSInteger)maximumFramesPerSecond { return mp_scene().screen.maximumFramesPerSecond ?: 60; }
- (NSDictionary *)deviceDescription
{
    return @{ @"NSScreenNumber": @1, @"NSDeviceSize": [NSValue valueWithCGSize:self.frame.size] };
}
- (NSString *)localizedName { return @"iPhone"; }
@end

#pragma mark - NSView

@class MPHostView;

@interface NSView : NSResponder
@property(nonatomic, readonly) MPHostView *mp_host;
@property(nonatomic) NSRect frame;
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic, weak) NSView *superview;
@property(nonatomic, readonly) NSMutableArray<NSView *> *mp_subviews;
@property(nonatomic) BOOL wantsLayer;
@property(nonatomic, strong) CALayer *layer;
@property(nonatomic) BOOL needsDisplay;
- (instancetype)initWithFrame:(NSRect)frame;
- (CALayer *)makeBackingLayer;
- (void)mp_layout;
@end

@interface MPHostView : UIView {
    CGPoint _mp_last;           // последняя точка пальца (координаты окна AppKit)
    BOOL _mp_pressed;           // mouseDown уже отправлен
    BOOL _mp_release;           // палец убран до mouseDown
    NSUInteger _mp_generation;  // номер касания: отложенное нажатие старого касания не отправлять
}
@property(nonatomic, weak) NSView *owner;
@end

@interface NSWindow : NSResponder
@property(nonatomic, strong) NSView *contentView;
@property(nonatomic, copy) NSString *title;
@property(nonatomic) NSRect frame;
@property(nonatomic) NSUInteger styleMask;
@property(nonatomic, weak) id delegate;
@property(nonatomic, weak) NSResponder *firstResponder;
@property(nonatomic, readonly) UIWindow *mp_window;
- (void)sendEvent:(NSEvent *)event;
- (CGFloat)backingScaleFactor;
@end

@implementation MPHostView
- (void)layoutSubviews
{
    [super layoutSubviews];
    [self.owner mp_layout];
}

// Касание = левая кнопка мыши. Точка — в координатах окна AppKit (начало слева снизу).
// Игры берут положение курсора из mouseMoved:, а в mouseDown: только «кнопка нажата» (так у BG3), а у пальца
// нет наведения. Поэтому касание — сначала движение в точку, через пару кадров нажатие (интерфейс успевает
// отметить кнопку под курсором); палец убрали раньше — отпускание уходит после нажатия.
static const int64_t MPPressDelay = 40 * NSEC_PER_MSEC;

- (void)mp_send:(NSEventType)type at:(CGPoint)p clicks:(NSInteger)clicks
{
    NSWindow *window = self.owner.window;
    NSEvent *event = [NSEvent new];
    event.type = type;
    event.locationInWindow = p;
    event.timestamp = NSProcessInfo.processInfo.systemUptime;
    event.window = window;
    event.clickCount = clicks;
    event.mp_view = self.owner;
    mp_mouse_location = p;
    [window sendEvent:event];
}
// Точка в координатах окна AppKit: от вида содержимого (он сдвинут на поля безопасной области).
- (CGPoint)mp_point:(UITouch *)touch
{
    UIView *content = self.owner.window.contentView.mp_host ?: self;
    CGPoint p = [touch locationInView:content];
    return CGPointMake(p.x, content.bounds.size.height - p.y);
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    UITouch *touch = touches.anyObject;
    CGPoint p = [self mp_point:touch];
    NSInteger clicks = touch.tapCount;
    _mp_last = p;
    _mp_pressed = NO;
    _mp_release = NO;
    NSUInteger generation = ++_mp_generation;
    if (generation <= 50) mp_log(@"касание %.0f,%.0f → %@", p.x, p.y, NSStringFromClass([self.owner class]));
    [self mp_send:NSEventTypeMouseMoved at:p clicks:0];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, MPPressDelay), dispatch_get_main_queue(), ^{
        if (generation != self->_mp_generation) return;
        [self mp_send:NSEventTypeLeftMouseDown at:self->_mp_last clicks:clicks];
        self->_mp_pressed = YES;
        if (self->_mp_release) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, MPPressDelay), dispatch_get_main_queue(), ^{
                if (generation != self->_mp_generation) return;
                [self mp_send:NSEventTypeLeftMouseUp at:self->_mp_last clicks:clicks];
                self->_mp_pressed = NO;
            });
        }
    });
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    _mp_last = [self mp_point:touches.anyObject];
    [self mp_send:_mp_pressed ? NSEventTypeLeftMouseDragged : NSEventTypeMouseMoved at:_mp_last clicks:0];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    UITouch *touch = touches.anyObject;
    _mp_last = [self mp_point:touch];
    if (_mp_pressed) {
        [self mp_send:NSEventTypeLeftMouseUp at:_mp_last clicks:touch.tapCount];
        _mp_pressed = NO;
    } else {
        _mp_release = YES;
    }
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self touchesEnded:touches withEvent:event];
}
// Щелчок без касания этого вида: точка — в координатах окна UIKit. Как у касания: движение, нажатие, отпускание.
- (void)mp_tap:(CGPoint)point clicks:(NSInteger)clicks
{
    UIView *content = self.owner.window.contentView.mp_host ?: self;
    CGPoint p = [content convertPoint:point fromView:nil];
    p.y = content.bounds.size.height - p.y;
    _mp_last = p;
    _mp_pressed = NO;
    _mp_release = NO;
    NSUInteger generation = ++_mp_generation;
    if (generation <= 50) mp_log(@"щелчок %.0f,%.0f → %@", p.x, p.y, NSStringFromClass([self.owner class]));
    [self mp_send:NSEventTypeMouseMoved at:p clicks:0];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, MPPressDelay), dispatch_get_main_queue(), ^{
        if (generation != self->_mp_generation) return;
        [self mp_send:NSEventTypeLeftMouseDown at:p clicks:clicks];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, MPPressDelay), dispatch_get_main_queue(), ^{
            if (generation != self->_mp_generation) return;
            [self mp_send:NSEventTypeLeftMouseUp at:p clicks:clicks];
        });
    });
}
@end

@implementation NSView

- (instancetype)init { return [self initWithFrame:CGRectZero]; }

- (instancetype)initWithFrame:(NSRect)frame
{
    if (!(self = [super init])) return nil;
    _mp_host = [[MPHostView alloc] initWithFrame:frame];
    _mp_host.owner = self;
    _mp_host.multipleTouchEnabled = NO;
    _mp_subviews = [NSMutableArray array];
    _frame = frame;
    return self;
}

- (NSRect)bounds { return CGRectMake(0, 0, _frame.size.width, _frame.size.height); }
- (void)setFrame:(NSRect)frame
{
    _frame = frame;
    _mp_host.frame = frame;
    [self mp_layout];
}
- (void)setFrameSize:(NSSize)size { self.frame = CGRectMake(_frame.origin.x, _frame.origin.y, size.width, size.height); }
- (void)setFrameOrigin:(NSPoint)origin { self.frame = CGRectMake(origin.x, origin.y, _frame.size.width, _frame.size.height); }
- (BOOL)isFlipped { return NO; }
- (NSArray *)subviews { return [_mp_subviews copy]; }

- (CALayer *)makeBackingLayer { return [CALayer layer]; }

// Слой из makeBackingLayer — подслой MPHostView во весь его размер.
- (void)setWantsLayer:(BOOL)wantsLayer
{
    _wantsLayer = wantsLayer;
    if (wantsLayer && !_layer) self.layer = [self makeBackingLayer];
}
- (void)setLayer:(CALayer *)layer
{
    [_layer removeFromSuperlayer];
    _layer = layer;
    if (layer) [_mp_host.layer addSublayer:layer];
    [self mp_layout];
}
- (void)mp_layout
{
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _layer.frame = _mp_host.bounds;
    _layer.contentsScale = _mp_host.window.screen.scale ?: 3;
    [CATransaction commit];
}

- (void)addSubview:(NSView *)view
{
    if ([(id)view isKindOfClass:UIView.class]) {
        UIView *ui = (UIView *)view;
        ui.frame = _mp_host.bounds;
        ui.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_mp_host addSubview:ui];
        return;
    }
    [view removeFromSuperview];
    [_mp_subviews addObject:view];
    view.superview = self;
    view.window = self.window;
    view.nextResponder = self;
    [_mp_host addSubview:view.mp_host];
}
- (void)removeFromSuperview
{
    [self.superview.mp_subviews removeObject:self];
    [_mp_host removeFromSuperview];
    self.superview = nil;
}
- (void)setNeedsDisplay:(BOOL)needs { _needsDisplay = needs; }
- (void)setNeedsLayout:(BOOL)needs { [_mp_host setNeedsLayout]; }
- (void)viewDidMoveToWindow {}
- (void)updateTrackingAreas {}
- (void)addTrackingArea:(id)area {}
- (void)removeTrackingArea:(id)area {}
- (NSArray *)trackingAreas { return @[]; }
- (void)setPostsFrameChangedNotifications:(BOOL)posts {}
- (void)setAutoresizingMask:(NSUInteger)mask {}
- (void)setTranslatesAutoresizingMaskIntoConstraints:(BOOL)value {}
- (void)setHidden:(BOOL)hidden { _mp_host.hidden = hidden; }
- (BOOL)isHidden { return _mp_host.hidden; }

// Пример и BG3 работают в координатах одного окна, где все виды без смещений: перевод — тождество.
- (NSPoint)convertPoint:(NSPoint)point fromView:(NSView *)view { return point; }
- (NSPoint)convertPoint:(NSPoint)point toView:(NSView *)view { return point; }
- (NSRect)convertRect:(NSRect)rect fromView:(NSView *)view { return rect; }
- (NSRect)convertRect:(NSRect)rect toView:(NSView *)view { return rect; }
- (CGFloat)mp_scale { return self.window ? [self.window backingScaleFactor] : NSScreen.mainScreen.backingScaleFactor; }
- (NSRect)convertRectToBacking:(NSRect)rect
{
    CGFloat s = self.mp_scale;
    return CGRectMake(rect.origin.x * s, rect.origin.y * s, rect.size.width * s, rect.size.height * s);
}
- (NSSize)convertSizeToBacking:(NSSize)size { return CGSizeMake(size.width * self.mp_scale, size.height * self.mp_scale); }
- (NSPoint)convertPointToBacking:(NSPoint)point { return CGPointMake(point.x * self.mp_scale, point.y * self.mp_scale); }
@end

#pragma mark - NSWindow

static __weak NSWindow *mp_key_window;  // последнее окно, выведенное на экран: оно же ключевое и главное

@protocol MPWindowDelegate <NSObject>
@optional
- (void)windowDidBecomeKey:(NSNotification *)notification;
@end

// Корневой контроллер окна: как у полноэкранной игры — полоска «домой» прячется, жесты у краёв экрана
// (переключение приложений, центр управления) срабатывают только со второго свайпа, без строки состояния.
@interface MPGameViewController : UIViewController
@end
@implementation MPGameViewController
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (BOOL)prefersStatusBarHidden { return YES; }
// Одна ориентация — остров камеры слева: под него разложены кнопки экранного геймпада хоста.
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscapeRight; }
@end

@implementation NSWindow {
    UIWindow *_window;
}

- (instancetype)initWithContentRect:(NSRect)rect styleMask:(NSUInteger)style backing:(NSUInteger)backing defer:(BOOL)defer
{
    if (!(self = [super init])) return nil;
    _frame = rect;
    _styleMask = style;
    mp_log(@"окно %@", NSStringFromCGRect(rect));
    return self;
}
- (instancetype)initWithContentRect:(NSRect)rect styleMask:(NSUInteger)style backing:(NSUInteger)backing
                              defer:(BOOL)defer screen:(id)screen
{
    return [self initWithContentRect:rect styleMask:style backing:backing defer:defer];
}

- (UIWindow *)mp_window
{
    if (!_window) {
        UIWindowScene *scene = mp_scene();
        _window = [[UIWindow alloc] initWithWindowScene:scene];
        _window.windowLevel = UIWindowLevelNormal + 1;
        UIViewController *controller = [MPGameViewController new];
        controller.view.backgroundColor = UIColor.blackColor;
        _window.rootViewController = controller;
        // На телефоне окно — вся безопасная область, как у полноэкранной игры; поля вокруг — чёрные.
        CGRect game = mp_game_rect();
        _frame = CGRectMake(0, 0, game.size.width, game.size.height);
    }
    return _window;
}

- (void)setContentView:(NSView *)view
{
    [_contentView.mp_host removeFromSuperview];
    _contentView = view;
    view.window = self;
    view.nextResponder = self;
    // Вид содержимого — в контейнере по безопасной области (у AppKit он всегда начинается в 0,0).
    UIView *root = self.mp_window.rootViewController.view;
    UIView *container = root.subviews.firstObject;
    if (!container) {
        container = [[UIView alloc] initWithFrame:UIEdgeInsetsInsetRect(root.bounds, mp_safe_insets())];
        container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        container.backgroundColor = UIColor.blackColor;
        [root addSubview:container];
    }
    view.frame = container.bounds;
    view.mp_host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [container addSubview:view.mp_host];
}

- (void)makeKeyAndOrderFront:(id)sender
{
    mp_key_window = self;
    [self.mp_window makeKeyAndVisible];
    [self.contentView mp_layout];
    NSNotification *key = [NSNotification notificationWithName:NSWindowDidBecomeKeyNotification object:self];
    [NSNotificationCenter.defaultCenter postNotification:key];
    id<MPWindowDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(windowDidBecomeKey:)]) [delegate windowDidBecomeKey:key];
    mp_log(@"окно на экране: %@", NSStringFromCGRect(self.mp_window.bounds));
}
- (void)orderFront:(id)sender { [self makeKeyAndOrderFront:sender]; }
- (void)orderOut:(id)sender { _window.hidden = YES; }
- (void)close
{
    [NSNotificationCenter.defaultCenter postNotificationName:NSWindowWillCloseNotification object:self];
    _window.hidden = YES;
}
- (BOOL)makeFirstResponder:(NSResponder *)responder
{
    self.firstResponder = responder;
    return YES;
}
- (BOOL)isKeyWindow { return _window.isKeyWindow; }
- (BOOL)isVisible { return _window && !_window.hidden; }
- (CGFloat)backingScaleFactor { return _window.screen.scale ?: NSScreen.mainScreen.backingScaleFactor; }
- (NSScreen *)screen { return NSScreen.mainScreen; }
- (NSRect)contentRectForFrameRect:(NSRect)rect { return rect; }
- (NSRect)frameRectForContentRect:(NSRect)rect { return rect; }
- (void)setFrame:(NSRect)frame display:(BOOL)display { self.frame = frame; }
- (void)center {}
- (void)setAcceptsMouseMovedEvents:(BOOL)accepts {}
- (void)setCollectionBehavior:(NSUInteger)behavior {}
- (void)setLevel:(NSInteger)level {}
- (void)setReleasedWhenClosed:(BOOL)released {}
- (void)setRestorable:(BOOL)restorable {}
- (void)toggleFullScreen:(id)sender {}
- (NSInteger)windowNumber { return 1; }

// Мышь — виду, которого коснулись (у BG3 это LSMTLView внутри вида содержимого), клавиши — первому ответчику.
- (void)sendEvent:(NSEvent *)event
{
    NSResponder *target = self.firstResponder ?: self.contentView;
    NSView *view = event.mp_view ?: self.contentView;
    switch (event.type) {
    case NSEventTypeLeftMouseDown: [view mouseDown:event]; break;
    case NSEventTypeLeftMouseUp: [view mouseUp:event]; break;
    case NSEventTypeLeftMouseDragged: [view mouseDragged:event]; break;
    case NSEventTypeMouseMoved: [view mouseMoved:event]; break;
    case NSEventTypeScrollWheel: [view scrollWheel:event]; break;
    case NSEventTypeKeyDown: [target keyDown:event]; break;
    case NSEventTypeKeyUp: [target keyUp:event]; break;
    default: break;
    }
}
@end

// Короткое касание картинки от экранного геймпада хоста (он забирает касания себе): щелчок в точке сцены по виду,
// который под ней в окне игры.
__attribute__((visibility("default"))) void mp_appkit_tap(double x, double y, long clicks)
{
    UIWindow *window = mp_key_window.mp_window;
    if (!window) return;
    CGPoint point = [window convertPoint:CGPointMake(x, y) fromCoordinateSpace:window.windowScene.coordinateSpace];
    UIView *hit = [window hitTest:point withEvent:nil];
    while (hit && ![hit isKindOfClass:MPHostView.class]) hit = hit.superview;
    [(MPHostView *)hit mp_tap:point clicks:clicks];
}

#pragma mark - NSApplication

// Методы делегата AppKit; имена совпадают с методами UIApplicationDelegate, но параметр — NSNotification.
@protocol MPApplicationDelegate <NSObject>
@optional
- (void)applicationWillFinishLaunching:(NSNotification *)notification;
- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (void)applicationDidBecomeActive:(NSNotification *)notification;
@end

@interface NSApplication : NSResponder
@property(nonatomic, strong) id delegate;
@property(nonatomic, readonly, getter=isRunning) BOOL running;
@end

@implementation NSApplication {
    NSMutableArray<NSEvent *> *_queue;
    BOOL _launched;
    BOOL _active;
}

+ (instancetype)sharedApplication
{
    if (!NSApp) {
        NSApp = [[self alloc] init];
        mp_log(@"NSApp — %@", NSStringFromClass([NSApp class]));
    }
    return NSApp;
}

- (instancetype)init
{
    if (!(self = [super init])) return nil;
    _queue = [NSMutableArray array];
    return self;
}

- (BOOL)setActivationPolicy:(NSInteger)policy { return YES; }
- (void)activateIgnoringOtherApps:(BOOL)flag {}
- (void)activate {}
- (BOOL)isActive { return YES; }
- (void)setMainMenu:(id)menu {}
- (id)mainMenu { return nil; }
- (void)setPresentationOptions:(NSUInteger)options {}
- (NSUInteger)presentationOptions { return 0; }
- (void)hide:(id)sender {}
- (void)unhide:(id)sender {}

- (void)finishLaunching
{
    if (_launched) return;
    _launched = YES;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center postNotificationName:NSApplicationWillFinishLaunchingNotification object:self];
    id<MPApplicationDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(applicationWillFinishLaunching:)])
        [delegate applicationWillFinishLaunching:[NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification object:self]];
    NSNotification *did = [NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:self];
    [center postNotification:did];
    if ([delegate respondsToSelector:@selector(applicationDidFinishLaunching:)])
        [delegate applicationDidFinishLaunching:did];
    mp_log(@"запуск приложения завершён");
}

// Вложенный главный run loop: UIKit и главная очередь работают, пока крутится приложение.
- (void)run
{
    [self finishLaunching];
    _running = YES;
    mp_log(@"run: главный цикл");
    while (_running) {
        @autoreleasepool {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, true);
        }
    }
    mp_log(@"run: цикл окончен");
}
- (void)stop:(id)sender { _running = NO; }
- (void)terminate:(id)sender
{
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationWillTerminateNotification object:self];
    _running = NO;
}

// Игры часто сами выбирают события в своём цикле: прогоняем run loop до срока, отдаём событие из очереди.
- (NSEvent *)nextEventMatchingMask:(unsigned long long)mask untilDate:(NSDate *)date inMode:(NSString *)mode
                           dequeue:(BOOL)dequeue
{
    [self finishLaunching];
    if (!_active) {
        _active = YES;
        NSNotification *active = [NSNotification notificationWithName:NSApplicationDidBecomeActiveNotification object:self];
        [NSNotificationCenter.defaultCenter postNotification:active];
        if ([self.delegate respondsToSelector:@selector(applicationDidBecomeActive:)])
            [(id<MPApplicationDelegate>)self.delegate applicationDidBecomeActive:active];
        mp_log(@"приложение активно");
        // Отладка без человека у телефона: -MPAutoClick N (аргумент запуска → NSUserDefaults) — через N секунд
        // нажатие в центр окна (например, «Нажмите любую клавишу» на заставке).
        NSInteger autoClick = [NSUserDefaults.standardUserDefaults integerForKey:@"MPAutoClick"];
        if (autoClick > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, autoClick * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                NSWindow *window = mp_key_window;
                NSView *view = window.contentView;
                NSView *target = view.mp_subviews.lastObject ?: view;
                CGPoint center = CGPointMake(view.frame.size.width / 2, view.frame.size.height / 2);
                mp_log(@"автоклик %.0f,%.0f → %@", center.x, center.y, NSStringFromClass(target.class));
                NSArray *types = @[ @(NSEventTypeMouseMoved), @(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp) ];
                for (NSUInteger i = 0; i < types.count; i++) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)i * 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                        NSEvent *event = [NSEvent new];
                        event.type = [types[i] unsignedIntegerValue];
                        event.locationInWindow = center;
                        event.window = window;
                        event.clickCount = 1;
                        event.mp_view = target;
                        [window sendEvent:event];
                    });
                }
            });
        }
    }
    NSTimeInterval wait = date ? MAX(0, date.timeIntervalSinceNow) : 0;
    // Цикл событий iOS: касания, обновления экранного геймпада (его обработчики идут в главную очередь), таймеры.
    // Игра зовёт этот метод раз в кадр, пока он не вернёт nil, — если за вызов разбирать один источник, при 20–40
    // кадрах в секунду касания и геймпад копятся в очереди (стик «залипает»). Без ожидания — разбираем все готовые
    // источники (до 64 за вызов), с ожиданием — ждём первого, как AppKit.
    if (!_queue.count) {
        if (wait > 0) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, wait, true);
        } else {
            for (int i = 0; i < 64 && !_queue.count; i++)
                if (CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true) != kCFRunLoopRunHandledSource) break;
        }
    }
    NSEvent *event = _queue.firstObject;
    if (event && dequeue) [_queue removeObjectAtIndex:0];
    return event;
}
- (void)postEvent:(NSEvent *)event atStart:(BOOL)atStart
{
    if (atStart) [_queue insertObject:event atIndex:0];
    else [_queue addObject:event];
}
- (void)sendEvent:(NSEvent *)event { [event.window sendEvent:event]; }
- (void)updateWindows {}
- (NSArray *)windows { return mp_key_window ? @[ mp_key_window ] : @[]; }
- (NSWindow *)keyWindow { return mp_key_window; }
- (NSWindow *)mainWindow { return mp_key_window; }
@end

// Скомпилированный nib (формат NIBArchive): «NIBArchive», две версии, затем число и смещение таблиц объектов,
// ключей, значений и классов (u32). Числа внутри таблиц — varint, старший бит отмечает последний байт.
// Объект: класс, первое значение, число значений. Ключ: длина, байты. Значение: ключ, тип, данные
// (0–3 — целые 1/2/4/8 байт, 4/5 — false/true, 6/7 — float/double, 8 — длина и байты, 9 — nil,
// 10 — ссылка на объект, u32). Класс: длина с NUL, число доп. u32, они, имя.
typedef struct {
    const uint8_t *b;
    NSUInteger n, at;
} MPNibReader;

static uint64_t mp_varint(MPNibReader *r)
{
    uint64_t v = 0;
    for (int shift = 0; r->at < r->n && shift < 64; shift += 7) {
        uint8_t c = r->b[r->at++];
        v |= (uint64_t)(c & 0x7f) << shift;
        if (c & 0x80) break;
    }
    return v;
}

// Классы, которые nib создаёт сам: NSCustomObject с NSClassName (делегат приложения и т. п.).
static NSArray<NSString *> *mp_nib_custom_classes(NSData *data)
{
    MPNibReader r = {data.bytes, data.length, 0};
    if (r.n < 50 || memcmp(r.b, "NIBArchive", 10)) return @[];
    uint32_t t[8];
    memcpy(t, r.b + 18, sizeof t);
    uint32_t objectCount = t[0], keyCount = t[2], valueCount = t[4], classCount = t[6];

    NSMutableArray<NSString *> *classes = [NSMutableArray array];
    r.at = t[7];
    for (uint32_t i = 0; i < classCount && r.at < r.n; i++) {
        uint64_t len = mp_varint(&r), extra = mp_varint(&r);
        r.at += extra * 4;
        if (!len || r.at + len > r.n) return @[];
        [classes addObject:[[NSString alloc] initWithBytes:r.b + r.at length:len - 1 encoding:NSUTF8StringEncoding] ?: @""];
        r.at += len;
    }
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    r.at = t[3];
    for (uint32_t i = 0; i < keyCount && r.at < r.n; i++) {
        uint64_t len = mp_varint(&r);
        if (r.at + len > r.n) return @[];
        [keys addObject:[[NSString alloc] initWithBytes:r.b + r.at length:len encoding:NSUTF8StringEncoding] ?: @""];
        r.at += len;
    }
    // Значения: ключ, тип и полезное — ссылка на объект или данные.
    NSMutableArray<NSString *> *valueKeys = [NSMutableArray array];
    NSMutableArray *valueData = [NSMutableArray array];  // NSNumber (ссылка), NSData или NSNull
    static const int sizes[] = {1, 2, 4, 8, 0, 0, 4, 8};
    r.at = t[5];
    for (uint32_t i = 0; i < valueCount && r.at < r.n; i++) {
        uint64_t key = mp_varint(&r);
        uint8_t type = r.b[r.at++];
        id payload = NSNull.null;
        if (type < 8) {
            r.at += sizes[type];
        } else if (type == 8) {
            uint64_t len = mp_varint(&r);
            if (r.at + len > r.n) return @[];
            payload = [NSData dataWithBytes:r.b + r.at length:len];
            r.at += len;
        } else if (type == 10) {
            uint32_t ref;
            memcpy(&ref, r.b + r.at, 4);
            r.at += 4;
            payload = @(ref);
        } else if (type != 9) {
            return @[];
        }
        [valueKeys addObject:key < keys.count ? keys[key] : @""];
        [valueData addObject:payload];
    }
    // Объекты: класс и диапазон значений.
    NSMutableArray<NSValue *> *objects = [NSMutableArray array];  // {класс, первое значение, число}
    NSMutableArray<NSString *> *objectClasses = [NSMutableArray array];
    r.at = t[1];
    for (uint32_t i = 0; i < objectCount && r.at < r.n; i++) {
        uint64_t cls = mp_varint(&r), first = mp_varint(&r), count = mp_varint(&r);
        [objectClasses addObject:cls < classes.count ? classes[cls] : @""];
        [objects addObject:[NSValue valueWithRange:NSMakeRange(first, count)]];
    }
    id (^value)(NSUInteger, NSString *) = ^id(NSUInteger object, NSString *key) {
        if (object >= objects.count) return nil;
        NSRange range = objects[object].rangeValue;
        for (NSUInteger v = range.location; v < NSMaxRange(range) && v < valueKeys.count; v++)
            if ([valueKeys[v] isEqualToString:key]) return valueData[v];
        return nil;
    };
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSUInteger i = 0; i < objects.count; i++) {
        if (![objectClasses[i] isEqualToString:@"NSCustomObject"]) continue;
        id ref = value(i, @"NSClassName");
        if (![ref isKindOfClass:NSNumber.class]) continue;
        id bytes = value([ref unsignedIntegerValue], @"NS.bytes");
        if (![bytes isKindOfClass:NSData.class]) continue;
        NSString *name = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
        if (name.length && ![names containsObject:name]) [names addObject:name];
    }
    return names;
}

static NSMutableArray *mp_nib_objects;  // объекты главного nib живут всё время, как в AppKit

// NSApplicationMain: класс приложения — NSPrincipalClass из Info.plist; из главного nib (NSMainNibFile)
// создаются его NSCustomObject (кроме File's Owner и прочих NS…), и тот, что отвечает на
// applicationDidFinishLaunching:, — делегат.
int NSApplicationMain(int argc, const char *argv[])
{
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *name = info[@"NSPrincipalClass"];
    Class cls = name ? NSClassFromString(name) : Nil;
    if (!cls) cls = NSApplication.class;
    mp_log(@"NSApplicationMain: %@ (NSPrincipalClass %@)", NSStringFromClass(cls), name);
    NSApplication *app = [cls sharedApplication];
    NSString *nib = info[@"NSMainNibFile"];
    NSString *path = nib ? [NSBundle.mainBundle pathForResource:nib ofType:@"nib"] : nil;
    NSArray *classes = path ? mp_nib_custom_classes([NSData dataWithContentsOfFile:path]) : @[];
    mp_log(@"главный nib %@: %@", path.lastPathComponent, [classes componentsJoinedByString:@", "]);
    mp_nib_objects = [NSMutableArray array];
    for (NSString *className in classes) {
        Class c = NSClassFromString(className);
        if (!c || [className hasPrefix:@"NS"]) continue;
        id object = [c new];
        [mp_nib_objects addObject:object];
        if (!app.delegate && [object respondsToSelector:@selector(applicationDidFinishLaunching:)]) {
            app.delegate = object;
            mp_log(@"делегат приложения — %@", className);
        }
    }
    [NSApp run];
    return 0;
}

#pragma mark - Сравнения NSObject

// NSComparisonMethods (NSScriptWhoseTests.h) есть только в Foundation macOS.
@implementation NSObject (MPComparisonMethods)
- (BOOL)isEqualTo:(id)object { return [self isEqual:object]; }
- (BOOL)isNotEqualTo:(id)object { return ![self isEqual:object]; }
- (NSComparisonResult)mp_compare:(id)object
{
    return [self respondsToSelector:@selector(compare:)] ? ((NSComparisonResult(*)(id, SEL, id))objc_msgSend)(self, @selector(compare:), object)
                                                         : NSOrderedSame;
}
- (BOOL)isLessThan:(id)object { return [self mp_compare:object] == NSOrderedAscending; }
- (BOOL)isLessThanOrEqualTo:(id)object { return [self mp_compare:object] != NSOrderedDescending; }
- (BOOL)isGreaterThan:(id)object { return [self mp_compare:object] == NSOrderedDescending; }
- (BOOL)isGreaterThanOrEqualTo:(id)object { return [self mp_compare:object] != NSOrderedAscending; }
@end

#pragma mark - Обход папок без /private

// На iOS контейнер приложения — /var/mobile/…, а это ссылка на /private/var/mobile/…; NSDirectoryEnumerator
// возвращает адреса с /private. Движок BG3 (ls::mac::FileSystem::CollectFiles/CollectDirectories) строит
// относительные пути, отрезая от найденных адресов столько компонентов, сколько их в исходном пути, — на
// macOS (/Users/…, без ссылок) они совпадают, а здесь сдвигаются на один, и сохранения в список не попадают.
// Сверка url с URLByResolvingSymlinksInPath разницы не видит: iOS при этом /private отрезает. Поэтому обход,
// начатый не с /private, возвращает адреса тоже без /private — как на macOS.
@interface MPPathEnumerator : NSEnumerator
@property(nonatomic, strong) NSDirectoryEnumerator *inner;
@end
@implementation MPPathEnumerator
- (id)nextObject
{
    NSURL *url = [self.inner nextObject];
    if ([url isKindOfClass:NSURL.class] && [url.path hasPrefix:@"/private/var/"]) {
        NSNumber *directory = nil;
        [url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
        url = [NSURL fileURLWithPath:[url.path substringFromIndex:strlen("/private")] isDirectory:directory.boolValue];
    }
    return url;
}
- (NSUInteger)level { return self.inner.level; }
- (void)skipDescendants { [self.inner skipDescendants]; }
- (void)skipDescendents { [self.inner skipDescendants]; }
- (NSDictionary *)fileAttributes { return self.inner.fileAttributes; }
- (NSDictionary *)directoryAttributes { return self.inner.directoryAttributes; }
- (BOOL)isEnumeratingDirectoryPostOrder { return self.inner.isEnumeratingDirectoryPostOrder; }
@end

static id (*mp_orig_enumerator)(id, SEL, NSURL *, NSArray *, NSUInteger, id);
static id mp_enumerator(id self, SEL _cmd, NSURL *url, NSArray *keys, NSUInteger options, id handler)
{
    NSDirectoryEnumerator *inner = mp_orig_enumerator(self, _cmd, url, keys, options, handler);
    if (!inner || [url.path hasPrefix:@"/private/"] || ![url.path hasPrefix:@"/var/"]) return inner;
    MPPathEnumerator *wrapper = [MPPathEnumerator new];
    wrapper.inner = inner;
    return wrapper;
}

__attribute__((constructor)) static void mp_enumerator_hook(void)
{
    Method m = class_getInstanceMethod(NSFileManager.class, @selector(enumeratorAtURL:includingPropertiesForKeys:options:errorHandler:));
    mp_orig_enumerator = (void *)method_setImplementation(m, (IMP)mp_enumerator);
}

#pragma mark - NSTask

// Запустить процесс на iOS нельзя (и в /usr/bin нет программ macOS): -[NSConcreteTask launch] ничего не
// запускает, а пишет в standardOutput заготовленный ответ и считается завершённым с кодом 0.
// BG3 спрашивает `hdiutil info -plist` — не запущена ли игра с образа диска.
static NSData *mp_task_output(NSString *path, NSArray *arguments)
{
    if ([path.lastPathComponent isEqualToString:@"hdiutil"])
        return [NSPropertyListSerialization dataWithPropertyList:@{@"images" : @[]}
                                                          format:NSPropertyListXMLFormat_v1_0
                                                         options:0
                                                           error:nil];
    return [NSData data];
}

static id mp_send(id object, const char *selector)
{
    return ((id(*)(id, SEL))objc_msgSend)(object, sel_registerName(selector));
}

static void mp_task_launch(id task, SEL _cmd)
{
    NSString *path = mp_send(task, "launchPath") ?: [mp_send(task, "executableURL") path];
    NSArray *arguments = mp_send(task, "arguments");
    mp_log(@"NSTask: %@ %@ — не запускается, ответ заготовлен", path, [arguments componentsJoinedByString:@" "]);
    id output = mp_send(task, "standardOutput");
    NSFileHandle *handle = [output isKindOfClass:NSPipe.class] ? [output fileHandleForWriting]
                         : [output isKindOfClass:NSFileHandle.class] ? output : nil;
    NSData *data = mp_task_output(path, arguments);
    if (handle && data.length) [handle writeData:data];
    if ([output isKindOfClass:NSPipe.class]) [handle closeFile];
}
static BOOL mp_task_launch_error(id task, SEL _cmd, NSError **error)
{
    mp_task_launch(task, _cmd);
    return YES;
}
static void mp_task_wait(id task, SEL _cmd) {}
static int mp_task_status(id task, SEL _cmd) { return 0; }
static NSInteger mp_task_reason(id task, SEL _cmd) { return 1; }  // NSTaskTerminationReasonExit
static BOOL mp_task_running(id task, SEL _cmd) { return NO; }

__attribute__((constructor)) static void mp_task_init(void)
{
    Class task = NSClassFromString(@"NSConcreteTask") ?: NSClassFromString(@"NSTask");
    if (!task) return;
    class_replaceMethod(task, @selector(launch), (IMP)mp_task_launch, "v@:");
    class_replaceMethod(task, sel_registerName("launchAndReturnError:"), (IMP)mp_task_launch_error, "B@:^@");
    class_replaceMethod(task, sel_registerName("waitUntilExit"), (IMP)mp_task_wait, "v@:");
    class_replaceMethod(task, sel_registerName("terminationStatus"), (IMP)mp_task_status, "i@:");
    class_replaceMethod(task, sel_registerName("terminationReason"), (IMP)mp_task_reason, "q@:");
    class_replaceMethod(task, sel_registerName("isRunning"), (IMP)mp_task_running, "B@:");
}

#pragma mark - Остальное, что использует BG3

NSString *const NSImageNameStatusAvailable = @"NSStatusAvailable";
NSString *const NSImageNameStatusUnavailable = @"NSStatusUnavailable";
NSString *const NSPasteboardTypeString = @"public.utf8-plain-text";
NSString *const NSStringPboardType = @"NSStringPboardType";

// Модальные окна AppKit: в журнал и «первая кнопка».
NSInteger NSRunCriticalAlertPanel(NSString *title, NSString *format, NSString *defaultButton, NSString *alternate,
                                  NSString *other, ...)
{
    mp_log(@"NSRunCriticalAlertPanel: %@ — %@", title, format);
    return 1;
}
NSInteger NSRunInformationalAlertPanel(NSString *title, NSString *format, NSString *defaultButton,
                                       NSString *alternate, NSString *other, ...)
{
    mp_log(@"NSRunInformationalAlertPanel: %@ — %@", title, format);
    return 1;
}

@interface NSControl : NSView
@property(nonatomic, copy) NSString *stringValue;
@property(nonatomic, weak) id target;
@property(nonatomic) SEL action;
@property(nonatomic, getter=isEnabled) BOOL enabled;
@end
@implementation NSControl
@end

@interface NSButton : NSControl
@property(nonatomic, copy) NSString *title;
@property(nonatomic) NSInteger state;
@end
@implementation NSButton
@end

@interface NSTextField : NSControl
@end
@implementation NSTextField
@end

@interface NSImageView : NSControl
@property(nonatomic, strong) id image;
@end
@implementation NSImageView
@end

@interface NSScrollView : NSView
@property(nonatomic, strong) NSView *documentView;
@end
@implementation NSScrollView
@end

@interface NSTextView : NSView
@property(nonatomic, copy) NSString *string;
@end
@implementation NSTextView
@end

@interface NSViewController : NSResponder
@property(nonatomic, strong) NSView *view;
@end
@implementation NSViewController
- (instancetype)initWithNibName:(NSString *)nib bundle:(NSBundle *)bundle
{
    mp_log(@"NSViewController %@: nib %@ не загружается", NSStringFromClass(self.class), nib);
    return [super init];
}
- (NSView *)view
{
    if (!_view) {
        [self loadView];
        [self viewDidLoad];
    }
    return _view;
}
- (void)loadView { if (!_view) _view = [[NSView alloc] initWithFrame:NSScreen.mainScreen.frame]; }
- (void)viewDidLoad {}
@end

@interface NSImage : NSObject
@property(nonatomic, strong) UIImage *mp_image;
@end
@implementation NSImage
MP_FORWARDING
+ (instancetype)imageNamed:(NSString *)name
{
    NSImage *image = [NSImage new];
    image.mp_image = [UIImage imageNamed:name inBundle:NSBundle.mainBundle compatibleWithTraitCollection:nil];
    return image.mp_image ? image : nil;
}
- (instancetype)initWithContentsOfFile:(NSString *)path
{
    if (!(self = [super init])) return nil;
    _mp_image = [UIImage imageWithContentsOfFile:path];
    return _mp_image ? self : nil;
}
- (NSSize)size { return _mp_image.size; }
@end

@interface NSCursor : NSObject
@end
@implementation NSCursor
MP_FORWARDING
+ (instancetype)arrowCursor { return [self new]; }
+ (void)hide {}
+ (void)unhide {}
+ (void)setHiddenUntilMouseMoves:(BOOL)flag {}
- (void)set {}
@end

@interface NSPasteboard : NSObject
@end
@implementation NSPasteboard
MP_FORWARDING
+ (instancetype)generalPasteboard { return [self new]; }
- (NSInteger)clearContents { UIPasteboard.generalPasteboard.string = @""; return 1; }
- (BOOL)setString:(NSString *)string forType:(NSString *)type { UIPasteboard.generalPasteboard.string = string; return YES; }
- (NSString *)stringForType:(NSString *)type { return UIPasteboard.generalPasteboard.string; }
@end

@interface NSWorkspaceOpenConfiguration : NSObject
@end
@implementation NSWorkspaceOpenConfiguration
MP_FORWARDING
+ (instancetype)configuration { return [self new]; }
@end

@interface NSWorkspace : NSObject
@end
@implementation NSWorkspace
MP_FORWARDING
+ (instancetype)sharedWorkspace { return [self new]; }
- (NSNotificationCenter *)notificationCenter { return NSNotificationCenter.defaultCenter; }
- (BOOL)openURL:(NSURL *)url
{
    dispatch_async(dispatch_get_main_queue(), ^{ [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil]; });
    return YES;
}
@end

@interface NSNib : NSObject
@end
@implementation NSNib
MP_FORWARDING
- (instancetype)initWithNibNamed:(NSString *)name bundle:(NSBundle *)bundle
{
    mp_log(@"NSNib %@: не загружается", name);
    return [super init];
}
- (BOOL)instantiateWithOwner:(id)owner topLevelObjects:(NSArray **)objects
{
    if (objects) *objects = @[];
    return NO;
}
@end

@interface NSGraphicsContext : NSObject
@end
@implementation NSGraphicsContext
MP_FORWARDING
+ (instancetype)currentContext { return nil; }
@end

@interface NSAnimationContext : NSObject
@property(nonatomic) NSTimeInterval duration;
@end
@implementation NSAnimationContext
MP_FORWARDING
+ (instancetype)currentContext { return [self new]; }
+ (void)beginGrouping {}
+ (void)endGrouping {}
+ (void)runAnimationGroup:(void (^)(NSAnimationContext *))changes completionHandler:(void (^)(void))done
{
    if (changes) changes([self new]);
    if (done) done();
}
@end

@interface NSTrackingArea : NSObject
@end
@implementation NSTrackingArea
MP_FORWARDING
- (instancetype)initWithRect:(NSRect)rect options:(NSUInteger)options owner:(id)owner userInfo:(NSDictionary *)info
{
    return [super init];
}
@end
