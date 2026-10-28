// MPCoreAudio: настоящий CoreAudio iOS (реэкспорт), а вместо HAL (AudioObject…) — одно описанное здесь
// устройство вывода: стерео, 48 кГц.
//
// HAL — интерфейс macOS. На iOS его вызовы из приложения загружают модули HAL в процесс, а модуль Bluetooth
// (BTAudioHALPlugin) не может подключиться к своей службе из песочницы и повторяет попытку в цикле, занимая
// целое ядро процессора. Звук всё равно идёт через RemoteIO (см. MPAudioToolbox), поэтому HAL не нужен:
// на вопросы о «звуковой карте» отвечаем сами. Незнакомые свойства — в журнал (по одному разу) и ошибка
// «неизвестное свойство», как у HAL.

#include <CoreAudio/CoreAudioTypes.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>

typedef UInt32 MPObjectID;
typedef struct {
    UInt32 selector, scope, element;
} MPPropertyAddress;

enum {
    MPSystemObject = 1,
    MPDevice = 0x4D50,  // 'MP'
    MPUnknownProperty = 0x77686F3F,  // 'who?' kAudioHardwareUnknownPropertyError
    MPBadObject = 0x216F626A,  // '!obj' kAudioHardwareBadObjectError
};
#define FOURCC(a, b, c, d) ((UInt32)(a) << 24 | (UInt32)(b) << 16 | (UInt32)(c) << 8 | (UInt32)(d))

static const Float64 MPSampleRate = 48000;

// Стереораскладка описанием каналов: левый и правый.
typedef struct {
    AudioChannelLayoutTag tag;
    AudioChannelBitmap bitmap;
    UInt32 count;
    AudioChannelDescription channels[2];
} MPStereoLayout;

typedef struct {
    UInt32 count;
    AudioBuffer buffers[1];
} MPBufferList;

static void mp_unknown(MPObjectID object, const MPPropertyAddress *address)
{
    static UInt32 seen[64];
    static int count;
    for (int i = 0; i < count; i++)
        if (seen[i] == address->selector) return;
    if (count < 64) seen[count++] = address->selector;
    char s[5];
    for (int i = 0; i < 4; i++) s[i] = (char)(address->selector >> (24 - 8 * i));
    s[4] = 0;
    fprintf(stderr, "MPCoreAudio: неизвестное свойство '%s' у объекта %u\n", s, (unsigned)object);
}

// Значение свойства: размер и данные (data == NULL — только размер). 0 — нет такого свойства.
static UInt32 mp_property(MPObjectID object, const MPPropertyAddress *address, void *data)
{
    UInt32 u32;
    Float64 f64;
    const void *value = NULL;
    UInt32 size = 0;
    MPStereoLayout layout;
    MPBufferList buffers;
    AudioStreamBasicDescription format;
    UInt32 stereo[2] = {1, 2};
    CFStringRef string = NULL;

    if (object == MPSystemObject) {
        switch (address->selector) {
        case FOURCC('d', 'O', 'u', 't'):  // устройство вывода по умолчанию
        case FOURCC('s', 'O', 'u', 't'):  // системное
        case FOURCC('d', 'e', 'v', '#'):  // все устройства
            u32 = MPDevice;
            value = &u32;
            size = 4;
            break;
        case FOURCC('d', 'I', 'n', ' '):  // ввода нет
            u32 = 0;
            value = &u32;
            size = 4;
            break;
        default:
            return 0;
        }
    } else if (object == MPDevice) {
        switch (address->selector) {
        case FOURCC('s', 'r', 'n', 'd'):  // предпочтительная раскладка каналов
            memset(&layout, 0, sizeof layout);
            layout.tag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout.count = 2;
            layout.channels[0].mChannelLabel = kAudioChannelLabel_Left;
            layout.channels[1].mChannelLabel = kAudioChannelLabel_Right;
            value = &layout;
            size = sizeof layout;
            break;
        case FOURCC('d', 'c', 'h', '2'):  // каналы для стерео
            value = stereo;
            size = sizeof stereo;
            break;
        case FOURCC('n', 's', 'r', 't'):  // частота
        case FOURCC('a', 's', 'r', 't'):
            f64 = MPSampleRate;
            value = &f64;
            size = sizeof f64;
            break;
        case FOURCC('f', 's', 'i', 'z'):  // кадров в буфере
            u32 = 512;
            value = &u32;
            size = 4;
            break;
        case FOURCC('s', 'l', 'a', 'y'):  // конфигурация потоков: один буфер, два канала
            memset(&buffers, 0, sizeof buffers);
            buffers.count = 1;
            buffers.buffers[0].mNumberChannels = 2;
            value = &buffers;
            size = sizeof buffers;
            break;
        case FOURCC('s', 'f', 'm', 't'):
        case FOURCC('p', 'f', 't', ' '):
        case FOURCC('v', 'f', 'm', 't'):
            memset(&format, 0, sizeof format);
            format.mSampleRate = MPSampleRate;
            format.mFormatID = kAudioFormatLinearPCM;
            format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
            format.mBytesPerPacket = format.mBytesPerFrame = 8;
            format.mFramesPerPacket = 1;
            format.mChannelsPerFrame = 2;
            format.mBitsPerChannel = 32;
            value = &format;
            size = sizeof format;
            break;
        case FOURCC('t', 'r', 'a', 'n'):  // встроенное
            u32 = FOURCC('b', 'l', 't', 'n');
            value = &u32;
            size = 4;
            break;
        case FOURCC('l', 'i', 'v', 'n'):  // живо
            u32 = 1;
            value = &u32;
            size = 4;
            break;
        case FOURCC('g', 'o', 'i', 'n'):  // где-то идёт вывод
        case FOURCC('l', 't', 'n', 'c'):  // задержка
        case FOURCC('s', 'a', 'f', 't'):  // запас
        case FOURCC('h', 'o', 'g', 'p'):  // монопольный режим
            u32 = 0;
            value = &u32;
            size = 4;
            break;
        case FOURCC('u', 'i', 'd', ' '):
        case FOURCC('m', 'u', 'i', 'd'):
        case FOURCC('l', 'n', 'a', 'm'):
        case FOURCC('n', 'a', 'm', 'e'):
            if (data) string = CFSTR("iPhone");
            value = &string;
            size = sizeof string;
            break;
        default:
            return 0;
        }
    } else {
        return 0;
    }
    if (data) memcpy(data, value, size);
    return size;
}

OSStatus AudioObjectGetPropertyDataSize(MPObjectID object, const MPPropertyAddress *address, UInt32 qualifierSize,
                                        const void *qualifier, UInt32 *outSize)
{
    UInt32 size = mp_property(object, address, NULL);
    if (!size) {
        mp_unknown(object, address);
        return object == MPSystemObject || object == MPDevice ? MPUnknownProperty : MPBadObject;
    }
    *outSize = size;
    return 0;
}

OSStatus AudioObjectGetPropertyData(MPObjectID object, const MPPropertyAddress *address, UInt32 qualifierSize,
                                    const void *qualifier, UInt32 *ioSize, void *outData)
{
    UInt32 size = mp_property(object, address, NULL);
    if (!size) {
        mp_unknown(object, address);
        return object == MPSystemObject || object == MPDevice ? MPUnknownProperty : MPBadObject;
    }
    unsigned char buffer[256];
    mp_property(object, address, buffer);
    if (*ioSize < size) size = *ioSize;
    memcpy(outData, buffer, size);
    *ioSize = size;
    return 0;
}

OSStatus AudioObjectSetPropertyData(MPObjectID object, const MPPropertyAddress *address, UInt32 qualifierSize,
                                    const void *qualifier, UInt32 size, const void *data)
{
    // Цикл событий HAL ('rnlp'), размер буфера и прочее — принимаем молча: устройство одно и своё.
    return 0;
}

Boolean AudioObjectHasProperty(MPObjectID object, const MPPropertyAddress *address)
{
    return mp_property(object, address, NULL) != 0;
}
