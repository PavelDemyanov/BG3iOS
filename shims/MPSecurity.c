// MPSecurity: настоящий Security iOS (реэкспорт) плюс три функции macOS, которых в iOS нет.
// Их зовут сетевые библиотеки игры для сертификатов; на телефоне — «не найдено / не поддерживается».

#include <CoreFoundation/CoreFoundation.h>

enum { errSecUnimplemented = -4, errSecItemNotFound = -25300 };

CFStringRef SecCertificateCopyLongDescription(CFAllocatorRef alloc, const void *certificate, CFErrorRef *error)
{
    if (error) *error = NULL;
    return NULL;
}

int32_t SecIdentityCreateWithCertificate(CFTypeRef keychainOrArray, const void *certificate, const void **identity)
{
    if (identity) *identity = NULL;
    return errSecItemNotFound;
}

int32_t SecItemImport(CFDataRef data, CFStringRef fileName, void *inputFormat, void *itemType, uint32_t flags,
                      const void *keyParams, void *importKeychain, CFArrayRef *outItems)
{
    if (outItems) *outItems = NULL;
    return errSecUnimplemented;
}
