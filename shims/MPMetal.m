// MPMetal: настоящий Metal iOS (реэкспорт) плюс поправки для Mac-игр.
//
// - Режим хранения Managed (1) есть только в macOS: на iOS Metal падает с «Invalid storageMode 1». Память на
//   iPhone общая, поэтому Managed становится Shared: у буферов — в options при создании (у устройства и у кучи),
//   у текстур и куч — в копии дескриптора. Перехватываются методы конкретных классов устройства, кучи и буфера
//   (их узнаём, создав по одному объекту в конструкторе).
// - Методы, которые нужны только Managed-ресурсам и есть только в macOS (didModifyRange:,
//   synchronizeResource:, …), — пустые. Где в iOS они есть, но только как ловушка («is not supported on this
//   platform»), подменяется реализация в классе, который её определяет (IOGPUMetalBuffer и т. п.); где их нет
//   вовсе — категория на NSObject.
// - Форматы глубины только macOS: Depth24Unorm_Stencil8 (255) → Depth32Float_Stencil8, X24_Stencil8 (262) →
//   X32_Stencil8 — в сеттерах дескрипторов текстур и конвейеров (сами сеттеры проверяют формат и падают) и в
//   представлениях текстур. Объём и выравнивание игра берёт у Metal (heapTextureSizeAndAlign…), так что 8 байт
//   на пиксель вместо 4 она учитывает сама.
// - CAMetalLayer: displaySyncEnabled — только macOS (на iOS синхронизация с экраном всегда включена).

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <mach/mach.h>
#import <execinfo.h>
#import <dlfcn.h>
#import <pthread.h>
#import <sys/resource.h>
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

static void mp_log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void mp_log(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(stderr, "MPMetal: %s\n", text.UTF8String);
}

static const NSUInteger MPStorageModeManaged = 1;

static MTLResourceOptions mp_options(MTLResourceOptions options)
{
    if ((options & MTLResourceStorageModeMask) >> MTLResourceStorageModeShift == MPStorageModeManaged) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ mp_log(@"Managed → Shared (буферы)"); });
        options = (options & ~MTLResourceStorageModeMask) | MTLResourceStorageModeShared;
    }
    return options;
}

static MTLTextureDescriptor *mp_texture_descriptor(MTLTextureDescriptor *descriptor)
{
    if (!descriptor || descriptor.storageMode != MPStorageModeManaged) return descriptor;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mp_log(@"Managed → Shared (текстуры)"); });
    MTLTextureDescriptor *copy = [descriptor copy];
    copy.storageMode = MTLStorageModeShared;
    return copy;
}

static MTLHeapDescriptor *mp_heap_descriptor(MTLHeapDescriptor *descriptor)
{
    if (!descriptor || descriptor.storageMode != MPStorageModeManaged) return descriptor;
    MTLHeapDescriptor *copy = [descriptor copy];
    copy.storageMode = MTLStorageModeShared;
    return copy;
}

// Заменить реализацию selector у класса cls (если метод унаследован — добавить в сам класс); вернуть прежнюю.
static IMP mp_hook(Class cls, SEL selector, IMP replacement)
{
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        mp_log(@"нет -[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(selector));
        return NULL;
    }
    IMP original = method_getImplementation(method);
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method)))
        method_setImplementation(method, replacement);
    return original;
}

// Заменить selector там, где он определён (по цепочке суперклассов от cls), — для всех наследников разом.
static void mp_replace_defined(Class cls, SEL selector, IMP replacement)
{
    for (Class c = cls; c && c != NSObject.class; c = class_getSuperclass(c)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(c, &count);
        for (unsigned int i = 0; i < count; i++) {
            if (method_getName(methods[i]) == selector) {
                method_setImplementation(methods[i], replacement);
                mp_log(@"-[%@ %@] — пустой", NSStringFromClass(c), NSStringFromSelector(selector));
                free(methods);
                return;
            }
        }
        free(methods);
    }
}

static void mp_nothing(id self, SEL _cmd, ...) {}

static void mp_replace_hook(Class cls, SEL selector, IMP replacement, IMP *original)
{
    for (Class c = cls; c && c != NSObject.class; c = class_getSuperclass(c)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(c, &count);
        for (unsigned int i = 0; i < count; i++) {
            if (method_getName(methods[i]) == selector) {
                *original = method_setImplementation(methods[i], replacement);
                free(methods);
                return;
            }
        }
        free(methods);
    }
    mp_log(@"нет %@ у %@", NSStringFromSelector(selector), NSStringFromClass(cls));
}

#define HOOK(cls, sel, fn) orig_##fn = (__typeof__(orig_##fn))mp_hook(cls, @selector(sel), (IMP)fn)

#pragma mark - Устройство

static id (*orig_device_buffer)(id, SEL, NSUInteger, MTLResourceOptions);
static id device_buffer(id self, SEL _cmd, NSUInteger length, MTLResourceOptions options)
{
    return orig_device_buffer(self, _cmd, length, mp_options(options));
}

static id (*orig_device_buffer_bytes)(id, SEL, const void *, NSUInteger, MTLResourceOptions);
static id device_buffer_bytes(id self, SEL _cmd, const void *bytes, NSUInteger length, MTLResourceOptions options)
{
    return orig_device_buffer_bytes(self, _cmd, bytes, length, mp_options(options));
}

static id (*orig_device_buffer_nocopy)(id, SEL, void *, NSUInteger, MTLResourceOptions, id);
static id device_buffer_nocopy(id self, SEL _cmd, void *pointer, NSUInteger length, MTLResourceOptions options,
                               id deallocator)
{
    return orig_device_buffer_nocopy(self, _cmd, pointer, length, mp_options(options), deallocator);
}

static MTLSizeAndAlign (*orig_device_buffer_size)(id, SEL, NSUInteger, MTLResourceOptions);
static MTLSizeAndAlign device_buffer_size(id self, SEL _cmd, NSUInteger length, MTLResourceOptions options)
{
    return orig_device_buffer_size(self, _cmd, length, mp_options(options));
}

static id (*orig_device_texture)(id, SEL, MTLTextureDescriptor *);
static id device_texture(id self, SEL _cmd, MTLTextureDescriptor *descriptor)
{
    return orig_device_texture(self, _cmd, mp_texture_descriptor(descriptor));
}

static MTLSizeAndAlign (*orig_device_texture_size)(id, SEL, MTLTextureDescriptor *);
static MTLSizeAndAlign device_texture_size(id self, SEL _cmd, MTLTextureDescriptor *descriptor)
{
    return orig_device_texture_size(self, _cmd, mp_texture_descriptor(descriptor));
}

static id (*orig_device_heap)(id, SEL, MTLHeapDescriptor *);
static id device_heap(id self, SEL _cmd, MTLHeapDescriptor *descriptor)
{
    return orig_device_heap(self, _cmd, mp_heap_descriptor(descriptor));
}

#pragma mark - Куча и буфер

static id (*orig_heap_buffer)(id, SEL, NSUInteger, MTLResourceOptions);
static id heap_buffer(id self, SEL _cmd, NSUInteger length, MTLResourceOptions options)
{
    return orig_heap_buffer(self, _cmd, length, mp_options(options));
}

static id (*orig_heap_buffer_offset)(id, SEL, NSUInteger, MTLResourceOptions, NSUInteger);
static id heap_buffer_offset(id self, SEL _cmd, NSUInteger length, MTLResourceOptions options, NSUInteger offset)
{
    return orig_heap_buffer_offset(self, _cmd, length, mp_options(options), offset);
}

static id (*orig_heap_texture)(id, SEL, MTLTextureDescriptor *);
static id heap_texture(id self, SEL _cmd, MTLTextureDescriptor *descriptor)
{
    return orig_heap_texture(self, _cmd, mp_texture_descriptor(descriptor));
}

static id (*orig_heap_texture_offset)(id, SEL, MTLTextureDescriptor *, NSUInteger);
static id heap_texture_offset(id self, SEL _cmd, MTLTextureDescriptor *descriptor, NSUInteger offset)
{
    return orig_heap_texture_offset(self, _cmd, mp_texture_descriptor(descriptor), offset);
}

static id (*orig_buffer_texture)(id, SEL, MTLTextureDescriptor *, NSUInteger, NSUInteger);
static id buffer_texture(id self, SEL _cmd, MTLTextureDescriptor *descriptor, NSUInteger offset, NSUInteger bytesPerRow)
{
    return orig_buffer_texture(self, _cmd, mp_texture_descriptor(descriptor), offset, bytesPerRow);
}

#pragma mark - Профиль видеокарты по проходам

// MP_GPU_PROFILE=1: у каждого прохода (графического, вычислительного, копирования) — метки времени видеокарты на
// границах этапов (MTLCounterSampleBuffer, единственный вид, что есть у Apple GPU); имя прохода — по шейдерам его
// первого конвейера, у графического ещё размер цели. Раз в 10 с — в журнал проходы по убыванию времени на кадр.
static const void *MPNameKey = &MPNameKey;
static const void *MPPassKey = &MPPassKey;
static const void *MPPassesKey = &MPPassesKey;

static void mp_name_pipeline(id state, NSString *name)
{
    objc_setAssociatedObject(state, MPNameKey, name, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

@interface MPPass : NSObject
@property(nonatomic) NSUInteger first, count;  // метки в буфере buffer
@property(nonatomic, strong) id<MTLCounterSampleBuffer> buffer;
@property(nonatomic) char kind;                // r — графический, c — вычислительный, b — копирование
@property(nonatomic, copy) NSString *name, *target;
@property(nonatomic) NSUInteger draws, triangles;  // вызовы отрисовки и треугольники (с экземплярами)
@property(nonatomic) int skip;                     // MP_SKIP_PASS: 0 — не проверяли, 1 — рисовать, 2 — пропускать
@property(nonatomic) uint64_t frame;               // номер кадра при создании (для MP_DUMP_FRAME)
@property(nonatomic, copy) NSString *detail;       // цель, слой, действия загрузки и сохранения
@end
@implementation MPPass
@end

static int mp_profile = -1;
static _Atomic uint64_t mp_frames;  // счётчик кадров (ниже, «Счётчик кадров»)
// Буфер меток Metal вмещает не больше 4096 (32 КБ) — кольцо из 32 буферов.
enum { MPSamplesPerBuffer = 4096, MPSampleBuffers = 32 };
static id<MTLCounterSampleBuffer> mp_sample_buffers[MPSampleBuffers];
static _Atomic NSUInteger mp_sample_next;
static double mp_gpu_to_ns = 1;  // тики меток → нс
static MTLTimestamp mp_cpu0, mp_gpu0;  // пара (процессор, видеокарта) для перевода меток во время процессора
static double mp_tick_seconds;         // секунд в тике mach_absolute_time
static os_unfair_lock mp_profile_lock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSNumber *> *mp_pass_ns;  // имя → нс за окно
static NSMutableDictionary<NSString *, NSNumber *> *mp_pass_count;
static NSMutableDictionary<NSString *, NSNumber *> *mp_pass_draws, *mp_pass_triangles;

static void mp_take_samples(MPPass *pass, NSUInteger n)
{
    NSUInteger index = atomic_fetch_add(&mp_sample_next, n) % (MPSamplesPerBuffer * MPSampleBuffers);
    NSUInteger local = index % MPSamplesPerBuffer;
    if (local + n > MPSamplesPerBuffer) local = 0;  // не переходить через край буфера
    pass.buffer = mp_sample_buffers[index / MPSamplesPerBuffer];
    pass.first = local;
}

static MPPass *mp_new_pass(id commandBuffer, char kind, NSUInteger samples)
{
    MPPass *pass = [MPPass new];
    pass.kind = kind;
    mp_take_samples(pass, samples);
    pass.count = samples;
    NSMutableArray *passes = objc_getAssociatedObject(commandBuffer, MPPassesKey);
    if (!passes) {
        passes = [NSMutableArray array];
        objc_setAssociatedObject(commandBuffer, MPPassesKey, passes, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [passes addObject:pass];
    return pass;
}

#pragma mark - Повторная отрисовка каскадов теней

// BG3 4.1.1 на телефоне рисует каскады теней солнца дважды за кадр: тот же массив глубины 1024×1024×4, те же
// слои, с очисткой и теми же вызовами (≈9 млн треугольников, четверть геометрии кадра в Нижнем городе); второй
// раз просто перезаписывает первый. Повторная отрисовка того же слоя массива каскадов (2D-массив глубины из 4
// слоёв, очистка) в пределах кадра пропускается: вызовы отрисовки её энкодера не выполняются. Кадр — от одного
// nextDrawable до следующего (каскады рисуются внутри него). MP_SHADOW_DEDUP=0 — рисовать как есть;
// MP_DEDUP_ALTERNATE=1 — через 10-секундное окно, с FPS окна в журнале (сравнение в одном запуске).
static int mp_dedup = -1;
static _Atomic int mp_dedup_active = 1;
enum { MPSkipEncoders = 8, MPDedupSeen = 32 };
static void *_Atomic mp_skip_encoders[MPSkipEncoders];  // энкодеры, чьи вызовы отрисовки не выполняются
static os_unfair_lock mp_dedup_lock = OS_UNFAIR_LOCK_INIT;
static uint64_t mp_dedup_frame;
static struct { void *texture; NSUInteger slice; } mp_dedup_seen[MPDedupSeen];
static int mp_dedup_count;
static _Atomic uint64_t mp_dedup_skipped;  // пропущено проходов (для журнала)

static BOOL mp_dedup_should_skip(MTLRenderPassDescriptor *descriptor)
{
    if (descriptor.colorAttachments[0].texture) return NO;
    MTLRenderPassDepthAttachmentDescriptor *depth = descriptor.depthAttachment;
    id<MTLTexture> texture = depth.texture;
    if (!texture || texture.textureType != MTLTextureType2DArray || texture.arrayLength != 4 ||
        depth.loadAction != MTLLoadActionClear)
        return NO;
    BOOL seen = NO;
    os_unfair_lock_lock(&mp_dedup_lock);
    uint64_t frame = atomic_load(&mp_frames);
    if (frame != mp_dedup_frame) {
        mp_dedup_frame = frame;
        mp_dedup_count = 0;
    }
    for (int i = 0; i < mp_dedup_count && !seen; i++)
        seen = mp_dedup_seen[i].texture == (__bridge void *)texture && mp_dedup_seen[i].slice == depth.slice;
    // MP_DEDUP_TRACE=1: откуда идут оба набора — стек вызова для слоя 0 (адреса без сдвига ASLR, подписи — atos).
    static int traced;
    if (depth.slice == 0 && traced < 6 && getenv("MP_DEDUP_TRACE")) {
        traced++;
        void *frames[24];
        int n = backtrace(frames, 24);
        NSMutableString *line = [NSMutableString string];
        for (int i = 2; i < n; i++) {
            Dl_info info;
            if (dladdr(frames[i], &info) && info.dli_fname && strstr(info.dli_fname, "/Contents/MacOS/")) {
                intptr_t slide = (intptr_t)info.dli_fbase - 0x100000000;
                [line appendFormat:@" %#lx", (unsigned long)((intptr_t)frames[i] - slide)];
            }
        }
        mp_log(@"каскад слой 0, %@ в кадре:%@", seen ? @"повтор" : @"первый", line);
    }
    if (!seen && mp_dedup_count < MPDedupSeen) {
        mp_dedup_seen[mp_dedup_count].texture = (__bridge void *)texture;
        mp_dedup_seen[mp_dedup_count++].slice = depth.slice;
    }
    os_unfair_lock_unlock(&mp_dedup_lock);
    return seen && atomic_load(&mp_dedup_active);
}

// MP_CASCADE_EVERY=П0,П1,П2,П3: каскад N перерисовывается раз в ПN кадров (по очереди: каскад N — в кадрах, где
// номер кадра по модулю ПN равен N по тому же модулю), в остальных кадрах его слой сохраняется с прошлого раза.
// Например «1,1,2,2» — ближние каждый кадр, дальние через кадр, в каждом кадре один из дальних: где упор
// в видеокарту, +15–20 % FPS, но при движении тени вдали прыгают — по умолчанию выключено.
// MP_CASCADE_ALTERNATE=1 — через 10-секундное окно, с FPS окна (сравнение в одном запуске).
static int mp_cascade_period[4];
static _Atomic int mp_cascade_active = 1;

static BOOL mp_cascade_skip(MTLRenderPassDescriptor *descriptor)
{
    if (!atomic_load(&mp_cascade_active) || descriptor.colorAttachments[0].texture) return NO;
    MTLRenderPassDepthAttachmentDescriptor *depth = descriptor.depthAttachment;
    id<MTLTexture> texture = depth.texture;
    if (!texture || texture.textureType != MTLTextureType2DArray || texture.arrayLength != 4 ||
        depth.loadAction != MTLLoadActionClear || depth.slice >= 4)
        return NO;
    int period = mp_cascade_period[depth.slice];
    return period > 1 && atomic_load(&mp_frames) % period != depth.slice % period;
}

static BOOL mp_encoder_skipped(id encoder)
{
    for (int i = 0; i < MPSkipEncoders; i++)
        if (atomic_load_explicit(&mp_skip_encoders[i], memory_order_relaxed) == (__bridge void *)encoder) return YES;
    return NO;
}

static void mp_skip_encoder(id encoder, BOOL skip)
{
    void *want = skip ? NULL : (__bridge void *)encoder, *put = skip ? (__bridge void *)encoder : NULL;
    for (int i = 0; i < MPSkipEncoders; i++) {
        void *expected = want;
        if (atomic_compare_exchange_strong(&mp_skip_encoders[i], &expected, put)) return;
    }
}

static void (*orig_end_encoding)(id, SEL);
static void end_encoding(id self, SEL _cmd)
{
    if (mp_encoder_skipped(self)) mp_skip_encoder(self, NO);
    orig_end_encoding(self, _cmd);
}

static id (*orig_render_encoder)(id, SEL, MTLRenderPassDescriptor *);
static id mp_profiled_render_encoder(id self, SEL _cmd, MTLRenderPassDescriptor *descriptor);
static id render_encoder(id self, SEL _cmd, MTLRenderPassDescriptor *descriptor)
{
    BOOL skip = descriptor && mp_dedup == 1 && mp_dedup_should_skip(descriptor);
    if (!skip && descriptor && mp_cascade_period[0]) skip = mp_cascade_skip(descriptor);
    // Пропущенный проход не должен очищать слой: иначе он сотрёт то, что нарисовал первый набор (без вызовов
    // отрисовки очистка всё равно выполняется). Описание прохода игра может использовать снова — вернуть как было.
    if (skip) descriptor.depthAttachment.loadAction = MTLLoadActionLoad;
    id encoder = mp_profile == 1 && descriptor ? mp_profiled_render_encoder(self, _cmd, descriptor)
                                               : orig_render_encoder(self, _cmd, descriptor);
    if (skip) descriptor.depthAttachment.loadAction = MTLLoadActionClear;
    if (skip && encoder) {
        mp_skip_encoder(encoder, YES);
        atomic_fetch_add(&mp_dedup_skipped, 1);
    }
    return encoder;
}

static id mp_profiled_render_encoder(id self, SEL _cmd, MTLRenderPassDescriptor *descriptor)
{
    MPPass *pass = mp_new_pass(self, 'r', 4);
    MTLRenderPassSampleBufferAttachmentDescriptor *a = descriptor.sampleBufferAttachments[0];
    a.sampleBuffer = pass.buffer;
    a.startOfVertexSampleIndex = pass.first;
    a.endOfVertexSampleIndex = pass.first + 1;
    a.startOfFragmentSampleIndex = pass.first + 2;
    a.endOfFragmentSampleIndex = pass.first + 3;
    id<MTLTexture> target = descriptor.colorAttachments[0].texture ?: descriptor.depthAttachment.texture;
    pass.target = target ? [NSString stringWithFormat:@"%lu×%lu%@", (unsigned long)target.width,
                                     (unsigned long)target.height, descriptor.colorAttachments[0].texture ? @"" : @" глубина"]
                         : @"?";
    pass.frame = atomic_load(&mp_frames);
    MTLRenderPassDepthAttachmentDescriptor *depth = descriptor.depthAttachment;
    MTLRenderPassColorAttachmentDescriptor *color = descriptor.colorAttachments[0];
    pass.detail = [NSString stringWithFormat:@"цвет %p сл.%lu загр.%lu сохр.%lu; глубина %p (%lu, слоёв %lu, %@) сл.%lu загр.%lu сохр.%lu очистка %.2f",
                   color.texture, (unsigned long)color.slice, (unsigned long)color.loadAction,
                   (unsigned long)color.storeAction, depth.texture, (unsigned long)depth.texture.textureType,
                   (unsigned long)depth.texture.arrayLength, depth.texture.heap ? @"в куче" : @"своя",
                   (unsigned long)depth.slice, (unsigned long)depth.loadAction, (unsigned long)depth.storeAction,
                   depth.clearDepth];
    id encoder = orig_render_encoder(self, _cmd, descriptor);
    a.sampleBuffer = nil;
    objc_setAssociatedObject(encoder, MPPassKey, pass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return encoder;
}

static id (*orig_compute_encoder_type)(id, SEL, MTLDispatchType);
static id compute_encoder_type(id self, SEL _cmd, MTLDispatchType type)
{
    if (mp_profile != 1) return orig_compute_encoder_type(self, _cmd, type);
    MPPass *pass = mp_new_pass(self, 'c', 2);
    MTLComputePassDescriptor *descriptor = [MTLComputePassDescriptor computePassDescriptor];
    descriptor.dispatchType = type;
    descriptor.sampleBufferAttachments[0].sampleBuffer = pass.buffer;
    descriptor.sampleBufferAttachments[0].startOfEncoderSampleIndex = pass.first;
    descriptor.sampleBufferAttachments[0].endOfEncoderSampleIndex = pass.first + 1;
    id encoder = [(id<MTLCommandBuffer>)self computeCommandEncoderWithDescriptor:descriptor];
    objc_setAssociatedObject(encoder, MPPassKey, pass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return encoder;
}

static id (*orig_blit_encoder)(id, SEL);
static id blit_encoder(id self, SEL _cmd)
{
    if (mp_profile != 1) return orig_blit_encoder(self, _cmd);
    MPPass *pass = mp_new_pass(self, 'b', 2);
    pass.name = @"копирование";
    MTLBlitPassDescriptor *descriptor = [MTLBlitPassDescriptor blitPassDescriptor];
    descriptor.sampleBufferAttachments[0].sampleBuffer = pass.buffer;
    descriptor.sampleBufferAttachments[0].startOfEncoderSampleIndex = pass.first;
    descriptor.sampleBufferAttachments[0].endOfEncoderSampleIndex = pass.first + 1;
    return [(id<MTLCommandBuffer>)self blitCommandEncoderWithDescriptor:descriptor];
}

// Вызовы отрисовки и треугольники прохода. Опыт: MP_SKIP_PASS=ПОДСТРОКА — вызовы отрисовки в проходах, чьё имя
// в отчёте («ШЕЙДЕРЫ [ЦЕЛЬ]») содержит подстроку, не выполняются (например «1024×1024 глубина» — карты теней):
// так видно, сколько кадра стоит проход. С MP_SKIP_ALTERNATE=1 опыт включается через окно отчёта (10 с с ним,
// 10 с без): сравнение в одном запуске, на одном месте и при одном нагреве. Возвращает YES, если вызов пропустить.
static _Atomic int mp_skip_active = 1;
static BOOL mp_count_draw(id encoder, MTLPrimitiveType type, NSUInteger elements, NSUInteger instances)
{
    if (mp_profile != 1) return NO;
    MPPass *pass = objc_getAssociatedObject(encoder, MPPassKey);
    if (!pass) return NO;
    if (!pass.skip) {
        static NSString *skip;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ skip = getenv("MP_SKIP_PASS") ? @(getenv("MP_SKIP_PASS")) : nil; });
        NSString *key = [NSString stringWithFormat:@"%@ [%@]", pass.name ?: @"?", pass.target];
        pass.skip = skip.length && atomic_load(&mp_skip_active) && [key containsString:skip] ? 2 : 1;
    }
    if (pass.skip == 2) return YES;
    pass.draws += 1;
    NSUInteger per = type == MTLPrimitiveTypeTriangle ? elements / 3 : type == MTLPrimitiveTypeTriangleStrip && elements > 2 ? elements - 2 : 0;
    pass.triangles += per * (instances ?: 1);
    return NO;
}

static void (*orig_draw_indexed)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id, NSUInteger);
static void draw_indexed(id self, SEL _cmd, MTLPrimitiveType type, NSUInteger count, MTLIndexType indexType, id buffer,
                         NSUInteger offset)
{
    if (mp_encoder_skipped(self) || mp_count_draw(self, type, count, 1)) return;
    orig_draw_indexed(self, _cmd, type, count, indexType, buffer, offset);
}

static void (*orig_draw_indexed_instanced)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id, NSUInteger, NSUInteger,
                                           NSInteger, NSUInteger);
static void draw_indexed_instanced(id self, SEL _cmd, MTLPrimitiveType type, NSUInteger count, MTLIndexType indexType,
                                   id buffer, NSUInteger offset, NSUInteger instances, NSInteger baseVertex,
                                   NSUInteger baseInstance)
{
    if (mp_encoder_skipped(self) || mp_count_draw(self, type, count, instances)) return;
    orig_draw_indexed_instanced(self, _cmd, type, count, indexType, buffer, offset, instances, baseVertex, baseInstance);
}

static void (*orig_draw_primitives)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger);
static void draw_primitives(id self, SEL _cmd, MTLPrimitiveType type, NSUInteger start, NSUInteger count)
{
    if (mp_encoder_skipped(self) || mp_count_draw(self, type, count, 1)) return;
    orig_draw_primitives(self, _cmd, type, start, count);
}

static void (*orig_set_render_pipeline)(id, SEL, id);
static void set_render_pipeline(id self, SEL _cmd, id state)
{
    MPPass *pass = mp_profile == 1 ? objc_getAssociatedObject(self, MPPassKey) : nil;
    if (pass && !pass.name) pass.name = objc_getAssociatedObject(state, MPNameKey) ?: @"?";
    orig_set_render_pipeline(self, _cmd, state);
}

static void (*orig_set_compute_pipeline)(id, SEL, id);
static void set_compute_pipeline(id self, SEL _cmd, id state)
{
    MPPass *pass = mp_profile == 1 ? objc_getAssociatedObject(self, MPPassKey) : nil;
    if (pass && !pass.name) pass.name = objc_getAssociatedObject(state, MPNameKey) ?: @"?";
    orig_set_compute_pipeline(self, _cmd, state);
}

// Метка → секунды во времени процессора (как GPUStartTime буфера); 0 — метки нет.
// На A19 Pro метки и sampleTimestamps — наносекунды в той же шкале, что GPUStartTime (секунды): мерим
// соотношение по паре замеров на случай других устройств.
// MP_DUMP_FRAME=1: через 120 с после старта — все проходы одного кадра по порядку (цели, слои, действия).
static _Atomic uint64_t mp_dump_frame;

static double mp_sample_seconds(uint64_t ts)
{
    if (!ts || ts == MTLCounterErrorValue) return 0;
    return ((double)mp_cpu0 + ((double)ts - (double)mp_gpu0) * mp_gpu_to_ns) / 1e9;
}

// Завершение буфера команд: разобрать метки его проходов. Этап, который не выполнялся, метку не пишет — в слоте
// остаётся старая; поэтому берутся только метки внутри [GPUStartTime, GPUEndTime] буфера.
static void mp_profile_completed(id<MTLCommandBuffer> commandBuffer)
{
    NSArray<MPPass *> *passes = objc_getAssociatedObject(commandBuffer, MPPassesKey);
    double from = commandBuffer.GPUStartTime - 0.002, to = commandBuffer.GPUEndTime + 0.002;
    for (MPPass *pass in passes) {
        NSData *data = [pass.buffer resolveCounterRange:NSMakeRange(pass.first, pass.count)];
        const MTLCounterResultTimestamp *ts = data.bytes;
        if (!ts || data.length < pass.count * sizeof *ts) continue;
        double s[4] = {0};
        for (NSUInteger i = 0; i < pass.count && i < 4; i++) {
            double v = mp_sample_seconds(ts[i].timestamp);
            s[i] = v >= from && v <= to ? v : 0;
        }
        // Графический: вершинный этап s0..s1, фрагментный s2..s3; остальные: s0..s1.
        double ns = 0;
        if (s[0] && s[1] && s[1] > s[0]) ns += (s[1] - s[0]) * 1e9;
        if (pass.kind == 'r' && s[2] && s[3] && s[3] > s[2]) ns += (s[3] - s[2]) * 1e9;
        if (ns <= 0 || ns > 1e9) continue;
        if (pass.frame && pass.frame == atomic_load(&mp_dump_frame))
            mp_log(@"кадр %llu: %c %.2f мс, %lu вызовов, %.2f млн тр.: %@ [%@] — %@", pass.frame, pass.kind, ns / 1e6,
                   (unsigned long)pass.draws, pass.triangles / 1e6, pass.name ?: @"?", pass.target ?: @"", pass.detail ?: @"");
        NSString *key = pass.kind == 'r' ? [NSString stringWithFormat:@"рисование %@ [%@]", pass.name ?: @"?", pass.target]
                      : pass.kind == 'c' ? [NSString stringWithFormat:@"вычисление %@", pass.name ?: @"?"]
                                         : @"копирование";
        os_unfair_lock_lock(&mp_profile_lock);
        mp_pass_ns[key] = @(mp_pass_ns[key].doubleValue + ns);
        mp_pass_count[key] = @(mp_pass_count[key].unsignedIntegerValue + 1);
        mp_pass_draws[key] = @(mp_pass_draws[key].unsignedIntegerValue + pass.draws);
        mp_pass_triangles[key] = @(mp_pass_triangles[key].unsignedIntegerValue + pass.triangles);
        os_unfair_lock_unlock(&mp_profile_lock);
    }
}

double mp_metal_gpu_busy_seconds(void);
static uint64_t mp_now_ns(void);
static uint64_t mp_started_ns;
static thread_act_t mp_main_thread;  // поток загрузки программы — у игры на нём цикл кадров

static double mp_thread_seconds(thread_act_t thread)
{
    thread_basic_info_data_t info;
    mach_msg_type_number_t size = THREAD_BASIC_INFO_COUNT;
    if (!thread || thread_info(thread, THREAD_BASIC_INFO, (thread_info_t)&info, &size) != KERN_SUCCESS) return 0;
    return info.user_time.seconds + info.user_time.microseconds / 1e6 + info.system_time.seconds +
           info.system_time.microseconds / 1e6;
}

static void mp_profile_report(void)
{
    static uint64_t last_frames;
    static double last_time, last_busy, last_main;
    uint64_t frames = atomic_load(&mp_frames);
    double perFrame = frames > last_frames ? 1.0 / (frames - last_frames) : 0;
    double now = mp_now_ns() / 1e9, busy = mp_metal_gpu_busy_seconds(), main = mp_thread_seconds(mp_main_thread);
    double span = last_time ? now - last_time : 0;
    static BOOL alternate;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ alternate = getenv("MP_SKIP_ALTERNATE") && getenv("MP_SKIP_ALTERNATE")[0] == '1'; });
    int skipped = atomic_load(&mp_skip_active);
    if (span > 0)
        mp_log(@"окно%s: кадров/с %.1f, видеокарта занята %.0f%%, главный поток %.0f%% ядра",
               !getenv("MP_SKIP_PASS") ? "" : skipped ? " С ОПЫТОМ" : " без опыта", (frames - last_frames) / span,
               (busy - last_busy) / span * 100, (main - last_main) / span * 100);
    if (alternate) atomic_store(&mp_skip_active, !skipped);
    if (getenv("MP_DUMP_FRAME") && !atomic_load(&mp_dump_frame) && now - mp_started_ns / 1e9 > 120)
        atomic_store(&mp_dump_frame, frames + 3);
    last_frames = frames;
    last_time = now;
    last_busy = busy;
    last_main = main;
    os_unfair_lock_lock(&mp_profile_lock);
    NSDictionary *ns = [mp_pass_ns copy], *count = [mp_pass_count copy];
    NSDictionary *draws = [mp_pass_draws copy], *triangles = [mp_pass_triangles copy];
    [mp_pass_ns removeAllObjects];
    [mp_pass_count removeAllObjects];
    [mp_pass_draws removeAllObjects];
    [mp_pass_triangles removeAllObjects];
    os_unfair_lock_unlock(&mp_profile_lock);
    double total = 0, allDraws = 0, allTriangles = 0;
    for (NSNumber *v in ns.allValues) total += v.doubleValue;
    for (NSNumber *v in draws.allValues) allDraws += v.doubleValue;
    for (NSNumber *v in triangles.allValues) allTriangles += v.doubleValue;
    mp_log(@"геометрия: %.0f вызовов отрисовки и %.2f млн треугольников на кадр", allDraws * perFrame,
           allTriangles * perFrame / 1e6);
    NSArray *keys = [ns keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
    mp_log(@"проходы видеокарты (вершины + фрагменты, этапы разных проходов идут параллельно): сумма %.1f мс на кадр, "
           @"%lu видов", total / 1e6 * perFrame, (unsigned long)keys.count);
    for (NSUInteger i = 0; i < MIN(keys.count, 15); i++)
        mp_log(@"  %5.2f мс/кадр ×%-3.0f %5.0f вызовов %5.2f млн тр. %@", [ns[keys[i]] doubleValue] / 1e6 * perFrame,
               [count[keys[i]] doubleValue] * perFrame, [draws[keys[i]] doubleValue] * perFrame,
               [triangles[keys[i]] doubleValue] * perFrame / 1e6, keys[i]);
}

// Перехваты энкодеров — для профиля (MP_GPU_PROFILE) и для пропуска повторных каскадов, один раз.
static void mp_install_encoder_hooks(Class commandBufferClass, Class renderClass, Class computeClass)
{
    static BOOL installed;
    if (installed) return;
    installed = YES;
    mp_replace_hook(commandBufferClass, @selector(renderCommandEncoderWithDescriptor:), (IMP)render_encoder, (IMP *)&orig_render_encoder);
    mp_replace_hook(commandBufferClass, @selector(computeCommandEncoderWithDispatchType:), (IMP)compute_encoder_type, (IMP *)&orig_compute_encoder_type);
    mp_replace_hook(commandBufferClass, @selector(blitCommandEncoder), (IMP)blit_encoder, (IMP *)&orig_blit_encoder);
    mp_replace_hook(renderClass, @selector(setRenderPipelineState:), (IMP)set_render_pipeline, (IMP *)&orig_set_render_pipeline);
    mp_replace_hook(renderClass, @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:),
                    (IMP)draw_indexed, (IMP *)&orig_draw_indexed);
    mp_replace_hook(renderClass,
                    @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:),
                    (IMP)draw_indexed_instanced, (IMP *)&orig_draw_indexed_instanced);
    mp_replace_hook(renderClass, @selector(drawPrimitives:vertexStart:vertexCount:), (IMP)draw_primitives,
                    (IMP *)&orig_draw_primitives);
    mp_replace_hook(computeClass, @selector(setComputePipelineState:), (IMP)set_compute_pipeline, (IMP *)&orig_set_compute_pipeline);
    mp_replace_hook(renderClass, @selector(endEncoding), (IMP)end_encoding, (IMP *)&orig_end_encoding);
}

// Каскады через кадр (MP_CASCADE_EVERY, выше).
static void mp_cascade_start(void)
{
    const char *every = getenv("MP_CASCADE_EVERY");
    if (!every) return;
    sscanf(every, "%d,%d,%d,%d", &mp_cascade_period[0], &mp_cascade_period[1], &mp_cascade_period[2],
           &mp_cascade_period[3]);
    if (!mp_cascade_period[0]) mp_cascade_period[0] = 1;
    mp_log(@"каскады: перерисовка раз в %d, %d, %d, %d кадров", mp_cascade_period[0], mp_cascade_period[1],
           mp_cascade_period[2], mp_cascade_period[3]);
    if (!(getenv("MP_CASCADE_ALTERNATE") && getenv("MP_CASCADE_ALTERNATE")[0] == '1')) return;
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        static uint64_t last_frames;
        uint64_t frames = atomic_load(&mp_frames);
        mp_log(@"окно %@: кадров/с %.1f", atomic_load(&mp_cascade_active) ? @"КАСКАДЫ РЕЖЕ" : @"каскады каждый кадр",
               (frames - last_frames) / 10.0);
        last_frames = frames;
        atomic_store(&mp_cascade_active, !atomic_load(&mp_cascade_active));
    });
    dispatch_resume(timer);
}

// Пропуск повторных каскадов (выше): по умолчанию включён; MP_DEDUP_ALTERNATE=1 — через окно, с FPS окна.
static void mp_dedup_start(Class commandBufferClass, Class renderClass, Class computeClass)
{
    mp_dedup = !(getenv("MP_SHADOW_DEDUP") && getenv("MP_SHADOW_DEDUP")[0] == '0');
    mp_cascade_start();
    if (mp_dedup != 1 && !mp_cascade_period[0]) return;
    mp_install_encoder_hooks(commandBufferClass, renderClass, computeClass);
    BOOL alternate = getenv("MP_DEDUP_ALTERNATE") && getenv("MP_DEDUP_ALTERNATE")[0] == '1';
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        static uint64_t last_frames, last_skipped;
        uint64_t frames = atomic_load(&mp_frames), skipped = atomic_load(&mp_dedup_skipped);
        if (alternate || skipped != last_skipped)
            mp_log(@"окно %@: кадров/с %.1f, пропущено повторных каскадов %llu",
                   atomic_load(&mp_dedup_active) ? @"БЕЗ ДУБЛЕЙ" : @"с дублями", (frames - last_frames) / 10.0,
                   skipped - last_skipped);
        last_frames = frames;
        last_skipped = skipped;
        if (alternate) atomic_store(&mp_dedup_active, !atomic_load(&mp_dedup_active));
    });
    dispatch_resume(timer);
}

static void mp_profile_start(id<MTLDevice> device, Class commandBufferClass, Class renderClass, Class computeClass)
{
    mp_profile = getenv("MP_GPU_PROFILE") && getenv("MP_GPU_PROFILE")[0] == '1';
    if (mp_profile != 1) return;
    if (![device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) {
        mp_log(@"профиль видеокарты: метки на границах этапов не поддерживаются");
        mp_profile = 0;
        return;
    }
    id<MTLCounterSet> timestamps = nil;
    for (id<MTLCounterSet> set in device.counterSets)
        if ([set.name isEqualToString:MTLCommonCounterSetTimestamp]) timestamps = set;
    MTLCounterSampleBufferDescriptor *d = [MTLCounterSampleBufferDescriptor new];
    d.counterSet = timestamps;
    d.sampleCount = MPSamplesPerBuffer;
    d.storageMode = MTLStorageModeShared;
    for (NSUInteger i = 0; i < MPSampleBuffers; i++) {
        NSError *error = nil;
        mp_sample_buffers[i] = [device newCounterSampleBufferWithDescriptor:d error:&error];
        if (!mp_sample_buffers[i]) {
            mp_log(@"профиль видеокарты: %@", error);
            mp_profile = 0;
            return;
        }
    }
    // Тики меток → нс: два замера пары (процессор, видеокарта) с промежутком.
    MTLTimestamp cpu0, gpu0, cpu1, gpu1;
    [device sampleTimestamps:&cpu0 gpuTimestamp:&gpu0];
    usleep(20000);
    [device sampleTimestamps:&cpu1 gpuTimestamp:&gpu1];
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    mp_tick_seconds = (double)tb.numer / tb.denom / 1e9;
    if (gpu1 > gpu0) mp_gpu_to_ns = (double)(cpu1 - cpu0) / (double)(gpu1 - gpu0);  // обе шкалы — нс
    mp_cpu0 = cpu1;
    mp_gpu0 = gpu1;
    mp_pass_ns = [NSMutableDictionary dictionary];
    mp_pass_count = [NSMutableDictionary dictionary];
    mp_pass_draws = [NSMutableDictionary dictionary];
    mp_pass_triangles = [NSMutableDictionary dictionary];
    mp_install_encoder_hooks(commandBufferClass, renderClass, computeClass);
    static dispatch_source_t report;
    report = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(report, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(report, ^{ mp_profile_report(); });
    dispatch_resume(report);
    mp_log(@"профиль видеокарты включён: 1 тик = %.3f нс", mp_gpu_to_ns);
}

#pragma mark - Учёт компиляции конвейеров

// Игра создаёт конвейеры синхронно и без бинарных архивов: каждый шейдер компилируется на телефоне при первой
// надобности (результат Metal кладёт в свой кэш в Library/Caches). Счётчики — в журнал раз в 5 с, если менялись:
// по ним видно, сколько времени уходит на компиляцию и становится ли её меньше при следующих запусках.
static _Atomic uint64_t mp_render_count, mp_compute_count, mp_compile_ns;

static uint64_t mp_now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static uint64_t mp_started_ns;  // загрузка игры (конструктор MPMetal)

// Поток, который берёт drawable, — цикл кадров игры: компиляция в нём держит кадр целиком, в других потоках —
// только если кадр ждёт их работы. Самые долгие компиляции окна (с функциями и потоком) — в отчёт о рывках.
static _Atomic uintptr_t mp_frame_thread;
static _Atomic uint64_t mp_compile_frame_ns, mp_compile_frame_count;

typedef struct {
    double ms;
    bool frame;
    char thread[24];
    char name[120];
} MPSlowCompile;

static os_unfair_lock mp_compile_lock = OS_UNFAIR_LOCK_INIT;
static MPSlowCompile mp_slow[5];     // самые долгие за окно, по убыванию
static unsigned mp_compile_hist[4];  // за окно: < 10 мс, 10–50, 50–200, ≥ 200 мс

static void mp_note_compile(uint64_t ns, NSString *name)
{
    bool frame = (uintptr_t)pthread_self() == atomic_load(&mp_frame_thread);
    if (frame) {
        atomic_fetch_add(&mp_compile_frame_ns, ns);
        atomic_fetch_add(&mp_compile_frame_count, 1);
    }
    double ms = ns / 1e6;
    MPSlowCompile item = {.ms = ms, .frame = frame};
    if (ms >= 50) {
        pthread_getname_np(pthread_self(), item.thread, sizeof item.thread);
        if (!item.thread[0]) snprintf(item.thread, sizeof item.thread, "%u", pthread_mach_thread_np(pthread_self()));
        strlcpy(item.name, name.UTF8String ?: "-", sizeof item.name);
    }
    const int n = sizeof mp_slow / sizeof *mp_slow;
    os_unfair_lock_lock(&mp_compile_lock);
    mp_compile_hist[ms < 10 ? 0 : ms < 50 ? 1 : ms < 200 ? 2 : 3]++;
    if (ms >= 50 && ms > mp_slow[n - 1].ms) {
        int i = n - 1;
        for (; i > 0 && mp_slow[i - 1].ms < ms; i--) mp_slow[i] = mp_slow[i - 1];
        mp_slow[i] = item;
    }
    os_unfair_lock_unlock(&mp_compile_lock);
}

static id (*orig_device_render_pipeline)(id, SEL, MTLRenderPipelineDescriptor *, NSError **);
static id device_render_pipeline(id self, SEL _cmd, MTLRenderPipelineDescriptor *descriptor, NSError **error)
{
    uint64_t start = mp_now_ns();
    id state = orig_device_render_pipeline(self, _cmd, descriptor, error);
    uint64_t ns = mp_now_ns() - start;
    atomic_fetch_add(&mp_compile_ns, ns);
    atomic_fetch_add(&mp_render_count, 1);
    NSString *name = [NSString stringWithFormat:@"%@|%@", descriptor.vertexFunction.name ?: @"-",
                                                         descriptor.fragmentFunction.name ?: @"-"];
    mp_note_compile(ns, name);
    if (state) mp_name_pipeline(state, name);
    return state;
}

static id (*orig_device_compute_pipeline)(id, SEL, id<MTLFunction>, NSError **);
static id device_compute_pipeline(id self, SEL _cmd, id<MTLFunction> function, NSError **error)
{
    uint64_t start = mp_now_ns();
    id state = orig_device_compute_pipeline(self, _cmd, function, error);
    uint64_t ns = mp_now_ns() - start;
    atomic_fetch_add(&mp_compile_ns, ns);
    atomic_fetch_add(&mp_compute_count, 1);
    mp_note_compile(ns, function.name ?: @"-");
    if (state) mp_name_pipeline(state, function.name ?: @"-");
    return state;
}

static void mp_pipeline_report(void)
{
    static uint64_t last_render, last_compute, last_ns;
    uint64_t render = atomic_load(&mp_render_count), compute = atomic_load(&mp_compute_count);
    uint64_t ns = atomic_load(&mp_compile_ns);
    if (render == last_render && compute == last_compute) return;
    static uint64_t start;
    if (!start) start = mp_started_ns;
    mp_log(@"t+%.0f с конвейеры: графических %llu (+%llu), вычислительных %llu (+%llu), компиляция %.1f с (+%.1f с)",
           (mp_now_ns() - start) / 1e9, render, render - last_render, compute, compute - last_compute, ns / 1e9,
           (ns - last_ns) / 1e9);
    last_render = render;
    last_compute = compute;
    last_ns = ns;
}

#pragma mark - Время видеокарты

// Сумма времени выполнения буферов команд на видеокарте (GPUEndTime − GPUStartTime) — хост делит её на кадры:
// видно, упирается ли кадр в видеокарту.
static _Atomic uint64_t mp_gpu_ns;

__attribute__((visibility("default"))) double mp_metal_gpu_seconds(void) { return atomic_load(&mp_gpu_ns) / 1e9; }

// Занятость без двойного счёта: объединение интервалов буферов (параллельные очереди перекрываются, и сумма
// длительностей бывает больше 100 %). Буферы завершаются почти по порядку начала — копим отрезок за отрезком.
static os_unfair_lock mp_gpu_lock = OS_UNFAIR_LOCK_INIT;
static double mp_gpu_union, mp_gpu_last_end;

__attribute__((visibility("default"))) double mp_metal_gpu_busy_seconds(void)
{
    os_unfair_lock_lock(&mp_gpu_lock);
    double busy = mp_gpu_union;
    os_unfair_lock_unlock(&mp_gpu_lock);
    return busy;
}

static void (*orig_command_buffer_commit)(id, SEL);
static void command_buffer_commit(id self, SEL _cmd)
{
    [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        if (mp_profile == 1) mp_profile_completed(buffer);
        CFTimeInterval start = buffer.GPUStartTime, end = buffer.GPUEndTime, busy = end - start;
        if (busy > 0 && busy < 5) {
            atomic_fetch_add(&mp_gpu_ns, (uint64_t)(busy * 1e9));
            os_unfair_lock_lock(&mp_gpu_lock);
            if (start >= mp_gpu_last_end) mp_gpu_union += busy;
            else if (end > mp_gpu_last_end) mp_gpu_union += end - mp_gpu_last_end;
            if (end > mp_gpu_last_end) mp_gpu_last_end = end;
            os_unfair_lock_unlock(&mp_gpu_lock);
        }
    }];
    orig_command_buffer_commit(self, _cmd);
}

#pragma mark - Бюджет видеопамяти

// Рабочий набор видеокарты — по нему движок задаёт бюджет текстур. На iPhone память общая, Metal сообщает 8 ГБ,
// а это весь лимит процесса: в Нижнем городе игра доходит до 7,8 ГБ из 8,2. MP_VRAM_MB — ограничение в МБ.
static uint64_t (*orig_device_working_set)(id, SEL);
static uint64_t device_working_set(id self, SEL _cmd)
{
    uint64_t size = orig_device_working_set(self, _cmd);
    const char *limit = getenv("MP_VRAM_MB");
    if (limit && atoll(limit) > 0 && (uint64_t)atoll(limit) << 20 < size) size = (uint64_t)atoll(limit) << 20;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mp_log(@"рабочий набор видеокарты для игры: %llu МБ", size >> 20); });
    return size;
}

#pragma mark - Форматы глубины

static MTLPixelFormat mp_format(MTLPixelFormat format)
{
    switch ((NSUInteger)format) {
    case 255: {  // MTLPixelFormatDepth24Unorm_Stencil8
        static dispatch_once_t once;
        dispatch_once(&once, ^{ mp_log(@"Depth24Unorm_Stencil8 → Depth32Float_Stencil8"); });
        return MTLPixelFormatDepth32Float_Stencil8;
    }
    case 262:  // MTLPixelFormatX24_Stencil8
        return MTLPixelFormatX32_Stencil8;
    default:
        return format;
    }
}

// Сеттер формата: у каждого класса и селектора своя прежняя реализация.
#define FORMAT_SETTER(fn)                                                                                              \
    static void (*orig_##fn)(id, SEL, MTLPixelFormat);                                                                 \
    static void fn(id self, SEL _cmd, MTLPixelFormat format) { orig_##fn(self, _cmd, mp_format(format)); }
FORMAT_SETTER(texture_descriptor_format)
FORMAT_SETTER(pipeline_depth_format)
FORMAT_SETTER(pipeline_stencil_format)
FORMAT_SETTER(mesh_depth_format)
FORMAT_SETTER(mesh_stencil_format)

static id (*orig_texture_view)(id, SEL, MTLPixelFormat);
static id texture_view(id self, SEL _cmd, MTLPixelFormat format)
{
    return orig_texture_view(self, _cmd, mp_format(format));
}

static id (*orig_texture_view_range)(id, SEL, MTLPixelFormat, MTLTextureType, NSRange, NSRange);
static id texture_view_range(id self, SEL _cmd, MTLPixelFormat format, MTLTextureType type, NSRange levels, NSRange slices)
{
    return orig_texture_view_range(self, _cmd, mp_format(format), type, levels, slices);
}

static id (*orig_texture_view_swizzle)(id, SEL, MTLPixelFormat, MTLTextureType, NSRange, NSRange, MTLTextureSwizzleChannels);
static id texture_view_swizzle(id self, SEL _cmd, MTLPixelFormat format, MTLTextureType type, NSRange levels,
                               NSRange slices, MTLTextureSwizzleChannels swizzle)
{
    return orig_texture_view_swizzle(self, _cmd, mp_format(format), type, levels, slices, swizzle);
}

static void mp_hook_formats(id<MTLTexture> texture)
{
    HOOK([[MTLTextureDescriptor new] class], setPixelFormat:, texture_descriptor_format);
    Class pipeline = [[MTLRenderPipelineDescriptor new] class];
    HOOK(pipeline, setDepthAttachmentPixelFormat:, pipeline_depth_format);
    HOOK(pipeline, setStencilAttachmentPixelFormat:, pipeline_stencil_format);
    Class mesh = [[MTLMeshRenderPipelineDescriptor new] class];
    HOOK(mesh, setDepthAttachmentPixelFormat:, mesh_depth_format);
    HOOK(mesh, setStencilAttachmentPixelFormat:, mesh_stencil_format);
    if (texture) {
        Class cls = [texture class];
        HOOK(cls, newTextureViewWithPixelFormat:, texture_view);
        HOOK(cls, newTextureViewWithPixelFormat:textureType:levels:slices:, texture_view_range);
        HOOK(cls, newTextureViewWithPixelFormat:textureType:levels:slices:swizzle:, texture_view_swizzle);
    }
}

static void mp_pace_install(Class commandBufferClass);
static void mp_pace_report(void);

__attribute__((constructor)) static void mp_metal_init(void)
{
    mp_started_ns = mp_now_ns();
    mp_main_thread = mach_thread_self();
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            mp_log(@"нет устройства Metal");
            return;
        }
        Class deviceClass = [device class];
        HOOK(deviceClass, newBufferWithLength:options:, device_buffer);
        HOOK(deviceClass, newBufferWithBytes:length:options:, device_buffer_bytes);
        HOOK(deviceClass, newBufferWithBytesNoCopy:length:options:deallocator:, device_buffer_nocopy);
        HOOK(deviceClass, heapBufferSizeAndAlignWithLength:options:, device_buffer_size);
        HOOK(deviceClass, newTextureWithDescriptor:, device_texture);
        HOOK(deviceClass, heapTextureSizeAndAlignWithDescriptor:, device_texture_size);
        HOOK(deviceClass, newHeapWithDescriptor:, device_heap);
        HOOK(deviceClass, recommendedMaxWorkingSetSize, device_working_set);
        HOOK(deviceClass, newRenderPipelineStateWithDescriptor:error:, device_render_pipeline);
        HOOK(deviceClass, newComputePipelineStateWithFunction:error:, device_compute_pipeline);
        static dispatch_source_t report;
        report = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(report, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(report, ^{
            mp_pace_report();
            mp_pipeline_report();
        });
        dispatch_resume(report);

        MTLHeapDescriptor *heapDescriptor = [MTLHeapDescriptor new];
        heapDescriptor.size = 1 << 16;
        heapDescriptor.storageMode = MTLStorageModePrivate;
        id<MTLHeap> heap = [device newHeapWithDescriptor:heapDescriptor];
        if (heap) {
            Class heapClass = [heap class];
            HOOK(heapClass, newBufferWithLength:options:, heap_buffer);
            HOOK(heapClass, newTextureWithDescriptor:, heap_texture);
            heapDescriptor.type = MTLHeapTypePlacement;
            id<MTLHeap> placement = [device newHeapWithDescriptor:heapDescriptor];
            if (placement) {
                Class placementClass = [placement class];
                if (placementClass != heapClass) {
                    HOOK(placementClass, newBufferWithLength:options:, heap_buffer);
                    HOOK(placementClass, newTextureWithDescriptor:, heap_texture);
                }
                HOOK(placementClass, newBufferWithLength:options:offset:, heap_buffer_offset);
                HOOK(placementClass, newTextureWithDescriptor:offset:, heap_texture_offset);
            }
        }
        id<MTLBuffer> buffer = [device newBufferWithLength:256 options:MTLResourceStorageModeShared];
        if (buffer) HOOK([buffer class], newTextureWithDescriptor:offset:bytesPerRow:, buffer_texture);

        // Ловушки macOS-only методов: у буфера, текстуры и кодировщиков.
        MTLTextureDescriptor *textureDescriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
        textureDescriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [device newTextureWithDescriptor:textureDescriptor];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> commands = [queue commandBuffer];
        // commit — там, где он определён (буферы команд игры могут быть другим подклассом, чем пробный).
        for (Class c = [commands class]; c && c != NSObject.class; c = class_getSuperclass(c)) {
            Method m = NULL;
            unsigned int n = 0;
            Method *list = class_copyMethodList(c, &n);
            for (unsigned int i = 0; i < n; i++)
                if (method_getName(list[i]) == @selector(commit)) m = list[i];
            free(list);
            if (m) {
                orig_command_buffer_commit = (void *)method_setImplementation(m, (IMP)command_buffer_commit);
                mp_log(@"время видеокарты: -[%@ commit]", NSStringFromClass(c));
                break;
            }
        }
        mp_pace_install([commands class]);
        id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
        Class blitClass = [blit class];
        [blit endEncoding];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = texture;
        id<MTLRenderCommandEncoder> render = [commands renderCommandEncoderWithDescriptor:pass];
        Class renderClass = [render class];
        [render endEncoding];
        id<MTLComputeCommandEncoder> compute = [commands computeCommandEncoder];
        Class computeClass = [compute class];
        [compute endEncoding];
        mp_hook_formats(texture);
        mp_profile_start(device, [commands class], renderClass, computeClass);
        mp_dedup_start([commands class], renderClass, computeClass);
        for (Class cls in @[ [buffer class], [texture class], blitClass, renderClass, computeClass ])
            for (NSString *name in @[ @"didModifyRange:", @"synchronizeResource:", @"synchronizeTexture:slice:level:",
                                      @"textureBarrier" ])
                mp_replace_defined(cls, NSSelectorFromString(name), (IMP)mp_nothing);
        mp_log(@"устройство %@ (%@), поправки Managed установлены", device.name, NSStringFromClass(deviceClass));
    }
}

#pragma mark - Методы только macOS

@implementation NSObject (MPMetalMacOnly)
- (void)didModifyRange:(NSRange)range {}
- (void)synchronizeResource:(id)resource {}
- (void)synchronizeTexture:(id)texture slice:(NSUInteger)slice level:(NSUInteger)level {}
- (void)textureBarrier {}
@end

#pragma mark - Счётчик кадров

// Кадр = один drawable у CAMetalLayer. Хост (MacRunner) читает счётчик через dlsym: FPS в журнал и на экран.
static _Atomic uint64_t mp_frames;

__attribute__((visibility("default"))) uint64_t mp_metal_frames(void) { return atomic_load(&mp_frames); }

// Размер буфера кадра (итоговое разрешение отрисовки) — в журнал при каждом изменении.
static void (*orig_set_drawable_size)(id, SEL, CGSize);
static void set_drawable_size(id self, SEL _cmd, CGSize size)
{
    CGSize old = [(CAMetalLayer *)self drawableSize];
    if (old.width != size.width || old.height != size.height)
        mp_log(@"буфер кадра %.0f×%.0f", size.width, size.height);
    orig_set_drawable_size(self, _cmd, size);
}

#pragma mark - Ритм кадров и рывки

// Что видит игрок: сколько держался на экране каждый кадр (разница presentedTime соседних drawable). Экран
// обновляется с шагом 16,7 мс (8,3 мс при 120 Гц), поэтому кадр держится ≈17, 33, 50 мс…; в отчёте — обычная
// длительность (медиана), 95-й процентиль и самый долгий. Рывок — кадр, который держался 45 мс и дольше. У каждого
// кадра запоминается, что было между ним и прошлым drawable: компиляция конвейеров в потоке кадра и в других, чтение
// с диска процессом, ожидание свободного drawable (упор в видеокарту или экран), отклонённые стики (бег, камера).
// Отчёт — раз в 5 с, перед строкой конвейеров.

int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);  // libproc: в SDK iOS не объявлена

typedef struct {
    double t, cpu_ms, wait_ms, compile_ms, compile_other_ms, read_mb;
    bool move, turn;
} MPFrame;

static _Atomic bool mp_stick_move, mp_stick_turn;  // выборка 10 раз в секунду в главном потоке

enum { MPPaceFrames = 2048 };  // за окно в 5 с — с запасом и при 120 кадрах/с

static struct {
    unsigned shown, dropped, pauses, moving, turning, hitches, hitches_moving;
    unsigned with_compile, with_compile_other, with_read, with_wait, unexplained;
    float ms[MPPaceFrames];  // сколько держались показанные кадры
    struct {
        double ms;
        MPFrame f;
    } worst[3];
} mp_pace;
static CFTimeInterval mp_pace_last;
static os_unfair_lock mp_pace_lock = OS_UNFAIR_LOCK_INIT;

static uint64_t mp_bytes_read(void)
{
    struct rusage_info_v6 info;
    return proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&info) == 0 ? info.ri_diskio_bytesread : 0;
}

static void mp_frame_presented(CFTimeInterval when, MPFrame f)
{
    const int n = sizeof mp_pace.worst / sizeof *mp_pace.worst;
    os_unfair_lock_lock(&mp_pace_lock);
    if (when <= 0) {
        mp_pace.dropped++;
    } else if (mp_pace_last > 0 && when > mp_pace_last) {
        double ms = (when - mp_pace_last) * 1000;
        if (ms >= 1000) {
            mp_pace.pauses++;  // загрузка, ролик, приложение в фоне — не рывок
        } else {
            if (mp_pace.shown < MPPaceFrames) mp_pace.ms[mp_pace.shown] = ms;
            mp_pace.shown++;
            mp_pace.moving += f.move;
            mp_pace.turning += f.turn;
            if (ms >= 45) {
                bool compile = f.compile_ms >= 10, other = f.compile_other_ms >= 20, read = f.read_mb >= 1,
                     wait = f.wait_ms >= 20;
                mp_pace.hitches++;
                mp_pace.hitches_moving += f.move || f.turn;
                mp_pace.with_compile += compile;
                mp_pace.with_compile_other += other;
                mp_pace.with_read += read;
                mp_pace.with_wait += wait;
                mp_pace.unexplained += !(compile || other || read || wait);
                if (ms > mp_pace.worst[n - 1].ms) {
                    int i = n - 1;
                    for (; i > 0 && mp_pace.worst[i - 1].ms < ms; i--) mp_pace.worst[i] = mp_pace.worst[i - 1];
                    mp_pace.worst[i].ms = ms;
                    mp_pace.worst[i].f = f;
                }
            }
        }
    }
    if (when > 0) mp_pace_last = when;
    os_unfair_lock_unlock(&mp_pace_lock);
}

// Зовётся в потоке кадра сразу после nextDrawable: start — вызов, end — drawable получен.
static void mp_frame_acquired(id<CAMetalDrawable> drawable, uint64_t start, uint64_t end)
{
    static uint64_t last_start, last_all, last_frame, last_read;
    uint64_t all = atomic_load(&mp_compile_ns), frame = atomic_load(&mp_compile_frame_ns), read = mp_bytes_read();
    MPFrame f = {
        .t = (start - mp_started_ns) / 1e9,
        .cpu_ms = last_start ? (start - last_start) / 1e6 : 0,
        .wait_ms = (end - start) / 1e6,
        .compile_ms = (frame - last_frame) / 1e6,
        .compile_other_ms = ((all - last_all) - (frame - last_frame)) / 1e6,
        .read_mb = last_start ? (read - last_read) / 1048576.0 : 0,
        .move = atomic_load(&mp_stick_move),
        .turn = atomic_load(&mp_stick_turn),
    };
    last_start = start;
    last_all = all;
    last_frame = frame;
    last_read = read;
    [drawable addPresentedHandler:^(id<MTLDrawable> shown) { mp_frame_presented(shown.presentedTime, f); }];
}

static id (*orig_next_drawable)(id, SEL);
static id next_drawable(id self, SEL _cmd)
{
    atomic_fetch_add(&mp_frames, 1);
    uintptr_t thread = (uintptr_t)pthread_self();
    if (atomic_exchange(&mp_frame_thread, thread) != thread) {
        char name[32] = "";
        pthread_getname_np(pthread_self(), name, sizeof name);
        mp_log(@"кадры берёт поток «%s» (%u)", name, pthread_mach_thread_np(pthread_self()));
    }
    uint64_t start = mp_now_ns();
    id drawable = orig_next_drawable(self, _cmd);
    if (drawable) mp_frame_acquired(drawable, start, mp_now_ns());
    return drawable;
}

// Как игра показывает кадры: просто presentDrawable или с минимальной длительностью (своё ограничение частоты).
// MP_FPS_CAP=N — не больше N кадров в секунду ровным шагом: presentDrawable: становится
// presentDrawable:afterMinimumDuration: (кадр держится на экране не меньше 1/N с минус 2 мс — запас на дрожание
// времени, иначе при 60 Гц шаг то и дело выходил бы на три обновления экрана вместо двух).
static _Atomic uint64_t mp_presents, mp_presents_after, mp_present_after_us;
static CFTimeInterval mp_present_min;

static void (*orig_present_after)(id, SEL, id, CFTimeInterval);

static void (*orig_present)(id, SEL, id);
static void command_buffer_present(id self, SEL _cmd, id drawable)
{
    atomic_fetch_add(&mp_presents, 1);
    if (mp_present_min > 0 && orig_present_after)
        orig_present_after(self, @selector(presentDrawable:afterMinimumDuration:), drawable, mp_present_min);
    else
        orig_present(self, _cmd, drawable);
}

static void command_buffer_present_after(id self, SEL _cmd, id drawable, CFTimeInterval duration)
{
    atomic_fetch_add(&mp_presents_after, 1);
    atomic_store(&mp_present_after_us, (uint64_t)(duration * 1e6));
    orig_present_after(self, _cmd, drawable, duration);
}

static void mp_pace_install(Class commandBufferClass)
{
    mp_replace_hook(commandBufferClass, @selector(presentDrawable:), (IMP)command_buffer_present, (IMP *)&orig_present);
    mp_replace_hook(commandBufferClass, @selector(presentDrawable:afterMinimumDuration:),
                    (IMP)command_buffer_present_after, (IMP *)&orig_present_after);
    const char *cap = getenv("MP_FPS_CAP");
    if (cap && atof(cap) > 0) {
        mp_present_min = 1.0 / atof(cap) - 0.002;
        mp_log(@"не больше %.0f кадров/с: каждый кадр на экране не меньше %.1f мс", atof(cap), mp_present_min * 1000);
    }
}

static void (*orig_set_max_drawables)(id, SEL, NSUInteger);
static void set_max_drawables(id self, SEL _cmd, NSUInteger count)
{
    if ([(CAMetalLayer *)self maximumDrawableCount] != count) mp_log(@"drawable у слоя: %lu", (unsigned long)count);
    orig_set_max_drawables(self, _cmd, count);
}

static void mp_sample_sticks(void)
{
    bool move = false, turn = false;
    for (GCController *controller in GCController.controllers) {
        GCExtendedGamepad *pad = controller.extendedGamepad;
        if (!pad) continue;
        move |= hypotf(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value) > 0.5f;
        turn |= hypotf(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value) > 0.5f;
    }
    atomic_store(&mp_stick_move, move);
    atomic_store(&mp_stick_turn, turn);
}

static void mp_pace_report(void)
{
    os_unfair_lock_lock(&mp_pace_lock);
    __typeof__(mp_pace) w = mp_pace;
    memset(&mp_pace, 0, sizeof mp_pace);
    os_unfair_lock_unlock(&mp_pace_lock);
    MPSlowCompile slow[sizeof mp_slow / sizeof *mp_slow];
    unsigned hist[4];
    os_unfair_lock_lock(&mp_compile_lock);
    memcpy(slow, mp_slow, sizeof slow);
    memset(mp_slow, 0, sizeof mp_slow);
    memcpy(hist, mp_compile_hist, sizeof hist);
    memset(mp_compile_hist, 0, sizeof mp_compile_hist);
    os_unfair_lock_unlock(&mp_compile_lock);
    static uint64_t last_after, last_frame_ns, last_frame_count;
    uint64_t after = atomic_load(&mp_presents_after), frame_ns = atomic_load(&mp_compile_frame_ns),
             frame_count = atomic_load(&mp_compile_frame_count);
    uint64_t new_after = after - last_after, new_frame_ns = frame_ns - last_frame_ns,
             new_frame_count = frame_count - last_frame_count;
    last_after = after;
    last_frame_ns = frame_ns;
    last_frame_count = frame_count;
    if (!w.shown) return;
    double n = w.shown;
    unsigned kept = MIN(w.shown, (unsigned)MPPaceFrames);
    qsort_b(w.ms, kept, sizeof *w.ms, ^int(const void *a, const void *b) {
        float x = *(const float *)a, y = *(const float *)b;
        return x < y ? -1 : x > y;
    });
    mp_log(@"t+%.0f с кадры: %.1f/с, обычно %.0f мс (95 %% не дольше %.0f мс), самый долгий %.0f мс; бег %.0f%%, "
           @"камера %.0f%%%@%@",
           (mp_now_ns() - mp_started_ns) / 1e9, n / 5, w.ms[kept / 2], w.ms[kept * 95 / 100], w.ms[kept - 1],
           w.moving * 100 / n, w.turning * 100 / n,
           new_after ? [NSString stringWithFormat:@"; показ с паузой %llu раз (%.1f мс)", new_after,
                                                  atomic_load(&mp_present_after_us) / 1e3]
                     : @"",
           w.dropped || w.pauses ? [NSString stringWithFormat:@"; не показано %u, пауз %u", w.dropped, w.pauses] : @"");
    if (w.hitches) {
        mp_log(@"  рывков (≥45 мс) %u, на бегу или с камерой %u; в них: компиляция в потоке кадра %u, в других "
               @"потоках %u, чтение ≥1 МБ %u, ожидание drawable %u, ничего из этого %u",
               w.hitches, w.hitches_moving, w.with_compile, w.with_compile_other, w.with_read, w.with_wait,
               w.unexplained);
        for (int i = 0; i < 3 && w.worst[i].ms > 0; i++) {
            MPFrame f = w.worst[i].f;
            mp_log(@"    %.0f мс (t+%.1f%@): кадр на процессоре %.0f мс, ожидание drawable %.0f, компиляция в потоке кадра "
                   @"%.0f, в других %.0f, прочитано %.1f МБ",
                   w.worst[i].ms, f.t, f.move ? @", бег" : f.turn ? @", камера" : @"", f.cpu_ms, f.wait_ms, f.compile_ms,
                   f.compile_other_ms, f.read_mb);
        }
    }
    unsigned compiled = hist[0] + hist[1] + hist[2] + hist[3];
    if (compiled) {
        mp_log(@"  компиляция: %u конвейеров (<10 мс %u, 10–50 %u, 50–200 %u, ≥200 %u), в потоке кадра %llu — %.2f с",
               compiled, hist[0], hist[1], hist[2], hist[3], new_frame_count, new_frame_ns / 1e9);
        for (size_t i = 0; i < sizeof slow / sizeof *slow && slow[i].ms > 0; i++)
            mp_log(@"    %.0f мс, поток «%s»%s: %s", slow[i].ms, slow[i].thread, slow[i].frame ? " (кадра)" : "",
                   slow[i].name);
    }
}

__attribute__((constructor)) static void mp_frames_init(void)
{
    HOOK(CAMetalLayer.class, nextDrawable, next_drawable);
    HOOK(CAMetalLayer.class, setDrawableSize:, set_drawable_size);
    HOOK(CAMetalLayer.class, setMaximumDrawableCount:, set_max_drawables);
    dispatch_async(dispatch_get_main_queue(), ^{
        mp_log(@"экран: до %ld кадров/с", (long)UIScreen.mainScreen.maximumFramesPerSecond);
    });
    static dispatch_source_t sticks;
    sticks = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(sticks, DISPATCH_TIME_NOW, NSEC_PER_SEC / 10, NSEC_PER_SEC / 50);
    dispatch_source_set_event_handler(sticks, ^{ mp_sample_sticks(); });
    dispatch_resume(sticks);
}

@implementation CAMetalLayer (MPMetalMacOnly)
- (BOOL)displaySyncEnabled { return YES; }
- (void)setDisplaySyncEnabled:(BOOL)enabled {}
@end
