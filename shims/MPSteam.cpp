// MPSteam: замена libsteam_api.dylib для Mac-игр на iOS — клиента Steam на телефоне нет.
//
// Интерфейсы Steam — C++-объекты: игра получает их по строке версии (SteamUser023 и т. п.) и зовёт
// виртуальные методы. Здесь каждый интерфейс — «зонд»: своя таблица из 256 заглушек; заглушка слота N
// один раз пишет в stderr «интерфейс, слот N» и возвращает 0. По журналу видно, какие методы игре
// нужны, и нужные получают настоящую реализацию (override).

#include <array>
#include <cstdint>
#include <cstdio>
#include <map>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr int kSlots = 256;

struct Probe {
    void **vtable;
    std::string name;
    std::array<bool, kSlots> seen{};
};

std::mutex lock;

template <int N> uint64_t slot(Probe *self)
{
    if (!self->seen[N]) {
        self->seen[N] = true;
        fprintf(stderr, "MPSteam: %s слот %d\n", self->name.c_str(), N);
    }
    return 0;
}

template <size_t... I> std::array<void *, sizeof...(I)> make_table(std::index_sequence<I...>)
{
    return {{reinterpret_cast<void *>(&slot<static_cast<int>(I)>)...}};
}

const std::array<void *, kSlots> &probe_table()
{
    static const auto table = make_table(std::make_index_sequence<kSlots>{});
    return table;
}

Probe *probe(const char *version)
{
    std::lock_guard<std::mutex> guard(lock);
    static std::map<std::string, Probe *> probes;
    std::string name = version ? version : "?";
    auto it = probes.find(name);
    if (it != probes.end()) return it->second;
    auto *p = new Probe;
    p->name = name;
    auto *vtable = new void *[kSlots];
    std::copy(probe_table().begin(), probe_table().end(), vtable);
    p->vtable = vtable;
    probes[name] = p;
    fprintf(stderr, "MPSteam: интерфейс %s\n", name.c_str());
    return p;
}

uintptr_t context_counter = 1;

}  // namespace

extern "C" {

bool SteamAPI_Init() { fprintf(stderr, "MPSteam: SteamAPI_Init\n"); return true; }
bool SteamAPI_RestartAppIfNecessary(uint32_t app) { return false; }
bool SteamAPI_IsSteamRunning() { return true; }
int32_t SteamAPI_GetHSteamUser() { return 1; }
void SteamAPI_RunCallbacks() {}
void SteamAPI_Shutdown() {}
void SteamAPI_RegisterCallback(void *callback, int id) { fprintf(stderr, "MPSteam: callback %d\n", id); }
void SteamAPI_UnregisterCallback(void *callback) {}
void SteamAPI_RegisterCallResult(void *callback, uint64_t call) {}
void SteamAPI_UnregisterCallResult(void *callback, uint64_t call) {}

// Как у Valve: контекст заполняет функция игры, когда счётчик контекста сменился.
void *SteamInternal_ContextInit(void *data)
{
    struct ContextInitData {
        void (*init)(void *ctx);
        uintptr_t counter;
        void *ctx[1];
    };
    auto *d = static_cast<ContextInitData *>(data);
    if (d->counter != context_counter) {
        d->init(&d->ctx);
        d->counter = context_counter;
    }
    return &d->ctx;
}

void *SteamInternal_FindOrCreateUserInterface(int32_t user, const char *version) { return probe(version); }
void *SteamInternal_CreateInterface(const char *version) { return probe(version); }

}  // extern "C"
