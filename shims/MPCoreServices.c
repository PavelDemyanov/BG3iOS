// MPCoreServices: настоящий CoreServices iOS (реэкспорт) плюс Gestalt и пара функций Launch Services
// (их зовёт Discord SDK), которых в iOS нет.

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

// Gestalt: версия системы — как у macOS 14.5, под которую игра рассчитана.
int16_t Gestalt(uint32_t selector, int32_t *response)
{
    switch (selector) {
    case 'sysv': *response = 0x1450; return 0;  // gestaltSystemVersion
    case 'sys1': *response = 14; return 0;      // major
    case 'sys2': *response = 5; return 0;       // minor
    case 'sys3': *response = 0; return 0;       // bugfix
    default: *response = 0; return -5551;       // gestaltUndefSelectorErr
    }
}

int32_t LSRegisterURL(CFURLRef url, Boolean update) { return 0; }
int32_t LSSetDefaultHandlerForURLScheme(CFStringRef scheme, CFStringRef handler) { return 0; }
