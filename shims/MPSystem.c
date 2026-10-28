// MPSystem: настоящая libSystem iOS (реэкспорт) плюс то, что macOS экспортирует, а iOS — нет.

#include <stdarg.h>
#include <syslog.h>

// На macOS syslog у новых программ — syslog$DARWIN_EXTSN; на iOS только syslog.
void mp_syslog_extsn(int priority, const char *format, ...) __asm("_syslog$DARWIN_EXTSN");
void mp_syslog_extsn(int priority, const char *format, ...)
{
    va_list args;
    va_start(args, format);
    vsyslog(priority, format, args);
    va_end(args);
}

#pragma mark - Трассировка исключений

// Игра на iOS падает в std::terminate, не говоря, что вылетело. Поэтому каждое исключение C++ из библиотек
// приложения (их __cxa_throw подменяется в GOT, как это делает fishhook) и каждое исключение Objective-C
// (objc_setExceptionPreprocessor) пишется в stderr: тип, сообщение и стек «библиотека+смещение» для atos.

#include <dlfcn.h>
#include <execinfo.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

char *__cxa_demangle(const char *name, char *buffer, size_t *length, int *status);
typedef void (*cxa_throw_fn)(void *object, void *type, void (*destructor)(void *));
typedef id (*objc_preprocessor_fn)(id exception);
objc_preprocessor_fn objc_setExceptionPreprocessor(objc_preprocessor_fn fn);

static cxa_throw_fn mp_real_throw;
static objc_preprocessor_fn mp_previous_preprocessor;
static int mp_traced;
enum { MP_TRACE_LIMIT = 200 };

static void mp_backtrace(void)
{
    void *frames[24];
    int n = backtrace(frames, 24);
    for (int i = 2; i < n; i++) {
        Dl_info info;
        if (dladdr(frames[i], &info) && info.dli_fname) {
            const char *file = strrchr(info.dli_fname, '/');
            fprintf(stderr, "    %2d %s+0x%lx %s\n", i - 2, file ? file + 1 : info.dli_fname,
                    (unsigned long)((char *)frames[i] - (char *)info.dli_fbase), info.dli_sname ? info.dli_sname : "");
        } else {
            fprintf(stderr, "    %2d %p\n", i - 2, frames[i]);
        }
    }
}

static void mp_throw(void *object, void *type, void (*destructor)(void *))
{
    if (mp_traced++ < MP_TRACE_LIMIT) {
        // std::type_info: указатель на vtable, затем имя (старший бит — признак неуникального RTTI).
        const char *mangled = (const char *)(((uintptr_t *)type)[1] & ~(1ULL << 63));
        int status = 0;
        char *name = __cxa_demangle(mangled, NULL, NULL, &status);
        const char *shown = status == 0 && name ? name : mangled;
        fprintf(stderr, "MPSystem: исключение C++ %s", shown);
        // Наследники std::exception: what() — третий слот vtable (после двух деструкторов).
        if (strstr(shown, "exception") || strstr(shown, "error") || !strncmp(shown, "std::", 5)) {
            const char *(*what)(void *) = (const char *(*)(void *))(*(void ***)object)[2];
            fprintf(stderr, ": %s", what(object));
        }
        fputc('\n', stderr);
        free(name);
        mp_backtrace();
    }
    mp_real_throw(object, type, destructor);
}

static id mp_objc_exception(id exception)
{
    if (mp_traced++ < MP_TRACE_LIMIT) {
        id name = ((id(*)(id, SEL))objc_msgSend)(exception, sel_registerName("name"));
        id reason = ((id(*)(id, SEL))objc_msgSend)(exception, sel_registerName("reason"));
        const char *(*utf8)(id, SEL) = (const char *(*)(id, SEL))objc_msgSend;
        fprintf(stderr, "MPSystem: исключение Objective-C %s: %s\n", name ? utf8(name, sel_registerName("UTF8String")) : "?",
                reason ? utf8(reason, sel_registerName("UTF8String")) : "");
        mp_backtrace();
    }
    return mp_previous_preprocessor ? mp_previous_preprocessor(exception) : exception;
}

// Заменить в образе ячейки указателей на функцию name (без «_») на replacement — как fishhook: ячейки
// (__got, __la_symbol_ptr) сопоставляются с именами по таблице косвенных символов. Сравнивать значения нельзя:
// ленивые ячейки до первого вызова указывают на заглушку dyld, а не на функцию.
#include <mach-o/nlist.h>

static int mp_rebind(const struct mach_header_64 *header, intptr_t slide, const char *name, void *replacement)
{
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct segment_command_64 *linkedit = NULL;
    const struct load_command *cmd = (const void *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, cmd = (const void *)((const char *)cmd + cmd->cmdsize)) {
        if (cmd->cmd == LC_SYMTAB) symtab = (const void *)cmd;
        else if (cmd->cmd == LC_DYSYMTAB) dysymtab = (const void *)cmd;
        else if (cmd->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)cmd)->segname, SEG_LINKEDIT))
            linkedit = (const void *)cmd;
    }
    if (!symtab || !dysymtab || !linkedit || !dysymtab->nindirectsyms) return 0;
    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symbols = (const void *)(base + symtab->symoff);
    const char *strings = (const char *)(base + symtab->stroff);
    const uint32_t *indirect = (const void *)(base + dysymtab->indirectsymoff);
    int replaced = 0;
    cmd = (const void *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, cmd = (const void *)((const char *)cmd + cmd->cmdsize)) {
        if (cmd->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment = (const void *)cmd;
        const struct section_64 *section = (const void *)(segment + 1);
        for (uint32_t s = 0; s < segment->nsects; s++, section++) {
            uint32_t type = section->flags & SECTION_TYPE;
            if (type != S_NON_LAZY_SYMBOL_POINTERS && type != S_LAZY_SYMBOL_POINTERS) continue;
            void **slots = (void **)(section->addr + slide);
            size_t count = section->size / sizeof(void *);
            for (size_t k = 0; k < count; k++) {
                uint32_t index = indirect[section->reserved1 + k];
                if (index == INDIRECT_SYMBOL_ABS || index == INDIRECT_SYMBOL_LOCAL ||
                    index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS) || index >= symtab->nsyms)
                    continue;
                const char *symbol = strings + symbols[index].n_un.n_strx;
                if (symbol[0] != '_' || strcmp(symbol + 1, name)) continue;
                uintptr_t page = (uintptr_t)&slots[k] & ~(uintptr_t)(getpagesize() - 1);
                mprotect((void *)page, getpagesize(), PROT_READ | PROT_WRITE);
                slots[k] = replacement;
                replaced++;
            }
        }
    }
    return replaced;
}

// Указатели на функции в обычных данных (таблицы функций, как у файловой системы движка: opendir/readdir там,
// а не в импорте) связаны dyld при загрузке — их находим по значению: слово, равное адресу функции.
static int mp_rebind_data(const struct mach_header_64 *header, intptr_t slide, void *const *originals,
                          void *const *replacements, size_t count)
{
    int replaced = 0;
    const struct load_command *cmd = (const void *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, cmd = (const void *)((const char *)cmd + cmd->cmdsize)) {
        if (cmd->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment = (const void *)cmd;
        if (strncmp(segment->segname, "__DATA", 6) && strncmp(segment->segname, "__AUTH", 6)) continue;
        const struct section_64 *section = (const void *)(segment + 1);
        for (uint32_t s = 0; s < segment->nsects; s++, section++) {
            uint32_t type = section->flags & SECTION_TYPE;
            if (type == S_NON_LAZY_SYMBOL_POINTERS || type == S_LAZY_SYMBOL_POINTERS || type == S_ZEROFILL ||
                type == S_MOD_INIT_FUNC_POINTERS || type == S_THREAD_LOCAL_VARIABLES || type == S_GB_ZEROFILL)
                continue;
            void **words = (void **)(section->addr + slide);
            size_t n = section->size / sizeof(void *);
            for (size_t k = 0; k < n; k++) {
                void *w = words[k];
                for (size_t h = 0; h < count; h++) {
                    if (!originals[h] || w != originals[h]) continue;
                    uintptr_t page = (uintptr_t)&words[k] & ~(uintptr_t)(getpagesize() - 1);
                    mprotect((void *)page, getpagesize(), PROT_READ | PROT_WRITE);
                    words[k] = replacements[h];
                    replaced++;
                    break;
                }
            }
        }
    }
    return replaced;
}

#pragma mark - Журнал файловых обращений

// Неудачные обращения игры к файлам (путь и errno) — чтобы видеть, что она ищет и не находит (и где мешает
// регистр имён: на iOS файловая система различает регистр, на macOS — нет).
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/mount.h>
#include <sys/stat.h>

static int mp_fs_logged;
enum { MP_FS_LIMIT = 3000 };

// MP_TRACE_FS=1 (переменная окружения): всё про сохранения и профили — и удачи, и промахи без фильтра.
static int mp_trace_fs = -1;
static int mp_tracing(const char *path)
{
    if (mp_trace_fs < 0) mp_trace_fs = getenv("MP_TRACE_FS") != NULL;
    return mp_trace_fs && path && (strstr(path, "Savegame") || strstr(path, "PlayerProfiles"));
}

static void mp_fs_fail(const char *call, const char *path)
{
    int saved = errno;
    if (mp_tracing(path)) {
        fprintf(stderr, "MPSystem: [трасса] %s %s: %s\n", call, path, strerror(saved));
        errno = saved;
        return;
    }
    // Движок проверяет, нет ли распакованной копии каждого ресурса и файла настроек, — эти промахи не пишем.
    if (saved == ENOENT && call[0] == 's' && path && (strstr(path, "/Contents/Data/") || strstr(path, "/Larian Studios/")))
        return;
    if (mp_fs_logged++ < MP_FS_LIMIT) fprintf(stderr, "MPSystem: %s %s: %s\n", call, path ? path : "(null)", strerror(saved));
    errno = saved;
}

static int mp_open(const char *path, int flags, ...)
{
    int mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, int);
        va_end(args);
    }
    int fd = open(path, flags, mode);
    if (fd < 0) mp_fs_fail("open", path);
    else if (mp_tracing(path)) fprintf(stderr, "MPSystem: [трасса] open %s (0x%x): fd %d\n", path, flags, fd);
    return fd;
}
static FILE *mp_fopen(const char *path, const char *mode)
{
    FILE *f = fopen(path, mode);
    if (!f) mp_fs_fail(mode[0] == 'r' ? "fopen r" : "fopen w", path);
    else if (mp_tracing(path)) fprintf(stderr, "MPSystem: [трасса] fopen %s (%s): ок\n", path, mode);
    return f;
}
// Движок перед чтением каждого ресурса из архива проверяет, нет ли его распакованной копии в Contents/Data
// (Public/…, Generated/…, Mods/…): на iOS stat из песочницы дорог — секунды на загрузку. В Data лежат только
// архивы и пара папок, поэтому путь, первая папка которого в Data не существует, отклоняется без вызова.
static const char *mp_data_dir;        // …/Contents/Data/
static char mp_data_entries[64][64];   // что лежит в Data
static int mp_data_count = -1;

static void mp_data_scan(void)
{
    mp_data_count = 0;
    DIR *d = opendir(mp_data_dir);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d)) && mp_data_count < 64)
        if (e->d_name[0] != '.') snprintf(mp_data_entries[mp_data_count++], 64, "%s", e->d_name);
    closedir(d);
}

static int mp_data_missing(const char *path)
{
    if (!mp_data_dir || !path) return 0;
    const char *at = strstr(path, "/Contents/Data/");
    if (!at) return 0;
    const char *first = at + strlen("/Contents/Data/");
    const char *slash = strchr(first, '/');
    if (!slash) return 0;  // сам файл в Data — проверяем по-настоящему
    if (mp_data_count < 0) mp_data_scan();
    size_t len = (size_t)(slash - first);
    for (int i = 0; i < mp_data_count; i++)
        if (strlen(mp_data_entries[i]) == len && !strncmp(mp_data_entries[i], first, len)) return 0;
    return 1;
}

static int mp_stat(const char *path, struct stat *st)
{
    if (mp_data_missing(path)) {
        errno = ENOENT;
        return -1;
    }
    int r = stat(path, st);
    if (r) mp_fs_fail("stat", path);
    else if (mp_tracing(path)) fprintf(stderr, "MPSystem: [трасса] stat %s: ок, %s\n", path, S_ISDIR(st->st_mode) ? "папка" : "файл");
    return r;
}
static int mp_access(const char *path, int mode)
{
    if (mp_data_missing(path)) {
        errno = ENOENT;
        return -1;
    }
    int r = access(path, mode);
    if (r) mp_fs_fail("access", path);
    return r;
}
static int mp_trace_dirs = 0;  // 1 — все открытые папки

// Папки сохранений — в журнал целиком (что открыто и что в ней нашлось): так видно, находит ли игра сохранения.
static DIR *mp_traced_dirs[16];

static DIR *mp_opendir(const char *path)
{
    DIR *d = opendir(path);
    if (!d) mp_fs_fail("opendir", path);
    else if (path && (strstr(path, "Savegames") || getenv("MP_TRACE_DIRS") || mp_trace_dirs)) {
        fprintf(stderr, "MPSystem: opendir %s\n", path);
        for (int i = 0; i < 16; i++)
            if (!mp_traced_dirs[i]) {
                mp_traced_dirs[i] = d;
                break;
            }
    }
    return d;
}

static struct dirent *mp_readdir(DIR *d)
{
    struct dirent *e = readdir(d);
    for (int i = 0; i < 16; i++)
        if (mp_traced_dirs[i] == d) {
            if (e) fprintf(stderr, "MPSystem:   %s (тип %d)\n", e->d_name, e->d_type);
            else mp_traced_dirs[i] = NULL;
        }
    return e;
}
static int mp_mkdir(const char *path, mode_t mode)
{
    int r = mkdir(path, mode);
    if (r && errno != EEXIST) mp_fs_fail("mkdir", path);
    return r;
}
static int mp_statfs(const char *path, struct statfs *st)
{
    int r = statfs(path, st);
    if (r) mp_fs_fail("statfs", path);
    return r;
}
static int mp_chdir(const char *path)
{
    int r = chdir(path);
    if (r) mp_fs_fail("chdir", path);
    else fprintf(stderr, "MPSystem: chdir %s\n", path);
    return r;
}

#pragma mark - Путь к программе

// Для игры процесс должен выглядеть как Mac-приложение: её файлы (Data, журналы) ищутся рядом с исполняемым
// файлом. Главный Mach-O приложения (…/Contents/MacOS/…) запоминается при загрузке; _NSGetExecutablePath
// в библиотеках игры отдаёт его путь, а argv[0] процесса меняется на него же, без «--mac ИМЯ» хоста.
#include <crt_externs.h>

static char *mp_executable_path;

static int mp_get_executable_path(char *buffer, uint32_t *size)
{
    uint32_t need = (uint32_t)strlen(mp_executable_path) + 1;
    if (*size < need) {
        *size = need;
        return -1;
    }
    memcpy(buffer, mp_executable_path, need);
    return 0;
}

static void mp_set_executable(const char *path)
{
    mp_executable_path = strdup(path);
    // …/X.app/Contents/MacOS/X → …/X.app/Contents/Data/
    char data[1024];
    snprintf(data, sizeof data, "%s", path);
    char *macos = strstr(data, "/Contents/MacOS/");
    if (macos) {
        strcpy(macos, "/Contents/Data/");
        mp_data_dir = strdup(data);
    }
    int *argc = _NSGetArgc();
    char **argv = *_NSGetArgv();
    int out = 0;
    argv[out++] = mp_executable_path;
    for (int i = 1; i < *argc; i++) {
        if (!strcmp(argv[i], "--mac") && i + 1 < *argc) {
            i++;
            continue;
        }
        argv[out++] = argv[i];
    }
    argv[out] = NULL;
    *argc = out;
    const char *name = strrchr(mp_executable_path, '/');
    setprogname(name ? name + 1 : mp_executable_path);
    fprintf(stderr, "MPSystem: программа %s, аргументов %d\n", mp_executable_path, out);
}

#pragma mark - Приоритеты потоков

// Движок опускает приоритет своим потокам загрузки (WT/Low/…). На Mac с десятком производительных ядер это
// не мешает, а iOS отправляет потоки с приоритетом ниже обычного (31) только на энергоэффективные ядра —
// загрузка уровня и меню тянется секундами. Ниже обычного приоритет не опускаем; повышать — пожалуйста.
#include <pthread.h>

// Поднимаются только потоки загрузки (WT/Low/…, приоритет 15). Планировщик заданий и стример текстур (23)
// ждут работы, крутясь в sched_yield: на быстром ядре такой поток сжигает его впустую (17 с из 40 в профиле).
enum { MP_DEFAULT_PRIORITY = 31, MP_LOW_PRIORITY_FLOOR = 20 };

static void mp_priority_note(const char *call, int requested)
{
    static int seen[128];
    if (requested >= 0 && requested < 128 && !seen[requested]++)
        fprintf(stderr, "MPSystem: %s приоритет %d%s\n", call, requested,
                requested < MP_LOW_PRIORITY_FLOOR ? " → 31" : "");
}

// Потоки движка получают класс QoS «инициировано пользователем»: по классу iOS решает, пускать ли поток на
// быстрые ядра. Явный приоритет (pthread_setschedparam) выводит поток из системы классов, и загрузчики, сервер
// одиночной игры и даже главный поток работали в основном на E-ядрах. Поэтому приоритеты движка при включённых
// классах не применяются. MP_QOS=0 (переменная окружения) — по-старому, для сравнения.
#include <pthread/qos.h>

static int mp_qos = -1;
static int mp_qos_enabled(void)
{
    if (mp_qos < 0) {
        const char *v = getenv("MP_QOS");
        mp_qos = !(v && v[0] == '0');
    }
    return mp_qos;
}

typedef struct {
    void *(*start)(void *);
    void *arg;
} MPThreadStart;

// MP_QOS_CLASS=ui — класс «интерактивный» (выше «инициированного пользователем»).
static qos_class_t mp_qos_class(void)
{
    const char *v = getenv("MP_QOS_CLASS");
    return v && !strcmp(v, "ui") ? QOS_CLASS_USER_INTERACTIVE : QOS_CLASS_USER_INITIATED;
}

static void *mp_thread_start(void *p)
{
    MPThreadStart s = *(MPThreadStart *)p;
    free(p);
    pthread_set_qos_class_self_np(mp_qos_class(), 0);
    return s.start(s.arg);
}

static int mp_pthread_create(pthread_t *thread, const pthread_attr_t *attr, void *(*start)(void *), void *arg)
{
    if (!mp_qos_enabled()) return pthread_create(thread, attr, start, arg);
    MPThreadStart *s = malloc(sizeof *s);
    s->start = start;
    s->arg = arg;
    // Атрибуты с явным приоритетом (inheritsched = explicit) отменили бы класс — создаём с классом по умолчанию.
    pthread_attr_t copy;
    if (attr) {
        copy = *attr;
        pthread_attr_setinheritsched(&copy, PTHREAD_INHERIT_SCHED);
        pthread_attr_set_qos_class_np(&copy, mp_qos_class(), 0);
    }
    int r = pthread_create(thread, attr ? &copy : NULL, mp_thread_start, s);
    if (r) free(s);
    return r;
}

static int mp_attr_setschedparam(pthread_attr_t *attr, const struct sched_param *param)
{
    if (mp_qos_enabled()) return 0;
    struct sched_param p = *param;
    mp_priority_note("pthread_attr_setschedparam", p.sched_priority);
    if (p.sched_priority < MP_LOW_PRIORITY_FLOOR) p.sched_priority = MP_DEFAULT_PRIORITY;
    return pthread_attr_setschedparam(attr, &p);
}

static int mp_setschedparam(pthread_t thread, int policy, const struct sched_param *param)
{
    struct sched_param p = *param;
    char name[64] = "";
    pthread_getname_np(thread, name, sizeof name);
    static int logged;
    if (logged++ < 64) fprintf(stderr, "MPSystem: поток «%s» приоритет %d\n", name, p.sched_priority);
    if (mp_qos_enabled()) return 0;
    if (p.sched_priority < MP_LOW_PRIORITY_FLOOR) p.sched_priority = MP_DEFAULT_PRIORITY;
    return pthread_setschedparam(thread, policy, &p);
}

// Ограничитель кадров (ls::GameClock::CapFrame) и планировщик заданий движка ждут в цикле «уступи процессор»
// (sched_yield / pthread_yield_np). На Mac это незаметно, а на телефоне два быстрых ядра из двух крутятся впустую
// (в профиле загрузки ~20 с процессора из 57) — греют телефон и отнимают ядра у загрузки. Вместо уступки —
// сон на 50 мкс: для кадра в 8–16 мс задержка ничтожная.
// MP_YIELD=0 (переменная окружения) — уступка как у движка, без сна (для сравнения).
static int mp_yield_sleep = -1;
#include <stdatomic.h>
static _Atomic uint64_t mp_yield_calls;  // для отчёта MP_CPU_PROFILE: сколько раз потоки уступали ядро

static int mp_sched_yield(void)
{
    atomic_fetch_add_explicit(&mp_yield_calls, 1, memory_order_relaxed);
    if (mp_yield_sleep < 0) mp_yield_sleep = !(getenv("MP_YIELD") && getenv("MP_YIELD")[0] == '0');
    if (!mp_yield_sleep) return sched_yield();
    usleep(50);
    return 0;
}
static void mp_pthread_yield_np(void) { mp_sched_yield(); }

#pragma mark - Число ядер для движка

// Пулы потоков движок считает по hw.logicalcpu_max/physicalcpu_max: на 6 ядрах iPhone — 3 «быстрых» и 3
// «медленных» потока, и модели после загрузки уровня распаковывают только три последних. MP_CPUS=N
// (переменная окружения) — сколько ядер сообщать движку; без неё — сколько есть.
#include <sys/sysctl.h>

static int mp_sysctlbyname(const char *name, void *old, size_t *oldlen, void *newp, size_t newlen)
{
    int r = sysctlbyname(name, old, oldlen, newp, newlen);
    const char *cpus = getenv("MP_CPUS");
    if (!r && cpus && old && oldlen && *oldlen == sizeof(int) &&
        (!strcmp(name, "hw.logicalcpu_max") || !strcmp(name, "hw.physicalcpu_max") || !strcmp(name, "hw.ncpu") ||
         !strcmp(name, "hw.logicalcpu") || !strcmp(name, "hw.physicalcpu") || !strcmp(name, "hw.activecpu"))) {
        fprintf(stderr, "MPSystem: %s = %d → %s\n", name, *(int *)old, cpus);
        *(int *)old = atoi(cpus);
    }
    return r;
}

#pragma mark - Загрузка процессора по потокам

// MP_CPU_PROFILE=1: раз в 10 с — процессорное время каждого потока за окно (task_threads + thread_info), в % ядра.
#include <mach/mach.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <sys/resource.h>

int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);  // libproc: в SDK iOS не объявлена

// Процесс целиком за окно: доля времени на производительных ядрах, время готовых к работе потоков, которым не
// досталось ядра (очередь к процессору), средняя частота (циклы / время) и инструкции за такт.
static int mp_boost_count, mp_boost_on;  // подъём потоков кадра (MP_BOOST, ниже)
static int mp_rt_on;                     // главный поток в реальном времени (MP_RT, ниже)

static void mp_cpu_cores_report(void)
{
    static struct rusage_info_v6 last;
    struct rusage_info_v6 now;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&now) != 0) return;
    if (last.ri_user_time) {
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        double tick = (double)tb.numer / tb.denom / 1e9;  // ri_*_time — тики mach_absolute_time
        double cpu = (now.ri_user_time + now.ri_system_time - last.ri_user_time - last.ri_system_time) * tick;
        double pcpu = (now.ri_user_ptime + now.ri_system_ptime - last.ri_user_ptime - last.ri_system_ptime) * tick;
        double runnable = (now.ri_runnable_time - last.ri_runnable_time) * tick;
        double cycles = now.ri_cycles - last.ri_cycles, pcycles = now.ri_pcycles - last.ri_pcycles;
        double instr = now.ri_instructions - last.ri_instructions;
        static uint64_t last_yields, last_frames;
        uint64_t yields = atomic_load(&mp_yield_calls);
        typedef uint64_t (*frames_fn)(void);
        frames_fn frames_now = (frames_fn)dlsym(RTLD_DEFAULT, "mp_metal_frames");
        uint64_t frames = frames_now ? frames_now() : 0;
        if (getenv("MP_BOOST"))
            fprintf(stderr, "MPSystem: окно %s: кадров/с %.1f, подъём потоков: %d\n",
                    mp_boost_on ? "С ПОДЪЁМОМ" : "без подъёма", (frames - last_frames) / 10.0, mp_boost_count);
        if (getenv("MP_RT"))
            fprintf(stderr, "MPSystem: окно %s: кадров/с %.1f\n", mp_rt_on ? "РЕАЛЬНОЕ ВРЕМЯ" : "обычный поток",
                    (frames - last_frames) / 10.0);
        last_frames = frames;
        fprintf(stderr,
                "MPSystem: ядра за 10 с: на P-ядрах %.0f%% времени процессора (%.2f из %.2f ядра), ждали ядра %.0f%% "
                "ядра; частота P %.2f ГГц, E %.2f ГГц; инструкций за такт %.2f; уступок ядра %.0f в секунду\n",
                cpu > 0 ? pcpu / cpu * 100 : 0, pcpu / 10, cpu / 10, runnable * 10,
                pcpu > 0 ? pcycles / pcpu / 1e9 : 0, cpu > pcpu ? (cycles - pcycles) / (cpu - pcpu) / 1e9 : 0,
                cycles > 0 ? instr / cycles : 0, (yields - last_yields) / 10.0);
        last_yields = yields;
    }
    last = now;
}

typedef struct {
    uint64_t id;
    double seconds;
} MPThreadTime;

static pthread_t mp_main_thread;  // поток, на котором загрузилась программа (у игры — цикл кадров)

static void mp_cpu_report(void)
{
    static MPThreadTime last[256];
    static int last_count;
    thread_act_array_t threads;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return;
    MPThreadTime now[256];
    char names[256][64];
    double used[256];
    int n = 0;
    for (mach_msg_type_number_t i = 0; i < count && n < 256; i++) {
        thread_basic_info_data_t basic;
        mach_msg_type_number_t size = THREAD_BASIC_INFO_COUNT;
        thread_identifier_info_data_t ident;
        mach_msg_type_number_t isize = THREAD_IDENTIFIER_INFO_COUNT;
        if (thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&basic, &size) == KERN_SUCCESS &&
            thread_info(threads[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ident, &isize) == KERN_SUCCESS) {
            double s = basic.user_time.seconds + basic.user_time.microseconds / 1e6 + basic.system_time.seconds +
                       basic.system_time.microseconds / 1e6;
            now[n].id = ident.thread_id;
            now[n].seconds = s;
            used[n] = 0;
            for (int k = 0; k < last_count; k++)
                if (last[k].id == ident.thread_id) used[n] = s - last[k].seconds;
            names[n][0] = 0;
            pthread_t pt = pthread_from_mach_thread_np(threads[i]);
            if (pt) pthread_getname_np(pt, names[n], sizeof names[n]);
            if (!names[n][0] && pt == mp_main_thread) snprintf(names[n], sizeof names[n], "главный");
            if (!names[n][0]) snprintf(names[n], sizeof names[n], "поток %llu", ident.thread_id);
            // Класс QoS потока: от него зависит, пустит ли планировщик поток на производительные ядра.
            qos_class_t qos = QOS_CLASS_UNSPECIFIED;
            int relative = 0;
            if (pt) pthread_get_qos_class_np(pt, &qos, &relative);
            const char *tag = qos == QOS_CLASS_USER_INTERACTIVE ? "ui" : qos == QOS_CLASS_USER_INITIATED ? "in"
                            : qos == QOS_CLASS_DEFAULT ? "df" : qos == QOS_CLASS_UTILITY ? "ut"
                            : qos == QOS_CLASS_BACKGROUND ? "bg" : "—";
            size_t len = strlen(names[n]);
            struct thread_extended_info ext;
            mach_msg_type_number_t esize = THREAD_EXTENDED_INFO_COUNT;
            int priority = thread_info(threads[i], THREAD_EXTENDED_INFO, (thread_info_t)&ext, &esize) == KERN_SUCCESS
                               ? ext.pth_curpri : -1;
            snprintf(names[n] + len, sizeof names[n] - len, " [%s, %d]", tag, priority);
            n++;
        }
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_act_t));
    double total = 0;
    for (int i = 0; i < n; i++) total += used[i];
    // Восемь самых занятых.
    int order[256];
    for (int i = 0; i < n; i++) order[i] = i;
    for (int i = 0; i < n; i++)
        for (int j = i + 1; j < n; j++)
            if (used[order[j]] > used[order[i]]) {
                int x = order[i];
                order[i] = order[j];
                order[j] = x;
            }
    if (last_count) {
        fprintf(stderr, "MPSystem: процессор за 10 с: всего %.0f%% ядра (%d потоков):", total * 10, n);
        for (int i = 0; i < n && i < 8; i++) fprintf(stderr, " %s %.0f%%;", names[order[i]], used[order[i]] * 10);
        fputc('\n', stderr);
    }
    memcpy(last, now, n * sizeof *now);
    last_count = n;
}

#pragma mark - Подъём приоритета потоков кадра

// MP_BOOST=ПРЕФИКС[,ПРЕФИКС…]: потоки, чьё имя начинается с префикса (например GameThread,WT/High), поднимаются
// до USER_INTERACTIVE поверх своего QoS (pthread_override_qos_class_start_np): когда ядер не хватает, они идут
// раньше серверной логики (ServerWorker) и фоновых задач. MP_BOOST_ALTERNATE=1 — через окно отчёта: сравнение
// в одном запуске. Включается вместе с MP_CPU_PROFILE.
enum { MPBoostMax = 64 };
static pthread_override_t mp_boosts[MPBoostMax];
static int mp_boost_count, mp_boost_on;

static void mp_boost_set(int on)
{
    const char *list = getenv("MP_BOOST");
    if (!list || !*list) return;
    for (int i = 0; i < mp_boost_count; i++) pthread_override_qos_class_end_np(mp_boosts[i]);
    mp_boost_count = 0;
    mp_boost_on = on;
    if (!on) return;
    thread_act_array_t threads;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return;
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        pthread_t pt = pthread_from_mach_thread_np(threads[i]);
        char name[64] = "";
        if (pt) pthread_getname_np(pt, name, sizeof name);
        char copy[256];
        snprintf(copy, sizeof copy, "%s", list);
        for (char *save = NULL, *prefix = strtok_r(copy, ",", &save); prefix && name[0];
             prefix = strtok_r(NULL, ",", &save)) {
            if (strncmp(name, prefix, strlen(prefix)) || mp_boost_count >= MPBoostMax) continue;
            mp_boosts[mp_boost_count++] = pthread_override_qos_class_start_np(pt, QOS_CLASS_USER_INTERACTIVE, 0);
            break;
        }
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_act_t));
}

#pragma mark - Главный поток в реальном времени

// MP_RT=ПЕРИОД_МС[,СЧЁТ_МС]: главный поток (у игры на нём цикл кадров и вся отрисовка) — поток реального времени
// (THREAD_TIME_CONSTRAINT_POLICY: каждые ПЕРИОД мс нужно СЧЁТ мс процессора, срок — период), как звуковые потоки:
// опыт — даст ли iOS ему производительные ядра. MP_RT_ALTERNATE=1 — через окно отчёта (с MP_CPU_PROFILE).
#include <mach/thread_policy.h>

static int mp_rt_on;

static void mp_rt_set(int on)
{
    const char *rt = getenv("MP_RT");
    if (!rt || !*rt) return;
    double period = 33, computation = 0;
    sscanf(rt, "%lf,%lf", &period, &computation);
    if (computation <= 0 || computation > period) computation = period * 0.8;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    double ticks_per_ms = 1e6 * tb.denom / tb.numer;
    thread_act_t thread = pthread_mach_thread_np(mp_main_thread);
    kern_return_t kr;
    if (on) {
        thread_time_constraint_policy_data_t policy = {
            .period = (uint32_t)(period * ticks_per_ms),
            .computation = (uint32_t)(computation * ticks_per_ms),
            .constraint = (uint32_t)(period * ticks_per_ms),
            .preemptible = 1,
        };
        kr = thread_policy_set(thread, THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&policy,
                               THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    } else {
        thread_standard_policy_data_t policy = {0};
        kr = thread_policy_set(thread, THREAD_STANDARD_POLICY, (thread_policy_t)&policy, THREAD_STANDARD_POLICY_COUNT);
    }
    if (kr != KERN_SUCCESS) fprintf(stderr, "MPSystem: реальное время главного потока: ошибка %d\n", kr);
    mp_rt_on = on && kr == KERN_SUCCESS;
}

#pragma mark - Сэмплер стеков

// MP_SAMPLE=ПОТОК[,ПОТОК…] — имена pthread («главный» — поток загрузки, у игры на нём цикл кадров): 500 раз
// в секунду поток останавливается (thread_suspend), по цепочке x29 снимаются адреса возврата. Ключ — первые четыре
// адреса в коде игры (Contents/MacOS) и признак «ждёт» (поток стоит в системном вызове: PC в libsystem_kernel).
// Раз в 10 с — доля ожидания и частые ключи каждого потока; адреса — без сдвига ASLR, как в файле игры:
// подписи — atos -o БИНАРНИК АДРЕС…
#include <mach-o/getsect.h>

enum { MPSampleThreads = 4, MPSampleSlots = 4096, MPSampleDepth = 4 };
typedef struct {
    uint64_t key[MPSampleDepth];
    uint32_t count;
    uint8_t wait;
} MPSample;
static MPSample mp_samples[MPSampleThreads][MPSampleSlots];
static uint32_t mp_sample_total[MPSampleThreads], mp_sample_waits[MPSampleThreads];
static char mp_sample_names[MPSampleThreads][64];
static int mp_sample_count;
static uintptr_t mp_game_start, mp_game_end, mp_game_slide, mp_kernel_start, mp_kernel_end;

static void mp_text_range(const char *part, uintptr_t *start, uintptr_t *end, uintptr_t *slide)
{
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, part) || strstr(name, "/MP")) continue;
        unsigned long size = 0;
        uint8_t *text = getsegmentdata((const struct mach_header_64 *)_dyld_get_image_header(i), "__TEXT", &size);
        *start = (uintptr_t)text;
        *end = (uintptr_t)text + size;
        if (slide) *slide = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
        return;
    }
}

static thread_act_t mp_find_thread(const char *want)
{
    thread_act_array_t threads;
    mach_msg_type_number_t count = 0;
    thread_act_t found = MACH_PORT_NULL;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return found;
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        pthread_t pt = pthread_from_mach_thread_np(threads[i]);
        char name[64] = "";
        if (pt) pthread_getname_np(pt, name, sizeof name);
        if (!found && pt && (strcmp(name, want) == 0 || (strcmp(want, "главный") == 0 && pt == mp_main_thread)))
            found = threads[i];
        else
            mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_act_t));
    return found;
}

static void mp_sample_one(int index, thread_act_t thread)
{
    pthread_t pt = pthread_from_mach_thread_np(thread);
    if (!pt) return;
    uintptr_t top = (uintptr_t)pthread_get_stackaddr_np(pt), bottom = top - pthread_get_stacksize_np(pt);
    arm_thread_state64_t state;
    mach_msg_type_number_t size = ARM_THREAD_STATE64_COUNT;
    uint64_t key[MPSampleDepth] = {0};
    int depth = 0, wait = 0;
    if (thread_suspend(thread) != KERN_SUCCESS) return;
    if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &size) == KERN_SUCCESS) {
        uintptr_t pc = arm_thread_state64_get_pc(state) & 0x7FFFFFFFFFull;
        uintptr_t fp = arm_thread_state64_get_fp(state);
        wait = pc >= mp_kernel_start && pc < mp_kernel_end;
        if (pc >= mp_game_start && pc < mp_game_end) key[depth++] = pc - mp_game_slide;
        for (int frame = 0; frame < 64 && depth < MPSampleDepth; frame++) {
            if (fp < bottom || fp + 16 > top || (fp & 15)) break;
            uintptr_t next = ((uintptr_t *)fp)[0], ret = ((uintptr_t *)fp)[1] & 0x7FFFFFFFFFull;
            if (ret >= mp_game_start && ret < mp_game_end) key[depth++] = ret - mp_game_slide;
            if (next <= fp) break;
            fp = next;
        }
    }
    thread_resume(thread);
    mp_sample_total[index]++;
    mp_sample_waits[index] += wait;
    uint64_t hash = key[0] * 31 + key[1] * 17 + key[2] * 7 + key[3] + wait;
    for (uint32_t probe = 0; probe < MPSampleSlots; probe++) {
        MPSample *s = &mp_samples[index][(hash + probe) % MPSampleSlots];
        if (!s->count) {
            memcpy(s->key, key, sizeof key);
            s->wait = wait;
        } else if (memcmp(s->key, key, sizeof key) || s->wait != wait) {
            continue;
        }
        s->count++;
        return;
    }
}

static int mp_sample_compare(const void *a, const void *b)
{
    return (int)((const MPSample *)b)->count - (int)((const MPSample *)a)->count;
}

static void mp_sample_report(void)
{
    for (int t = 0; t < mp_sample_count; t++) {
        uint32_t total = mp_sample_total[t];
        if (!total) continue;
        fprintf(stderr, "MPSystem: стеки «%s»: %u выборок, ждёт в системном вызове %.0f%%\n", mp_sample_names[t], total,
                mp_sample_waits[t] * 100.0 / total);
        qsort(mp_samples[t], MPSampleSlots, sizeof(MPSample), mp_sample_compare);
        for (int i = 0; i < 12 && mp_samples[t][i].count; i++) {
            MPSample *s = &mp_samples[t][i];
            fprintf(stderr, "MPSystem:   %4.1f%% %s %#llx %#llx %#llx %#llx\n", s->count * 100.0 / total,
                    s->wait ? "ждёт" : "счёт", s->key[0], s->key[1], s->key[2], s->key[3]);
        }
        memset(mp_samples[t], 0, sizeof mp_samples[t]);
        mp_sample_total[t] = mp_sample_waits[t] = 0;
    }
}

static void *mp_sampler(void *arg)
{
    (void)arg;
    pthread_setname_np("MPSampler");
    sleep(10);
    mp_text_range("/Contents/MacOS/", &mp_game_start, &mp_game_end, &mp_game_slide);
    mp_text_range("libsystem_kernel.dylib", &mp_kernel_start, &mp_kernel_end, NULL);
    thread_act_t threads[MPSampleThreads] = {0};
    uint64_t window = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    for (;;) {
        for (int t = 0; t < mp_sample_count; t++) {
            if (!threads[t]) threads[t] = mp_find_thread(mp_sample_names[t]);
            if (threads[t]) mp_sample_one(t, threads[t]);
        }
        usleep(2000);
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (now - window >= 10 * NSEC_PER_SEC) {
            mp_sample_report();
            window = now;
        }
    }
    return NULL;
}

static void mp_sampler_start(void)
{
    const char *list = getenv("MP_SAMPLE");
    if (!list || !*list) return;
    char copy[256];
    snprintf(copy, sizeof copy, "%s", list);
    for (char *name = strtok(copy, ","); name && mp_sample_count < MPSampleThreads; name = strtok(NULL, ","))
        snprintf(mp_sample_names[mp_sample_count++], sizeof mp_sample_names[0], "%s", name);
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
    pthread_t thread;
    pthread_create(&thread, &attr, mp_sampler, NULL);
    pthread_attr_destroy(&attr);
}

static void mp_cpu_profile_start(void)
{
    mp_main_thread = pthread_self();
    mp_sampler_start();
    if (!getenv("MP_CPU_PROFILE") || getenv("MP_CPU_PROFILE")[0] != '1') return;
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        mp_cpu_report();
        mp_cpu_cores_report();
        // Новые потоки появляются после загрузки: подъём пересобирается каждое окно.
        int alternate = getenv("MP_BOOST_ALTERNATE") && getenv("MP_BOOST_ALTERNATE")[0] == '1';
        mp_boost_set(alternate ? !mp_boost_on : 1);
        int rt_alternate = getenv("MP_RT_ALTERNATE") && getenv("MP_RT_ALTERNATE")[0] == '1';
        mp_rt_set(rt_alternate ? !mp_rt_on : 1);
    });
    dispatch_resume(timer);
}

static struct {
    const char *name;
    void *replacement;
    void *original;
} mp_hooks[] = {
    {"__cxa_throw", (void *)mp_throw}, {"open", (void *)mp_open},     {"fopen", (void *)mp_fopen},
    {"stat", (void *)mp_stat},         {"access", (void *)mp_access}, {"opendir", (void *)mp_opendir},
    {"mkdir", (void *)mp_mkdir},       {"statfs", (void *)mp_statfs}, {"chdir", (void *)mp_chdir},
    {"_NSGetExecutablePath", (void *)mp_get_executable_path},
    {"readdir", (void *)mp_readdir},
    {"pthread_create", (void *)mp_pthread_create},
    {"sysctlbyname", (void *)mp_sysctlbyname},
    {"pthread_attr_setschedparam", (void *)mp_attr_setschedparam},
    {"pthread_setschedparam", (void *)mp_setschedparam},
    {"sched_yield", (void *)mp_sched_yield},
    {"pthread_yield_np", (void *)mp_pthread_yield_np},
};

static void mp_image_added(const struct mach_header *header, intptr_t slide)
{
    Dl_info info;
    if (!dladdr(header, &info) || !info.dli_fname) return;
    // Только Mach-O самого приложения (Contents/MacOS, Contents/Frameworks), не системные и не наши.
    if (!strstr(info.dli_fname, "/Contents/") || strstr(info.dli_fname, "/MP")) return;
    if (!mp_executable_path && strstr(info.dli_fname, "/Contents/MacOS/")) mp_set_executable(info.dli_fname);
    size_t count = sizeof mp_hooks / sizeof *mp_hooks;
    void *originals[count], *replacements[count];
    for (size_t i = 0; i < count; i++) {
        if (mp_hooks[i].original)
            mp_rebind((const struct mach_header_64 *)header, slide, mp_hooks[i].name, mp_hooks[i].replacement);
        originals[i] = mp_hooks[i].original;
        replacements[i] = mp_hooks[i].replacement;
    }
    int data = mp_rebind_data((const struct mach_header_64 *)header, slide, originals, replacements, count);
    if (data) {
        const char *file = strrchr(info.dli_fname, '/');
        fprintf(stderr, "MPSystem: %s — указателей в данных подменено: %d\n", file ? file + 1 : info.dli_fname, data);
    }
}

// Игра может выйти сама (exit), не падая: тогда в журнал — откуда.
static void mp_on_exit(void)
{
    fprintf(stderr, "MPSystem: exit\n");
    mp_backtrace();
}

__attribute__((constructor)) static void mp_trace_init(void)
{
    mp_cpu_profile_start();
    atexit(mp_on_exit);
    mp_real_throw = (cxa_throw_fn)dlsym(RTLD_DEFAULT, "__cxa_throw");
    for (size_t i = 0; i < sizeof mp_hooks / sizeof *mp_hooks; i++) mp_hooks[i].original = dlsym(RTLD_DEFAULT, mp_hooks[i].name);
    _dyld_register_func_for_add_image(mp_image_added);
    mp_previous_preprocessor = objc_setExceptionPreprocessor(mp_objc_exception);
}
