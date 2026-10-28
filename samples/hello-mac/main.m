// hello-mac: маленькая Mac-программа, устроенная как BG3 — NSApplication с делегатом,
// NSWindow, свой подкласс NSView с CAMetalLayer (makeBackingLayer), кадры от CVDisplayLink,
// шейдеры из отдельного metallib рядом с программой. На ней проверяется цепочка
// «Mac-бинарник → iOS»: конвертер, заменители, загрузка в MacportLab.

#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

static void say(NSString *line) { fprintf(stderr, "hello-mac: %s\n", line.UTF8String); }

@interface MetalView : NSView
@property(nonatomic) id<MTLDevice> device;
@property(nonatomic) id<MTLCommandQueue> queue;
@property(nonatomic) id<MTLRenderPipelineState> pipeline;
@property(nonatomic) NSUInteger frames;
@end

@implementation MetalView {
    CVDisplayLinkRef _link;
}

- (CALayer *)makeBackingLayer
{
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = self.device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    return layer;
}

- (instancetype)initWithFrame:(NSRect)frame
{
    if (!(self = [super initWithFrame:frame])) return nil;
    _device = MTLCreateSystemDefaultDevice();
    _queue = [_device newCommandQueue];
    self.wantsLayer = YES;

    // Шейдеры — из файла рядом с программой, как у игры.
    NSString *dir = [[NSBundle mainBundle] resourcePath] ?: @".";
    NSString *path = [dir stringByAppendingPathComponent:@"hello.metallib"];
    NSError *error = nil;
    id<MTLLibrary> library = [_device newLibraryWithURL:[NSURL fileURLWithPath:path] error:&error];
    if (!library) {
        say([NSString stringWithFormat:@"metallib %@ не загружен: %@", path, error]);
    } else {
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [library newFunctionWithName:@"vs"];
        d.fragmentFunction = [library newFunctionWithName:@"fs"];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        _pipeline = [_device newRenderPipelineStateWithDescriptor:d error:&error];
        say(_pipeline ? @"конвейер собран" : [NSString stringWithFormat:@"конвейер не собран: %@", error]);
    }
    say([NSString stringWithFormat:@"окно %.0fx%.0f, экран %@, масштаб %.1f", frame.size.width, frame.size.height,
         NSStringFromRect(NSScreen.mainScreen.frame), NSScreen.mainScreen.backingScaleFactor]);
    return self;
}

static CVReturn tick(CVDisplayLinkRef link, const CVTimeStamp *now, const CVTimeStamp *output, CVOptionFlags flags,
                     CVOptionFlags *flagsOut, void *context)
{
    MetalView *view = (__bridge MetalView *)context;
    dispatch_async(dispatch_get_main_queue(), ^{ [view draw]; });
    return kCVReturnSuccess;
}

- (void)startLink
{
    CVDisplayLinkCreateWithActiveCGDisplays(&_link);
    CVDisplayLinkSetOutputCallback(_link, tick, (__bridge void *)self);
    CVDisplayLinkStart(_link);
    say(@"CVDisplayLink запущен");
}

- (void)draw
{
    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    CGSize size = self.bounds.size;
    CGFloat scale = self.window.backingScaleFactor ?: 1;
    layer.drawableSize = CGSizeMake(size.width * scale, size.height * scale);
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable) return;
    double t = self.frames / 60.0;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.2 + 0.2 * sin(t), 0.4, 1);
    id<MTLCommandBuffer> buffer = [self.queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    if (self.pipeline) {
        float angle = (float)t;
        [encoder setRenderPipelineState:self.pipeline];
        [encoder setVertexBytes:&angle length:sizeof(angle) atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [encoder endEncoding];
    [buffer presentDrawable:drawable];
    [buffer commit];
    if (++self.frames % 120 == 1) say([NSString stringWithFormat:@"кадр %lu, %.0fx%.0f", (unsigned long)self.frames,
                                       layer.drawableSize.width, layer.drawableSize.height]);
}

- (BOOL)acceptsFirstResponder { return YES; }
- (void)mouseDown:(NSEvent *)event
{
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    say([NSString stringWithFormat:@"мышь: %.0f, %.0f", p.x, p.y]);
}
- (void)keyDown:(NSEvent *)event { say([NSString stringWithFormat:@"клавиша: %@", event.characters]); }
@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic) NSWindow *window;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    say(@"applicationDidFinishLaunching");
    NSRect frame = NSMakeRect(0, 0, 800, 450);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"hello-mac";
    MetalView *view = [[MetalView alloc] initWithFrame:frame];
    self.window.contentView = view;
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:view];
    [view startLink];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
@end

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        say(@"main");
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
