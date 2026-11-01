#import "WPProbe.h"
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <mach-o/dyld.h>
#import <mach-o/fat.h>
#import <mach-o/getsect.h>
#import <mach-o/loader.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <signal.h>
#import <sys/ucontext.h>
#import <mach/mach.h>


// dlsym goes through Nyxian's hook and can be slow; symbols are looked up once.
static void *WPCachedDlsym(const char *name) {
    static NSMutableDictionary<NSString *, NSValue *> *cache;
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; lock = [NSLock new]; });
    NSString *key = @(name);
    [lock lock];
    NSValue *v = cache[key];
    [lock unlock];
    if (v) return v.pointerValue;
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p) {
        [lock lock];
        cache[key] = [NSValue valueWithPointer:p];
        [lock unlock];
    }
    return p;
}
#define dlsym(handle, name) WPCachedDlsym(name)

#pragma mark - Swift runtime glue (C, swiftcall)

#define SWIFTCALL __attribute__((swiftcall))

typedef struct {
    const void *metadata;
    size_t state;
} WPMetadataResponse;

typedef struct {
    const char *data;
    uintptr_t length;
} WPTypeNamePair;

typedef WPMetadataResponse (*WPMetadataAccessor)(size_t request) SWIFTCALL;
typedef WPTypeNamePair (*WPGetTypeName)(const void *type, bool qualified) SWIFTCALL;
typedef const void *(*WPConformsToProtocol)(const void *type, const void *protocol);
typedef WPMetadataResponse (*WPGetAssociatedTypeWitness)(size_t request, const void *wtable, const void *conformingType,
                                                         const void *reqBase, const void *assocType) SWIFTCALL;

// Relative pointer helpers for Swift metadata records.
static const void *WPRelDirect(const int32_t *field) {
    if (*field == 0) return NULL;
    return (const char *)field + *field;
}

static const void *WPRelIndirectable(const int32_t *field) {
    int32_t v = *field;
    if (v == 0) return NULL;
    const char *p = (const char *)field + (v & ~1);
    if (v & 1) return *(const void *const *)p;
    return p;
}

typedef struct {
    int32_t protocol;
    int32_t typeRef;
    int32_t witnessTablePattern;
    uint32_t flags;
} WPConformanceDescriptor;

#pragma mark - Model

@implementation WPWidgetExtension
@end

#pragma mark - Crash markers

static NSString *WPMarkerPath(NSString *name, NSString *suffix) {
    return [[[WPProbe reportPath] stringByDeletingLastPathComponent] stringByAppendingPathComponent:[name stringByAppendingString:suffix]];
}

BOOL WPMarkerTripped(NSString *name) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *running = WPMarkerPath(name, @".running"), *bad = WPMarkerPath(name, @".bad");
    NSString *owner = [NSString stringWithContentsOfFile:running encoding:NSUTF8StringEncoding error:nil];
    if (owner && owner.intValue != getpid()) { // left by an earlier SpringBoard: that one crashed
        [fm removeItemAtPath:bad error:nil];
        [fm moveItemAtPath:running toPath:bad error:nil];
    }
    return [fm fileExistsAtPath:bad];
}

void WPMarkerBegin(NSString *name) {
    [[NSString stringWithFormat:@"%d", getpid()] writeToFile:WPMarkerPath(name, @".running") atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

void WPMarkerEnd(NSString *name) {
    [[NSFileManager defaultManager] removeItemAtPath:WPMarkerPath(name, @".running") error:nil];
}

#pragma mark - Logging

static NSString *gWPLogPath; // overrides report.txt (the home screen runtime logs elsewhere)
static BOOL gWPQuiet;        // details (the widget's type tree) stay in memory

BOOL WPDiagnosticLogEnabled(void); // WPSettings.m

static void WPAppend(NSMutableString *log, NSString *line) {
    [log appendString:line];
    [log appendString:@"\n"];
    if (gWPQuiet || ![NSThread isMainThread]) return; // background work is written by its caller
    if (!WPDiagnosticLogEnabled()) return;             // the diagnostic log is off (the default)
    NSString *path = gWPLogPath ?: [WPProbe reportPath];
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        write(fd, data.bytes, data.length);
        fsync(fd);
        close(fd);
    }
    NSLog(@"[WidgetProbe] %@", line);
}

// While quiet (reading a widget's type tree on the main thread), or with the diagnostic log
// off, the line is not even built.
#define WPLOG(log, fmt, ...) do { if (!gWPQuiet && WPDiagnosticLogEnabled()) WPAppend(log, [NSString stringWithFormat:fmt, ##__VA_ARGS__]); } while (0)

#pragma mark - Mach-O inspection

// Install names the binary links through @rpath (these are the only ones that need
// to be found in the app's or the extension's Frameworks folder).
static NSArray<NSString *> *WPRpathDependencies(NSString *path) {
    NSMutableArray *out = [NSMutableArray array];
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (data.length < sizeof(struct mach_header_64)) return out;
    const uint8_t *base = data.bytes;
    size_t offset = 0;
    uint32_t magic = *(const uint32_t *)base;
    if (magic == FAT_CIGAM || magic == FAT_MAGIC) {
        const struct fat_header *fh = (const void *)base;
        const struct fat_arch *archs = (const void *)(fh + 1);
        for (uint32_t i = 0; i < OSSwapBigToHostInt32(fh->nfat_arch); i++) {
            if ((cpu_type_t)OSSwapBigToHostInt32(archs[i].cputype) == CPU_TYPE_ARM64 &&
                (OSSwapBigToHostInt32(archs[i].cpusubtype) & ~CPU_SUBTYPE_MASK) != CPU_SUBTYPE_ARM64E) {
                offset = OSSwapBigToHostInt32(archs[i].offset);
                break;
            }
        }
    }
    if (offset + sizeof(struct mach_header_64) > data.length) return out;
    const struct mach_header_64 *mh = (const void *)(base + offset);
    if (mh->magic != MH_MAGIC_64) return out;
    const uint8_t *cmd = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const void *)cmd;
        if ((const uint8_t *)lc + sizeof(*lc) > base + data.length || lc->cmdsize == 0) break;
        if (lc->cmd == LC_LOAD_DYLIB || lc->cmd == LC_LOAD_WEAK_DYLIB) {
            const struct dylib_command *d = (const void *)lc;
            NSString *n = @((const char *)lc + d->dylib.name.offset);
            if ([n hasPrefix:@"@rpath/"]) [out addObject:[n substringFromIndex:7]];
        }
        cmd += lc->cmdsize;
    }
    return out;
}

#pragma mark - Finding extensions

@implementation WPProbe

+ (NSString *)workDirectory {
    const char *home = getenv("HOME");
    NSString *dir = [(home ? @(home) : NSHomeDirectory()) stringByAppendingPathComponent:@"Library/Caches/SwitzachWidgetProbe"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

+ (NSString *)reportPath {
    return [[self workDirectory] stringByAppendingPathComponent:@"report.txt"];
}

+ (NSArray *)installedApplicationProxies {
    Class ws = NSClassFromString(@"LSApplicationWorkspace");
    if (!ws) return @[];
    id workspace = ((id (*)(id, SEL))objc_msgSend)(ws, NSSelectorFromString(@"defaultWorkspace"));
    SEL sel = NSSelectorFromString(@"allInstalledApplications");
    if (![workspace respondsToSelector:sel]) sel = NSSelectorFromString(@"allApplications");
    if (![workspace respondsToSelector:sel]) return @[];
    NSArray *apps = ((id (*)(id, SEL))objc_msgSend)(workspace, sel);
    return [apps isKindOfClass:[NSArray class]] ? apps : @[];
}

static id WPValue(id obj, NSString *key) {
    @try {
        return [obj valueForKey:key];
    } @catch (NSException *e) {
        return nil;
    }
}

+ (NSArray<WPWidgetExtension *> *)findWidgetExtensionsWithLog:(NSMutableString *)log {
    NSMutableArray<WPWidgetExtension *> *found = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *apps = [self installedApplicationProxies];
    WPLOG(log, @"== Apps (%lu)", (unsigned long)apps.count);

    for (id proxy in apps) {
        NSURL *bundleURL = WPValue(proxy, @"bundleURL");
        NSString *bundleID = WPValue(proxy, @"bundleIdentifier") ?: @"?";
        NSString *name = WPValue(proxy, @"localizedName") ?: bundleID;
        if (![bundleURL isKindOfClass:[NSURL class]]) continue;
        NSString *appPath = bundleURL.path;
        NSString *plugins = [appPath stringByAppendingPathComponent:@"PlugIns"];
        NSArray *items = [fm contentsOfDirectoryAtPath:plugins error:nil];
        if (items.count == 0) continue;
        WPLOG(log, @"- %@ (%@) %lu extension(s)", name, bundleID, (unsigned long)items.count);

        for (NSString *item in items) {
            if (![item.pathExtension isEqualToString:@"appex"]) continue;
            NSString *extPath = [plugins stringByAppendingPathComponent:item];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[extPath stringByAppendingPathComponent:@"Info.plist"]];
            NSDictionary *ext = info[@"NSExtension"];
            NSString *point = [ext isKindOfClass:[NSDictionary class]] ? ext[@"NSExtensionPointIdentifier"] : nil;
            WPLOG(log, @"    %@ : %@", item, point ?: @"(no extension point)");
            if (![point isEqualToString:@"com.apple.widgetkit-extension"]) continue;

            WPWidgetExtension *w = [WPWidgetExtension new];
            w.appName = name;
            w.appBundleID = bundleID;
            w.appPath = appPath;
            w.extensionPath = extPath;
            w.extensionBundleID = info[@"CFBundleIdentifier"] ?: item;
            NSString *exe = info[@"CFBundleExecutable"] ?: item.stringByDeletingPathExtension;
            w.executablePath = [extPath stringByAppendingPathComponent:exe];
            NSURL *dataURL = WPValue(proxy, @"dataContainerURL");
            if ([dataURL isKindOfClass:[NSURL class]]) w.dataContainerPath = dataURL.path;
            [found addObject:w];
        }
    }
    WPLOG(log, @"== Widget extensions: %lu", (unsigned long)found.count);
    return found;
}

#pragma mark - Load test

static int64_t (*WPLiveShimSyscall(void))(uint32_t, ...) {
    return (int64_t (*)(uint32_t, ...))dlsym(RTLD_DEFAULT, "liveshim_syscall");
}

static const uint32_t kWPSysSign = 761; // SYS_sign in Nyxian's ksurface ABI

// Loads only the @rpath libraries the extension actually links, looking for them in
// the given folders. Loading anything else (an app's protection or DRM libraries)
// into SpringBoard is unnecessary and can take it down.
// Loads @rpath dependencies from the app's / extension's Frameworks folders, each one's own
// @rpath dependencies first: their install names then match images already loaded.
static BOOL WPPreloadOne(NSString *item, NSArray<NSString *> *dirs, NSMutableSet *visited, NSMutableString *log, int depth) {
    if ([visited containsObject:item] || depth > 12) return YES;
    [visited addObject:item];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *binary = nil;
    for (NSString *dir in dirs) {
        NSString *candidate = [dir stringByAppendingPathComponent:item];
        if ([fm fileExistsAtPath:candidate]) { binary = candidate; break; }
    }
    if (!binary) {
        if (![item hasPrefix:@"libswift"]) WPLOG(log, @"    Not found: @rpath/%@", item);
        return [item hasPrefix:@"libswift"];
    }
    for (NSString *dep in WPRpathDependencies(binary)) WPPreloadOne(dep, dirs, visited, log, depth + 1);
    void *h = dlopen(binary.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    if (h) {
        WPLOG(log, @"    preload OK: %@", item);
        return YES;
    }
    const char *err = dlerror();
    WPLOG(log, @"    preload NG: %@ — %s", item, err ?: "?");
    return NO;
}

static BOOL WPPreloadDependencies(NSArray<NSString *> *deps, NSArray<NSString *> *dirs, NSMutableString *log) {
    NSMutableSet *visited = [NSMutableSet set];
    BOOL ok = YES;
    for (NSString *item in deps) ok = WPPreloadOne(item, dirs, visited, log, 0) && ok;
    return ok;
}

// Nyxian's _dyld_get_image_name hook searches every image on each call, so walking all
// images that way is quadratic. Keep our own list, filled by the add-image callback.
static NSMutableArray<NSArray *> *gWPImages; // @[ path, NSValue(header), NSNumber(slide) ]
static NSLock *gWPImagesLock;

static void WPImageAdded(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    if (!dladdr(mh, &info) || !info.dli_fname) return;
    [gWPImagesLock lock];
    [gWPImages addObject:@[ @(info.dli_fname), [NSValue valueWithPointer:mh], @(slide) ]];
    [gWPImagesLock unlock];
}

static NSArray<NSArray *> *WPLoadedImages(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWPImages = [NSMutableArray array];
        gWPImagesLock = [NSLock new];
        _dyld_register_func_for_add_image(WPImageAdded);
    });
    [gWPImagesLock lock];
    NSArray *copy = [gWPImages copy];
    [gWPImagesLock unlock];
    return copy;
}

static const struct mach_header *WPFindLoadedImage(NSString *path, intptr_t *slideOut) {
    // Compare the last components only (paths differ by /private and symlinks).
    NSArray *parts = path.pathComponents;
    NSString *tail = [NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(parts.count > 3 ? parts.count - 3 : 0, MIN(3, parts.count))]];
    for (NSArray *img in WPLoadedImages()) {
        NSString *n = img[0];
        if ([n isEqualToString:path] || [n hasSuffix:tail]) {
            if (slideOut) *slideOut = [img[2] longValue];
            return [img[1] pointerValue];
        }
    }
    return NULL;
}

static NSString *WPTypeName(const void *metadata) {
    static WPGetTypeName getTypeName;
    if (!getTypeName) getTypeName = (WPGetTypeName)dlsym(RTLD_DEFAULT, "swift_getTypeName");
    if (!getTypeName || !metadata) return @"?";
    WPTypeNamePair pair = getTypeName(metadata, true);
    if (!pair.data) return @"?";
    return [[NSString alloc] initWithBytes:pair.data length:pair.length encoding:NSUTF8StringEncoding] ?: @"?";
}

typedef struct {
    const char *name;            // display name
    const char *protocolSymbol;  // protocol descriptor
    const char *reqBaseSymbol;   // requirements base
    const char *bodySymbol;      // Body associated type descriptor
} WPProtocolInfo;

static const WPProtocolInfo kWPProtocols[] = {
    { "WidgetBundle", "$s7SwiftUI12WidgetBundleMp", "$s7SwiftUI12WidgetBundleTL", "$s7SwiftUI12WidgetBundleP4BodyAC_AA0C0Tn" },
    { "Widget", "$s7SwiftUI6WidgetMp", "$s7SwiftUI6WidgetTL", "$s7SwiftUI6WidgetP4BodyAC_AA0C13ConfigurationTn" },
    { "WidgetConfiguration", "$s7SwiftUI19WidgetConfigurationMp", "$s7SwiftUI19WidgetConfigurationTL", "$s7SwiftUI19WidgetConfigurationP4BodyAC_AaBTn" },
    { "TimelineProvider", "$s9WidgetKit16TimelineProviderMp", NULL, NULL },
    { "TimelineEntry", "$s9WidgetKit13TimelineEntryMp", NULL, NULL },
};

#pragma mark - Crash breadcrumbs

static int gWPCrashFD = -1;
static struct sigaction gWPOldActions[NSIG];
static const int kWPSignals[] = { SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE };

static void WPWriteRaw(const char *s) {
    if (gWPCrashFD >= 0 && s) write(gWPCrashFD, s, strlen(s));
}

static void WPWriteAddress(const char *label, uintptr_t addr) {
    char line[512];
    Dl_info info;
    if (addr && dladdr((const void *)addr, &info) && info.dli_fname) {
        const char *image = strrchr(info.dli_fname, '/');
        image = image ? image + 1 : info.dli_fname;
        snprintf(line, sizeof line, "  %s 0x%lx %s+0x%lx %s\n", label, (unsigned long)addr, image,
                 (unsigned long)(addr - (uintptr_t)info.dli_fbase), info.dli_sname ?: "");
    } else {
        snprintf(line, sizeof line, "  %s 0x%lx\n", label, (unsigned long)addr);
    }
    WPWriteRaw(line);
}

static void WPCrashHandler(int sig, siginfo_t *info, void *uap) {
    char line[256];
    snprintf(line, sizeof line, "\n!! Crash: signal %d, address %p\n", sig, info ? info->si_addr : NULL);
    WPWriteRaw(line);
    ucontext_t *uc = (ucontext_t *)uap;
    if (uc && uc->uc_mcontext) {
        uintptr_t pc = (uintptr_t)uc->uc_mcontext->__ss.__pc;
        uintptr_t lr = (uintptr_t)uc->uc_mcontext->__ss.__lr;
        uintptr_t fp = (uintptr_t)uc->uc_mcontext->__ss.__fp;
        WPWriteAddress("pc", pc);
        WPWriteAddress("lr", lr);
        char regs[400];
        snprintf(regs, sizeof regs, "  x0=%llx x1=%llx x2=%llx x3=%llx x4=%llx x5=%llx x8=%llx\n  x19=%llx x20=%llx x21=%llx x22=%llx x23=%llx\n",
                 uc->uc_mcontext->__ss.__x[0], uc->uc_mcontext->__ss.__x[1], uc->uc_mcontext->__ss.__x[2], uc->uc_mcontext->__ss.__x[3],
                 uc->uc_mcontext->__ss.__x[4], uc->uc_mcontext->__ss.__x[5], uc->uc_mcontext->__ss.__x[8], uc->uc_mcontext->__ss.__x[19],
                 uc->uc_mcontext->__ss.__x[20], uc->uc_mcontext->__ss.__x[21], uc->uc_mcontext->__ss.__x[22], uc->uc_mcontext->__ss.__x[23]);
        WPWriteRaw(regs);
        // Registers that point at text (e.g. the message of a Swift fatal error).
        for (int r = 0; r < 6; r++) {
            uint64_t v = uc->uc_mcontext->__ss.__x[r] & 0x0000000FFFFFFFFFULL;
            if (v < 0x100000000ULL) continue;
            char buf[161] = { 0 };
            vm_size_t got = 0;
            if (vm_read_overwrite(mach_task_self(), (vm_address_t)v, 160, (vm_address_t)buf, &got) != KERN_SUCCESS) continue;
            int printable = 0;
            while (printable < 160 && ((unsigned char)buf[printable] >= 0x20 || buf[printable] == '\n')) printable++;
            if (printable < 6) continue;
            buf[printable] = 0;
            char line[260];
            snprintf(line, sizeof line, "  string at x%d: %s\n", r, buf);
            WPWriteRaw(line);
        }
        // Async callers: walk the async context chain from x22 (each context: Parent, ResumeParent).
        uint64_t actx = uc->uc_mcontext->__ss.__x[22];
        for (int i = 0; i < 16 && actx > 0x100000000ULL; i++) {
            uint64_t pair[2] = { 0, 0 };
            vm_size_t got = 0;
            if (vm_read_overwrite(mach_task_self(), (vm_address_t)actx, 16, (vm_address_t)pair, &got) != KERN_SUCCESS) break;
            uintptr_t resume = (uintptr_t)(pair[1] & 0x0000000FFFFFFFFFULL);
            if (!resume) break;
            snprintf(line, sizeof line, "async#%02d", i);
            WPWriteAddress(line, resume);
            actx = pair[0] & 0x0000000FFFFFFFFFULL;
        }
        // Walk the frame pointer chain of the faulting thread.
        for (int i = 0; i < 24 && fp && (fp & 7) == 0; i++) {
            uintptr_t next = ((uintptr_t *)fp)[0];
            uintptr_t ret = ((uintptr_t *)fp)[1];
            if (!ret) break;
            snprintf(line, sizeof line, "#%02d", i);
            WPWriteAddress(line, ret);
            if (next <= fp) break;
            fp = next;
        }
    }
    // Messages left for the crash reporter (Swift's "Fatal error: …", libdispatch, …).
    for (uint32_t i = 0; i < _dyld_image_count() && i < 4000; i++) {
        unsigned long size = 0;
        const uint8_t *ci = getsectiondata((const struct mach_header_64 *)_dyld_get_image_header(i), "__DATA", "__crash_info", &size);
        if (!ci || size < 40) continue;
        const char *msgs[2] = { *(const char *const *)(ci + 8), *(const char *const *)(ci + 32) };
        for (int k = 0; k < 2; k++) {
            if (!msgs[k] || !msgs[k][0]) continue;
            char m[700];
            snprintf(m, sizeof m, "  message: %.600s\n", msgs[k]);
            WPWriteRaw(m);
        }
    }
    if (gWPCrashFD >= 0) fsync(gWPCrashFD);
    // Hand the signal back to whoever handled it before (or the default).
    if (sig > 0 && sig < NSIG) sigaction(sig, &gWPOldActions[sig], NULL);
    raise(sig);
}

static BOOL gWPRuntimeCrashLog; // the home screen keeps a permanent handler writing to runtime.txt

static void WPInstallCrashHandler(void) {
    if (gWPRuntimeCrashLog) return;
    gWPCrashFD = open([WPProbe reportPath].fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = WPCrashHandler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    for (size_t i = 0; i < sizeof(kWPSignals) / sizeof(kWPSignals[0]); i++) {
        sigaction(kWPSignals[i], &sa, &gWPOldActions[kWPSignals[i]]);
    }
}

#pragma mark - Protocol descriptor reading

// TargetProtocolDescriptor: flags, parent, name, numRequirementsInSignature,
// numRequirements, associatedTypeNames, then GenericRequirementDescriptor[sig] (12 bytes
// each) and ProtocolRequirement[n] (8 bytes each). The requirements base is one
// ProtocolRequirement before the first requirement; witness table slot = index + 1.
typedef struct {
    const void *reqBase;
    const void *firstAssocType;
    uint32_t assocIndex;
    uint32_t numRequirements;
} WPProtocolLayout;

static BOOL WPReadProtocolLayout(const void *protocol, WPProtocolLayout *out) {
    if (!protocol) return NO;
    const uint8_t *p = protocol;
    uint32_t numSig = *(const uint32_t *)(p + 12);
    uint32_t numReq = *(const uint32_t *)(p + 16);
    if (numReq > 64 || numSig > 64) return NO;
    const uint8_t *reqs = p + 24 + numSig * 12;
    out->reqBase = reqs - 8;
    out->numRequirements = numReq;
    out->firstAssocType = NULL;
    for (uint32_t i = 0; i < numReq; i++) {
        uint32_t flags = *(const uint32_t *)(reqs + i * 8);
        if ((flags & 0x0F) == 7) { // AssociatedTypeAccessFunction
            out->firstAssocType = reqs + i * 8;
            out->assocIndex = i;
            break;
        }
    }
    return out->firstAssocType != NULL;
}

static NSString *WPDescribeMangled(const uint8_t *name) {
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < 64 && name[i]; i++) {
        uint8_t c = name[i];
        if (c >= 0x01 && c <= 0x17) {
            // symbolic reference: control byte + 4-byte relative offset
            int32_t rel;
            memcpy(&rel, name + i + 1, 4);
            const void *target = name + i + 1 + rel;
            Dl_info info;
            const char *what = "";
            if (c == 0x02 || c == 0x01) {
                const void *t = (c == 0x02) ? *(const void *const *)target : target;
                const char *n = t ? WPRelDirect((const int32_t *)((const uint8_t *)t + 8)) : NULL;
                [s appendFormat:@"<ref%02x %s>", c, n ?: "?"];
            } else {
                if (dladdr(target, &info) && info.dli_sname) what = info.dli_sname;
                [s appendFormat:@"<ref%02x %s>", c, what];
            }
            i += 4;
        } else if (c >= 0x18 && c <= 0x1F) {
            [s appendFormat:@"<ptr%02x>", c];
            i += 8;
        } else {
            [s appendFormat:@"%c", c];
        }
    }
    return s;
}


#pragma mark - Phase 3: structure of a widget

typedef void (*WPWitnessInit)(void *out __attribute__((swift_indirect_result)), const void *selfType, const void *wt,
                              const void *metatype __attribute__((swift_context))) SWIFTCALL;
typedef void (*WPWitnessGetter)(void *out __attribute__((swift_indirect_result)), const void *selfType, const void *wt,
                                const void *selfValue __attribute__((swift_context))) SWIFTCALL;
typedef const void *(*WPGetTypeByMangledName)(const char *name, size_t length, const void *context,
                                              const void *const *genericArgs) SWIFTCALL;

typedef struct {
    void *functions[8];
    size_t size;
    size_t stride;
    uint32_t flags;
    uint32_t extraInhabitantCount;
} WPValueWitnessTable;

static const WPValueWitnessTable *WPVWT(const void *metadata) {
    return ((const WPValueWitnessTable *const *)metadata)[-1];
}

// Zeroed, suitably aligned storage for one value of the type. Probe values are never freed.
static void *WPAllocValue(const void *metadata) {
    const WPValueWitnessTable *vwt = WPVWT(metadata);
    size_t align = (vwt->flags & 0xFF) + 1;
    if (align < 16) align = 16;
    size_t size = vwt->stride > 16 ? vwt->stride : 16;
    void *p = NULL;
    if (posix_memalign(&p, align, size) != 0) return NULL;
    memset(p, 0, size);
    return p;
}

// Index of the first requirement of the given kind (2 = init, 3 = getter), or -1.
static int WPFindRequirement(const void *protocol, uint32_t kind) {
    const uint8_t *p = protocol;
    uint32_t numSig = *(const uint32_t *)(p + 12);
    uint32_t numReq = *(const uint32_t *)(p + 16);
    if (numReq > 64 || numSig > 64) return -1;
    const uint8_t *reqs = p + 24 + numSig * 12;
    for (uint32_t i = 0; i < numReq; i++) {
        if ((*(const uint32_t *)(reqs + i * 8) & 0x0F) == kind) return (int)i;
    }
    return -1;
}

static size_t WPMangledLength(const uint8_t *name) {
    size_t i = 0;
    while (name[i]) {
        uint8_t c = name[i];
        if (c >= 0x01 && c <= 0x17) i += 5;
        else if (c >= 0x18 && c <= 0x1F) i += 9;
        else i += 1;
    }
    return i;
}

static NSString *WPIndent(int depth) {
    return [@"" stringByPaddingToLength:(NSUInteger)(depth * 2) withString:@" " startingAtIndex:0];
}

static const uint8_t *WPStructDescriptor(const void *metadata) {
    uintptr_t kind = *(const uintptr_t *)metadata;
    if (kind != 0x200 && kind != 0x201 && kind != 0x202) return NULL; // struct / enum / optional
    return ((const uint8_t *const *)metadata)[1];
}

static void WPDumpStructFields(const void *metadata, int depth, NSMutableString *log) {
    if (gWPQuiet || !WPDiagnosticLogEnabled()) return;
    const uint8_t *desc = WPStructDescriptor(metadata);
    if (!desc || *(const uintptr_t *)metadata != 0x200) return;
    const uint8_t *fd = WPRelDirect((const int32_t *)(desc + 16));
    uint32_t fieldOffsetVector = *(const uint32_t *)(desc + 24);
    if (!fd) {
        WPLOG(log, @"%@  (no field info)", WPIndent(depth));
        return;
    }
    uint16_t recordSize = *(const uint16_t *)(fd + 10);
    uint32_t count = *(const uint32_t *)(fd + 12);
    if (recordSize < 12 || count > 32) return;
    const uint32_t *offsets = (const uint32_t *)((const uint8_t *)metadata + fieldOffsetVector * 8);
    static WPGetTypeByMangledName getType;
    if (!getType) getType = (WPGetTypeByMangledName)dlsym(RTLD_DEFAULT, "swift_getTypeByMangledNameInContext");
    const uint8_t *rec = fd + 16;
    for (uint32_t i = 0; i < count; i++, rec += recordSize) {
        const uint8_t *mangled = WPRelDirect((const int32_t *)(rec + 4));
        const char *name = WPRelDirect((const int32_t *)(rec + 8));
        NSString *typeName = @"?";
        if (mangled && getType) {
            const void *fieldType = getType((const char *)mangled, WPMangledLength(mangled), desc,
                                            (const void *const *)metadata + 2);
            typeName = fieldType ? WPTypeName(fieldType) : [NSString stringWithFormat:@"(unresolved: %@)", WPDescribeMangled(mangled)];
        }
        WPLOG(log, @"%@  .%s : %@ @%u", WPIndent(depth), name ?: "?", typeName, offsets[i]);
    }
}



#pragma mark - Main bundle redirect

// Code inside the widget extension that asks for Bundle.main expects its own bundle,
// not SpringBoard's. Only calls coming from the extension's own code are redirected,
// so SpringBoard and everything else keep seeing the real main bundle.
static uintptr_t gWPImageStart, gWPImageEnd;
static NSBundle *gWPExtensionBundle;
static IMP gWPOrigMainBundle;

static uintptr_t gWPExtraStart[16], gWPExtraEnd[16];
static NSMutableArray<NSBundle *> *gWPExtraBundles;
static int gWPExtraCount;

static NSBundle *WPMainBundleHook(id self, SEL _cmd) {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    if (gWPExtensionBundle && caller >= gWPImageStart && caller < gWPImageEnd) return gWPExtensionBundle;
    for (int i = 0; i < gWPExtraCount; i++) {
        if (caller >= gWPExtraStart[i] && caller < gWPExtraEnd[i]) return gWPExtraBundles[i];
    }
    return ((NSBundle *(*)(id, SEL))gWPOrigMainBundle)(self, _cmd);
}

static uint64_t WPTextSize(const struct mach_header *mh) {
    const struct mach_header_64 *h = (const struct mach_header_64 *)mh;
    const uint8_t *cmd = (const uint8_t *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const void *)cmd;
        if (lc->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *)lc)->segname, "__TEXT") == 0) {
            return ((const struct segment_command_64 *)lc)->vmsize;
        }
        cmd += lc->cmdsize;
    }
    return 0;
}

// Another extension image (e.g. the Intents extension) whose Bundle.main is its own bundle.
static void WPAddBundleRedirect(const struct mach_header *mh, NSString *bundlePath) {
    if (gWPExtraCount >= 16) return;
    uint64_t size = WPTextSize(mh);
    if (!size) return;
    if (!gWPExtraBundles) gWPExtraBundles = [NSMutableArray array];
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    if (!bundle) return;
    gWPExtraStart[gWPExtraCount] = (uintptr_t)mh;
    gWPExtraEnd[gWPExtraCount] = (uintptr_t)mh + size;
    [gWPExtraBundles addObject:bundle];
    gWPExtraCount++;
}

static void WPInstallMainBundleRedirect(const struct mach_header *mh, NSString *bundlePath, NSMutableString *log) {
    const struct mach_header_64 *h = (const struct mach_header_64 *)mh;
    const uint8_t *cmd = (const uint8_t *)(h + 1);
    uint64_t textVM = 0, textSize = 0;
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const void *)cmd;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const void *)lc;
            if (strcmp(seg->segname, "__TEXT") == 0) { textVM = seg->vmaddr; textSize = seg->vmsize; break; }
        }
        cmd += lc->cmdsize;
    }
    if (!textSize) return;
    if (gWPExtensionBundle) {
        // Another extension is already redirected: add this one alongside it.
        if ((uintptr_t)mh != gWPImageStart) WPAddBundleRedirect(mh, bundlePath);
        return;
    }
    gWPImageStart = (uintptr_t)mh;
    gWPImageEnd = (uintptr_t)mh + textSize;
    (void)textVM;
    gWPExtensionBundle = [NSBundle bundleWithPath:bundlePath];
    if (!gWPOrigMainBundle) {
        Method m = class_getClassMethod([NSBundle class], @selector(mainBundle));
        gWPOrigMainBundle = method_setImplementation(m, (IMP)WPMainBundleHook);
    }
    WPLOG(log, @"    Bundle.main redirect: returns %@ only when called from the extension's code", gWPExtensionBundle.bundleIdentifier ?: bundlePath.lastPathComponent);
}

#pragma mark - Phase 4/5: provider and first render

typedef struct {
    const void *value;
    const void *type;
    BOOL isStatic;
} WPFoundConfig;

static WPFoundConfig gWPConfigs[16];
static int gWPConfigCount;

typedef struct {
    const void *closure;      // address of the stored {function, context} pair
    const void *functionType; // function type metadata
    BOOL abstract;            // stored at maximal abstraction (declared in terms of generic parameters)
    NSString *where;
} WPContentClosure;

static WPContentClosure gWPContent;

typedef struct {
    const void *base;   // the struct value, or the object for a class
    const void *type;   // its (dynamic) metadata
    BOOL isClass;
    BOOL isIntent;
    BOOL isAppIntent; // AppIntentTimelineProvider (iOS 17)
} WPProviderBox;
static WPProviderBox gWPBoxes[16];
static int gWPBoxCount;

typedef struct { void *r0, *r1, *r2, *r3; } WPFourWords;
typedef WPFourWords (*WPThickDirect)(const void *ctx __attribute__((swift_context))) SWIFTCALL;
typedef void (*WPThickIndirect)(void *out __attribute__((swift_indirect_result)), const void *ctx __attribute__((swift_context))) SWIFTCALL;
typedef void (*WPContentFn)(void *out __attribute__((swift_indirect_result)), const void *entry,
                            const void *ctx __attribute__((swift_context))) SWIFTCALL;
typedef void *(*WPHostingInit)(void *rootView, const void *metatype __attribute__((swift_context))) SWIFTCALL;
typedef WPMetadataResponse (*WPGenericAccessor2)(size_t request, const void *arg, const void *wt) SWIFTCALL;

static BOOL WPIsClassMetadata(const void *md) {
    uintptr_t kind = *(const uintptr_t *)md;
    return kind == 0 || kind > 0x7FF;
}

// The Swift class descriptor of a class metadata, or NULL (Objective-C classes have none).
static const uint8_t *WPClassDescriptor(const void *md) {
    if (!WPIsClassMetadata(md)) return NULL;
    uintptr_t data = ((const uintptr_t *)md)[4];
    if (!(data & 3)) return NULL; // not a Swift class
    return ((const uint8_t *const *)md)[8];
}

// Whether a mangled type refers to the containing type's generic parameters.
static BOOL WPMangledUsesGenerics(const uint8_t *m) {
    for (size_t i = 0; m[i]; ) {
        uint8_t c = m[i];
        if (c >= 0x01 && c <= 0x17) { i += 5; continue; }
        if (c >= 0x18 && c <= 0x1F) { i += 9; continue; }
        if (c == 'x') return YES;
        if (c == 'q' && (m[i + 1] == '_' || (m[i + 1] >= '0' && m[i + 1] <= '9') || m[i + 1] == 'd')) return YES;
        i++;
    }
    return NO;
}

static void WPDumpValue(const void *value, const void *md, NSString *label, int depth, int maxDepth, NSMutableString *log);

static void WPDumpFields(const void *base, const void *md, const uint8_t *desc, BOOL isClass, int depth, int maxDepth,
                         NSMutableString *log) {
    const uint8_t *fd = WPRelDirect((const int32_t *)(desc + 16));
    if (!fd) return;
    uint16_t recordSize = *(const uint16_t *)(fd + 10);
    uint32_t count = *(const uint32_t *)(fd + 12);
    if (recordSize < 12 || count > 32) return;
    BOOL generic = (*(const uint32_t *)desc & 0x80) != 0;

    const void *const *genericArgs;
    const uint8_t *offsetBase;
    if (isClass) {
        uint32_t positive = *(const uint32_t *)(desc + 28);
        uint32_t immediate = *(const uint32_t *)(desc + 32);
        uint32_t fov = *(const uint32_t *)(desc + 40);
        genericArgs = (const void *const *)md + (positive - immediate);
        offsetBase = (const uint8_t *)md + fov * 8;
    } else {
        genericArgs = (const void *const *)md + 2;
        offsetBase = (const uint8_t *)md + *(const uint32_t *)(desc + 24) * 8;
    }

    static WPGetTypeByMangledName getType;
    if (!getType) getType = (WPGetTypeByMangledName)dlsym(RTLD_DEFAULT, "swift_getTypeByMangledNameInContext");
    const uint8_t *rec = fd + 16;
    for (uint32_t i = 0; i < count; i++, rec += recordSize) {
        const uint8_t *mangled = WPRelDirect((const int32_t *)(rec + 4));
        const char *name = WPRelDirect((const int32_t *)(rec + 8));
        size_t offset = isClass ? ((const size_t *)offsetBase)[i] : ((const uint32_t *)offsetBase)[i];
        const void *fieldType = (mangled && getType) ? getType((const char *)mangled, WPMangledLength(mangled), desc, genericArgs) : NULL;
        NSString *fieldLabel = [NSString stringWithFormat:@".%s @%zu", name ?: "?", offset];
        if (!fieldType) {
            WPLOG(log, @"%@%@ : (unresolved %@)", WPIndent(depth), fieldLabel, mangled ? WPDescribeMangled(mangled) : @"");
            continue;
        }
        const void *fieldValue = (const uint8_t *)base + offset;
        // Remember a stored "(Entry) -> AnyView" closure: that is the view builder.
        if (*(const uintptr_t *)fieldType == 0x302) {
            size_t fflags = ((const size_t *)fieldType)[1];
            const void *result = ((const void *const *)fieldType)[2];
            if ((fflags & 0xFFFF) == 1 && [WPTypeName(result) isEqualToString:@"SwiftUI.AnyView"] && !gWPContent.closure) {
                gWPContent.closure = fieldValue;
                gWPContent.functionType = fieldType;
                gWPContent.abstract = generic && WPMangledUsesGenerics(mangled);
                gWPContent.where = [NSString stringWithFormat:@"%@%@", WPTypeName(md), fieldLabel];
                WPLOG(log, @"%@  ★ candidate view-building function (%@)", WPIndent(depth), gWPContent.abstract ? @"generic calling convention" : @"concrete calling convention");
            }
        }
        WPDumpValue(fieldValue, fieldType, fieldLabel, depth, maxDepth, log);
    }
}

// Logs a value and, within maxDepth, what it contains (structs, classes, existentials).
static void WPDumpValue(const void *value, const void *md, NSString *label, int depth, int maxDepth, NSMutableString *log) {
    NSString *indent = WPIndent(depth);
    NSString *typeName = WPTypeName(md);
    uintptr_t kind = *(const uintptr_t *)md;
    if (kind == 0x303) { // existential
        uint32_t flags = *(const uint32_t *)((const uint8_t *)md + 8);
        BOOL classBound = (flags & 0x80000000) == 0;
        const void *dynType = NULL;
        const void *inner = NULL;
        if (classBound) {
            const void *obj = *(const void *const *)value;
            if (obj) { dynType = *(const void *const *)obj; inner = value; }
        } else {
            dynType = ((const void *const *)value)[3];
            if (dynType) {
                const WPValueWitnessTable *vwt = WPVWT(dynType);
                if (vwt->flags & 0x00020000) { // stored out of line in a box
                    size_t mask = vwt->flags & 0xFF;
                    const uint8_t *box = *(const uint8_t *const *)value;
                    inner = box + ((16 + mask) & ~mask);
                } else {
                    inner = value;
                }
            }
        }
        WPLOG(log, @"%@%@ : %@ → actual %@", indent, label, typeName, dynType ? WPTypeName(dynType) : @"(empty)");
        if (dynType && inner && depth < maxDepth) WPDumpValue(inner, dynType, @"(contents)", depth + 1, maxDepth, log);
        return;
    }
    if (WPIsClassMetadata(md)) {
        const void *obj = *(const void *const *)value;
        const void *dyn = obj ? *(const void *const *)obj : NULL;
        const uint8_t *desc = dyn ? WPClassDescriptor(dyn) : NULL;
        NSString *dynName = dyn ? WPTypeName(dyn) : typeName;
        WPLOG(log, @"%@%@ : %@%@", indent, label, dynName, obj ? @"" : @" (nil)");
        BOOL isTimelineBox = [dynName hasPrefix:@"WidgetKit.TimelineEntryProvider<"];
        BOOL isIntentBox = [dynName hasPrefix:@"WidgetKit.IntentTimelineEntryProvider<"];
        // By the box type itself: its generic arguments are the app's own types, whose names
        // may contain anything (Spotify's DJ view is "DJAppIntentWidgetCircularView").
        BOOL isAppIntentBox = [dynName hasPrefix:@"WidgetKit.AppIntentTimelineEntryProvider<"];
        if (obj && desc && (isTimelineBox || isIntentBox || isAppIntentBox) && gWPBoxCount < 16) {
            gWPBoxes[gWPBoxCount++] = (WPProviderBox){ obj, dyn, YES, isIntentBox || isAppIntentBox, isAppIntentBox };
        }
        if (desc && depth < maxDepth) WPDumpFields(obj, dyn, desc, YES, depth + 1, maxDepth, log);
        return;
    }
    WPLOG(log, @"%@%@ : %@", indent, label, typeName);
    BOOL isTimelineBox = [typeName hasPrefix:@"WidgetKit.TimelineEntryProvider<"];
    BOOL isIntentBox = [typeName hasPrefix:@"WidgetKit.IntentTimelineEntryProvider<"];
    BOOL isAppIntentBox = [typeName hasPrefix:@"WidgetKit.AppIntentTimelineEntryProvider<"];
    if ((isTimelineBox || isIntentBox || isAppIntentBox) && gWPBoxCount < 16) {
        gWPBoxes[gWPBoxCount++] = (WPProviderBox){ value, md, NO, isIntentBox || isAppIntentBox, isAppIntentBox };
    }
    if (kind == 0x200 && depth < maxDepth) {
        const uint8_t *desc = ((const uint8_t *const *)md)[1];
        // Standard library and Foundation values are not interesting here.
        if (![typeName hasPrefix:@"Swift."] && ![typeName hasPrefix:@"Foundation."] && ![typeName hasPrefix:@"CoreFoundation."] && ![typeName hasPrefix:@"SwiftUI."]) {
            WPDumpFields(value, md, desc, NO, depth + 1, maxDepth, log);
        }
    }
}

// Calls a stored "() -> T" closure and returns T in fresh storage.
static void *WPCallThunk(const void *closure, const void *fnType, const void **resultTypeOut, NSMutableString *log) {
    const void *const *pair = closure;
    const void *fn = pair[0];
    const void *ctx = pair[1];
    const void *resultType = ((const void *const *)fnType)[2];
    *resultTypeOut = resultType;
    const WPValueWitnessTable *vwt = WPVWT(resultType);
    void *out = WPAllocValue(resultType);
    if (!fn || !out) return NULL;
    BOOL opaqueExistential = *(const uintptr_t *)resultType == 0x303 &&
                             (*(const uint32_t *)((const uint8_t *)resultType + 8) & 0x80000000);
    BOOL indirect = vwt->size > 32 || (vwt->flags & 0x00020000) || opaqueExistential;
    WPLOG(log, @"      result %@ (%zu bytes, %@)", WPTypeName(resultType), vwt->size, indirect ? @"indirect" : @"registers");
    if (indirect) {
        ((WPThickIndirect)fn)(out, ctx);
    } else {
        WPFourWords r = ((WPThickDirect)fn)(ctx);
        memcpy(out, &r, vwt->size < sizeof r ? vwt->size : sizeof r);
    }
    return out;
}

static void WPPhase4(NSMutableString *log) {
    for (int i = 0; i < gWPConfigCount; i++) {
        WPFoundConfig c = gWPConfigs[i];
        WPLOG(log, @"  -- stage 4: %@", WPTypeName(c.type));
        WPDumpValue(c.value, c.type, @"(configuration)", 2, 5, log);

        // .provider is the first field: "() -> EntryProviding".
        const uint8_t *desc = ((const uint8_t *const *)c.type)[1];
        const uint32_t *offsets = (const uint32_t *)((const uint8_t *)c.type + *(const uint32_t *)(desc + 24) * 8);
        const uint8_t *fd = WPRelDirect((const int32_t *)(desc + 16));
        static WPGetTypeByMangledName getType;
        if (!getType) getType = (WPGetTypeByMangledName)dlsym(RTLD_DEFAULT, "swift_getTypeByMangledNameInContext");
        if (!fd || !getType) continue;
        const uint8_t *mangled = WPRelDirect((const int32_t *)(fd + 16 + 4));
        const void *fnType = getType((const char *)mangled, WPMangledLength(mangled), desc, (const void *const *)c.type + 2);
        if (!fnType || *(const uintptr_t *)fnType != 0x302) {
            WPLOG(log, @"    provider is not a function type");
            continue;
        }
        WPLOG(log, @"    calling provider()...");
        const void *resultType = NULL;
        void *result = WPCallThunk((const uint8_t *)c.value + offsets[0], fnType, &resultType, log);
        if (!result) continue;
        WPDumpValue(result, resultType, @"provider()", 3, 7, log);
    }
}



#pragma mark - Intent defaults from the app's Intents extension

static WPWidgetExtension *gWPCurrentExtension;

// Copies, signs and loads an extension bundle; returns its loaded image or NULL.
static NSMutableDictionary<NSString *, NSString *> *gWPLoadedCopies; // appex path → loaded executable copy

// Copying, signing and dlopen run on a background thread at startup (WPProbe
// prepareExtension:) and may be asked for on the main thread too; one at a time.
static NSRecursiveLock *WPLoadLock(void) {
    static NSRecursiveLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSRecursiveLock new]; });
    return lock;
}

// The copy is kept between launches (re-made when the app's extension changes) like the
// widget extension's own copy; only dlopen happens again.
static const struct mach_header *WPLoadExtensionCopy(NSString *appexPath, NSString *appPath, NSString **copyPathOut, NSMutableString *log) {
    [WPLoadLock() lock];
    NSFileManager *fm = [NSFileManager defaultManager];
    const struct mach_header *mh = NULL;
    NSString *loaded = gWPLoadedCopies[appexPath];
    if (loaded) mh = WPFindLoadedImage(loaded, NULL);
    if (mh) {
        if (copyPathOut) *copyPathOut = loaded.stringByDeletingLastPathComponent;
        [WPLoadLock() unlock];
        return mh;
    }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appexPath stringByAppendingPathComponent:@"Info.plist"]];
    NSString *bundleID = info[@"CFBundleIdentifier"] ?: appexPath.lastPathComponent;
    NSString *exeName = info[@"CFBundleExecutable"] ?: appexPath.lastPathComponent.stringByDeletingPathExtension;
    NSString *dir = [[WPProbe workDirectory] stringByAppendingPathComponent:bundleID];
    NSString *copy = [dir stringByAppendingPathComponent:appexPath.lastPathComponent];
    NSString *exe = [copy stringByAppendingPathComponent:exeName];
    NSString *source = [appexPath stringByAppendingPathComponent:exeName];
    NSDictionary *attrs = [fm attributesOfItemAtPath:source error:nil];
    NSString *stamp = [NSString stringWithFormat:@"%@|%@|%@", source, attrs[NSFileSize], @([attrs[NSFileModificationDate] timeIntervalSince1970])];
    NSString *stampPath = [dir stringByAppendingPathComponent:@".wp-source"];
    if (![[NSString stringWithContentsOfFile:stampPath encoding:NSUTF8StringEncoding error:nil] isEqualToString:stamp] ||
        ![fm fileExistsAtPath:exe]) {
        [fm removeItemAtPath:dir error:nil];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSError *err = nil;
        if (![fm copyItemAtPath:appexPath toPath:copy error:&err]) {
            WPLOG(log, @"      copy failed: %@", err.localizedDescription);
            [WPLoadLock() unlock];
            return NULL;
        }
        int64_t (*syscallFn)(uint32_t, ...) = WPLiveShimSyscall();
        if (syscallFn) {
            int fd = open(exe.fileSystemRepresentation, O_RDWR);
            if (fd >= 0) {
                int64_t r = syscallFn(kWPSysSign, (int64_t)fd, (int64_t)0, (int64_t)0, (int64_t)0, (int64_t)0, (int64_t)0);
                close(fd);
                WPLOG(log, @"      copy and sign → %lld", r);
            }
        }
        [stamp writeToFile:stampPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
    }
    NSArray<NSString *> *deps = WPRpathDependencies(exe);
    if (deps.count) {
        WPPreloadDependencies(deps, @[ [appPath stringByAppendingPathComponent:@"Frameworks"],
                                       [copy stringByAppendingPathComponent:@"Frameworks"] ], log);
    }
    void *handle = dlopen(exe.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        WPLOG(log, @"      dlopen failed: %s", dlerror() ?: "?");
        [WPLoadLock() unlock];
        return NULL;
    }
    mh = WPFindLoadedImage(exe, NULL);
    if (mh) {
        // Bundle.main for its code: registered on the main thread (the table is read from any
        // thread without a lock), before anything there can call into it.
        if ([NSThread isMainThread]) WPAddBundleRedirect(mh, copy);
        else dispatch_async(dispatch_get_main_queue(), ^{ WPAddBundleRedirect(mh, copy); });
        if (!gWPLoadedCopies) gWPLoadedCopies = [NSMutableDictionary dictionary];
        gWPLoadedCopies[appexPath] = exe;
    }
    if (copyPathOut) *copyPathOut = copy;
    [WPLoadLock() unlock];
    return mh;
}

// Both extensions carry their own copy of the generated intent classes (same names). The
// widget's code expects the classes of its own image, so objects coming from the Intents
// extension are rebuilt as instances of the first-registered class of the same name.
static id WPConvertToCanonicalClass(id value, int depth) {
    if (!value || depth > 4) return value;
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id v in value) [out addObject:WPConvertToCanonicalClass(v, depth + 1) ?: v];
        return out;
    }
    Class actual = [value class];
    Class canonical = NSClassFromString(NSStringFromClass(actual));
    if (!canonical || canonical == actual) return value;
    id copy = nil;
    if ([value respondsToSelector:@selector(identifier)] &&
        [canonical instancesRespondToSelector:@selector(initWithIdentifier:displayString:)]) {
        copy = ((id (*)(id, SEL, id, id))objc_msgSend)([canonical alloc], @selector(initWithIdentifier:displayString:),
                                                      [value valueForKey:@"identifier"], [value valueForKey:@"displayString"]);
    } else {
        copy = [[canonical alloc] init];
    }
    for (Class c = actual; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        if ([NSStringFromClass(c) hasPrefix:@"IN"]) break; // stop at the Intents framework classes
        unsigned int count = 0;
        objc_property_t *props = class_copyPropertyList(c, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = @(property_getName(props[i]));
            @try {
                id v = [value valueForKey:name];
                [copy setValue:WPConvertToCanonicalClass(v, depth + 1) forKey:name];
            } @catch (NSException *e) {
            }
        }
        free(props);
    }
    return copy ?: value;
}

// Asks the app's Intents extension for the intent's default parameter values, like iOS
// does when the widget is added: handlerForIntent: → default<Param>For<Intent>:.
static void WPApplyDefaultsFromIntentsExtension(id intent, NSMutableString *log) {
    NSString *className = NSStringFromClass([intent class]);
    NSString *shortName = [className componentsSeparatedByString:@"."].lastObject;
    NSString *plugins = [gWPCurrentExtension.appPath stringByAppendingPathComponent:@"PlugIns"];
    NSString *found = nil;
    NSDictionary *foundInfo = nil;
    for (NSString *item in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:plugins error:nil]) {
        NSString *path = [plugins stringByAppendingPathComponent:item];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
        NSDictionary *ext = info[@"NSExtension"];
        if (![ext[@"NSExtensionPointIdentifier"] isEqualToString:@"com.apple.intents-service"]) continue;
        NSArray *supported = ext[@"NSExtensionAttributes"][@"IntentsSupported"];
        BOOL matches = NO;
        for (NSString *name in supported) {
            if ([name isKindOfClass:[NSString class]] && ([name hasSuffix:shortName] || [shortName hasSuffix:name])) matches = YES;
        }
        WPLOG(log, @"    Intents extension %@: supports %@", item, matches ? @"yes" : [supported componentsJoinedByString:@","]);
        if (matches || !found) { found = path; foundInfo = info; }
        if (matches) break;
    }
    if (!found) {
        WPLOG(log, @"    no Intents extension");
        return;
    }
    WPLOG(log, @"    loading Intents extension: %@", found.lastPathComponent);
    if (!WPLoadExtensionCopy(found, gWPCurrentExtension.appPath, NULL, log)) return;

    NSString *principalName = foundInfo[@"NSExtension"][@"NSExtensionPrincipalClass"];
    principalName = [principalName stringByReplacingOccurrencesOfString:@"$(PRODUCT_MODULE_NAME)." withString:@""];
    Class principalClass = NSClassFromString(principalName);
    WPLOG(log, @"    principal class: %@ → %@", principalName, principalClass ? NSStringFromClass(principalClass) : @"not found");
    if (!principalClass) return;
    id principal = [[principalClass alloc] init];
    id handler = principal;
    if ([principal respondsToSelector:@selector(handlerForIntent:)]) {
        handler = ((id (*)(id, SEL, id))objc_msgSend)(principal, @selector(handlerForIntent:), intent) ?: principal;
    }
    WPLOG(log, @"    handler: %@", NSStringFromClass([handler class]));

    // default<Param>For<IntentName>: — one per parameter that has a dynamic default.
    for (Class c = [handler class]; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(c, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *sel = NSStringFromSelector(method_getName(methods[i]));
            if (![sel hasPrefix:@"default"] || ![sel hasSuffix:@":"] || [sel componentsSeparatedByString:@":"].count != 2) continue;
            NSRange forRange = [sel rangeOfString:@"For" options:NSBackwardsSearch];
            if (forRange.location == NSNotFound || forRange.location <= 7) continue;
            NSString *param = [sel substringWithRange:NSMakeRange(7, forRange.location - 7)];
            param = [[[param substringToIndex:1] lowercaseString] stringByAppendingString:[param substringFromIndex:1]];
            WPLOG(log, @"    calling %@...", sel);
            id value = nil;
            @try {
                value = ((id (*)(id, SEL, id))objc_msgSend)(handler, method_getName(methods[i]), intent);
                id converted = WPConvertToCanonicalClass(value, 0);
                if (converted != value) WPLOG(log, @"      (converted to the widget's class)");
                value = converted;
                if (value) [intent setValue:value forKey:param];
                WPLOG(log, @"      → .%@ = %@", param, value ?: @"(nil)");
            } @catch (NSException *e) {
                WPLOG(log, @"      exception: %@", e.reason);
            }
        }
        free(methods);
    }
}

#pragma mark - Phase 6: real entries from the timeline provider

typedef void (*WPCopyValue)(void *dest, const void *src, const void *type) SWIFTCALL;
typedef void (*WPStoreEnumTag)(void *value, unsigned whichCase, unsigned emptyCases, const void *type) SWIFTCALL;

static BOOL WPStructField(const void *md, const char *want, size_t *offsetOut, const void **typeOut) {
    BOOL isClass = WPIsClassMetadata(md);
    const uint8_t *desc = isClass ? WPClassDescriptor(md) : (*(const uintptr_t *)md == 0x200 ? ((const uint8_t *const *)md)[1] : NULL);
    if (!desc) return NO;
    const uint8_t *fd = WPRelDirect((const int32_t *)(desc + 16));
    if (!fd) return NO;
    uint16_t recordSize = *(const uint16_t *)(fd + 10);
    uint32_t count = *(const uint32_t *)(fd + 12);
    const void *const *genericArgs;
    const uint8_t *offsetBase;
    if (isClass) {
        uint32_t positive = *(const uint32_t *)(desc + 28);
        uint32_t immediate = *(const uint32_t *)(desc + 32);
        genericArgs = (const void *const *)md + (positive - immediate);
        offsetBase = (const uint8_t *)md + *(const uint32_t *)(desc + 40) * 8;
    } else {
        genericArgs = (const void *const *)md + 2;
        offsetBase = (const uint8_t *)md + *(const uint32_t *)(desc + 24) * 8;
    }
    static WPGetTypeByMangledName getType;
    if (!getType) getType = (WPGetTypeByMangledName)dlsym(RTLD_DEFAULT, "swift_getTypeByMangledNameInContext");
    const uint8_t *rec = fd + 16;
    for (uint32_t i = 0; i < count && i < 64; i++, rec += recordSize) {
        const char *name = WPRelDirect((const int32_t *)(rec + 8));
        if (!name || strcmp(name, want) != 0) continue;
        const uint8_t *mangled = WPRelDirect((const int32_t *)(rec + 4));
        if (offsetOut) *offsetOut = isClass ? ((const size_t *)offsetBase)[i] : ((const uint32_t *)offsetBase)[i];
        if (typeOut) *typeOut = (mangled && getType) ? getType((const char *)mangled, WPMangledLength(mangled), desc, genericArgs) : NULL;
        return YES;
    }
    return NO;
}

// Writes a valid "empty" value of the type: zero for plain data, empty collections and
// strings, nil for optionals, recursively for structs. Fails for anything else.
typedef void (*WPIndirectInit)(void *out __attribute__((swift_indirect_result))) SWIFTCALL;
typedef void *(*WPAllocObject)(const void *metadata, size_t size, size_t alignMask);

static BOOL WPDefaultInit(void *dst, const void *md, int depth, NSMutableString *log);

// A fresh instance of a class whose stored properties all get default values.
static void *WPDefaultObject(const void *md, int depth, NSMutableString *log) {
    NSString *name = WPTypeName(md);
    const uint8_t *desc = WPClassDescriptor(md);
    if (!desc) {
        Class cls = (__bridge Class)md;
        id obj = [[cls alloc] init];
        WPLOG(log, @"      made %@ with alloc/init", name);
        return (__bridge_retained void *)obj;
    }
    WPAllocObject allocObject = (WPAllocObject)dlsym(RTLD_DEFAULT, "swift_allocObject");
    if (!allocObject) return NULL;
    uint32_t size = *(const uint32_t *)((const uint8_t *)md + 48);
    uint16_t alignMask = *(const uint16_t *)((const uint8_t *)md + 52);
    void *obj = allocObject(md, size, alignMask);
    if (!obj) return NULL;
    memset((uint8_t *)obj + 16, 0, size > 16 ? size - 16 : 0);
    WPLOG(log, @"      made %@ (%u bytes)", name, size);

    const uint8_t *fd = WPRelDirect((const int32_t *)(desc + 16));
    if (!fd) return obj;
    uint16_t recordSize = *(const uint16_t *)(fd + 10);
    uint32_t count = *(const uint32_t *)(fd + 12);
    uint32_t positive = *(const uint32_t *)(desc + 28);
    uint32_t immediate = *(const uint32_t *)(desc + 32);
    const void *const *genericArgs = (const void *const *)md + (positive - immediate);
    const size_t *offsets = (const size_t *)((const uint8_t *)md + *(const uint32_t *)(desc + 40) * 8);
    static WPGetTypeByMangledName getType;
    if (!getType) getType = (WPGetTypeByMangledName)dlsym(RTLD_DEFAULT, "swift_getTypeByMangledNameInContext");
    const uint8_t *rec = fd + 16;
    for (uint32_t i = 0; i < count && i < 64; i++, rec += recordSize) {
        const uint8_t *mangled = WPRelDirect((const int32_t *)(rec + 4));
        const char *fieldName = WPRelDirect((const int32_t *)(rec + 8));
        const void *ft = (mangled && getType) ? getType((const char *)mangled, WPMangledLength(mangled), desc, genericArgs) : NULL;
        WPLOG(log, @"        .%s : %@ @%zu", fieldName ?: "?", ft ? WPTypeName(ft) : @"?", offsets[i]);
        if (!ft || !WPDefaultInit((uint8_t *)obj + offsets[i], ft, depth + 1, log)) return NULL;
    }
    return obj;
}

static BOOL WPDefaultInit(void *dst, const void *md, int depth, NSMutableString *log) {
    if (depth > 8) return NO;
    const WPValueWitnessTable *vwt = WPVWT(md);
    NSString *name = WPTypeName(md);
    uintptr_t kind = *(const uintptr_t *)md;
    if ([name isEqualToString:@"SwiftUI.EnvironmentValues"]) {
        WPIndirectInit init = (WPIndirectInit)dlsym(RTLD_DEFAULT, "$s7SwiftUI17EnvironmentValuesVACycfC");
        if (!init) return NO;
        WPLOG(log, @"      made with EnvironmentValues() (%zu bytes)", vwt->size);
        init(dst);
        return YES;
    }
    if (WPIsClassMetadata(md)) {
        void *obj = WPDefaultObject(md, depth, log);
        if (!obj) return NO;
        memcpy(dst, &obj, sizeof obj);
        return YES;
    }
    if (!(vwt->flags & 0x00010000)) { memset(dst, 0, vwt->size); return YES; } // POD
    if ([name isEqualToString:@"Swift.String"]) {
        uint64_t v[2] = { 0, 0xE000000000000000ULL };
        memcpy(dst, v, sizeof v);
        return YES;
    }
    const char *singleton = NULL;
    if ([name hasPrefix:@"Swift.Array<"] || [name hasPrefix:@"Swift.ContiguousArray<"]) singleton = "_swiftEmptyArrayStorage";
    else if ([name hasPrefix:@"Swift.Dictionary<"]) singleton = "_swiftEmptyDictionarySingleton";
    else if ([name hasPrefix:@"Swift.Set<"]) singleton = "_swiftEmptySetSingleton";
    if (singleton) {
        void *p = dlsym(RTLD_DEFAULT, singleton);
        memcpy(dst, &p, sizeof p);
        return p != NULL;
    }
    if (kind == 0x202) { // Optional: store the .none case
        const void *payload = ((const void *const *)md)[2];
        ((WPStoreEnumTag)WPVWT(payload)->functions[7])(dst, 1, 1, payload);
        return YES;
    }
    if (kind == 0x200) {
        const uint8_t *desc = ((const uint8_t *const *)md)[1];
        const uint8_t *fd = WPRelDirect((const int32_t *)(desc + 16));
        if (!fd) return NO;
        uint16_t recordSize = *(const uint16_t *)(fd + 10);
        uint32_t count = *(const uint32_t *)(fd + 12);
        const uint32_t *offsets = (const uint32_t *)((const uint8_t *)md + *(const uint32_t *)(desc + 24) * 8);
        static WPGetTypeByMangledName getType;
        if (!getType) getType = (WPGetTypeByMangledName)dlsym(RTLD_DEFAULT, "swift_getTypeByMangledNameInContext");
        const uint8_t *rec = fd + 16;
        for (uint32_t i = 0; i < count && i < 64; i++, rec += recordSize) {
            const uint8_t *mangled = WPRelDirect((const int32_t *)(rec + 4));
            const void *ft = (mangled && getType) ? getType((const char *)mangled, WPMangledLength(mangled), desc, (const void *const *)md + 2) : NULL;
            if (!ft || !WPDefaultInit((uint8_t *)dst + offsets[i], ft, depth + 1, log)) {
                WPLOG(log, @"      cannot make a default value: %@.%s", name, (const char *)WPRelDirect((const int32_t *)(rec + 8)));
                return NO;
            }
        }
        return YES;
    }
    WPLOG(log, @"      type without a default value: %@", name);
    return NO;
}

static void *WPMakeContext(int family, CGSize size, NSMutableString *log) {
    WPMetadataAccessor accessor = (WPMetadataAccessor)dlsym(RTLD_DEFAULT, "$s9WidgetKit23TimelineProviderContextVMa");
    if (!accessor) return NULL;
    const void *md = accessor(0).metadata;
    static BOOL logged;
    if (!logged) {
        logged = YES;
        WPLOG(log, @"    TimelineProviderContext layout (%zu bytes):", WPVWT(md)->size);
        WPDumpStructFields(md, 3, log);
    }
    void *ctx = WPAllocValue(md);
    if (!ctx || !WPDefaultInit(ctx, md, 0, log)) return NULL;
    size_t off;
    const void *t;
    if (WPStructField(md, "family", &off, &t)) *((uint8_t *)ctx + off) = (uint8_t)family;
    if (WPStructField(md, "internalFamily", &off, &t)) *((uint8_t *)ctx + off) = (uint8_t)family;
    if (WPStructField(md, "displaySize", &off, &t)) memcpy((uint8_t *)ctx + off, &size, sizeof size);
    return ctx;
}

// Requirement indices of the given kind, in declaration order.
static int WPRequirementsOfKind(const void *protocol, uint32_t kind, int *out, int max) {
    const uint8_t *p = protocol;
    uint32_t numSig = *(const uint32_t *)(p + 12);
    uint32_t numReq = *(const uint32_t *)(p + 16);
    if (numReq > 64 || numSig > 64) return 0;
    const uint8_t *reqs = p + 24 + numSig * 12;
    int n = 0;
    for (uint32_t i = 0; i < numReq && n < max; i++) {
        if ((*(const uint32_t *)(reqs + i * 8) & 0x0F) == kind) out[n++] = (int)i;
    }
    return n;
}

typedef void (*WPPlaceholderFn)(void *out __attribute__((swift_indirect_result)), const void *context, const void *selfType,
                                const void *wt, const void *self __attribute__((swift_context))) SWIFTCALL;
typedef void (*WPTimelineFn)(const void *context, const void *cbFn, const void *cbCtx, const void *selfType, const void *wt,
                             const void *self __attribute__((swift_context))) SWIFTCALL;
typedef void (*WPIntentTimelineFn)(const void *intent, const void *context, const void *cbFn, const void *cbCtx,
                                   const void *selfType, const void *wt, const void *self __attribute__((swift_context))) SWIFTCALL;

#pragma mark - Widget descriptors (name, description and sizes, for the add sheet)

// .configurationDisplayName / .description / .supportedFamilies do not store anything in the
// configuration itself: each wraps it in a _PreferenceTransformModifier<WidgetDescriptorKey>
// whose closure edits the WidgetDescriptor that the innermost configuration
// (WidgetDescriptorConfiguration) starts from. While walking the tree the closures on the
// path are kept; at the descriptor they are applied innermost first, like WidgetKit does.
static void WPRuntimeLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static NSString *WPSwiftString(const void *p);

typedef struct { const void *closure; const void *fnType; } WPDescTransform;
static WPDescTransform gWPDescTransforms[32];
static int gWPDescTransformCount;
static NSMutableArray<NSArray *> *gWPDescLeaves; // per descriptor found: its leaves (see WPCollectLeaves)
static BOOL gWPDescDisabled;                    // this extension's transforms crashed once

typedef void (*WPInoutClosure)(void *value, const void *ctx __attribute__((swift_context))) SWIFTCALL;
typedef unsigned (*WPEnumTagFn)(const void *value, const void *type) SWIFTCALL;
typedef void (*WPEnumProjectFn)(void *value, const void *type) SWIFTCALL;

// The leaves of a value: Swift strings ([path, string]), enum cases ([path, "case:name"]) and
// Objective-C objects ([path, @"<object>", object]), found through the Swift type metadata.
static void WPCollectLeaves(const void *value, const void *md, NSString *path, int depth, NSMutableArray *out) {
    if (!value || !md || depth > 9 || out.count > 300) return;
    uintptr_t kind = *(const uintptr_t *)md;
    NSString *typeName = WPTypeName(md);
    if ([typeName isEqualToString:@"Swift.String"]) {
        NSString *s = WPSwiftString(value);
        if (s) [out addObject:@[ path, s ]];
        return;
    }
    if (kind == 0x302 || kind == 0x304 || kind == 0x306 || [typeName hasPrefix:@"SwiftUI.EnvironmentValues"]) return;
    static NSSet *integers;
    if (!integers) integers = [NSSet setWithArray:@[ @"Swift.Int", @"Swift.UInt", @"Swift.Int64", @"Swift.UInt64", @"Swift.Int32",
                                                     @"Swift.UInt32", @"Swift.Int16", @"Swift.UInt16", @"Swift.Int8", @"Swift.UInt8" ]];
    size_t size = WPVWT(md)->size;
    BOOL importedPlain = (kind == 0x200 || kind == 0x201) && [typeName hasPrefix:@"__C."] && (size == 1 || size == 2 || size == 4 || size == 8);
    if ([integers containsObject:typeName] || importedPlain) {
        uint64_t v = 0;
        memcpy(&v, value, MIN(size, sizeof v));
        [out addObject:@[ path, [NSString stringWithFormat:@"int:%llu (%@)", v, typeName] ]];
        return;
    }
    if ([typeName hasPrefix:@"Swift.Set<"] || [typeName hasPrefix:@"Swift.Dictionary<"]) {
        [out addObject:@[ path, [NSString stringWithFormat:@"type:%@", typeName] ]];
        return;
    }
    if (kind == 0x305 || kind == 0x203) { // Objective-C class wrapper / foreign class: an object reference
        id o = (__bridge id)*(void *const *)value;
        if ([o isKindOfClass:[NSString class]]) [out addObject:@[ path, o ]];
        else if (o) [out addObject:@[ path, @"<object>", o ]];
        return;
    }
    if (kind == 0x303) { // existential
        uint32_t flags = *(const uint32_t *)((const uint8_t *)md + 8);
        if ((flags & 0x80000000) == 0) { // class-bound: like a class reference
            const void *obj = *(const void *const *)value;
            const void *dyn = obj ? *(const void *const *)obj : NULL;
            if (dyn) WPCollectLeaves(value, dyn, path, depth + 1, out);
            return;
        }
        const void *dyn = ((const void *const *)value)[3];
        if (!dyn) return;
        const WPValueWitnessTable *vwt = WPVWT(dyn);
        const void *inner = value;
        if (vwt->flags & 0x00020000) {
            size_t mask = vwt->flags & 0xFF;
            inner = *(const uint8_t *const *)value + ((16 + mask) & ~mask);
        }
        WPCollectLeaves(inner, dyn, path, depth + 1, out);
        return;
    }
    if ([typeName hasPrefix:@"Swift.Array<"] || [typeName hasPrefix:@"Swift.ContiguousArray<"]) {
        const uint8_t *buffer = *(const uint8_t *const *)value;
        const void *elementType = ((const void *const *)md)[2];
        if (!buffer || !elementType) return;
        intptr_t count = *(const intptr_t *)(buffer + 16);
        const WPValueWitnessTable *evwt = WPVWT(elementType);
        size_t mask = evwt->flags & 0xFF;
        const uint8_t *first = buffer + ((32 + mask) & ~mask);
        for (intptr_t i = 0; i < count && i < 16; i++) {
            WPCollectLeaves(first + i * MAX(evwt->stride, 1), elementType, [path stringByAppendingFormat:@"[%ld]", (long)i], depth + 1, out);
        }
        return;
    }
    static WPGetTypeByMangledName getType;
    if (!getType) getType = (WPGetTypeByMangledName)dlsym(RTLD_DEFAULT, "swift_getTypeByMangledNameInContext");
    if (!getType) return;
    if (kind == 0x201 || kind == 0x202) { // enum / optional
        const uint8_t *desc = ((const uint8_t *const *)md)[1];
        const uint8_t *fd = WPRelDirect((const int32_t *)(desc + 16));
        if (!fd) return;
        uint16_t recordSize = *(const uint16_t *)(fd + 10);
        uint32_t count = *(const uint32_t *)(fd + 12);
        uint32_t payloadCases = *(const uint32_t *)(desc + 20) & 0x00FFFFFF;
        const void *const *witnesses = (const void *const *)WPVWT(md);
        unsigned tag = ((WPEnumTagFn)witnesses[11])(value, md);
        if (tag >= count || recordSize < 12) return;
        const uint8_t *rec = fd + 16 + tag * recordSize;
        const char *caseName = WPRelDirect((const int32_t *)(rec + 8));
        const uint8_t *mangled = WPRelDirect((const int32_t *)(rec + 4));
        if (tag >= payloadCases || !mangled || !*mangled) {
            if (kind == 0x201) [out addObject:@[ path, [NSString stringWithFormat:@"case:%s", caseName ?: "?"] ]];
            return;
        }
        const void *payloadType = getType((const char *)mangled, WPMangledLength(mangled), desc, (const void *const *)md + 2);
        if (!payloadType) return;
        // Take the payload out of a copy (projecting clears the tag bits in place).
        void *copy = WPAllocValue(md);
        ((WPCopyValue)WPVWT(md)->functions[2])(copy, value, md);
        ((WPEnumProjectFn)witnesses[12])(copy, md);
        const void *payload = copy;
        if (*(const uint32_t *)rec & 1) { // indirect case: the payload lives in a box
            const WPValueWitnessTable *pvwt = WPVWT(payloadType);
            size_t pmask = pvwt->flags & 0xFF;
            payload = *(const uint8_t *const *)copy + ((16 + pmask) & ~pmask);
        }
        NSString *sub = kind == 0x202 ? path : [path stringByAppendingFormat:@".%s", caseName ?: "?"];
        WPCollectLeaves(payload, payloadType, sub, depth + 1, out);
        return;
    }
    BOOL isClass = WPIsClassMetadata(md);
    const uint8_t *base = value;
    const void *fieldsMD = md;
    const uint8_t *desc = NULL;
    if (isClass) {
        const void *obj = *(const void *const *)value;
        if (!obj) return;
        fieldsMD = *(const void *const *)obj;
        desc = WPClassDescriptor(fieldsMD);
        if (!desc) { // an Objective-C object (NSBundle, NSString…)
            id o = (__bridge id)obj;
            if ([o isKindOfClass:[NSString class]]) [out addObject:@[ path, o ]];
            else [out addObject:@[ path, @"<object>", o ]];
            return;
        }
        base = obj;
    } else if (kind == 0x200) {
        desc = ((const uint8_t *const *)md)[1];
    }
    if (!desc) return;
    const uint8_t *fd = WPRelDirect((const int32_t *)(desc + 16));
    if (!fd) return;
    uint16_t recordSize = *(const uint16_t *)(fd + 10);
    uint32_t count = *(const uint32_t *)(fd + 12);
    if (recordSize < 12 || count > 128) return;
    const void *const *genericArgs;
    const uint8_t *offsetBase;
    if (isClass) {
        uint32_t positive = *(const uint32_t *)(desc + 28);
        uint32_t immediate = *(const uint32_t *)(desc + 32);
        genericArgs = (const void *const *)fieldsMD + (positive - immediate);
        offsetBase = (const uint8_t *)fieldsMD + *(const uint32_t *)(desc + 40) * 8;
    } else {
        genericArgs = (const void *const *)md + 2;
        offsetBase = (const uint8_t *)md + *(const uint32_t *)(desc + 24) * 8;
    }
    const uint8_t *rec = fd + 16;
    for (uint32_t i = 0; i < count; i++, rec += recordSize) {
        const uint8_t *mangled = WPRelDirect((const int32_t *)(rec + 4));
        const char *name = WPRelDirect((const int32_t *)(rec + 8));
        if (!mangled || !*mangled) continue;
        const void *fieldType = getType((const char *)mangled, WPMangledLength(mangled), desc, genericArgs);
        if (!fieldType) continue;
        size_t offset = isClass ? ((const size_t *)offsetBase)[i] : ((const uint32_t *)offsetBase)[i];
        WPCollectLeaves(base + offset, fieldType, [path stringByAppendingFormat:@".%s", name ?: "?"], depth + 1, out);
    }
}

// A Swift Array<T> holding a copy of one value, made by the standard library's own
// _allocateUninitializedArray<T>(_:); returns storage for the array variable.
typedef struct { void *array; void *elements; } WPArrayAndBase;
typedef WPArrayAndBase (*WPAllocArrayFn)(intptr_t count, const void *elementType) SWIFTCALL;

static void *WPMakeArrayOfOne(const void *value, const void *type) {
    WPAllocArrayFn alloc = (WPAllocArrayFn)dlsym(RTLD_DEFAULT, "$ss27_allocateUninitializedArrayySayxG_BptBwlF");
    if (!alloc) {
        WPRuntimeLog(@"  the array-making function was not found");
        return NULL;
    }
    WPArrayAndBase r = alloc(1, type);
    if (!r.array || !r.elements) return NULL;
    ((WPCopyValue)WPVWT(type)->functions[2])(r.elements, value, type);
    void **var = calloc(1, sizeof(void *));
    *var = r.array;
    return var;
}

// At the innermost configuration: its descriptor, with the collected transforms applied.
static void WPRecordDescriptor(const void *value, const void *md) {
    size_t offset = 0;
    const void *descType = NULL;
    if (gWPDescDisabled || !WPStructField(md, "descriptor", &offset, &descType) || !descType) return;
    void *descriptor = WPAllocValue(descType);
    ((WPCopyValue)WPVWT(descType)->functions[2])(descriptor, (const uint8_t *)value + offset, descType);
    // WidgetDescriptorKey's value is [WidgetDescriptor] (a bundle's widgets go together); the
    // transforms edit that array, so they get one holding this widget's descriptor.
    void *array = NULL; // storage of a Swift.Array<WidgetDescriptor> variable
    for (int i = gWPDescTransformCount - 1; i >= 0; i--) {
        const void *fnType = gWPDescTransforms[i].fnType;
        if (!fnType || *(const uintptr_t *)fnType != 0x302 || (((const size_t *)fnType)[1] & 0xFFFF) != 1) continue;
        const void *param = ((const void *const *)fnType)[3];
        const void *const *pair = gWPDescTransforms[i].closure;
        if (param == descType && !array) {
            ((WPInoutClosure)pair[0])(descriptor, pair[1]);
            continue;
        }
        if (![WPTypeName(param) hasPrefix:@"Swift.Array<"] || ((const void *const *)param)[2] != descType) {
            static BOOL logged;
            if (!logged) {
                logged = YES;
                WPRuntimeLog(@"  unexpected type of the descriptor transform: %@", WPTypeName(fnType));
            }
            continue;
        }
        if (!array) array = WPMakeArrayOfOne(descriptor, descType);
        if (array) ((WPInoutClosure)pair[0])(array, pair[1]);
    }
    if (array) { // back from the array: its first element
        const uint8_t *buffer = *(const uint8_t *const *)array;
        intptr_t count = buffer ? *(const intptr_t *)(buffer + 16) : 0;
        if (count >= 1) {
            const WPValueWitnessTable *vwt = WPVWT(descType);
            size_t mask = vwt->flags & 0xFF;
            const uint8_t *first = buffer + ((32 + mask) & ~mask);
            descriptor = WPAllocValue(descType);
            ((WPCopyValue)vwt->functions[2])(descriptor, first, descType);
        }
        if (count != 1) WPRuntimeLog(@"  descriptor array: %ld after the transform", (long)count);
    }
    NSMutableArray *leaves = [NSMutableArray array];
    WPCollectLeaves(descriptor, descType, @"", 0, leaves);
    if (leaves.count == 0) {
        // Nothing readable: record how the descriptor type looks, to read it next time.
        static BOOL logged;
        if (!logged) {
            logged = YES;
            uintptr_t kind = *(const uintptr_t *)descType;
            const uint8_t *tdesc = (kind == 0x200 || kind == 0x201 || kind == 0x202) ? ((const uint8_t *const *)descType)[1] : NULL;
            const uint8_t *fd = tdesc ? WPRelDirect((const int32_t *)(tdesc + 16)) : NULL;
            NSMutableArray *fields = [NSMutableArray array];
            if (fd) {
                uint16_t recordSize = *(const uint16_t *)(fd + 10);
                uint32_t count = *(const uint32_t *)(fd + 12);
                static WPGetTypeByMangledName getType;
                if (!getType) getType = (WPGetTypeByMangledName)dlsym(RTLD_DEFAULT, "swift_getTypeByMangledNameInContext");
                const uint8_t *rec = fd + 16;
                for (uint32_t i = 0; i < count && i < 64 && recordSize >= 12; i++, rec += recordSize) {
                    const uint8_t *mangled = WPRelDirect((const int32_t *)(rec + 4));
                    const char *name = WPRelDirect((const int32_t *)(rec + 8));
                    const void *t = (mangled && *mangled && getType) ? getType((const char *)mangled, WPMangledLength(mangled), tdesc, (const void *const *)descType + 2) : NULL;
                    [fields addObject:[NSString stringWithFormat:@"%s:%@", name ?: "?", t ? WPTypeName(t) : (mangled && *mangled ? WPDescribeMangled(mangled) : @"-")]];
                }
            }
            WPRuntimeLog(@"  descriptor type: %@ (kind 0x%lx, %zu bytes, field info %@) %@", WPTypeName(descType), (unsigned long)kind,
                         WPVWT(descType)->size, fd ? @"yes" : @"no", [fields componentsJoinedByString:@", "]);
        }
    }
    if (!gWPDescLeaves) gWPDescLeaves = [NSMutableArray array];
    [gWPDescLeaves addObject:leaves];
}

// Reads kind, name, description and sizes out of a descriptor's leaves. Localized names are
// looked up in the bundle the text names, or the extension's bundle.
static NSDictionary *WPDescriptorInfo(NSArray *leaves, NSBundle *extensionBundle) {
    NSString *kind = nil;
    NSMutableDictionary<NSString *, NSMutableArray *> *byRoot = [NSMutableDictionary dictionary];
    NSMutableOrderedSet *families = [NSMutableOrderedSet orderedSet];
    BOOL sawFamilies = NO; // the widget names its sizes (none of them may be for the home screen)
    for (NSArray *leaf in leaves) {
        NSString *path = leaf[0];
        NSArray *parts = [path componentsSeparatedByString:@"."];
        NSString *root = parts.count > 1 ? parts[1] : @"";
        NSRange bracket = [root rangeOfString:@"["];
        if (bracket.location != NSNotFound) root = [root substringToIndex:bracket.location];
        // The kind sits at .kind or deeper (.source.timeline.kind).
        if (([root isEqualToString:@"kind"] || [path hasSuffix:@".kind"]) && leaf.count == 2 && !kind) kind = leaf[1];
        if ([root isEqualToString:@"supportedFamilies"] && [leaf[1] hasPrefix:@"int:"]) {
            sawFamilies = YES;
            long family = [[leaf[1] substringFromIndex:4] integerValue];
            if (family == 1) [families addObject:@"small"];
            else if (family == 2) [families addObject:@"medium"];
            else if (family == 3) [families addObject:@"large"];
        }
        if (!byRoot[root]) byRoot[root] = [NSMutableArray array];
        [byRoot[root] addObject:leaf];
    }
    // A text: a verbatim string, or a localization key (+ table, bundle) to look up.
    NSString * (^text)(NSArray *) = ^NSString *(NSArray *items) {
        NSString *key = nil, *verbatim = nil, *table = nil, *fallback = nil;
        NSBundle *bundle = nil;
        for (NSArray *leaf in items) {
            NSString *path = leaf[0];
            NSString *last = [[path componentsSeparatedByString:@"."] lastObject];
            if (leaf.count > 2) {
                if ([leaf[2] isKindOfClass:[NSBundle class]]) bundle = leaf[2];
                continue;
            }
            NSString *s = leaf[1];
            if (![s isKindOfClass:[NSString class]] || [s hasPrefix:@"case:"]) continue;
            NSString *lower = path.lowercaseString;
            if ([lower containsString:@"table"]) { if (!table) table = s; continue; }
            if ([lower containsString:@"verbatim"]) { if (!verbatim) verbatim = s; continue; }
            if ([lower containsString:@"default"]) { if (!fallback) fallback = s; continue; }
            if ([last isEqualToString:@"key"] || [lower containsString:@".key"]) { if (!key) key = s; continue; }
            if (!fallback) fallback = s;
        }
        if (verbatim.length) return verbatim;
        if (key.length) {
            NSString *found = [bundle ?: extensionBundle localizedStringForKey:key value:@"\x01" table:table];
            if (found.length && ![found isEqualToString:@"\x01"]) return found;
            if (bundle && extensionBundle) found = [extensionBundle localizedStringForKey:key value:@"\x01" table:table];
            if (found.length && ![found isEqualToString:@"\x01"]) return found;
            return fallback.length ? fallback : key;
        }
        return fallback;
    };
    NSString *name = nil, *description = nil;
    for (NSString *root in byRoot) {
        NSString *lower = root.lowercaseString;
        if (!name && [lower containsString:@"displayname"]) name = text(byRoot[root]);
        else if (!description && [lower containsString:@"description"]) description = text(byRoot[root]);
    }
    // Read as plain text but really a localization key (seen with SiriKit-intent widgets):
    // the extension's own strings know it.
    NSString * (^translated)(NSString *) = ^NSString *(NSString *t) {
        if (!t.length || !extensionBundle) return t;
        NSString *found = [extensionBundle localizedStringForKey:t value:@"\x01" table:nil];
        if (!found.length || [found isEqualToString:@"\x01"] || [found isEqualToString:t]) return t;
        static NSMutableSet *logged;
        if (!logged) logged = [NSMutableSet set];
        if (![logged containsObject:t]) {
            [logged addObject:t];
            WPRuntimeLog(@"  translated name key: %@ → %@", t, found);
        }
        return [found stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    };
    name = translated(name);
    description = translated(description);
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (kind) info[@"kind"] = kind;
    if (name.length) info[@"name"] = name;
    if (description.length) info[@"description"] = description;
    if (sawFamilies) { // in the order small, medium, large; may be empty: not for the home screen
        info[@"families"] = [@[ @"small", @"medium", @"large" ] filteredArrayUsingPredicate:
                             [NSPredicate predicateWithBlock:^BOOL(NSString *f, NSDictionary *b) { return [families containsObject:f]; }]];
    }
    return info;
}

static void WPExploreValue(const void *value, const void *metadata, int depth, NSMutableString *log) {
    NSString *indent = WPIndent(depth);
    NSString *typeName = WPTypeName(metadata);
    WPLOG(log, @"%@● %@", indent, typeName);
    BOOL isStatic = [typeName hasPrefix:@"WidgetKit.StaticConfiguration<"];
    if ((isStatic || [typeName hasPrefix:@"WidgetKit.IntentConfiguration<"] || [typeName hasPrefix:@"WidgetKit.AppIntentConfiguration<"]) &&
        gWPConfigCount < 16) {
        gWPConfigs[gWPConfigCount++] = (WPFoundConfig){ value, metadata, isStatic };
    }
    WPDumpStructFields(metadata, depth, log);
    if ([typeName isEqualToString:@"WidgetKit.WidgetDescriptorConfiguration"]) WPRecordDescriptor(value, metadata);

    const uint8_t *desc = WPStructDescriptor(metadata);
    const char *name = desc ? WPRelDirect((const int32_t *)(desc + 8)) : NULL;
    if (name && strcmp(name, "ModifiedContent") == 0) {
        // ModifiedContent<Content, Modifier>: field 0 is the content, generic argument 0 its type.
        uint32_t fieldOffsetVector = *(const uint32_t *)(desc + 24);
        const uint32_t *offsets = (const uint32_t *)((const uint8_t *)metadata + fieldOffsetVector * 8);
        const void *contentType = ((const void *const *)metadata)[2];
        const void *modifierType = ((const void *const *)metadata)[3];
        // A descriptor transform (display name, description, sizes…) around the content.
        BOOL pushed = NO;
        size_t transformOffset = 0;
        const void *transformType = NULL;
        if ([WPTypeName(modifierType) hasPrefix:@"SwiftUI._PreferenceTransformModifier<WidgetKit.WidgetDescriptorKey>"] &&
            gWPDescTransformCount < 32 && WPStructField(modifierType, "transform", &transformOffset, &transformType)) {
            gWPDescTransforms[gWPDescTransformCount++] =
                (WPDescTransform){ (const uint8_t *)value + offsets[1] + transformOffset, transformType };
            pushed = YES;
        }
        WPExploreValue((const uint8_t *)value + offsets[0], contentType, depth + 1, log);
        if (pushed) gWPDescTransformCount--;
        return;
    }
    if (depth >= 16) return;

    const void *proto = dlsym(RTLD_DEFAULT, "$s7SwiftUI19WidgetConfigurationMp");
    WPConformsToProtocol conformsTo = (WPConformsToProtocol)dlsym(RTLD_DEFAULT, "swift_conformsToProtocol");
    WPGetAssociatedTypeWitness assoc = (WPGetAssociatedTypeWitness)dlsym(RTLD_DEFAULT, "swift_getAssociatedTypeWitness");
    if (!proto || !conformsTo || !assoc) return;
    const void *const *wt = conformsTo(metadata, proto);
    if (!wt) return;
    WPProtocolLayout layout;
    if (!WPReadProtocolLayout(proto, &layout)) return;
    const void *bodyType = assoc(0, wt, metadata, layout.reqBase, layout.firstAssocType).metadata;
    NSString *bodyName = WPTypeName(bodyType);
    WPLOG(log, @"%@  Body = %@", indent, bodyName);
    if ([bodyName isEqualToString:@"Swift.Never"]) {
        WPLOG(log, @"%@  (basic configuration, cannot be taken apart further)", indent);
        return;
    }
    int getter = WPFindRequirement(proto, 3);
    if (getter < 0) return;
    void *out = WPAllocValue(bodyType);
    if (!out) return;
    WPLOG(log, @"%@  calling body...", indent);
    ((WPWitnessGetter)wt[getter + 1])(out, metadata, wt, value);
    WPExploreValue(out, bodyType, depth + 1, log);
}

// Builds the widget with init(), reads its body and explores the configuration tree.
static void WPExploreWidget(const void *metadata, const void *const *wt, const void *proto,
                            const void *bodyType, NSMutableString *log) {
    int initIndex = WPFindRequirement(proto, 2);
    int getterIndex = WPFindRequirement(proto, 3);
    WPLOG(log, @"    -- stage 3: contents (init is #%d, body is #%d)", initIndex, getterIndex);
    if (initIndex < 0 || getterIndex < 0) return;
    void *widget = WPAllocValue(metadata);
    void *body = WPAllocValue(bodyType);
    if (!widget || !body) return;
    WPLOG(log, @"    calling init()...");
    ((WPWitnessInit)wt[initIndex + 1])(widget, metadata, wt, metadata);
    WPLOG(log, @"    calling body...");
    ((WPWitnessGetter)wt[getterIndex + 1])(body, metadata, wt, widget);
    WPLOG(log, @"    configuration tree:");
    WPExploreValue(body, bodyType, 3, log);
}

typedef struct {
    size_t protocolIndex;
    const uint8_t *type; // type context descriptor
} WPMatch;

static void WPScanConformances(const struct mach_header *mh, NSMutableString *log) {
    unsigned long size = 0;
    const int32_t *records = (const int32_t *)getsectiondata((const struct mach_header_64 *)mh, "__TEXT", "__swift5_proto", &size);
    if (!records || size == 0) {
        WPLOG(log, @"  no __swift5_proto (no Swift type info)");
        return;
    }
    size_t count = size / sizeof(int32_t);
    WPLOG(log, @"  protocol conformance records: %zu", count);

    size_t nproto = sizeof(kWPProtocols) / sizeof(kWPProtocols[0]);
    const void *protocols[8] = {0};
    for (size_t p = 0; p < nproto; p++) {
        protocols[p] = dlsym(RTLD_DEFAULT, kWPProtocols[p].protocolSymbol);
        WPLOG(log, @"  descriptor %s: %@", kWPProtocols[p].name, protocols[p] ? @"OK" : @"not found");
    }

    // Phase 1: read descriptors only. Nothing from the extension runs here.
    WPLOG(log, @"  -- stage 1: reading type names (no code is run)");
    WPMatch matches[64];
    size_t nmatch = 0;
    for (size_t i = 0; i < count; i++) {
        const WPConformanceDescriptor *desc = WPRelDirect(&records[i]);
        if (!desc) continue;
        const void *proto = WPRelIndirectable(&desc->protocol);
        if (!proto) continue;
        size_t which = SIZE_MAX;
        for (size_t p = 0; p < nproto; p++) {
            if (protocols[p] && proto == protocols[p]) { which = p; break; }
        }
        if (which == SIZE_MAX) continue;

        uint32_t kind = (desc->flags >> 3) & 7;
        const uint8_t *type = NULL;
        if (kind == 0) type = WPRelDirect(&desc->typeRef);
        else if (kind == 1) {
            const void *const *slot = WPRelDirect(&desc->typeRef);
            type = slot ? *slot : NULL;
        }
        if (!type) {
            WPLOG(log, @"  [%s] (no type descriptor, kind %u)", kWPProtocols[which].name, kind);
            continue;
        }
        uint32_t typeFlags = *(const uint32_t *)type;
        const char *typeName = WPRelDirect((const int32_t *)(type + 8));
        WPLOG(log, @"  [%s] %s%s (kind %u)", kWPProtocols[which].name, typeName ?: "?",
              (typeFlags & 0x80) ? " <generic>" : "", typeFlags & 0x1F);
        if (!(typeFlags & 0x80) && nmatch < 64) {
            matches[nmatch].protocolIndex = which;
            matches[nmatch].type = type;
            nmatch++;
        }
    }

    // Phase 2: ask the Swift runtime for metadata (runs the types' metadata accessors).
    WPLOG(log, @"  -- stage 2: type info from the Swift runtime");
    WPConformsToProtocol conformsTo = (WPConformsToProtocol)dlsym(RTLD_DEFAULT, "swift_conformsToProtocol");
    WPGetAssociatedTypeWitness assoc = (WPGetAssociatedTypeWitness)dlsym(RTLD_DEFAULT, "swift_getAssociatedTypeWitness");

    // Widgets first, the bundle last (the bundle's Body crashed in 0.2).
    size_t order[64];
    size_t norder = 0;
    for (int pass = 0; pass < 2; pass++) {
        for (size_t m = 0; m < nmatch; m++) {
            BOOL isBundle = matches[m].protocolIndex == 0;
            if ((pass == 0) != isBundle) order[norder++] = m;
        }
    }

    for (size_t o = 0; o < norder; o++) {
        size_t m = order[o];
        size_t pidx = matches[m].protocolIndex;
        const WPProtocolInfo *info = &kWPProtocols[pidx];
        const uint8_t *type = matches[m].type;
        const char *typeName = WPRelDirect((const int32_t *)(type + 8));
        WPMetadataAccessor accessor = (WPMetadataAccessor)WPRelDirect((const int32_t *)(type + 12));
        if (!accessor) {
            WPLOG(log, @"  %s: no metadata accessor", typeName ?: "?");
            continue;
        }
        WPLOG(log, @"  [%s] %s: getting metadata...", info->name, typeName ?: "?");
        const void *metadata = accessor(0).metadata;
        WPLOG(log, @"    → %@", WPTypeName(metadata));
        if (!info->bodySymbol || !conformsTo || !assoc) continue;

        WPLOG(log, @"    getting the witness table...");
        const void *const *wt = conformsTo(metadata, protocols[pidx]);
        if (!wt) {
            WPLOG(log, @"    no witness table");
            continue;
        }
        WPProtocolLayout layout;
        BOOL haveLayout = WPReadProtocolLayout(protocols[pidx], &layout);
        const void *symBase = dlsym(RTLD_DEFAULT, info->reqBaseSymbol);
        const void *symBody = dlsym(RTLD_DEFAULT, info->bodySymbol);
        WPLOG(log, @"    requirements: from the descriptor base=%p body=%p (%u requirements, Body is #%u) / SDK symbols base=%p body=%p",
              haveLayout ? layout.reqBase : NULL, haveLayout ? layout.firstAssocType : NULL,
              haveLayout ? layout.numRequirements : 0, haveLayout ? layout.assocIndex : 0, symBase, symBody);
        if (!haveLayout) continue;

        uintptr_t slot = (uintptr_t)wt[layout.assocIndex + 1];
        if (slot & 1) {
            WPLOG(log, @"    Body entry (unresolved type name): %@", WPDescribeMangled((const uint8_t *)(slot & ~(uintptr_t)1)));
        } else {
            WPLOG(log, @"    Body entry (resolved): %@", WPTypeName((const void *)slot));
        }

        WPLOG(log, @"    getting the Body type...");
        const void *body = assoc(0, wt, metadata, layout.reqBase, layout.firstAssocType).metadata;
        WPLOG(log, @"    Body = %@", WPTypeName(body));
        if (pidx == 1 && body) WPExploreWidget(metadata, wt, protocols[pidx], body, log);
        if (pidx == 0 && body) {
            // The extension's @main WidgetBundle: WidgetKit creates it first, and apps set up
            // their services (Firebase, databases, …) in its init().
            int initIndex = WPFindRequirement(protocols[pidx], 2);
            int getterIndex = WPFindRequirement(protocols[pidx], 3);
            if (initIndex >= 0 && getterIndex >= 0) {
                void *bundle = WPAllocValue(metadata);
                void *bundleBody = WPAllocValue(body);
                WPLOG(log, @"    running the WidgetBundle's init() and body (the app's setup)");
                ((WPWitnessInit)wt[initIndex + 1])(bundle, metadata, wt, metadata);
                ((WPWitnessGetter)wt[getterIndex + 1])(bundleBody, metadata, wt, bundle);
            }
        }
    }
    WPLOG(log, @"  widget-related types: %zu", nmatch);
    WPPhase4(log);
}

@end

#pragma mark - Home screen runtime

// Reads a Swift.String stored at p (two words) without calling into Swift.
static NSString *WPSwiftString(const void *p) {
    uint64_t w0 = ((const uint64_t *)p)[0];
    uint64_t w1 = ((const uint64_t *)p)[1];
    uint8_t top = (uint8_t)(w1 >> 56);
    if (top & 0x20) { // small string: up to 15 UTF-8 bytes inline
        size_t count = top & 0x0F;
        char buf[16] = { 0 };
        memcpy(buf, &w0, 8);
        uint64_t rest = w1 & 0x00FFFFFFFFFFFFFFULL;
        memcpy(buf + 8, &rest, 7);
        return [[NSString alloc] initWithBytes:buf length:count encoding:NSUTF8StringEncoding];
    }
    uintptr_t object = (uintptr_t)(w1 & 0x0FFFFFFFFFFFFFFFULL);
    if (!object) return @"";
    if ((top & 0x10) == 0 && (top & 0x40)) { // bridged Objective-C string
        return (__bridge NSString *)(void *)object;
    }
    size_t count = (size_t)(w0 & 0x0000FFFFFFFFFFFFULL);
    if (count > 4096) return nil;
    return [[NSString alloc] initWithBytes:(const void *)(object + 32) length:count encoding:NSUTF8StringEncoding];
}

#pragma mark Shared data (App Groups) of the widget's app

// Nyxian gives each guest process its own view of App Groups and suite defaults, based on
// that process's home. The widget extension runs inside SpringBoard, so it would see
// SpringBoard's copies; these hooks point it at the app's.
static NSMutableDictionary<NSString *, NSString *> *gWPGroupAppData;       // group → app data container
static NSMutableDictionary<NSString *, NSArray<NSString *> *> *gWPExtGroups; // extension → groups
static NSMutableDictionary<NSString *, NSString *> *gWPGroupExtension;     // group → extension
static IMP gWPOrigContainerURL, gWPOrigPrefsInit;
static NSMutableDictionary<NSString *, NSNumber *> *gWPLastRender; // extension → time a render started

static NSString *WPAppGroupPath(NSString *dataPath, NSString *group) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *nyxianStyle = [NSString stringWithFormat:@"%@/Documents/(null)/Documents/AppGroup/%@", dataPath, group];
    NSString *plain = [NSString stringWithFormat:@"%@/Documents/AppGroup/%@", dataPath, group];
    if ([fm fileExistsAtPath:plain] && ![fm fileExistsAtPath:nyxianStyle]) return plain;
    return nyxianStyle;
}

static NSURL *WPContainerURLHook(id self, SEL _cmd, NSString *group) {
    NSString *dataPath = group ? gWPGroupAppData[group] : nil;
    if (dataPath) {
        NSString *path = WPAppGroupPath(dataPath, group);
        [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
        return [NSURL fileURLWithPath:path isDirectory:YES];
    }
    return ((NSURL *(*)(id, SEL, NSString *))gWPOrigContainerURL)(self, _cmd, group);
}

// Replacements for init methods follow init's ownership rules: self is consumed and the
// result is returned retained (+1), or ARC would release the object once too often.
#define WP_INIT_ATTRS __attribute__((ns_returns_retained))
typedef id (*WPPrefsInitFn)(__attribute__((ns_consumed)) id, SEL, CFStringRef, CFStringRef, bool, CFStringRef, id) WP_INIT_ATTRS;

static id WPPrefsInitHook(__attribute__((ns_consumed)) id self, SEL _cmd, CFStringRef domain, CFStringRef user, bool byHost,
                          CFStringRef containerPath, id containing) WP_INIT_ATTRS {
    NSString *dataPath = domain ? gWPGroupAppData[(__bridge NSString *)domain] : nil;
    if (dataPath) {
        // Nyxian's own hook replaces the container path with the process home; call the
        // original implementation (which Nyxian keeps under its hook's selector) directly.
        SEL original = NSSelectorFromString(@"hook_initWithDomain:user:byHost:containerPath:containingPreferences:");
        if (user == kCFPreferencesAnyUser) user = kCFPreferencesCurrentUser;
        if ([self respondsToSelector:original]) {
            return ((WPPrefsInitFn)objc_msgSend)(self, original, domain, user, byHost, (__bridge CFStringRef)dataPath, containing);
        }
        return ((WPPrefsInitFn)gWPOrigPrefsInit)(self, _cmd, domain, user, byHost, (__bridge CFStringRef)dataPath, containing);
    }
    return ((WPPrefsInitFn)gWPOrigPrefsInit)(self, _cmd, domain, user, byHost, containerPath, containing);
}

// Suite defaults of an app group, read from and written to the app's own plist file.
// Foundation's typed getters are overridden too, so nothing goes through CFPreferences.
@interface WPGroupDefaults : NSUserDefaults
@property (nonatomic, copy) NSString *plistPath;
@property (nonatomic, copy) NSString *group;
@end

@implementation WPGroupDefaults {
    NSMutableDictionary *_values;
    NSDate *_loadedMTime;
    NSLock *_lock;
}

- (NSDictionary *)wp_values {
    [_lock lock];
    NSDate *m = [[NSFileManager defaultManager] attributesOfItemAtPath:self.plistPath error:nil][NSFileModificationDate];
    if (!_values || (m && ![m isEqualToDate:_loadedMTime])) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:self.plistPath];
        _values = d ? [d mutableCopy] : (_values ?: [NSMutableDictionary dictionary]);
        _loadedMTime = m;
    }
    NSDictionary *copy = [_values copy];
    [_lock unlock];
    return copy;
}

- (void)wp_write:(void (^)(NSMutableDictionary *values))change {
    [self wp_values];
    [_lock lock];
    change(_values);
    [[NSFileManager defaultManager] createDirectoryAtPath:self.plistPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:_values format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    [data writeToFile:self.plistPath atomically:YES];
    _loadedMTime = [[NSFileManager defaultManager] attributesOfItemAtPath:self.plistPath error:nil][NSFileModificationDate];
    [_lock unlock];
}

- (id)objectForKey:(NSString *)key { return key ? [self wp_values][key] : nil; }
- (void)setObject:(id)value forKey:(NSString *)key {
    if (!key) return;
    [self wp_write:^(NSMutableDictionary *v) { if (value) v[key] = value; else [v removeObjectForKey:key]; }];
}
- (void)removeObjectForKey:(NSString *)key { [self setObject:nil forKey:key]; }
- (NSDictionary *)dictionaryRepresentation { return [self wp_values]; }
- (BOOL)synchronize { [self wp_values]; return YES; }
- (NSString *)stringForKey:(NSString *)key { id v = [self objectForKey:key]; return [v isKindOfClass:[NSString class]] ? v : ([v isKindOfClass:[NSNumber class]] ? [v stringValue] : nil); }
- (NSData *)dataForKey:(NSString *)key { id v = [self objectForKey:key]; return [v isKindOfClass:[NSData class]] ? v : nil; }
- (NSArray *)arrayForKey:(NSString *)key { id v = [self objectForKey:key]; return [v isKindOfClass:[NSArray class]] ? v : nil; }
- (NSDictionary *)dictionaryForKey:(NSString *)key { id v = [self objectForKey:key]; return [v isKindOfClass:[NSDictionary class]] ? v : nil; }
- (NSArray *)stringArrayForKey:(NSString *)key { return [self arrayForKey:key]; }
- (BOOL)boolForKey:(NSString *)key { id v = [self objectForKey:key]; return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO; }
- (NSInteger)integerForKey:(NSString *)key { id v = [self objectForKey:key]; return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : 0; }
- (double)doubleForKey:(NSString *)key { id v = [self objectForKey:key]; return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0; }
- (float)floatForKey:(NSString *)key { id v = [self objectForKey:key]; return [v respondsToSelector:@selector(floatValue)] ? [v floatValue] : 0; }
- (NSURL *)URLForKey:(NSString *)key {
    id v = [self objectForKey:key];
    if ([v isKindOfClass:[NSURL class]]) return v;
    if ([v isKindOfClass:[NSString class]]) return [NSURL fileURLWithPath:[v stringByExpandingTildeInPath]];
    if ([v isKindOfClass:[NSData class]]) return [NSKeyedUnarchiver unarchivedObjectOfClass:[NSURL class] fromData:v error:nil];
    return nil;
}
- (void)setBool:(BOOL)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setInteger:(NSInteger)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setDouble:(double)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setFloat:(float)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setURL:(NSURL *)url forKey:(NSString *)key { [self setObject:url.absoluteString forKey:key]; }
- (void)registerDefaults:(NSDictionary *)defaults {
    [self wp_values];
    [_lock lock];
    for (NSString *k in defaults) if (!_values[k]) _values[k] = defaults[k];
    [_lock unlock];
}

+ (instancetype)defaultsForGroup:(NSString *)group plistPath:(NSString *)path {
    WPGroupDefaults *d = [[self alloc] initWithSuiteName:[@"com.rinapple.widgetprobe.shadow." stringByAppendingString:group]];
    d.group = group;
    d.plistPath = path;
    d->_lock = [NSLock new];
    return d;
}
@end

static IMP gWPOrigSuiteInit;
static NSUInteger gWPSuiteRedirects;

typedef id (*WPSuiteInitFn)(__attribute__((ns_consumed)) id, SEL, NSString *) WP_INIT_ATTRS;

static id WPSuiteInitHook(__attribute__((ns_consumed)) NSUserDefaults *self, SEL _cmd, NSString *suite) WP_INIT_ATTRS {
    NSString *dataPath = [suite isKindOfClass:[NSString class]] ? gWPGroupAppData[suite] : nil;
    if (dataPath && ![self isKindOfClass:[WPGroupDefaults class]]) {
        gWPSuiteRedirects++;
        // self (the allocated NSUserDefaults) is released by ARC; the replacement is returned +1.
        return [WPGroupDefaults defaultsForGroup:suite plistPath:[NSString stringWithFormat:@"%@/Library/Preferences/%@.plist", dataPath, suite]];
    }
    return ((WPSuiteInitFn)gWPOrigSuiteInit)(self, _cmd, suite);
}


static void WPInstallSharedDataHooks(void) {
    static BOOL installed;
    if (installed) return;
    installed = YES;
    Method m = class_getInstanceMethod([NSFileManager class], @selector(containerURLForSecurityApplicationGroupIdentifier:));
    if (m) gWPOrigContainerURL = method_setImplementation(m, (IMP)WPContainerURLHook);
    Class prefs = NSClassFromString(@"CFPrefsPlistSource");
    Method p = prefs ? class_getInstanceMethod(prefs, NSSelectorFromString(@"initWithDomain:user:byHost:containerPath:containingPreferences:")) : NULL;
    if (p) gWPOrigPrefsInit = method_setImplementation(p, (IMP)WPPrefsInitHook);
    Method su = class_getInstanceMethod([NSUserDefaults class], @selector(initWithSuiteName:));
    if (su) gWPOrigSuiteInit = method_setImplementation(su, (IMP)WPSuiteInitHook);
    NSLog(@"[WidgetProbe] shared data hooks: containerURL=%d prefs=%d suite=%d", m != NULL, p != NULL, su != NULL);
}

// When the app writes its shared data, tell the home screen (like WidgetCenter.reloadTimelines).
static void WPWatchDirectory(NSString *path, NSString *extID) {
    static NSMutableDictionary *sources;
    if (!sources) sources = [NSMutableDictionary dictionary];
    if (!path || sources[path]) return;
    int fd = open(path.fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) return;
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd,
                                                   DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_ATTRIB,
                                                   dispatch_get_main_queue());
    __block BOOL pending = NO;
    dispatch_source_set_event_handler(src, ^{
        if (pending) return;
        pending = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            pending = NO;
            // Writes made by the extension itself while it renders are not news.
            if (CFAbsoluteTimeGetCurrent() - [gWPLastRender[extID] doubleValue] < 5) return;
            for (NSString *g in gWPExtGroups[extID]) CFPreferencesAppSynchronize((__bridge CFStringRef)g);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"WPWidgetDataChanged" object:extID];
        });
    });
    dispatch_source_set_cancel_handler(src, ^{ close(fd); });
    dispatch_resume(src);
    sources[path] = src;
}

static void WPRegisterAppGroups(WPWidgetExtension *ext, NSSet<NSString *> *groups, NSString *dataPath) {
    if (!dataPath.length || groups.count == 0) return;
    if (!gWPGroupAppData) {
        gWPGroupAppData = [NSMutableDictionary dictionary];
        gWPExtGroups = [NSMutableDictionary dictionary];
        gWPGroupExtension = [NSMutableDictionary dictionary];
    }
    for (NSString *g in groups) {
        gWPGroupAppData[g] = dataPath;
        gWPGroupExtension[g] = ext.extensionBundleID;
    }
    gWPExtGroups[ext.extensionBundleID] = groups.allObjects;
    WPInstallSharedDataHooks();
    WPWatchDirectory([dataPath stringByAppendingPathComponent:@"Library/Preferences"], ext.extensionBundleID);
    for (NSString *g in groups) {
        NSString *path = WPAppGroupPath(dataPath, g);
        [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
        WPWatchDirectory(path, ext.extensionBundleID);
    }
}

static NSMutableDictionary<NSString *, NSArray<NSDictionary *> *> *gWPRuntimeWidgets; // extension ID → widgets
static NSMutableDictionary<NSString *, id> *gWPRuntimeIntents;                      // "ext|kind" → configured intent

typedef void (^WPEntriesHandler)(NSArray<NSValue *> *entries); // copied entry pointers, on the main queue

@interface WPPendingRequest : NSObject
@property (nonatomic) const void *entryType;
@property (nonatomic) size_t entriesOffset;
@property (nonatomic, copy) WPEntriesHandler handler;
@end
@implementation WPPendingRequest
@end

@implementation WPProbe (Runtime)

+ (NSString *)runtimeLogPath {
    return [[self workDirectory] stringByAppendingPathComponent:@"runtime.txt"];
}

// Copies the extension (reusing an earlier copy of the same build), signs and loads it.
static const struct mach_header *WPRuntimeLoadLocked(WPWidgetExtension *ext, NSString *dir, NSString *bundleCopy, NSString *exe,
                                                     NSMutableString *log);

static const struct mach_header *WPRuntimeLoad(WPWidgetExtension *ext, NSString **bundleCopyOut, NSMutableString *log) {
    NSString *dir = [[WPProbe workDirectory] stringByAppendingPathComponent:[@"runtime-" stringByAppendingString:ext.extensionBundleID]];
    NSString *bundleCopy = [dir stringByAppendingPathComponent:ext.extensionPath.lastPathComponent];
    NSString *exe = [bundleCopy stringByAppendingPathComponent:ext.executablePath.lastPathComponent];
    if (bundleCopyOut) *bundleCopyOut = bundleCopy;

    const struct mach_header *already = WPFindLoadedImage(exe, NULL);
    if (already) return already;
    [WPLoadLock() lock];
    const struct mach_header *mh = WPRuntimeLoadLocked(ext, dir, bundleCopy, exe, log);
    [WPLoadLock() unlock];
    return mh;
}

static const struct mach_header *WPRuntimeLoadLocked(WPWidgetExtension *ext, NSString *dir, NSString *bundleCopy, NSString *exe,
                                                     NSMutableString *log) {
    NSFileManager *fm = [NSFileManager defaultManager];
    const struct mach_header *already = WPFindLoadedImage(exe, NULL);
    if (already) return already;

    NSDictionary *attrs = [fm attributesOfItemAtPath:ext.executablePath error:nil];
    NSString *stamp = [NSString stringWithFormat:@"%@|%@|%@", ext.executablePath, attrs[NSFileSize], @([attrs[NSFileModificationDate] timeIntervalSince1970])];
    NSString *stampPath = [dir stringByAppendingPathComponent:@".wp-source"];
    NSString *oldStamp = [NSString stringWithContentsOfFile:stampPath encoding:NSUTF8StringEncoding error:nil];
    if (![oldStamp isEqualToString:stamp] || ![fm fileExistsAtPath:exe]) {
        WPLOG(log, @"  copy and sign: %@", ext.extensionBundleID);
        [fm removeItemAtPath:dir error:nil];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSError *err = nil;
        if (![fm copyItemAtPath:ext.extensionPath toPath:bundleCopy error:&err]) {
            WPLOG(log, @"  copy failed: %@", err.localizedDescription);
            return NULL;
        }
        int64_t (*syscallFn)(uint32_t, ...) = WPLiveShimSyscall();
        if (syscallFn) {
            int fd = open(exe.fileSystemRepresentation, O_RDWR);
            if (fd >= 0) {
                int64_t r = syscallFn(kWPSysSign, (int64_t)fd, (int64_t)0, (int64_t)0, (int64_t)0, (int64_t)0, (int64_t)0);
                close(fd);
                WPLOG(log, @"  sign → %lld", r);
            }
        }
        [stamp writeToFile:stampPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        WPLOG(log, @"  using the earlier copy: %@", ext.extensionBundleID);
    }
    NSArray<NSString *> *deps = WPRpathDependencies(exe);
    if (deps.count) {
        WPPreloadDependencies(deps, @[ [ext.appPath stringByAppendingPathComponent:@"Frameworks"],
                                       [ext.extensionPath stringByAppendingPathComponent:@"Frameworks"] ], log);
    }
    void *handle = dlopen(exe.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        WPLOG(log, @"  dlopen failed: %s", dlerror() ?: "?");
        return NULL;
    }
    return WPFindLoadedImage(exe, NULL);
}

// App Groups the extension is entitled to, read from the signature's entitlements plist.
static NSArray<NSString *> *WPAppGroupsOfBinary(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data) return @[];
    NSData *key = [@"<key>com.apple.security.application-groups</key>" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange r = [data rangeOfData:key options:NSDataSearchBackwards range:NSMakeRange(0, data.length)];
    if (r.location == NSNotFound) return @[];
    NSUInteger start = NSMaxRange(r);
    NSData *endTag = [@"</array>" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange e = [data rangeOfData:endTag options:0 range:NSMakeRange(start, MIN(4096, data.length - start))];
    if (e.location == NSNotFound) return @[];
    NSString *chunk = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(start, e.location - start)] encoding:NSUTF8StringEncoding];
    NSMutableArray *groups = [NSMutableArray array];
    for (NSString *part in [chunk componentsSeparatedByString:@"<string>"]) {
        NSRange close = [part rangeOfString:@"</string>"];
        if (close.location != NSNotFound) [groups addObject:[part substringToIndex:close.location]];
    }
    return groups;
}

// "group.xxx" identifiers mentioned in a binary (entitlements may be gone after re-signing,
// but the code that opens the shared container names the group).
static NSSet<NSString *> *WPGroupStringsInBinary(NSString *path) {
    NSMutableSet *found = [NSMutableSet set];
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data) return found;
    const uint8_t *bytes = data.bytes;
    NSUInteger len = data.length;
    for (NSUInteger i = 0; i + 8 < len; i++) {
        if (bytes[i] != 'g' || memcmp(bytes + i, "group.", 6) != 0) continue;
        if (i > 0 && (isalnum(bytes[i - 1]) || bytes[i - 1] == '.')) continue;
        NSUInteger j = i + 6;
        while (j < len && j - i < 120 && (isalnum(bytes[j]) || bytes[j] == '.' || bytes[j] == '-' || bytes[j] == '_')) j++;
        if (j - i > 8 && bytes[j - 1] != '.') {
            NSString *g = [[NSString alloc] initWithBytes:bytes + i length:j - i encoding:NSASCIIStringEncoding];
            if (g && ![g hasPrefix:@"group.com.apple."]) [found addObject:g];
        }
        i = j;
    }
    return found;
}

// The app groups the extension (and the app's frameworks) use. Finding them reads every
// binary of the app, so the answer is kept next to the extension's copy until it changes.
static NSString *WPExtensionStamp(WPWidgetExtension *ext) {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:ext.executablePath error:nil];
    return [NSString stringWithFormat:@"%@|%@|%@", ext.executablePath, attrs[NSFileSize], @([attrs[NSFileModificationDate] timeIntervalSince1970])];
}

static NSArray<NSString *> *WPAppGroupsForExtension(WPWidgetExtension *ext) {
    NSString *cachePath = [[[WPProbe workDirectory] stringByAppendingPathComponent:[@"runtime-" stringByAppendingString:ext.extensionBundleID]]
                           stringByAppendingPathComponent:@".wp-groups"];
    NSString *stamp = WPExtensionStamp(ext);
    NSArray *lines = [[NSString stringWithContentsOfFile:cachePath encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"];
    if (lines.count >= 1 && [lines[0] isEqualToString:stamp]) {
        return [[lines subarrayWithRange:NSMakeRange(1, lines.count - 1)] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    }
    NSMutableSet *groups = [NSMutableSet setWithArray:WPAppGroupsOfBinary(ext.executablePath)];
    [groups unionSet:WPGroupStringsInBinary(ext.executablePath)];
    NSString *frameworks = [ext.appPath stringByAppendingPathComponent:@"Frameworks"];
    for (NSString *fw in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:frameworks error:nil]) {
        if (![fw.pathExtension isEqualToString:@"framework"]) continue;
        [groups unionSet:WPGroupStringsInBinary([[frameworks stringByAppendingPathComponent:fw] stringByAppendingPathComponent:fw.stringByDeletingPathExtension])];
    }
    NSArray *sorted = [groups.allObjects sortedArrayUsingSelector:@selector(compare:)];
    [[NSFileManager defaultManager] createDirectoryAtPath:cachePath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [[[@[ stamp ] arrayByAddingObjectsFromArray:sorted] componentsJoinedByString:@"\n"] writeToFile:cachePath atomically:NO
                                                                                          encoding:NSUTF8StringEncoding error:nil];
    return sorted;
}

static void WPSetUpAppGroups(WPWidgetExtension *ext, NSMutableString *log) {
    NSArray *groups = WPAppGroupsForExtension(ext);
    if (groups.count) WPLOG(log, @"  App Group: %@", [groups componentsJoinedByString:@", "]);
    WPRegisterAppGroups(ext, [NSSet setWithArray:groups], ext.dataContainerPath);
}

// The app's Intents extension (for the defaults of intent-configured widgets), loaded ahead.
static void WPPreloadIntentsExtension(WPWidgetExtension *ext, NSMutableString *log) {
    NSString *plugins = [ext.appPath stringByAppendingPathComponent:@"PlugIns"];
    for (NSString *item in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:plugins error:nil]) {
        NSString *path = [plugins stringByAppendingPathComponent:item];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
        if (![info[@"NSExtension"][@"NSExtensionPointIdentifier"] isEqualToString:@"com.apple.intents-service"]) continue;
        WPLoadExtensionCopy(path, ext.appPath, NULL, log);
        return;
    }
}

+ (NSArray<NSDictionary *> *)loadedWidgetsForExtension:(WPWidgetExtension *)ext {
    return gWPRuntimeWidgets[ext.extensionBundleID];
}

// The slow part of loading an extension — copying and signing, dlopen of it, its frameworks
// and its Intents extension, finding its App Groups — runs on a background queue, so the
// home screen stays responsive. Reading its Swift types (which runs the app's WidgetBundle
// code) stays on the main thread, in widgetsForExtension:, now without the waiting.
+ (void)prepareExtension:(WPWidgetExtension *)ext completion:(void (^)(void))completion {
    NSString *extID = ext.extensionBundleID;
    if (!gWPRuntimeWidgets) gWPRuntimeWidgets = [NSMutableDictionary dictionary];
    if (gWPRuntimeWidgets[extID] || !extID) {
        if (completion) completion();
        return;
    }
    static NSMutableDictionary<NSString *, NSMutableArray *> *waiting;
    static dispatch_queue_t queue;
    if (!queue) {
        queue = dispatch_queue_create("com.rinapple.widgetprobe.load", DISPATCH_QUEUE_SERIAL);
        waiting = [NSMutableDictionary dictionary];
    }
    NSMutableArray *list = waiting[extID];
    if (list) {
        if (completion) [list addObject:[completion copy]];
        return;
    }
    waiting[extID] = completion ? [NSMutableArray arrayWithObject:[completion copy]] : [NSMutableArray array];
    dispatch_async(queue, ^{
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        NSMutableString *log = [NSMutableString string];
        const struct mach_header *mh = WPRuntimeLoad(ext, NULL, log);
        WPAppGroupsForExtension(ext);
        if (mh && !WPHasIntentCache(ext)) WPPreloadIntentsExtension(ext, log);
        double background = (CFAbsoluteTimeGetCurrent() - start) * 1000;
        dispatch_async(dispatch_get_main_queue(), ^{
            for (NSString *line in [log componentsSeparatedByString:@"\n"]) if (line.length) WPRuntimeLog(@"%@", line);
            CFAbsoluteTime scanStart = CFAbsoluteTimeGetCurrent();
            [WPProbe widgetsForExtension:ext];
            WPRuntimeLog(@"  %@: background load %.0f ms / type reading %.0f ms", ext.appName, background,
                         (CFAbsoluteTimeGetCurrent() - scanStart) * 1000);
            NSArray *blocks = waiting[extID];
            [waiting removeObjectForKey:extID];
            for (void (^b)(void) in blocks) b();
        });
    });
}

+ (NSArray<NSDictionary *> *)widgetsForExtension:(WPWidgetExtension *)ext {
    if (!gWPRuntimeWidgets) gWPRuntimeWidgets = [NSMutableDictionary dictionary];
    NSArray *cached = gWPRuntimeWidgets[ext.extensionBundleID];
    if (cached) return cached;

    NSString *savedPath = gWPLogPath;
    gWPLogPath = [self runtimeLogPath];
    NSMutableString *log = [NSMutableString string];
    WPLOG(log, @"== Load %@ (%@)", ext.appName, ext.extensionBundleID);
    NSString *bundleCopy = nil;
    const struct mach_header *mh = WPRuntimeLoad(ext, &bundleCopy, log);
    WPSetUpAppGroups(ext, log);
    if (mh) {
        // Frameworks of the app loaded for this extension (e.g. its shared UI code) look up
        // their strings and images through Bundle.main as well.
        for (NSArray *img in WPLoadedImages()) {
            NSString *path = img[0];
            NSString *appTail = [NSString stringWithFormat:@"%@/%@/Frameworks/", ext.appPath.stringByDeletingLastPathComponent.lastPathComponent,
                                 ext.appPath.lastPathComponent];
            BOOL appFramework = [path containsString:appTail] ||
                                [path containsString:[ext.extensionPath.lastPathComponent stringByAppendingString:@"/Frameworks/"]];
            if (!appFramework) continue;
            WPAddBundleRedirect([img[1] pointerValue], bundleCopy);
            WPLOG(log, @"  Bundle.main redirect (framework): %@", path.lastPathComponent);
        }
    }
    NSMutableArray *widgets = [NSMutableArray array];
    if (mh) {
        WPInstallMainBundleRedirect(mh, bundleCopy, log);
        gWPCurrentExtension = ext;
        gWPConfigCount = 0;
        gWPBoxCount = 0;
        gWPDescLeaves = [NSMutableArray array];
        gWPDescTransformCount = 0;
        // Applying the descriptor transforms runs the app's code; if that ever took SpringBoard
        // down (the marker survived), skip it for this extension.
        NSString *descMarker = [NSString stringWithFormat:@"descriptor-%@", ext.extensionBundleID];
        gWPDescDisabled = WPMarkerTripped(descMarker);
        if (!gWPDescDisabled) WPMarkerBegin(descMarker);
        gWPQuiet = YES;
        WPScanConformances(mh, log);
        gWPQuiet = NO;
        WPMarkerEnd(descMarker);
        NSBundle *extBundle = [NSBundle bundleWithPath:ext.extensionPath];
        NSMutableDictionary *infos = [NSMutableDictionary dictionary];
        NSMutableArray *infoList = [NSMutableArray array]; // in walk order, like the boxes
        for (NSArray *leaves in gWPDescLeaves) {
            NSDictionary *info = WPDescriptorInfo(leaves, extBundle);
            [infoList addObject:info];
            if (info[@"kind"]) infos[info[@"kind"]] = info;
            static NSMutableSet *logged;
            if (!logged) logged = [NSMutableSet set];
            if (!info[@"name"] && ![logged containsObject:ext.extensionBundleID]) {
                // Not understood yet: keep what the descriptor holds, to read it better later.
                [logged addObject:ext.extensionBundleID];
                NSMutableArray *lines = [NSMutableArray array];
                for (NSArray *leaf in leaves) [lines addObject:[NSString stringWithFormat:@"%@=%@", leaf[0], leaf.count > 2 ? leaf[2] : leaf[1]]];
                WPLOG(log, @"  descriptor contents: %@", [lines componentsJoinedByString:@" | "]);
            }
        }
        for (int b = 0; b < gWPBoxCount; b++) {
            WPProviderBox *box = malloc(sizeof *box);
            *box = gWPBoxes[b];
            size_t configOff = 0;
            NSString *kind = nil;
            if (WPStructField(box->type, "config", &configOff, NULL)) kind = WPSwiftString((const uint8_t *)box->base + configOff);
            if (!kind.length) kind = [NSString stringWithFormat:@"widget%d", b];
            NSDictionary *info = infos[kind] ?: ((int)infoList.count == gWPBoxCount ? infoList[b] : nil);
            NSArray *fams = info[@"families"];
            NSString *sizes = !fams ? @"sizes unknown" : fams.count ? [fams componentsJoinedByString:@"/"] : @"no Home Screen sizes";
            WPLOG(log, @"  widget: %@ \"%@\" %@ (%@)", kind, info[@"name"] ?: @"", sizes,
                  box->isAppIntent ? @"configurable, AppIntent" : box->isIntent ? @"configurable" : @"static");
            NSMutableDictionary *w = [@{ @"kind" : kind, @"intent" : @(box->isIntent), @"appIntent" : @(box->isAppIntent),
                                         @"box" : [NSValue valueWithPointer:box] } mutableCopy];
            if (info[@"name"]) w[@"name"] = info[@"name"];
            if (info[@"description"]) w[@"description"] = info[@"description"];
            if (info[@"families"]) w[@"families"] = info[@"families"];
            [widgets addObject:w];
        }
    }
    gWPRuntimeWidgets[ext.extensionBundleID] = widgets;
    gWPLogPath = savedPath;
    return widgets;
}

// The configured intent of a widget, made once like iOS does when the widget is added.
static NSString *WPIntentCachePath(WPWidgetExtension *ext, NSString *kind) {
    NSString *name = [[NSString stringWithFormat:@"%@|%@", ext.extensionBundleID, kind] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [[[[WPProbe workDirectory] stringByAppendingPathComponent:[@"runtime-" stringByAppendingString:ext.extensionBundleID]]
             stringByAppendingPathComponent:@"intents"] stringByAppendingPathComponent:[name stringByAppendingString:@".plist"]];
}

static BOOL WPHasIntentCache(WPWidgetExtension *ext) {
    NSString *dir = WPIntentCachePath(ext, @"x").stringByDeletingLastPathComponent;
    return [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil].count > 0;
}

static id WPRuntimeIntent(WPWidgetExtension *ext, NSString *kind, const void *proto, const void *const *wt,
                          const void *providerType, NSMutableString *log) {
    NSString *key = [NSString stringWithFormat:@"%@|%@", ext.extensionBundleID, kind];
    if (!gWPRuntimeIntents) gWPRuntimeIntents = [NSMutableDictionary dictionary];
    id intent = gWPRuntimeIntents[key];
    if (intent) return intent;
    WPGetAssociatedTypeWitness assoc = (WPGetAssociatedTypeWitness)dlsym(RTLD_DEFAULT, "swift_getAssociatedTypeWitness");
    int assocs[4];
    int nassoc = WPRequirementsOfKind(proto, 7, assocs, 4);
    WPProtocolLayout layout;
    if (!assoc || !WPReadProtocolLayout(proto, &layout)) return nil;
    const void *intentType = NULL;
    for (int a = 0; a < nassoc; a++) {
        const void *t = assoc(0, wt, providerType, layout.reqBase, (const uint8_t *)layout.reqBase + 8 + assocs[a] * 8).metadata;
        if (t && WPIsClassMetadata(t)) intentType = t;
    }
    if (!intentType) return nil;
    // The defaults the Intents extension gave last time (kept until the extension changes):
    // then that extension need not be loaded at all.
    NSString *cachePath = WPIntentCachePath(ext, kind);
    NSDictionary *cached = [NSDictionary dictionaryWithContentsOfFile:cachePath];
    if ([cached[@"stamp"] isEqual:WPExtensionStamp(ext)] && [cached[@"intent"] isKindOfClass:[NSData class]]) {
        NSKeyedUnarchiver *u = [[NSKeyedUnarchiver alloc] initForReadingFromData:cached[@"intent"] error:nil];
        u.requiresSecureCoding = NO;
        @try { intent = [u decodeObjectForKey:NSKeyedArchiveRootObjectKey]; } @catch (NSException *e) { intent = nil; }
        [u finishDecoding];
        if ([intent isKindOfClass:(__bridge Class)intentType]) {
            gWPRuntimeIntents[key] = intent;
            return intent;
        }
    }
    intent = [[(__bridge Class)intentType alloc] init];
    if (!intent) return nil;
    gWPCurrentExtension = ext;
    // Asking the app's Intents extension for defaults runs the app's own code; if that ever
    // crashed SpringBoard (the marker survived), do not ask again for this extension.
    NSString *marker = [NSString stringWithFormat:@"intent-defaults-%@", ext.extensionBundleID];
    if (WPMarkerTripped(marker)) {
        WPLOG(log, @"  Intents extension defaults: not used (crashed last time)");
    } else {
        WPMarkerBegin(marker);
        WPApplyDefaultsFromIntentsExtension(intent, log);
        WPMarkerEnd(marker);
        NSData *data = nil;
        @try { data = [NSKeyedArchiver archivedDataWithRootObject:intent requiringSecureCoding:NO error:nil]; } @catch (NSException *e) {}
        if (data) {
            [[NSFileManager defaultManager] createDirectoryAtPath:cachePath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            [@{ @"stamp" : WPExtensionStamp(ext), @"intent" : data } writeToFile:cachePath atomically:NO];
        }
    }
    gWPRuntimeIntents[key] = intent;
    return intent;
}

// The widget's configuration intent (an AppIntent struct) made with its init(), so its
// @Parameter defaults apply — what iOS does when such a widget is added.
static NSMutableDictionary<NSString *, NSValue *> *gWPRuntimeAppIntents;

static void *WPRuntimeAppIntent(WPWidgetExtension *ext, NSString *kind, const void *proto, const void *const *wt,
                                const void *providerType, NSMutableString *log) {
    NSString *key = [NSString stringWithFormat:@"%@|%@", ext.extensionBundleID, kind];
    if (!gWPRuntimeAppIntents) gWPRuntimeAppIntents = [NSMutableDictionary dictionary];
    NSValue *cached = gWPRuntimeAppIntents[key];
    if (cached) return cached.pointerValue;
    WPGetAssociatedTypeWitness assoc = (WPGetAssociatedTypeWitness)dlsym(RTLD_DEFAULT, "swift_getAssociatedTypeWitness");
    WPConformsToProtocol conformsTo = (WPConformsToProtocol)dlsym(RTLD_DEFAULT, "swift_conformsToProtocol");
    const void *appIntentProto = dlsym(RTLD_DEFAULT, "$s10AppIntents0A6IntentMp");
    WPWitnessInit initThunk = (WPWitnessInit)dlsym(RTLD_DEFAULT, "$s10AppIntents0A6IntentPxycfCTj");
    WPProtocolLayout layout;
    if (!assoc || !conformsTo || !appIntentProto || !initThunk || !WPReadProtocolLayout(proto, &layout)) {
        WPLOG(log, @"  the AppIntent functions were not found");
        return NULL;
    }
    int assocs[4];
    int nassoc = WPRequirementsOfKind(proto, 7, assocs, 4);
    const void *intentType = NULL, *intentWT = NULL;
    for (int a = 0; a < nassoc && !intentType; a++) {
        const void *t = assoc(0, wt, providerType, layout.reqBase, (const uint8_t *)layout.reqBase + 8 + assocs[a] * 8).metadata;
        const void *w = t ? conformsTo(t, appIntentProto) : NULL;
        if (w) { intentType = t; intentWT = w; }
    }
    if (!intentType) {
        WPLOG(log, @"  the configuration type (AppIntent) was not found");
        return NULL;
    }
    void *value = WPAllocValue(intentType);
    initThunk(value, intentType, intentWT, intentType);
    WPLOG(log, @"  made configuration %@ with init()", WPTypeName(intentType));
    gWPRuntimeAppIntents[key] = [NSValue valueWithPointer:value];
    return value;
}

// Hosts any SwiftUI view value in a UIHostingController<ViewType>.
static UIViewController *WPHostView(void *view, const void *viewType) {
    const void *viewProto = dlsym(RTLD_DEFAULT, "$s7SwiftUI4ViewMp");
    WPConformsToProtocol conformsTo = (WPConformsToProtocol)dlsym(RTLD_DEFAULT, "swift_conformsToProtocol");
    WPGenericAccessor2 hostingAccessor = (WPGenericAccessor2)dlsym(RTLD_DEFAULT, "$s7SwiftUI19UIHostingControllerCMa");
    WPHostingInit hostingInit = (WPHostingInit)dlsym(RTLD_DEFAULT, "$s7SwiftUI19UIHostingControllerC8rootViewACyxGx_tcfC");
    if (!viewProto || !conformsTo || !hostingAccessor || !hostingInit) return nil;
    const void *viewWT = conformsTo(viewType, viewProto);
    if (!viewWT) return nil;
    const void *hostingType = hostingAccessor(0, viewType, viewWT).metadata;
    void *controller = hostingInit(view, hostingType); // takes the view (+1)
    return controller ? (__bridge_transfer UIViewController *)controller : nil;
}

// Calls the stored "(Entry) -> Content" view builder; Content may be AnyView or the app's own view type.
static UIViewController *WPRenderEntryGeneric(const void *generatorClosure, const void *generatorType, const void *entry) {
    const void *resultType = ((const void *const *)generatorType)[2];
    void *view = WPAllocValue(resultType);
    if (!view) return nil;
    const void *const *pair = generatorClosure;
    ((WPContentFn)pair[0])(view, entry, pair[1]);
    return WPHostView(view, resultType);
}

#pragma mark Async completions with a per-request context

// Completion closures get a real Swift heap object as their context (WidgetKit retains
// and releases it), carrying the request number. Its metadata is a minimal
// HeapLocalVariable record whose destroy function frees it.
typedef struct {
    const void *metadata;
    uint64_t refCounts;
    uint64_t requestID;
} WPCtxObject;

typedef void (*WPHeapDestroy)(void *object __attribute__((swift_context))) SWIFTCALL;
static struct {
    WPHeapDestroy destroy;
    const void *valueWitnesses;
    uintptr_t kind;
    uint32_t offsetToFirstCapture;
    uint32_t pad;
    const void *captureDescription;
} gWPCtxMetadata;

static void WPCtxDestroy(void *object __attribute__((swift_context))) SWIFTCALL {
    void (*dealloc)(void *, size_t, size_t) = dlsym(RTLD_DEFAULT, "swift_deallocObject");
    if (dealloc) dealloc(object, sizeof(WPCtxObject), 7);
}

static void *WPMakeCtx(uint64_t requestID) {
    static void *(*alloc)(const void *, size_t, size_t);
    if (!alloc) {
        alloc = dlsym(RTLD_DEFAULT, "swift_allocObject");
        gWPCtxMetadata.destroy = WPCtxDestroy;
        gWPCtxMetadata.valueWitnesses = dlsym(RTLD_DEFAULT, "$sBoWV");
        gWPCtxMetadata.kind = 0x400; // HeapLocalVariable
        gWPCtxMetadata.offsetToFirstCapture = 16;
    }
    if (!alloc) return NULL;
    WPCtxObject *o = alloc(&gWPCtxMetadata.kind, sizeof(WPCtxObject), 7);
    if (o) o->requestID = requestID;
    return o;
}

static void WPReleaseCtx(void *o) {
    void (*release)(void *) = dlsym(RTLD_DEFAULT, "swift_release");
    if (o && release) release(o);
}



static NSMutableDictionary<NSNumber *, WPPendingRequest *> *gWPRequests;
static NSLock *gWPRequestsLock;
static uint64_t gWPNextRequestID = 1;

static uint64_t WPRegisterRequest(const void *entryType, size_t entriesOffset, WPEntriesHandler handler) {
    if (!gWPRequestsLock) {
        gWPRequestsLock = [NSLock new];
        gWPRequests = [NSMutableDictionary dictionary];
    }
    WPPendingRequest *r = [WPPendingRequest new];
    r.entryType = entryType;
    r.entriesOffset = entriesOffset;
    r.handler = handler;
    [gWPRequestsLock lock];
    uint64_t rid = gWPNextRequestID++;
    gWPRequests[@(rid)] = r;
    [gWPRequestsLock unlock];
    return rid;
}

static WPPendingRequest *WPTakeRequestID(uint64_t rid) {
    [gWPRequestsLock lock];
    WPPendingRequest *r = gWPRequests[@(rid)];
    [gWPRequests removeObjectForKey:@(rid)];
    [gWPRequestsLock unlock];
    return r;
}

static WPPendingRequest *WPTakeRequest(const void *ctx) {
    if (!ctx) return nil;
    uint64_t rid = ((const WPCtxObject *)ctx)->requestID;
    [gWPRequestsLock lock];
    WPPendingRequest *r = gWPRequests[@(rid)];
    [gWPRequests removeObjectForKey:@(rid)];
    [gWPRequestsLock unlock];
    return r;
}

static void *WPCopyEntry(const void *entry, const void *type) {
    const WPValueWitnessTable *vwt = WPVWT(type);
    void *copy = WPAllocValue(type);
    ((WPCopyValue)vwt->functions[2])(copy, entry, type);
    return copy;
}

static void WPDeliverTimeline(WPPendingRequest *r, const void *timeline) {
    NSMutableArray *entries = [NSMutableArray array];
    const uint8_t *array = *(const uint8_t *const *)((const uint8_t *)timeline + r.entriesOffset);
    if (array) {
        intptr_t count = *(const intptr_t *)(array + 16);
        const WPValueWitnessTable *vwt = WPVWT(r.entryType);
        size_t mask = vwt->flags & 0xFF;
        const uint8_t *elements = array + ((32 + mask) & ~mask);
        for (intptr_t i = 0; i < count && i < 64; i++) {
            [entries addObject:[NSValue valueWithPointer:WPCopyEntry(elements + i * vwt->stride, r.entryType)]];
        }
    }
    WPEntriesHandler handler = r.handler;
    dispatch_async(dispatch_get_main_queue(), ^{ handler(entries); });
}

static void WPDeliverEntry(WPPendingRequest *r, const void *entry) {
    NSArray *entries = @[ [NSValue valueWithPointer:WPCopyEntry(entry, r.entryType)] ];
    WPEntriesHandler handler = r.handler;
    dispatch_async(dispatch_get_main_queue(), ^{ handler(entries); });
}

static void WPAsyncTimelineCompletion(const void *timeline, const void *ctx __attribute__((swift_context))) SWIFTCALL {
    WPPendingRequest *r = WPTakeRequest(ctx);
    if (r) WPDeliverTimeline(r, timeline);
}

static void WPAsyncSnapshotCompletion(const void *entry, const void *ctx __attribute__((swift_context))) SWIFTCALL {
    WPPendingRequest *r = WPTakeRequest(ctx);
    if (r) WPDeliverEntry(r, entry);
}

#pragma mark Calling Swift async functions (AppIntentTimelineProvider)

// A task is created whose entry (WPAsync.s) tail-calls the async function like Swift code
// does; its resume function hands the result back here. The request number travels in the
// task's closure context.
typedef struct { int32_t function; uint32_t contextSize; } WPAsyncFunctionPointer;
extern void WPAsyncEntry(void);
extern void WPAsyncResume(void);

typedef struct {
    const WPAsyncFunctionPointer *afp;
    void *args[5];      // x0..x4: result buffer, configuration, context, Self, witness table
    const void *selfValue;
    BOOL isTimeline;
    uint64_t rid;
} WPAsyncCallInfo;

typedef struct {
    uint64_t magic;
    WPAsyncCallInfo *info;
    void *callee;
} WPAsyncTaskState;

#define WP_ASYNC_MAGIC 0x5750415359434E31ULL
#define WP_ASYNC_STATE(ctx) ((WPAsyncTaskState *)((uint8_t *)(ctx) + 64))

static NSMutableDictionary<NSNumber *, NSValue *> *gWPAsyncCalls;
static NSLock *gWPAsyncLock;
static WPAsyncFunctionPointer gWPEntryAFP;

static WPPendingRequest *WPTakeRequestID(uint64_t rid);
static void WPDeliverTimeline(WPPendingRequest *r, const void *timeline);
static void WPDeliverEntry(WPPendingRequest *r, const void *entry);

void WPAsyncPrepare(void *ctx, void *closure, void **out) {
    uint64_t rid = closure ? ((WPCtxObject *)closure)->requestID : 0;
    [gWPAsyncLock lock];
    WPAsyncCallInfo *info = [gWPAsyncCalls[@(rid)] pointerValue];
    [gWPAsyncLock unlock];
    void *(*taskAlloc)(size_t) = dlsym(RTLD_DEFAULT, "swift_task_alloc");
    WPAsyncTaskState *state = WP_ASYNC_STATE(ctx);
    state->magic = WP_ASYNC_MAGIC;
    state->info = info;
    void **callee = taskAlloc(info->afp->contextSize < 32 ? 32 : info->afp->contextSize);
    callee[0] = ctx;                    // Parent
    callee[1] = (void *)WPAsyncResume;  // ResumeParent
    state->callee = callee;
    for (int i = 0; i < 5; i++) out[i] = info->args[i];
    out[5] = (void *)info->selfValue;
    out[6] = callee;
    out[7] = (void *)((const uint8_t *)&info->afp->function + info->afp->function);
}

void WPAsyncFinish(void *x22, void **out) {
    void *ctx = WP_ASYNC_STATE(x22)->magic == WP_ASYNC_MAGIC ? x22 : ((void **)x22)[0];
    WPAsyncTaskState *state = WP_ASYNC_STATE(ctx);
    void (*taskDealloc)(void *) = dlsym(RTLD_DEFAULT, "swift_task_dealloc");
    taskDealloc(state->callee);
    WPAsyncCallInfo *info = state->info;
    WPPendingRequest *r = WPTakeRequestID(info->rid);
    if (r) {
        if (info->isTimeline) WPDeliverTimeline(r, info->args[0]);
        else WPDeliverEntry(r, info->args[0]);
    }
    [gWPAsyncLock lock];
    [gWPAsyncCalls removeObjectForKey:@(info->rid)];
    [gWPAsyncLock unlock];
    out[0] = ctx;
    out[1] = ((void **)ctx)[1]; // this task's ResumeParent
}

typedef struct { void *task; void *context; } WPTaskAndContext;
typedef WPTaskAndContext (*WPTaskCreate)(size_t flags, void *options, const void *resultType, void *entry, void *closureContext) SWIFTCALL;

// Runs `async` function (its async function pointer symbol) with the given arguments in a new task.
static BOOL WPStartAsyncCall(const char *afpSymbol, BOOL isTimeline, void *result, void *configuration, void *context,
                             const void *selfType, const void *wt, const void *selfValue, uint64_t rid) {
    const WPAsyncFunctionPointer *afp = dlsym(RTLD_DEFAULT, afpSymbol);
    WPTaskCreate create = (WPTaskCreate)dlsym(RTLD_DEFAULT, "swift_task_create");
    // "$sytN" (metadata of ()) is a builtin "full metadata" symbol: it starts with the value
    // witness table pointer, and the metadata itself is 8 bytes in (compiled code adds 8 too).
    const uint8_t *emptyTupleFull = dlsym(RTLD_DEFAULT, "$sytN");
    const void *voidType = emptyTupleFull ? emptyTupleFull + 8 : NULL;
    void (*release)(void *) = dlsym(RTLD_DEFAULT, "swift_release");
    if (!afp || !create || !voidType) return NO;
    if (!gWPAsyncLock) {
        gWPAsyncLock = [NSLock new];
        gWPAsyncCalls = [NSMutableDictionary dictionary];
        gWPEntryAFP.function = (int32_t)((intptr_t)WPAsyncEntry - (intptr_t)&gWPEntryAFP.function);
        gWPEntryAFP.contextSize = 160;
    }
    WPAsyncCallInfo *info = calloc(1, sizeof *info);
    info->afp = afp;
    info->args[0] = result;
    info->args[1] = configuration;
    info->args[2] = context;
    info->args[3] = (void *)selfType;
    info->args[4] = (void *)wt;
    info->selfValue = selfValue;
    info->isTimeline = isTimeline;
    info->rid = rid;
    [gWPAsyncLock lock];
    gWPAsyncCalls[@(rid)] = [NSValue valueWithPointer:info];
    [gWPAsyncLock unlock];
    // Flags as compiled code for a detached task: enqueue the job (bit 12), the closure
    // context is handed over (bit 15), priority unspecified.
    size_t flags = (1u << 12) | (1u << 15);
    void *closure = WPMakeCtx(rid);
    // Created from a background thread (the main thread may report a current task).
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        WPTaskAndContext t = create(flags, NULL, voidType, &gWPEntryAFP, closure);
        if (t.task && release) release(t.task);
    });
    return YES;
}

// The entry's "date" (TimelineEntry requirement), as seconds since 2001, or NAN.
static double WPEntryDate(const void *entry, const void *entryType) {
    size_t off = 0;
    const void *t = NULL;
    if (!entry || !WPStructField(entryType, "date", &off, &t)) return NAN;
    double d;
    memcpy(&d, (const uint8_t *)entry + off, sizeof d);
    return d;
}

static void WPRuntimeLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void WPRuntimeLog(NSString *fmt, ...) {
    if (!WPDiagnosticLogEnabled()) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *saved = gWPLogPath;
    BOOL quiet = gWPQuiet;
    gWPLogPath = [WPProbe runtimeLogPath];
    gWPQuiet = NO; // runtime lines are always written
    WPAppend([NSMutableString string], line);
    gWPQuiet = quiet;
    gWPLogPath = saved;
}

+ (void)renderWidgetKind:(NSString *)kind extension:(WPWidgetExtension *)ext family:(int)family size:(CGSize)size
                  update:(void (^)(UIViewController *controller, NSDate *nextRefresh, BOOL final))update {
    NSArray *widgets = [self widgetsForExtension:ext];
    const WPProviderBox *found = NULL;
    for (NSDictionary *w in widgets) {
        if ([w[@"kind"] isEqualToString:kind]) found = [w[@"box"] pointerValue];
    }
    if (!found) {
        WPRuntimeLog(@"== Render %@ / %@: this widget was not found", ext.extensionBundleID, kind);
        update(nil, nil, YES);
        return;
    }
    WPProviderBox box = *found;
    if (!gWPLastRender) gWPLastRender = [NSMutableDictionary dictionary];
    gWPLastRender[ext.extensionBundleID] = @(CFAbsoluteTimeGetCurrent());
    for (NSString *g in gWPExtGroups[ext.extensionBundleID]) CFPreferencesAppSynchronize((__bridge CFStringRef)g);
    NSString *savedPath = gWPLogPath;
    gWPLogPath = [self runtimeLogPath];
    NSMutableString *log = [NSMutableString string];
    WPLOG(log, @"== Render %@ / %@ family=%d %.0fx%.0f", ext.extensionBundleID, kind, family, size.width, size.height);

    WPConformsToProtocol conformsTo = (WPConformsToProtocol)dlsym(RTLD_DEFAULT, "swift_conformsToProtocol");
    const void *proto = dlsym(RTLD_DEFAULT, box.isAppIntent ? "$s9WidgetKit25AppIntentTimelineProviderMp" :
                                            box.isIntent ? "$s9WidgetKit22IntentTimelineProviderMp" : "$s9WidgetKit16TimelineProviderMp");
    const void *entryProto = dlsym(RTLD_DEFAULT, "$s9WidgetKit13TimelineEntryMp");
    WPGenericAccessor2 timelineAccessor = (WPGenericAccessor2)dlsym(RTLD_DEFAULT, "$s9WidgetKit8TimelineVMa");
    size_t providerOff = 0, generatorOff = 0;
    const void *providerType = NULL, *generatorType = NULL;
    if (!conformsTo || !proto || !WPStructField(box.type, "provider", &providerOff, &providerType) ||
        !WPStructField(box.type, "generator", &generatorOff, &generatorType) || !providerType || !generatorType) {
        WPLOG(log, @"  provider / generator not found");
        gWPLogPath = savedPath;
        update(nil, nil, YES);
        return;
    }
    const void *provider = (const uint8_t *)box.base + providerOff;
    const void *generator = (const uint8_t *)box.base + generatorOff;
    const void *entryType = ((const void *const *)generatorType)[3];
    const void *const *wt = conformsTo(providerType, proto);
    int methods[8];
    int nmethods = wt ? WPRequirementsOfKind(proto, 1, methods, 8) : 0;
    int base = box.isIntent ? 1 : 0;
    const void *placeholderFn = NULL, *snapshotFn = NULL, *timelineFn = NULL;
    if (box.isAppIntent && wt) {
        // Its data methods are async; WidgetKit also declares completion-handler versions
        // (getSnapshot / getTimeline(for:in:completion:)), called through their dispatch thunks.
        placeholderFn = dlsym(RTLD_DEFAULT, "$s9WidgetKit25AppIntentTimelineProviderP11placeholder2in5EntryQzAA0eF7ContextV_tFTj");
        snapshotFn = dlsym(RTLD_DEFAULT, "$s9WidgetKit25AppIntentTimelineProviderP11getSnapshot3for2in10completiony0D0Qz_AA0eF7ContextVy5EntryQzctFTj");
        timelineFn = dlsym(RTLD_DEFAULT, "$s9WidgetKit25AppIntentTimelineProviderP03getE03for2in10completiony0D0Qz_AA0eF7ContextVyAA0E0Vy5EntryQzGctFTj");
    } else if (nmethods >= base + 3) {
        placeholderFn = wt[methods[base] + 1];
        snapshotFn = wt[methods[base + 1] + 1];
        timelineFn = wt[methods[base + 2] + 1];
    }
    gWPQuiet = YES;
    void *context = (placeholderFn && snapshotFn && timelineFn) ? WPMakeContext(family, size, log) : NULL;
    gWPQuiet = NO;
    void *intentArg = NULL;
    if (context && box.isAppIntent) intentArg = WPRuntimeAppIntent(ext, kind, proto, wt, providerType, log);
    else if (context && box.isIntent) intentArg = (__bridge void *)WPRuntimeIntent(ext, kind, proto, wt, providerType, log); // kept alive by gWPRuntimeIntents
    if (!context || (box.isIntent && !intentArg)) {
        WPLOG(log, @"  setup failed (requirements %d, functions %p %p %p, configuration %p)", nmethods, placeholderFn, snapshotFn, timelineFn, intentArg);
        gWPLogPath = savedPath;
        update(nil, nil, YES);
        return;
    }

    // 1. placeholder(in:) — synchronous, shown right away.
    void *placeholder = WPAllocValue(entryType);
    ((WPPlaceholderFn)placeholderFn)(placeholder, context, providerType, wt, provider);
    UIViewController *first = WPRenderEntryGeneric(generator, generatorType, placeholder);
    WPLOG(log, @"  placeholder → %@ (view type %@)", first ? @"drawn" : @"failed", WPTypeName(((const void *const *)generatorType)[2]));
    gWPLogPath = savedPath;
    update(first, nil, NO);

    // 2. getTimeline — asynchronous; the provider may take its time (network, shared data).
    const void *timelineType = timelineAccessor ? timelineAccessor(0, entryType, conformsTo(entryType, entryProto)).metadata : NULL;
    size_t entriesOffset = 0;
    if (!timelineType || !WPStructField(timelineType, "entries", &entriesOffset, NULL)) {
        WPRuntimeLog(@"  cannot read the Timeline layout");
        update(nil, nil, YES);
        return;
    }
    __block BOOL answered = NO;
    void (^showEntries)(NSArray<NSValue *> *, NSString *) = ^(NSArray<NSValue *> *entries, NSString *source) {
        double now = CFAbsoluteTimeGetCurrent(), next = NAN;
        const void *current = entries.count ? entries[0].pointerValue : NULL;
        for (NSValue *v in entries) {
            double d = WPEntryDate(v.pointerValue, entryType);
            if (isnan(d) || d <= now) current = v.pointerValue;
            else if (isnan(next) || d < next) next = d;
        }
        WPRuntimeLog(@"  %@ %@: %lu entries%@", kind, source, (unsigned long)entries.count,
                     isnan(next) ? @"" : [NSString stringWithFormat:@" (next change in %.0f s)", next - now]);
        UIViewController *vc = current ? WPRenderEntryGeneric(generator, generatorType, current) : nil;
        update(vc, isnan(next) ? nil : [NSDate dateWithTimeIntervalSinceReferenceDate:next], YES);
    };
    void (^requestSnapshot)(void) = ^{
        uint64_t rid = WPRegisterRequest(entryType, 0, ^(NSArray<NSValue *> *entries) {
            if (answered) return;
            answered = YES;
            showEntries(entries, @"snapshot");
        });
        if (box.isAppIntent) {
            void *out = WPAllocValue(entryType);
            if (!WPStartAsyncCall("$s9WidgetKit25AppIntentTimelineProviderP8snapshot3for2in5EntryQz0D0Qz_AA0eF7ContextVtYaFTjTu", NO,
                                  out, intentArg, context, providerType, wt, provider, rid)) {
                WPRuntimeLog(@"  cannot start snapshot(for:in:)");
            }
            return;
        }
        void *ctx = WPMakeCtx(rid);
        if (box.isIntent) {
            ((WPIntentTimelineFn)snapshotFn)(intentArg, context, (const void *)WPAsyncSnapshotCompletion, ctx, providerType, wt, provider);
        } else {
            ((WPTimelineFn)snapshotFn)(context, (const void *)WPAsyncSnapshotCompletion, ctx, providerType, wt, provider);
        }
        WPReleaseCtx(ctx);
    };
    uint64_t rid = WPRegisterRequest(entryType, entriesOffset, ^(NSArray<NSValue *> *entries) {
        if (answered) return;
        if (entries.count == 0) {
            WPRuntimeLog(@"  %@: the timeline is empty, asking for a snapshot", kind);
            requestSnapshot();
            return;
        }
        answered = YES;
        showEntries(entries, @"timeline");
    });
    NSString *asyncMarker = [NSString stringWithFormat:@"async2-%@-%@", ext.extensionBundleID, kind];
    if (box.isAppIntent && WPMarkerTripped(asyncMarker)) {
        WPRuntimeLog(@"  %@: the async call crashed last time, keeping the placeholder", kind);
        update(nil, nil, YES);
        return;
    }
    if (box.isAppIntent) {
        // timeline(for:in:) async, run in its own task.
        WPMarkerBegin(asyncMarker);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WPMarkerEnd(asyncMarker);
        });
        void *out = WPAllocValue(timelineType);
        BOOL started = WPStartAsyncCall("$s9WidgetKit25AppIntentTimelineProviderP8timeline3for2inAA0E0Vy5EntryQzG0D0Qz_AA0eF7ContextVtYaFTjTu", YES,
                                        out, intentArg, context, providerType, wt, provider, rid);
        WPRuntimeLog(@"  %@ timeline(for:in:) async: %@", kind, started ? @"started" : @"cannot start");
    } else {
        void *ctx = WPMakeCtx(rid);
        if (box.isIntent) {
            ((WPIntentTimelineFn)timelineFn)(intentArg, context, (const void *)WPAsyncTimelineCompletion, ctx, providerType, wt, provider);
        } else {
            ((WPTimelineFn)timelineFn)(context, (const void *)WPAsyncTimelineCompletion, ctx, providerType, wt, provider);
        }
        WPReleaseCtx(ctx);
    }
    // No answer yet: ask for a snapshot as well, and give up quietly after a while.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (answered) return;
        WPRuntimeLog(@"  %@: no timeline after 10 s, asking for a snapshot", kind);
        requestSnapshot();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (answered) return;
        answered = YES;
        WPRuntimeLog(@"  %@: no data came back (keeping the placeholder)", kind);
        update(nil, nil, YES);
    });
}

+ (BOOL)isRenderBusy {
    return NO;
}

static NSUncaughtExceptionHandler *gWPOldExceptionHandler;

static void WPExceptionHandler(NSException *e) {
    char line[600];
    snprintf(line, sizeof line, "\n!! Exception: %s: %s\n", e.name.UTF8String ?: "?", e.reason.UTF8String ?: "");
    WPWriteRaw(line);
    NSArray *symbols = e.callStackSymbols;
    for (NSUInteger i = 0; i < MIN(symbols.count, 20); i++) {
        snprintf(line, sizeof line, "  %s\n", [symbols[i] UTF8String]);
        WPWriteRaw(line);
    }
    if (gWPOldExceptionHandler) gWPOldExceptionHandler(e);
}

// Logs where the main thread is when it has not answered for a few seconds.
static void WPStartWatchdog(void) {
    static mach_port_t mainThread;
    mainThread = mach_thread_self();
    static volatile double lastPong;
    lastPong = CFAbsoluteTimeGetCurrent();
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) { lastPong = CFAbsoluteTimeGetCurrent(); }];
    [NSThread detachNewThreadWithBlock:^{
        BOOL reported = NO;
        for (;;) {
            sleep(2);
            double stall = CFAbsoluteTimeGetCurrent() - lastPong;
            if (stall < 4) { reported = NO; continue; }
            if (reported) continue;
            reported = YES;
            // A very long gap usually means SpringBoard itself was paused (an app in front).
            if (stall > 30) continue;
            char line[160];
            snprintf(line, sizeof line, "\n!! The main thread has been stuck for %.0f s. Current position:\n", stall);
            WPWriteRaw(line);
            if (thread_suspend(mainThread) != KERN_SUCCESS) continue;
            arm_thread_state64_t st;
            mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
            if (thread_get_state(mainThread, ARM_THREAD_STATE64, (thread_state_t)&st, &count) == KERN_SUCCESS) {
                uintptr_t pc = (uintptr_t)arm_thread_state64_get_pc(st), lr = (uintptr_t)arm_thread_state64_get_lr(st);
                uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(st);
                pc &= 0x0000000FFFFFFFFFULL; lr &= 0x0000000FFFFFFFFFULL;
                WPWriteAddress("pc", pc);
                WPWriteAddress("lr", lr);
                for (int i = 0; i < 24 && fp && (fp & 7) == 0; i++) {
                    uintptr_t next = ((uintptr_t *)fp)[0];
                    uintptr_t ret = ((uintptr_t *)fp)[1] & 0x0000000FFFFFFFFFULL;
                    if (!ret) break;
                    snprintf(line, sizeof line, "#%02d", i);
                    WPWriteAddress(line, ret);
                    if (next <= fp) break;
                    fp = next;
                }
            }
            thread_resume(mainThread);
            if (gWPCrashFD >= 0) fsync(gWPCrashFD);
        }
    }];
}

// Where iOS performs a widget button's intent: in the widget extension's process, unless the
// intent has openAppWhenRun or adopts ForegroundContinuableIntent, LiveActivityIntent,
// AudioPlaybackIntent or PushToTalkTransmissionIntent — then in the app's process
// (WidgetKit, "Adding interactivity to widgets and Live Activities"). The extension's
// Metadata.appintents lists its intents with those traits. When every intent a button could
// run is an app-process one, returns their names; otherwise nil (buttons run here).
+ (NSString *)appProcessIntentsForExtension:(WPWidgetExtension *)ext {
    static NSMutableDictionary<NSString *, id> *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *extID = ext.extensionBundleID;
    if (!extID) return nil;
    id cached = cache[extID];
    if (cached) return cached == [NSNull null] ? nil : cached;

    NSString *path = [ext.extensionPath stringByAppendingPathComponent:@"Metadata.appintents/extract.actionsdata"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *actions = [root isKindOfClass:[NSDictionary class]] ? root[@"actions"] : nil;
    NSMutableArray *inApp = [NSMutableArray array], *here = [NSMutableArray array];
    if ([actions isKindOfClass:[NSDictionary class]]) {
        for (NSString *name in actions) {
            NSDictionary *a = actions[name];
            if (![a isKindOfClass:[NSDictionary class]]) continue;
            NSArray *protocols = [a[@"systemProtocols"] isKindOfClass:[NSArray class]] ? a[@"systemProtocols"] : @[];
            NSString *joined = [protocols componentsJoinedByString:@" "];
            // Widget / control configuration intents are settings, not button actions.
            if ([joined containsString:@"WidgetConfiguration"] || [joined containsString:@"ControlConfiguration"]) continue;
            BOOL app = [a[@"openAppWhenRun"] boolValue];
            for (NSString *p in @[ @"ForegroundContinuable", @"LiveActivity", @"AudioPlayback", @"PushToTalk" ]) {
                if ([joined containsString:p]) app = YES;
            }
            [(app ? inApp : here) addObject:name];
        }
    }
    NSString *result = (inApp.count && !here.count) ? [[inApp sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "] : nil;
    if (inApp.count || here.count) {
        WPRuntimeLog(@"  %@ button actions: run in the app [%@] / run in the widget [%@]", ext.appName ?: extID,
                     [inApp componentsJoinedByString:@", "], [here componentsJoinedByString:@", "]);
    }
    cache[extID] = result ?: [NSNull null];
    return result;
}

+ (void)installRuntimeCrashLog {
    if (gWPRuntimeCrashLog) return;
    // Keep runtime.txt small: past 1 MB, the old log moves to runtime-old.txt.
    NSString *logPath = [self runtimeLogPath];
    NSNumber *logSize = [[NSFileManager defaultManager] attributesOfItemAtPath:logPath error:nil][NSFileSize];
    if (logSize.unsignedLongLongValue > 1024 * 1024) {
        NSString *old = [[logPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"runtime-old.txt"];
        [[NSFileManager defaultManager] removeItemAtPath:old error:nil];
        [[NSFileManager defaultManager] moveItemAtPath:logPath toPath:old error:nil];
    }
    if (gWPCrashFD >= 0) close(gWPCrashFD);
    gWPCrashFD = -1;
    WPInstallCrashHandler();           // opens report.txt …
    if (gWPCrashFD >= 0) close(gWPCrashFD);
    gWPCrashFD = open([self runtimeLogPath].fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644); // … but write here
    gWPRuntimeCrashLog = YES;
    gWPOldExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(WPExceptionHandler);
    WPStartWatchdog();
}

@end
