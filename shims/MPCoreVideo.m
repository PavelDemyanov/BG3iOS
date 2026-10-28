// MPCoreVideo: настоящий CoreVideo iOS (реэкспорт) плюс CVDisplayLink, которого в iOS нет.
// CVDisplayLink macOS зовёт колбэк на своём потоке на каждый кадр дисплея; здесь — CADisplayLink
// на отдельном потоке со своим run loop. Ссылка — ObjC-объект, так что CFRetain/CFRelease на ней работают.

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

typedef uint32_t CGDirectDisplayID;

@class MPDisplayLink;
typedef void *CVDisplayLinkRef;
typedef CVReturn (*CVDisplayLinkOutputCallback)(CVDisplayLinkRef, const CVTimeStamp *, const CVTimeStamp *,
                                                CVOptionFlags, CVOptionFlags *, void *);

@interface MPDisplayLink : NSObject
@property(nonatomic) CVDisplayLinkOutputCallback callback;
@property(nonatomic) void *context;
@property(atomic) BOOL running;
@property(nonatomic) CADisplayLink *link;
@property(nonatomic) NSThread *thread;
@property(nonatomic) int64_t frames;
@end

@implementation MPDisplayLink
- (void)tick:(CADisplayLink *)link
{
    if (!self.running || !self.callback) return;
    int32_t rate = (int32_t)(UIScreen.mainScreen.maximumFramesPerSecond ?: 60);
    CVTimeStamp now = {0}, output = {0};
    now.videoTimeScale = output.videoTimeScale = rate;
    now.videoRefreshPeriod = output.videoRefreshPeriod = 1;
    now.videoTime = self.frames;
    output.videoTime = ++self.frames;
    now.hostTime = output.hostTime = mach_absolute_time();
    now.rateScalar = output.rateScalar = 1.0;
    now.flags = output.flags = 3;  // kCVTimeStampVideoTimeValid | kCVTimeStampHostTimeValid
    CVOptionFlags out = 0;
    self.callback((__bridge CVDisplayLinkRef)self, &now, &output, 0, &out, self.context);
}
- (void)threadMain
{
    @autoreleasepool {
        self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        [self.link addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
        while (self.running) {
            @autoreleasepool { [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.5]]; }
        }
        [self.link invalidate];
        self.link = nil;
    }
}
@end

static MPDisplayLink *mp_link(CVDisplayLinkRef ref) { return (__bridge MPDisplayLink *)ref; }

CVReturn CVDisplayLinkCreateWithActiveCGDisplays(CVDisplayLinkRef *out)
{
    *out = (__bridge_retained CVDisplayLinkRef)[MPDisplayLink new];
    return kCVReturnSuccess;
}
CVReturn CVDisplayLinkCreateWithCGDisplay(CGDirectDisplayID display, CVDisplayLinkRef *out)
{
    return CVDisplayLinkCreateWithActiveCGDisplays(out);
}
CVReturn CVDisplayLinkCreateWithCGDisplays(CGDirectDisplayID *displays, long count, CVDisplayLinkRef *out)
{
    return CVDisplayLinkCreateWithActiveCGDisplays(out);
}
CVReturn CVDisplayLinkSetOutputCallback(CVDisplayLinkRef ref, CVDisplayLinkOutputCallback callback, void *context)
{
    mp_link(ref).callback = callback;
    mp_link(ref).context = context;
    return kCVReturnSuccess;
}
CVReturn CVDisplayLinkStart(CVDisplayLinkRef ref)
{
    MPDisplayLink *link = mp_link(ref);
    if (link.running) return kCVReturnSuccess;
    link.running = YES;
    link.thread = [[NSThread alloc] initWithTarget:link selector:@selector(threadMain) object:nil];
    link.thread.qualityOfService = NSQualityOfServiceUserInteractive;
    link.thread.name = @"CVDisplayLink";
    [link.thread start];
    return kCVReturnSuccess;
}
CVReturn CVDisplayLinkStop(CVDisplayLinkRef ref)
{
    mp_link(ref).running = NO;
    return kCVReturnSuccess;
}
int CVDisplayLinkIsRunning(CVDisplayLinkRef ref) { return mp_link(ref).running; }
CVDisplayLinkRef CVDisplayLinkRetain(CVDisplayLinkRef ref) { return ref ? (void *)CFRetain(ref) : NULL; }
void CVDisplayLinkRelease(CVDisplayLinkRef ref)
{
    if (!ref) return;
    mp_link(ref).running = NO;
    CFRelease(ref);
}
CVTime CVDisplayLinkGetNominalOutputVideoRefreshPeriod(CVDisplayLinkRef ref)
{
    int32_t rate = (int32_t)(UIScreen.mainScreen.maximumFramesPerSecond ?: 60);
    return (CVTime){1, rate, 0};
}
double CVDisplayLinkGetActualOutputVideoRefreshPeriod(CVDisplayLinkRef ref)
{
    return 1.0 / (UIScreen.mainScreen.maximumFramesPerSecond ?: 60);
}
CVReturn CVDisplayLinkSetCurrentCGDisplay(CVDisplayLinkRef ref, CGDirectDisplayID display) { return kCVReturnSuccess; }
CGDirectDisplayID CVDisplayLinkGetCurrentCGDisplay(CVDisplayLinkRef ref) { return 1; }
