// MPCoreGraphics: настоящий CoreGraphics iOS (реэкспорт) плюс функции дисплея, курсора и событий
// macOS, которых в iOS нет. Один дисплей (id 1) с одним режимом — экран телефона; гамма, затемнение,
// курсор и события — заглушки. Режимы и события — ObjC-объекты, так что CFRelease на них работает.
// Заголовки CoreGraphics целиком не подключаются: в iOS эти функции объявлены недоступными.

#import <CoreGraphics/CGGeometry.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef uint32_t CGDirectDisplayID;

typedef uint32_t CGDisplayFadeReservationToken;
typedef void *CGDisplayModeRef;
typedef void *CGEventRef;
typedef int32_t CGWindowLevel;

static void mp_log(const char *what) { fprintf(stderr, "MPCoreGraphics: %s\n", what); }

@interface MPDisplayMode : NSObject
@property(nonatomic) size_t width, height;
@property(nonatomic) double rate;
@end
@implementation MPDisplayMode
@end

@interface MPEvent : NSObject
@end
@implementation MPEvent
@end

// Режимы экрана — ступени родного разрешения с тем же соотношением сторон: из них игра строит список
// «Разрешение». Родное — размер окна игры в пикселях: его сообщает NSScreen из MPAppKit (безопасная область,
// по краям чёрные поля). Режим с другими пропорциями игра растянула бы на окно — картинка сжималась.
// Считается при каждом запросе: поля становятся известны не сразу.
static NSArray<MPDisplayMode *> *mp_modes(void)
{
    UIScreen *screen = UIScreen.mainScreen;
    id appScreen = [NSClassFromString(@"NSScreen") valueForKey:@"mainScreen"];
    CGRect frame = appScreen ? [[appScreen valueForKey:@"frame"] CGRectValue] : screen.bounds;
    double width = MAX(frame.size.width, frame.size.height) * screen.scale;
    double height = MIN(frame.size.width, frame.size.height) * screen.scale;
    NSMutableArray *list = [NSMutableArray array];
    for (NSNumber *scale in @[ @1.0, @(5.0 / 6), @0.75, @(2.0 / 3), @(7.0 / 12), @0.5, @(5.0 / 12) ]) {
        MPDisplayMode *mode = [MPDisplayMode new];
        mode.width = (size_t)round(width * scale.doubleValue / 2) * 2;
        mode.height = (size_t)round(height * scale.doubleValue / 2) * 2;
        mode.rate = screen.maximumFramesPerSecond ?: 60;
        [list addObject:mode];
    }
    return list;
}
static MPDisplayMode *mp_current;

// Текущий режим: выбранный, если он из нынешнего списка (по размеру), иначе родной.
static MPDisplayMode *mp_mode(void)
{
    NSArray<MPDisplayMode *> *modes = mp_modes();
    for (MPDisplayMode *mode in modes)
        if (mp_current && mode.width == mp_current.width && mode.height == mp_current.height) return mode;
    return modes.firstObject;
}

CGDirectDisplayID CGMainDisplayID(void) { return 1; }

CFArrayRef CGDisplayCopyAllDisplayModes(CGDirectDisplayID display, CFDictionaryRef options)
{
    return (__bridge_retained CFArrayRef)[mp_modes() copy];
}
CGDisplayModeRef CGDisplayCopyDisplayMode(CGDirectDisplayID display) { return (__bridge_retained void *)mp_mode(); }
size_t CGDisplayModeGetWidth(CGDisplayModeRef mode) { return mode ? ((__bridge MPDisplayMode *)mode).width : 0; }
size_t CGDisplayModeGetHeight(CGDisplayModeRef mode) { return mode ? ((__bridge MPDisplayMode *)mode).height : 0; }
double CGDisplayModeGetRefreshRate(CGDisplayModeRef mode) { return mode ? ((__bridge MPDisplayMode *)mode).rate : 0; }
uint32_t CGDisplayModeGetIOFlags(CGDisplayModeRef mode) { return 0x3; }  // kDisplayModeValidFlag | SafeFlag
bool CGDisplayModeIsUsableForDesktopGUI(CGDisplayModeRef mode) { return true; }
CGDisplayModeRef CGDisplayModeRetain(CGDisplayModeRef mode) { return mode ? (void *)CFRetain(mode) : NULL; }
void CGDisplayModeRelease(CGDisplayModeRef mode) { if (mode) CFRelease(mode); }
CGError CGDisplaySetDisplayMode(CGDirectDisplayID display, CGDisplayModeRef mode, CFDictionaryRef options)
{
    MPDisplayMode *m = (__bridge MPDisplayMode *)mode;
    if ([m isKindOfClass:MPDisplayMode.class]) {
        mp_current = m;
        fprintf(stderr, "MPCoreGraphics: режим экрана %zux%zu\n", m.width, m.height);
    }
    return 0;
}

CGError CGAcquireDisplayFadeReservation(float seconds, CGDisplayFadeReservationToken *token)
{
    if (token) *token = 1;
    return 0;
}
CGError CGReleaseDisplayFadeReservation(CGDisplayFadeReservationToken token) { return 0; }
CGError CGDisplayFade(CGDisplayFadeReservationToken token, float duration, float start, float end, float r, float g,
                      float b, uint32_t synchronous)
{
    return 0;
}

CGError CGGetDisplayTransferByFormula(CGDirectDisplayID display, float *redMin, float *redMax, float *redGamma,
                                      float *greenMin, float *greenMax, float *greenGamma, float *blueMin,
                                      float *blueMax, float *blueGamma)
{
    *redMin = *greenMin = *blueMin = 0;
    *redMax = *greenMax = *blueMax = 1;
    *redGamma = *greenGamma = *blueGamma = 1;
    return 0;
}
CGError CGSetDisplayTransferByFormula(CGDirectDisplayID display, float redMin, float redMax, float redGamma,
                                      float greenMin, float greenMax, float greenGamma, float blueMin,
                                      float blueMax, float blueGamma)
{
    return 0;
}

CGWindowLevel CGShieldingWindowLevel(void) { return 2147483630; }
CFArrayRef CGWindowListCopyWindowInfo(uint32_t option, uint32_t relativeToWindow)
{
    return (__bridge_retained CFArrayRef) @[];
}

// Курсор и события мыши: на телефоне курсора нет.
static CGPoint mp_cursor;
CGError CGWarpMouseCursorPosition(CGPoint point)
{
    mp_cursor = point;
    return 0;
}
CGError CGDisplayMoveCursorToPoint(CGDirectDisplayID display, CGPoint point)
{
    mp_cursor = point;
    return 0;
}
CGEventRef CGEventCreate(void *source) { return (__bridge_retained void *)[MPEvent new]; }
CGEventRef CGEventCreateMouseEvent(void *source, uint32_t type, CGPoint position, uint32_t button)
{
    return (__bridge_retained void *)[MPEvent new];
}
CGPoint CGEventGetLocation(CGEventRef event) { return mp_cursor; }
void CGEventPost(uint32_t tap, CGEventRef event) {}
uint64_t CGEventSourceFlagsState(int32_t state) { return 0; }

const CFStringRef kCGDisplayShowDuplicateLowResolutionModes = CFSTR("kCGDisplayShowDuplicateLowResolutionModes");
const CFStringRef kCGWindowOwnerName = CFSTR("kCGWindowOwnerName");

__attribute__((constructor)) static void mp_init(void) { mp_log("загружен"); }
