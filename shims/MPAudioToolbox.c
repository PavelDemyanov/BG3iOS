// MPAudioToolbox: настоящий AudioToolbox iOS (реэкспорт) плюс поправки вывода звука Mac-игр.
//
// Wwise (звук BG3) на macOS строит AUGraph с выходом HAL ('ahal') и привязывает его к устройству HAL
// (kAudioOutputUnitProperty_CurrentDevice). На iOS выход — RemoteIO ('rioc'), устройства HAL у приложения нет:
// выход подменяется, привязка к устройству пропускается. Описание «устройства» отдаёт MPCoreAudio.
// Свои определения этих функций в заменителе находятся раньше реэкспорта; настоящие берутся через dlsym.

#include <AudioToolbox/AudioToolbox.h>
#include <dlfcn.h>
#include <stdio.h>

static void *mp_real(const char *name)
{
    static void *toolbox;
    if (!toolbox) toolbox = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_LAZY | RTLD_NOLOAD);
    return dlsym(toolbox, name);
}

static const char *mp_fourcc(UInt32 code, char out[5])
{
    for (int i = 0; i < 4; i++) {
        char c = (char)(code >> (24 - 8 * i));
        out[i] = c >= 32 && c < 127 ? c : '?';
    }
    out[4] = 0;
    return out;
}

OSStatus AUGraphAddNode(AUGraph graph, const AudioComponentDescription *description, AUNode *node)
{
    static OSStatus (*real)(AUGraph, const AudioComponentDescription *, AUNode *);
    if (!real) real = mp_real("AUGraphAddNode");
    AudioComponentDescription d = *description;
    if (d.componentType == kAudioUnitType_Output && d.componentSubType != kAudioUnitSubType_RemoteIO &&
        d.componentSubType != kAudioUnitSubType_GenericOutput && d.componentSubType != kAudioUnitSubType_VoiceProcessingIO)
        d.componentSubType = kAudioUnitSubType_RemoteIO;  // 'ahal', 'def ', 'sys ' — только macOS
    OSStatus status = real(graph, &d, node);
    char t[5], s[5], s2[5];
    fprintf(stderr, "MPAudioToolbox: узел %s/%s%s%s → %d\n", mp_fourcc(description->componentType, t),
            mp_fourcc(description->componentSubType, s), d.componentSubType != description->componentSubType ? " как " : "",
            d.componentSubType != description->componentSubType ? mp_fourcc(d.componentSubType, s2) : "", (int)status);
    return status;
}

OSStatus AudioUnitSetProperty(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element,
                              const void *data, UInt32 size)
{
    static OSStatus (*real)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
    if (!real) real = mp_real("AudioUnitSetProperty");
    if (property == 2000) return noErr;  // kAudioOutputUnitProperty_CurrentDevice: устройств HAL на iOS нет
    OSStatus status = real(unit, property, scope, element, data, size);
    if (status) fprintf(stderr, "MPAudioToolbox: AudioUnitSetProperty %u (область %u, элемент %u) → %d\n",
                        (unsigned)property, (unsigned)scope, (unsigned)element, (int)status);
    return status;
}

// Журнал запуска графа и счётчик вызовов отрисовки: по ним видно, просит ли iOS у игры звук.
OSStatus AUGraphInitialize(AUGraph graph)
{
    static OSStatus (*real)(AUGraph);
    if (!real) real = mp_real("AUGraphInitialize");
    OSStatus status = real(graph);
    fprintf(stderr, "MPAudioToolbox: AUGraphInitialize → %d\n", (int)status);
    return status;
}

OSStatus AUGraphStart(AUGraph graph)
{
    static OSStatus (*real)(AUGraph);
    if (!real) real = mp_real("AUGraphStart");
    OSStatus status = real(graph);
    fprintf(stderr, "MPAudioToolbox: AUGraphStart → %d\n", (int)status);
    return status;
}

static AURenderCallbackStruct mp_game_callback;
static volatile uint64_t mp_render_calls;

static OSStatus mp_render(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time, UInt32 bus,
                          UInt32 frames, AudioBufferList *data)
{
    uint64_t n = ++mp_render_calls;
    OSStatus status = mp_game_callback.inputProc(mp_game_callback.inputProcRefCon, flags, time, bus, frames, data);
    // Раз в ~10 с — пик громкости того, что отдала игра (float32): тишина или звук.
    if (n == 1 || n % 470 == 0) {
        float peak = 0;
        for (UInt32 b = 0; data && b < data->mNumberBuffers; b++) {
            const float *s = data->mBuffers[b].mData;
            for (UInt32 i = 0; s && i < data->mBuffers[b].mDataByteSize / sizeof(float); i++)
                if (s[i] > peak || -s[i] > peak) peak = s[i] > 0 ? s[i] : -s[i];
        }
        fprintf(stderr, "MPAudioToolbox: отрисовка звука №%llu, кадров %u, буферов %u, пик %.4f\n",
                (unsigned long long)n, (unsigned)frames, data ? (unsigned)data->mNumberBuffers : 0, peak);
    }
    return status;
}

OSStatus AUGraphSetNodeInputCallback(AUGraph graph, AUNode node, UInt32 bus, const AURenderCallbackStruct *callback)
{
    static OSStatus (*real)(AUGraph, AUNode, UInt32, const AURenderCallbackStruct *);
    if (!real) real = mp_real("AUGraphSetNodeInputCallback");
    mp_game_callback = *callback;
    AURenderCallbackStruct ours = {mp_render, NULL};
    OSStatus status = real(graph, node, bus, &ours);
    fprintf(stderr, "MPAudioToolbox: AUGraphSetNodeInputCallback (вход %u) → %d\n", (unsigned)bus, (int)status);
    return status;
}

OSStatus AudioUnitSetParameter(AudioUnit unit, AudioUnitParameterID parameter, AudioUnitScope scope,
                               AudioUnitElement element, AudioUnitParameterValue value, UInt32 offset)
{
    static OSStatus (*real)(AudioUnit, AudioUnitParameterID, AudioUnitScope, AudioUnitElement, AudioUnitParameterValue, UInt32);
    if (!real) real = mp_real("AudioUnitSetParameter");
    OSStatus status = real(unit, parameter, scope, element, value, offset);
    if (status) fprintf(stderr, "MPAudioToolbox: AudioUnitSetParameter %u (область %u, элемент 0x%x) = %g → %d\n",
                        (unsigned)parameter, (unsigned)scope, (unsigned)element, value, (int)status);
    return status;
}
