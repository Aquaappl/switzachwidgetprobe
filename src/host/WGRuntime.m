// The widget host's runtime: loads one app's WidgetKit extension and runs its Swift code the
// way WidgetKit does on iOS, without WidgetKit's host services.
//
// Everything here works from Swift's runtime metadata (type descriptors, witness tables, value
// witnesses) and the Swift calling convention; the layouts used are those of the Swift ABI
// (stable since Swift 5). Each step was checked on devices with real apps (YouTube, Spotify,
// to-do and timer apps) in SwitzachWidgetProbe 1.x / 2.x; this is that logic, reorganised for
// a process that hosts exactly one extension.
//
//   1. Load      copy the .appex, sign the copy (Nyxian), preload its @rpath frameworks, dlopen
//   2. Read      find WidgetBundle / Widget conformances (__swift5_proto), run the bundle's
//                init() and body, walk each Widget's configuration tree: timeline provider box,
//                kind, name, description, supported families
//   3. Render    TimelineProviderContext → placeholder(in:) → getTimeline / timeline(for:in:)
//                (async through WGAsync.s) → the entry through the widget's view builder → a
//                UIHostingController (container background, or WidgetKit's accented mode)
//   4. Data      App Groups and suite defaults redirected to the app's data container, watched
//                for changes (stands in for WidgetCenter.reloadTimelines)

#import "WGRuntime.h"
#import "WGSharedData.h"
#import <dlfcn.h>
#import <fcntl.h>
#import <signal.h>
#import <unistd.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/fat.h>
#import <mach-o/getsect.h>
#import <mach-o/loader.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/ucontext.h>
#import <os/lock.h>

NSNotificationName const WGRuntimeDataChangedNotification = @"WGRuntimeDataChanged";

static WGExtension *gExt;           // the extension this host runs
static NSString *gCopyPath;         // its signed copy (the bundle that is loaded)

#pragma mark - Symbols

// dlsym goes through Nyxian's hook and can be slow: each symbol is looked up once.
static void *WGSym(const char *name) {
    static NSMutableDictionary<NSString *, NSValue *> *cache;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    NSString *key = @(name);
    os_unfair_lock_lock(&lock);
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSValue *v = cache[key];
    os_unfair_lock_unlock(&lock);
    if (v) return v.pointerValue;
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p) {
        os_unfair_lock_lock(&lock);
        cache[key] = [NSValue valueWithPointer:p];
        os_unfair_lock_unlock(&lock);
    }
    return p;
}

#pragma mark - Swift ABI

#define SWIFTCALL __attribute__((swiftcall))
#define SWIFT_CONTEXT __attribute__((swift_context))
#define SWIFT_INDIRECT __attribute__((swift_indirect_result))

typedef struct { const void *metadata; size_t state; } WGMetadataResponse;
typedef struct { const char *data; uintptr_t length; } WGTypeNamePair;
typedef struct {
    void *functions[8]; // initializeBufferWithCopyOfBuffer, destroy, initializeWithCopy, assignWithCopy,
                        // initializeWithTake, assignWithTake, getEnumTagSinglePayload, storeEnumTagSinglePayload
    size_t size, stride;
    uint32_t flags, extraInhabitantCount;
} WGVWT;

typedef WGMetadataResponse (*WGMetadataAccessor)(size_t request) SWIFTCALL;
typedef WGMetadataResponse (*WGGenericAccessor1)(size_t request, const void *a) SWIFTCALL;
typedef WGMetadataResponse (*WGGenericAccessor2)(size_t request, const void *a, const void *b) SWIFTCALL;
typedef WGTypeNamePair (*WGGetTypeName)(const void *type, bool qualified) SWIFTCALL;
typedef const void *(*WGConformsToProtocol)(const void *type, const void *protocol);
typedef WGMetadataResponse (*WGGetAssociatedTypeWitness)(size_t request, const void *wt, const void *type, const void *reqBase,
                                                         const void *assocType) SWIFTCALL;
typedef const void *(*WGGetTypeByMangledName)(const char *name, size_t length, const void *context, const void *const *args) SWIFTCALL;
typedef void (*WGWitnessInit)(void *out SWIFT_INDIRECT, const void *selfType, const void *wt, const void *metatype SWIFT_CONTEXT) SWIFTCALL;
typedef void (*WGWitnessGetter)(void *out SWIFT_INDIRECT, const void *selfType, const void *wt, const void *selfValue SWIFT_CONTEXT) SWIFTCALL;
typedef void (*WGIndirectInit)(void *out SWIFT_INDIRECT) SWIFTCALL;
typedef void (*WGCopyValue)(void *dest, const void *src, const void *type) SWIFTCALL;
typedef void (*WGDestroyValue)(void *value, const void *type);
typedef void *(*WGInitializeWithTake)(void *dest, void *src, const void *type);
typedef unsigned (*WGGetEnumTagSinglePayload)(const void *value, unsigned emptyCases, const void *type);
typedef void (*WGStoreEnumTagSinglePayload)(void *value, unsigned whichCase, unsigned emptyCases, const void *type);
typedef void (*WGStoreEnumTag)(void *value, unsigned whichCase, unsigned emptyCases, const void *type) SWIFTCALL;
typedef unsigned (*WGEnumTagFn)(const void *value, const void *type) SWIFTCALL;
typedef void (*WGEnumProjectFn)(void *value, const void *type) SWIFTCALL;

// Metadata kinds.
enum { WGKindStruct = 0x200, WGKindEnum = 0x201, WGKindOptional = 0x202, WGKindForeignClass = 0x203, WGKindFunction = 0x302,
       WGKindExistential = 0x303, WGKindMetatype = 0x304, WGKindObjCWrapper = 0x305, WGKindExistentialMetatype = 0x306 };
#define WG_VWT_NON_POD 0x00010000u
#define WG_VWT_NON_INLINE 0x00020000u

static const void *WGRelDirect(const int32_t *field) {
    return *field ? (const char *)field + *field : NULL;
}

static const void *WGRelIndirectable(const int32_t *field) {
    int32_t v = *field;
    if (!v) return NULL;
    const char *p = (const char *)field + (v & ~1);
    return (v & 1) ? *(const void *const *)p : p;
}

static const WGVWT *WGValueWitnesses(const void *md) {
    return ((const WGVWT *const *)md)[-1];
}

static uintptr_t WGKind(const void *md) {
    return *(const uintptr_t *)md;
}

static BOOL WGIsClass(const void *md) {
    uintptr_t k = WGKind(md);
    return k == 0 || k > 0x7FF;
}

// Zeroed, aligned storage for one value. Values handed to the app's code are kept for good.
static void *WGAlloc(const void *md) {
    const WGVWT *vwt = WGValueWitnesses(md);
    size_t align = (vwt->flags & 0xFF) + 1;
    if (align < 16) align = 16;
    size_t size = vwt->stride > 16 ? vwt->stride : 16;
    void *p = NULL;
    if (posix_memalign(&p, align, size) != 0) return NULL;
    memset(p, 0, size);
    return p;
}

static NSString *WGTypeName(const void *md) {
    WGGetTypeName getName = WGSym("swift_getTypeName");
    if (!getName || !md) return @"?";
    WGTypeNamePair pair = getName(md, true);
    if (!pair.data) return @"?";
    return [[NSString alloc] initWithBytes:pair.data length:pair.length encoding:NSUTF8StringEncoding] ?: @"?";
}

static size_t WGMangledLength(const uint8_t *name) {
    size_t i = 0;
    while (name[i]) {
        uint8_t c = name[i];
        i += (c >= 0x01 && c <= 0x17) ? 5 : (c >= 0x18 && c <= 0x1F) ? 9 : 1;
    }
    return i;
}

static const void *WGResolveMangled(const uint8_t *mangled, const void *context, const void *const *args) {
    WGGetTypeByMangledName get = WGSym("swift_getTypeByMangledNameInContext");
    if (!mangled || !*mangled || !get) return NULL;
    return get((const char *)mangled, WGMangledLength(mangled), context, args);
}

// The Swift class descriptor of a class metadata, or NULL (Objective-C classes have none).
static const uint8_t *WGClassDescriptor(const void *md) {
    if (!WGIsClass(md)) return NULL;
    uintptr_t data = ((const uintptr_t *)md)[4];
    if (!(data & 3)) return NULL;
    return ((const uint8_t *const *)md)[8];
}

// Fields of a struct or class: (descriptor, generic arguments, field offsets).
typedef struct {
    const uint8_t *desc, *fieldDesc;
    const void *const *genericArgs;
    const uint8_t *offsets;
    BOOL isClass;
    uint32_t count;
    uint16_t recordSize;
} WGFields;

static BOOL WGGetFields(const void *md, WGFields *out) {
    memset(out, 0, sizeof *out);
    out->isClass = WGIsClass(md);
    if (out->isClass) {
        out->desc = WGClassDescriptor(md);
    } else if (WGKind(md) == WGKindStruct) {
        out->desc = ((const uint8_t *const *)md)[1];
    }
    if (!out->desc) return NO;
    out->fieldDesc = WGRelDirect((const int32_t *)(out->desc + 16));
    if (!out->fieldDesc) return NO;
    out->recordSize = *(const uint16_t *)(out->fieldDesc + 10);
    out->count = *(const uint32_t *)(out->fieldDesc + 12);
    if (out->recordSize < 12 || out->count > 128) return NO;
    if (out->isClass) {
        uint32_t positive = *(const uint32_t *)(out->desc + 28), immediate = *(const uint32_t *)(out->desc + 32);
        out->genericArgs = (const void *const *)md + (positive - immediate);
        out->offsets = (const uint8_t *)md + *(const uint32_t *)(out->desc + 40) * 8;
    } else {
        out->genericArgs = (const void *const *)md + 2;
        out->offsets = (const uint8_t *)md + *(const uint32_t *)(out->desc + 24) * 8;
    }
    return YES;
}

static const uint8_t *WGFieldRecord(const WGFields *f, uint32_t i) { return f->fieldDesc + 16 + i * f->recordSize; }
static const char *WGFieldName(const WGFields *f, uint32_t i) { return WGRelDirect((const int32_t *)(WGFieldRecord(f, i) + 8)); }
static const uint8_t *WGFieldMangled(const WGFields *f, uint32_t i) { return WGRelDirect((const int32_t *)(WGFieldRecord(f, i) + 4)); }
static size_t WGFieldOffset(const WGFields *f, uint32_t i) {
    return f->isClass ? ((const size_t *)f->offsets)[i] : ((const uint32_t *)f->offsets)[i];
}
static const void *WGFieldType(const WGFields *f, uint32_t i) {
    return WGResolveMangled(WGFieldMangled(f, i), f->desc, f->genericArgs);
}

// A named stored property: its offset and type.
static BOOL WGStructField(const void *md, const char *want, size_t *offsetOut, const void **typeOut) {
    WGFields f;
    if (!WGGetFields(md, &f)) return NO;
    for (uint32_t i = 0; i < f.count; i++) {
        const char *name = WGFieldName(&f, i);
        if (!name || strcmp(name, want) != 0) continue;
        if (offsetOut) *offsetOut = WGFieldOffset(&f, i);
        if (typeOut) *typeOut = WGFieldType(&f, i);
        return YES;
    }
    return NO;
}

// Reads a Swift.String (two words) without calling into Swift.
static NSString *WGSwiftString(const void *p) {
    uint64_t w0 = ((const uint64_t *)p)[0], w1 = ((const uint64_t *)p)[1];
    uint8_t top = (uint8_t)(w1 >> 56);
    if (top & 0x20) { // small: up to 15 UTF-8 bytes inline
        char buf[16] = { 0 };
        memcpy(buf, &w0, 8);
        uint64_t rest = w1 & 0x00FFFFFFFFFFFFFFULL;
        memcpy(buf + 8, &rest, 7);
        return [[NSString alloc] initWithBytes:buf length:(top & 0x0F) encoding:NSUTF8StringEncoding];
    }
    uintptr_t object = (uintptr_t)(w1 & 0x0FFFFFFFFFFFFFFFULL);
    if (!object) return @"";
    if (!(top & 0x10) && (top & 0x40)) return (__bridge NSString *)(void *)object; // bridged NSString
    size_t count = (size_t)(w0 & 0x0000FFFFFFFFFFFFULL);
    if (count > 4096) return nil;
    return [[NSString alloc] initWithBytes:(const void *)(object + 32) length:count encoding:NSUTF8StringEncoding];
}

// The elements of a Swift.Array value: (first element, count). Element stride from its type.
static const uint8_t *WGArrayElements(const void *arrayValue, const void *elementType, intptr_t *countOut) {
    const uint8_t *buffer = *(const uint8_t *const *)arrayValue;
    *countOut = buffer ? *(const intptr_t *)(buffer + 16) : 0;
    if (!buffer) return NULL;
    size_t mask = WGValueWitnesses(elementType)->flags & 0xFF;
    return buffer + ((32 + mask) & ~mask);
}

#pragma mark Protocol descriptors

// TargetProtocolDescriptor: flags, parent, name, numRequirementsInSignature, numRequirements,
// associatedTypeNames, then the signature requirements (12 bytes each) and the requirements
// (8 bytes each). The requirements base is one requirement before the first; witness table
// slot = requirement index + 1.
typedef struct {
    const void *reqBase;
    const void *firstAssocType;
    uint32_t assocIndex;
} WGProtocolLayout;

static const uint8_t *WGProtocolRequirements(const void *protocol, uint32_t *countOut) {
    const uint8_t *p = protocol;
    uint32_t numSig = *(const uint32_t *)(p + 12), numReq = *(const uint32_t *)(p + 16);
    if (numReq > 64 || numSig > 64) return NULL;
    *countOut = numReq;
    return p + 24 + numSig * 12;
}

static BOOL WGReadProtocolLayout(const void *protocol, WGProtocolLayout *out) {
    uint32_t n = 0;
    const uint8_t *reqs = protocol ? WGProtocolRequirements(protocol, &n) : NULL;
    if (!reqs) return NO;
    out->reqBase = reqs - 8;
    out->firstAssocType = NULL;
    for (uint32_t i = 0; i < n; i++) {
        if ((*(const uint32_t *)(reqs + i * 8) & 0x0F) == 7) { // associated type access function
            out->firstAssocType = reqs + i * 8;
            out->assocIndex = i;
            break;
        }
    }
    return out->firstAssocType != NULL;
}

// Requirement indices of a kind (1 method, 2 init, 3 getter, 7 associated type), in order.
static int WGRequirementsOfKind(const void *protocol, uint32_t kind, int *out, int max) {
    uint32_t n = 0;
    const uint8_t *reqs = WGProtocolRequirements(protocol, &n);
    if (!reqs) return 0;
    int found = 0;
    for (uint32_t i = 0; i < n && found < max; i++) {
        if ((*(const uint32_t *)(reqs + i * 8) & 0x0F) == kind) out[found++] = (int)i;
    }
    return found;
}

static int WGFirstRequirement(const void *protocol, uint32_t kind) {
    int i = -1;
    return WGRequirementsOfKind(protocol, kind, &i, 1) ? i : -1;
}

#pragma mark - Loading

// @rpath install names the binary links (the frameworks to find in the app's Frameworks).
static NSArray<NSString *> *WGRpathDependencies(NSString *path) {
    NSMutableArray *out = [NSMutableArray array];
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (data.length < sizeof(struct mach_header_64)) return out;
    const uint8_t *base = data.bytes;
    size_t offset = 0;
    uint32_t magic = *(const uint32_t *)base;
    if (magic == FAT_CIGAM || magic == FAT_MAGIC) {
        const struct fat_header *fh = (const void *)base;
        const struct fat_arch *archs = (const void *)(fh + 1);
        uint32_t n = OSSwapBigToHostInt32(fh->nfat_arch);
        for (uint32_t i = 0; i < n && (const uint8_t *)(archs + i + 1) <= base + data.length; i++) {
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
    const uint8_t *cmd = (const uint8_t *)(mh + 1), *end = base + data.length;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const void *)cmd;
        if (cmd + sizeof(*lc) > end || lc->cmdsize < sizeof(*lc) || cmd + lc->cmdsize > end) break;
        if (lc->cmd == LC_LOAD_DYLIB || lc->cmd == LC_LOAD_WEAK_DYLIB) {
            const struct dylib_command *d = (const void *)lc;
            if (d->dylib.name.offset < lc->cmdsize) {
                NSString *n = [[NSString alloc] initWithBytes:cmd + d->dylib.name.offset
                                                       length:strnlen((const char *)cmd + d->dylib.name.offset, lc->cmdsize - d->dylib.name.offset)
                                                     encoding:NSUTF8StringEncoding];
                if ([n hasPrefix:@"@rpath/"]) [out addObject:[n substringFromIndex:7]];
            }
        }
        cmd += lc->cmdsize;
    }
    return out;
}

// Loads @rpath frameworks the binary links, each one's own @rpath dependencies first (their
// install names then match images already loaded). Nothing else of the app is loaded.
static void WGPreload(NSString *item, NSArray<NSString *> *dirs, NSMutableSet *visited, int depth) {
    if ([visited containsObject:item] || depth > 12) return;
    [visited addObject:item];
    NSString *binary = nil;
    for (NSString *dir in dirs) {
        NSString *candidate = [dir stringByAppendingPathComponent:item];
        if (access(candidate.fileSystemRepresentation, R_OK) == 0) { binary = candidate; break; }
    }
    if (!binary) {
        if (![item hasPrefix:@"libswift"]) WGLog(@"  not found: @rpath/%@", item);
        return;
    }
    for (NSString *dep in WGRpathDependencies(binary)) WGPreload(dep, dirs, visited, depth + 1);
    if (!dlopen(binary.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) WGLog(@"  preload failed: %@ — %s", item, dlerror() ?: "?");
}

// Images loaded into this process, kept from the add-image callback (Nyxian's
// _dyld_get_image_name searches every image on each call).
static NSMutableArray<NSArray *> *gImages; // [path, header]
static os_unfair_lock gImagesLock = OS_UNFAIR_LOCK_INIT;

static void WGImageAdded(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    if (!dladdr(mh, &info) || !info.dli_fname) return;
    os_unfair_lock_lock(&gImagesLock);
    [gImages addObject:@[ @(info.dli_fname), [NSValue valueWithPointer:mh] ]];
    os_unfair_lock_unlock(&gImagesLock);
}

static const struct mach_header *WGFindImage(NSString *path) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gImages = [NSMutableArray array];
        _dyld_register_func_for_add_image(WGImageAdded);
    });
    // The last components only: paths differ by /private and symlinks.
    NSArray *parts = path.pathComponents;
    NSString *tail = [NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(parts.count > 3 ? parts.count - 3 : 0, MIN(3, parts.count))]];
    os_unfair_lock_lock(&gImagesLock);
    NSArray *images = [gImages copy];
    os_unfair_lock_unlock(&gImagesLock);
    for (NSArray *img in images) {
        NSString *n = img[0];
        if ([n isEqualToString:path] || [n hasSuffix:tail]) return [img[1] pointerValue];
    }
    return NULL;
}

// Copies an extension bundle into the work folder (once per build of it), signs the copy and
// loads it. Signing in place would change the app's own bundle.
static const struct mach_header *WGLoadBundleCopy(NSString *appexPath, NSString *executableName, NSString *copyDir, NSString **copyOut) {
    static NSRecursiveLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSRecursiveLock new]; });
    [lock lock];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *copy = [copyDir stringByAppendingPathComponent:appexPath.lastPathComponent];
    NSString *exe = [copy stringByAppendingPathComponent:executableName];
    if (copyOut) *copyOut = copy;
    const struct mach_header *mh = WGFindImage(exe);
    if (mh) {
        [lock unlock];
        return mh;
    }
    NSString *source = [appexPath stringByAppendingPathComponent:executableName];
    NSDictionary *a = [fm attributesOfItemAtPath:source error:nil];
    NSString *stamp = [NSString stringWithFormat:@"%@|%@|%@", source, a[NSFileSize], @([a[NSFileModificationDate] timeIntervalSince1970])];
    NSString *stampPath = [copyDir stringByAppendingPathComponent:@".wg-source"];
    if (![[NSString stringWithContentsOfFile:stampPath encoding:NSUTF8StringEncoding error:nil] isEqualToString:stamp] ||
        access(exe.fileSystemRepresentation, F_OK) != 0) {
        WGLog(@"  copying and signing %@", appexPath.lastPathComponent);
        [fm removeItemAtPath:copy error:nil];
        [fm createDirectoryAtPath:copyDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSError *err = nil;
        if (![fm copyItemAtPath:appexPath toPath:copy error:&err]) {
            WGLogImportant(@"  copying %@ failed: %@", appexPath.lastPathComponent, err.localizedDescription);
            [lock unlock];
            return NULL;
        }
        // Nyxian's SYS_sign (761) signs the file behind a read-write descriptor. dlopen would
        // also sign an unsigned binary itself; signing here keeps older Nyxian builds working.
        int64_t (*syscallFn)(uint32_t, ...) = WGSym("liveshim_syscall");
        if (syscallFn) {
            int fd = open(exe.fileSystemRepresentation, O_RDWR);
            if (fd >= 0) {
                int64_t r = syscallFn(761, (int64_t)fd, (int64_t)0, (int64_t)0, (int64_t)0, (int64_t)0, (int64_t)0);
                close(fd);
                WGLog(@"  signed → %lld", r);
            }
        }
        [stamp writeToFile:stampPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
    }
    NSArray *deps = WGRpathDependencies(exe);
    if (deps.count) {
        NSMutableSet *visited = [NSMutableSet set];
        NSArray *dirs = @[ [gExt.appPath stringByAppendingPathComponent:@"Frameworks"], [copy stringByAppendingPathComponent:@"Frameworks"] ];
        for (NSString *dep in deps) WGPreload(dep, dirs, visited, 0);
    }
    if (!dlopen(exe.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL)) {
        WGLogImportant(@"  dlopen failed: %s", dlerror() ?: "?");
        [lock unlock];
        return NULL;
    }
    mh = WGFindImage(exe);
    [lock unlock];
    return mh;
}

static NSString *WGExtensionWorkDir(void) {
    return WGWorkPath([@"runtime-" stringByAppendingString:gExt.extensionID]);
}

#pragma mark Bundle.main

// This host exists for one extension, so Bundle.main is the extension's bundle for every caller
// — the extension's code, its app's frameworks and the system's code that looks things up while
// drawing (UIImage(named:), Image("name"), Text("key"), String(localized:)) — as in an iOS
// extension process. Code of another extension loaded with it (the Intents extension) gets
// that extension's bundle.
static NSBundle *gMainBundle;
static IMP gOrigMainBundle;
static uintptr_t gExtraStart[8], gExtraEnd[8];
static NSBundle *__strong gExtraBundles[8];
static volatile int gExtraCount;

static NSBundle *WGMainBundleHook(id self, SEL _cmd) {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    int n = gExtraCount;
    for (int i = 0; i < n; i++) {
        if (caller >= gExtraStart[i] && caller < gExtraEnd[i]) return gExtraBundles[i];
    }
    return gMainBundle ?: ((NSBundle * (*)(id, SEL)) gOrigMainBundle)(self, _cmd);
}

static uint64_t WGTextSize(const struct mach_header *mh) {
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

// Registered on the main thread, before anything can call into that image; read lock-free.
static void WGAddBundleRedirect(const struct mach_header *mh, NSString *bundlePath) {
    int n = gExtraCount;
    uint64_t size = WGTextSize(mh);
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    if (n >= 8 || !size || !bundle) return;
    gExtraStart[n] = (uintptr_t)mh;
    gExtraEnd[n] = (uintptr_t)mh + size;
    gExtraBundles[n] = bundle;
    __atomic_store_n(&gExtraCount, n + 1, __ATOMIC_RELEASE);
}

static void WGInstallMainBundle(NSString *bundlePath) {
    if (gMainBundle) return;
    gMainBundle = [NSBundle bundleWithPath:bundlePath];
    Method m = class_getClassMethod([NSBundle class], @selector(mainBundle));
    gOrigMainBundle = method_setImplementation(m, (IMP)WGMainBundleHook);
}

#pragma mark - Reading the widgets

// A widget's timeline provider box (WidgetKit's TimelineEntryProvider family): holds the
// app's provider, the view builder ("generator") and the kind ("config").
typedef struct {
    const void *base;  // the value (struct) or the object (class)
    const void *type;  // its metadata
    BOOL isIntent;     // IntentTimelineProvider (SiriKit intent configuration)
    BOOL isAppIntent;  // AppIntentTimelineProvider (iOS 17)
} WGProviderBox;

typedef struct { const void *value, *type; } WGFoundConfig;
typedef struct { const void *closure, *fnType; } WGDescTransform;

static WGFoundConfig gConfigs[32];
static int gConfigCount;
static WGDescTransform gTransforms[32];
static int gTransformCount;
static NSMutableArray<NSArray *> *gDescLeaves; // per descriptor: its leaves (WGCollectLeaves)
static BOOL gDescDisabled;                    // applying descriptor transforms crashed once
static WGProviderBox gBoxes[32];
static int gBoxCount;

static NSArray<NSDictionary *> *gWidgets;      // what the host lists
static NSMutableDictionary<NSString *, NSValue *> *gBoxByKind;

typedef struct { void *r0, *r1, *r2, *r3; } WGFourWords;
typedef WGFourWords (*WGThickDirect)(const void *ctx SWIFT_CONTEXT) SWIFTCALL;
typedef void (*WGThickIndirect)(void *out SWIFT_INDIRECT, const void *ctx SWIFT_CONTEXT) SWIFTCALL;
typedef void (*WGInoutClosure)(void *value, const void *ctx SWIFT_CONTEXT) SWIFTCALL;

// The leaves of a value — Swift strings ([path, string]), enum cases ([path, "case:name"]),
// integers ([path, "int:n (type)"]) and Objective-C objects ([path, "<object>", object]) — found
// through its type metadata. Used to read a WidgetDescriptor without knowing its layout.
static void WGCollectLeaves(const void *value, const void *md, NSString *path, int depth, NSMutableArray *out) {
    if (!value || !md || depth > 9 || out.count > 300) return;
    uintptr_t kind = WGKind(md);
    NSString *typeName = WGTypeName(md);
    if ([typeName isEqualToString:@"Swift.String"]) {
        NSString *s = WGSwiftString(value);
        if (s) [out addObject:@[ path, s ]];
        return;
    }
    if (kind == WGKindFunction || kind == WGKindMetatype || kind == WGKindExistentialMetatype || [typeName hasPrefix:@"SwiftUI.EnvironmentValues"]) return;
    static NSSet *integers;
    if (!integers) integers = [NSSet setWithArray:@[ @"Swift.Int", @"Swift.UInt", @"Swift.Int64", @"Swift.UInt64", @"Swift.Int32",
                                                     @"Swift.UInt32", @"Swift.Int16", @"Swift.UInt16", @"Swift.Int8", @"Swift.UInt8" ]];
    size_t size = WGValueWitnesses(md)->size;
    BOOL importedPlain = (kind == WGKindStruct || kind == WGKindEnum) && [typeName hasPrefix:@"__C."] && (size == 1 || size == 2 || size == 4 || size == 8);
    if ([integers containsObject:typeName] || importedPlain) {
        uint64_t v = 0;
        memcpy(&v, value, MIN(size, sizeof v));
        [out addObject:@[ path, [NSString stringWithFormat:@"int:%llu (%@)", v, typeName] ]];
        return;
    }
    if ([typeName hasPrefix:@"Swift.Set<"] || [typeName hasPrefix:@"Swift.Dictionary<"]) return;
    if (kind == WGKindObjCWrapper || kind == WGKindForeignClass) {
        id o = (__bridge id) * (void *const *)value;
        if ([o isKindOfClass:[NSString class]]) [out addObject:@[ path, o ]];
        else if (o) [out addObject:@[ path, @"<object>", o ]];
        return;
    }
    if (kind == WGKindExistential) {
        uint32_t flags = *(const uint32_t *)((const uint8_t *)md + 8);
        if (!(flags & 0x80000000)) { // class-bound: like a class reference
            const void *obj = *(const void *const *)value;
            const void *dyn = obj ? *(const void *const *)obj : NULL;
            if (dyn) WGCollectLeaves(value, dyn, path, depth + 1, out);
            return;
        }
        const void *dyn = ((const void *const *)value)[3];
        if (!dyn) return;
        const WGVWT *vwt = WGValueWitnesses(dyn);
        const void *inner = value;
        if (vwt->flags & WG_VWT_NON_INLINE) {
            size_t mask = vwt->flags & 0xFF;
            inner = *(const uint8_t *const *)value + ((16 + mask) & ~mask);
        }
        WGCollectLeaves(inner, dyn, path, depth + 1, out);
        return;
    }
    if ([typeName hasPrefix:@"Swift.Array<"] || [typeName hasPrefix:@"Swift.ContiguousArray<"]) {
        const void *elementType = ((const void *const *)md)[2];
        intptr_t count = 0;
        const uint8_t *first = elementType ? WGArrayElements(value, elementType, &count) : NULL;
        size_t stride = elementType ? MAX(WGValueWitnesses(elementType)->stride, (size_t)1) : 1;
        for (intptr_t i = 0; first && i < count && i < 16; i++) {
            WGCollectLeaves(first + i * stride, elementType, [path stringByAppendingFormat:@"[%ld]", (long)i], depth + 1, out);
        }
        return;
    }
    if (kind == WGKindEnum || kind == WGKindOptional) {
        const uint8_t *desc = ((const uint8_t *const *)md)[1];
        const uint8_t *fd = WGRelDirect((const int32_t *)(desc + 16));
        if (!fd) return;
        uint16_t recordSize = *(const uint16_t *)(fd + 10);
        uint32_t count = *(const uint32_t *)(fd + 12);
        uint32_t payloadCases = *(const uint32_t *)(desc + 20) & 0x00FFFFFF;
        const void *const *witnesses = (const void *const *)WGValueWitnesses(md);
        unsigned tag = ((WGEnumTagFn)witnesses[11])(value, md);
        if (tag >= count || recordSize < 12) return;
        const uint8_t *rec = fd + 16 + tag * recordSize;
        const char *caseName = WGRelDirect((const int32_t *)(rec + 8));
        const uint8_t *mangled = WGRelDirect((const int32_t *)(rec + 4));
        if (tag >= payloadCases || !mangled || !*mangled) {
            if (kind == WGKindEnum) [out addObject:@[ path, [NSString stringWithFormat:@"case:%s", caseName ?: "?"] ]];
            return;
        }
        const void *payloadType = WGResolveMangled(mangled, desc, (const void *const *)md + 2);
        if (!payloadType) return;
        // The payload of a copy: projecting clears the tag bits in place.
        void *copy = WGAlloc(md);
        ((WGCopyValue)WGValueWitnesses(md)->functions[2])(copy, value, md);
        ((WGEnumProjectFn)witnesses[12])(copy, md);
        const void *payload = copy;
        if (*(const uint32_t *)rec & 1) { // indirect case: boxed
            size_t pmask = WGValueWitnesses(payloadType)->flags & 0xFF;
            payload = *(const uint8_t *const *)copy + ((16 + pmask) & ~pmask);
        }
        WGCollectLeaves(payload, payloadType, kind == WGKindOptional ? path : [path stringByAppendingFormat:@".%s", caseName ?: "?"], depth + 1, out);
        return;
    }
    const uint8_t *base = value;
    const void *fieldsMD = md;
    if (WGIsClass(md)) {
        const void *obj = *(const void *const *)value;
        if (!obj) return;
        fieldsMD = *(const void *const *)obj;
        if (!WGClassDescriptor(fieldsMD)) { // an Objective-C object
            id o = (__bridge id)obj;
            if ([o isKindOfClass:[NSString class]]) [out addObject:@[ path, o ]];
            else [out addObject:@[ path, @"<object>", o ]];
            return;
        }
        base = obj;
    } else if (kind != WGKindStruct) {
        return;
    }
    WGFields f;
    if (!WGGetFields(fieldsMD, &f)) return;
    for (uint32_t i = 0; i < f.count; i++) {
        const void *fieldType = WGFieldType(&f, i);
        if (!fieldType) continue;
        const char *name = WGFieldName(&f, i);
        WGCollectLeaves(base + WGFieldOffset(&f, i), fieldType, [path stringByAppendingFormat:@".%s", name ?: "?"], depth + 1, out);
    }
}

// An Array<T> holding a copy of one value (the standard library's own allocator); returns
// storage for the array variable.
typedef struct { void *array, *elements; } WGArrayAndBase;
typedef WGArrayAndBase (*WGAllocArrayFn)(intptr_t count, const void *elementType) SWIFTCALL;

static void *WGArrayOfOne(const void *value, const void *type) {
    WGAllocArrayFn alloc = WGSym("$ss27_allocateUninitializedArrayySayxG_BptBwlF");
    if (!alloc) return NULL;
    WGArrayAndBase r = alloc(1, type);
    if (!r.array || !r.elements) return NULL;
    ((WGCopyValue)WGValueWitnesses(type)->functions[2])(r.elements, value, type);
    void **var = calloc(1, sizeof(void *));
    *var = r.array;
    return var;
}

// .configurationDisplayName / .description / .supportedFamilies each wrap the configuration in
// a _PreferenceTransformModifier<WidgetDescriptorKey> whose closure edits the descriptor the
// innermost configuration (WidgetDescriptorConfiguration) starts from. The closures on the path
// are applied there, innermost first, as WidgetKit does.
static void WGRecordDescriptor(const void *value, const void *md) {
    size_t offset = 0;
    const void *descType = NULL;
    if (gDescDisabled || !WGStructField(md, "descriptor", &offset, &descType) || !descType) return;
    void *descriptor = WGAlloc(descType);
    ((WGCopyValue)WGValueWitnesses(descType)->functions[2])(descriptor, (const uint8_t *)value + offset, descType);
    // WidgetDescriptorKey's value is [WidgetDescriptor]: transforms that take the array get one
    // holding this widget's descriptor.
    void *array = NULL;
    for (int i = gTransformCount - 1; i >= 0; i--) {
        const void *fnType = gTransforms[i].fnType;
        if (!fnType || WGKind(fnType) != WGKindFunction || (((const size_t *)fnType)[1] & 0xFFFF) != 1) continue;
        const void *param = ((const void *const *)fnType)[3];
        const void *const *pair = gTransforms[i].closure;
        if (param == descType && !array) {
            ((WGInoutClosure)pair[0])(descriptor, pair[1]);
            continue;
        }
        if (![WGTypeName(param) hasPrefix:@"Swift.Array<"] || ((const void *const *)param)[2] != descType) continue;
        if (!array) array = WGArrayOfOne(descriptor, descType);
        if (array) ((WGInoutClosure)pair[0])(array, pair[1]);
    }
    if (array) {
        intptr_t count = 0;
        const uint8_t *first = WGArrayElements(array, descType, &count);
        if (count >= 1 && first) {
            descriptor = WGAlloc(descType);
            ((WGCopyValue)WGValueWitnesses(descType)->functions[2])(descriptor, first, descType);
        }
    }
    NSMutableArray *leaves = [NSMutableArray array];
    WGCollectLeaves(descriptor, descType, @"", 0, leaves);
    [gDescLeaves addObject:leaves];
}

// Kind, name, description and families from a descriptor's leaves. Localized texts are looked
// up in the bundle they name, or the extension's.
static NSDictionary *WGDescriptorInfo(NSArray *leaves, NSBundle *extensionBundle) {
    NSString *kind = nil;
    NSMutableDictionary<NSString *, NSMutableArray *> *byRoot = [NSMutableDictionary dictionary];
    NSMutableOrderedSet *families = [NSMutableOrderedSet orderedSet];
    BOOL sawFamilies = NO;
    for (NSArray *leaf in leaves) {
        NSString *path = leaf[0];
        NSArray *parts = [path componentsSeparatedByString:@"."];
        NSString *root = parts.count > 1 ? parts[1] : @"";
        NSRange bracket = [root rangeOfString:@"["];
        if (bracket.location != NSNotFound) root = [root substringToIndex:bracket.location];
        if (([root isEqualToString:@"kind"] || [path hasSuffix:@".kind"]) && leaf.count == 2 && !kind) kind = leaf[1];
        if ([root isEqualToString:@"supportedFamilies"] && [leaf[1] hasPrefix:@"int:"]) {
            sawFamilies = YES;
            long f = [[leaf[1] substringFromIndex:4] integerValue];
            // WidgetFamily raw values: 1 small, 2 medium, 3 large, 4 extraLarge.
            if (f >= 1 && f <= 4) [families addObject:WGFamilyName((WGFamily)(f - 1))];
        }
        if (!byRoot[root]) byRoot[root] = [NSMutableArray array];
        [byRoot[root] addObject:leaf];
    }
    NSString * (^lookup)(NSBundle *, NSString *, NSString *) = ^NSString *(NSBundle *b, NSString *key, NSString *table) {
        NSString *found = [b localizedStringForKey:key value:@"\x01" table:table];
        return found.length && ![found isEqualToString:@"\x01"] ? found : nil;
    };
    NSString * (^text)(NSArray *) = ^NSString *(NSArray *items) {
        NSString *key = nil, *verbatim = nil, *table = nil, *fallback = nil;
        NSBundle *bundle = nil;
        for (NSArray *leaf in items) {
            if (leaf.count > 2) {
                if ([leaf[2] isKindOfClass:[NSBundle class]]) bundle = leaf[2];
                continue;
            }
            NSString *s = leaf[1];
            if (![s isKindOfClass:[NSString class]] || [s hasPrefix:@"case:"] || [s hasPrefix:@"int:"]) continue;
            NSString *lower = [leaf[0] lowercaseString];
            NSString *last = [[leaf[0] componentsSeparatedByString:@"."] lastObject];
            if ([lower containsString:@"table"]) { if (!table) table = s; continue; }
            if ([lower containsString:@"verbatim"]) { if (!verbatim) verbatim = s; continue; }
            if ([lower containsString:@"default"]) { if (!fallback) fallback = s; continue; }
            if ([last isEqualToString:@"key"] || [lower containsString:@".key"]) { if (!key) key = s; continue; }
            if (!fallback) fallback = s;
        }
        if (verbatim.length) return verbatim;
        if (key.length) {
            NSString *found = (bundle ? lookup(bundle, key, table) : nil) ?: (extensionBundle ? lookup(extensionBundle, key, table) : nil);
            return found ?: (fallback.length ? fallback : key);
        }
        return fallback;
    };
    NSString *name = nil, *description = nil;
    for (NSString *root in byRoot) {
        NSString *lower = root.lowercaseString;
        if (!name && [lower containsString:@"displayname"]) name = text(byRoot[root]);
        else if (!description && [lower containsString:@"description"]) description = text(byRoot[root]);
    }
    // Plain text that is really a key (SiriKit-intent widgets): the extension's strings know it.
    NSString * (^translated)(NSString *) = ^NSString *(NSString *t) {
        NSString *found = t.length && extensionBundle ? lookup(extensionBundle, t, nil) : nil;
        return found && ![found isEqualToString:t] ? [found stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : t;
    };
    name = translated(name);
    description = translated(description);
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (kind) info[@"kind"] = kind;
    if (name.length) info[@"name"] = name;
    if (description.length) info[@"description"] = description;
    if (sawFamilies) { // possibly empty: not for the home screen
        info[@"families"] = [@[ @"small", @"medium", @"large", @"extraLarge" ] filteredArrayUsingPredicate:
                             [NSPredicate predicateWithBlock:^BOOL(NSString *f, NSDictionary *b) { return [families containsObject:f]; }]];
    }
    return info;
}

// Walks a configuration tree: records StaticConfiguration / IntentConfiguration /
// AppIntentConfiguration values, collects descriptor transforms on the way down, records
// descriptors, and takes composite configurations apart through their body.
static void WGExploreConfiguration(const void *value, const void *md, int depth) {
    if (depth > 24) return;
    NSString *typeName = WGTypeName(md);
    if (([typeName hasPrefix:@"WidgetKit.StaticConfiguration<"] || [typeName hasPrefix:@"WidgetKit.IntentConfiguration<"] ||
         [typeName hasPrefix:@"WidgetKit.AppIntentConfiguration<"]) && gConfigCount < 32) {
        gConfigs[gConfigCount++] = (WGFoundConfig){ value, md };
    }
    if ([typeName isEqualToString:@"WidgetKit.WidgetDescriptorConfiguration"]) WGRecordDescriptor(value, md);

    const uint8_t *desc = WGKind(md) == WGKindStruct ? ((const uint8_t *const *)md)[1] : NULL;
    const char *name = desc ? WGRelDirect((const int32_t *)(desc + 8)) : NULL;
    if (name && strcmp(name, "ModifiedContent") == 0) {
        // ModifiedContent<Content, Modifier>: field 0 the content (generic argument 0).
        const uint32_t *offsets = (const uint32_t *)((const uint8_t *)md + *(const uint32_t *)(desc + 24) * 8);
        const void *contentType = ((const void *const *)md)[2], *modifierType = ((const void *const *)md)[3];
        BOOL pushed = NO;
        size_t transformOffset = 0;
        const void *transformType = NULL;
        if ([WGTypeName(modifierType) hasPrefix:@"SwiftUI._PreferenceTransformModifier<WidgetKit.WidgetDescriptorKey>"] &&
            gTransformCount < 32 && WGStructField(modifierType, "transform", &transformOffset, &transformType)) {
            gTransforms[gTransformCount++] = (WGDescTransform){ (const uint8_t *)value + offsets[1] + transformOffset, transformType };
            pushed = YES;
        }
        WGExploreConfiguration((const uint8_t *)value + offsets[0], contentType, depth + 1);
        if (pushed) gTransformCount--;
        return;
    }
    const void *proto = WGSym("$s7SwiftUI19WidgetConfigurationMp");
    WGConformsToProtocol conformsTo = WGSym("swift_conformsToProtocol");
    WGGetAssociatedTypeWitness assoc = WGSym("swift_getAssociatedTypeWitness");
    WGProtocolLayout layout;
    if (!proto || !conformsTo || !assoc || !WGReadProtocolLayout(proto, &layout)) return;
    const void *const *wt = conformsTo(md, proto);
    if (!wt) return;
    const void *bodyType = assoc(0, wt, md, layout.reqBase, layout.firstAssocType).metadata;
    if (!bodyType || [WGTypeName(bodyType) isEqualToString:@"Swift.Never"]) return; // a basic configuration
    int getter = WGFirstRequirement(proto, 3);
    void *body = getter >= 0 ? WGAlloc(bodyType) : NULL;
    if (!body) return;
    ((WGWitnessGetter)wt[getter + 1])(body, md, wt, value);
    WGExploreConfiguration(body, bodyType, depth + 1);
}

// Calls a stored "() -> T" closure; T in fresh storage.
static void *WGCallThunk(const void *closure, const void *fnType, const void **resultTypeOut) {
    const void *const *pair = closure;
    const void *resultType = ((const void *const *)fnType)[2];
    *resultTypeOut = resultType;
    void *out = WGAlloc(resultType);
    if (!pair[0] || !out) return NULL;
    const WGVWT *vwt = WGValueWitnesses(resultType);
    BOOL opaqueExistential = WGKind(resultType) == WGKindExistential && (*(const uint32_t *)((const uint8_t *)resultType + 8) & 0x80000000);
    if (vwt->size > 32 || (vwt->flags & WG_VWT_NON_INLINE) || opaqueExistential) {
        ((WGThickIndirect)pair[0])(out, pair[1]);
    } else {
        WGFourWords r = ((WGThickDirect)pair[0])(pair[1]);
        memcpy(out, &r, MIN(vwt->size, sizeof r));
    }
    return out;
}

static void WGNoteBox(const void *base, const void *type, NSString *typeName) {
    BOOL timeline = [typeName hasPrefix:@"WidgetKit.TimelineEntryProvider<"];
    BOOL intent = [typeName hasPrefix:@"WidgetKit.IntentTimelineEntryProvider<"];
    // By the box type itself: its generic arguments are the app's types, named anything.
    BOOL appIntent = [typeName hasPrefix:@"WidgetKit.AppIntentTimelineEntryProvider<"];
    if ((timeline || intent || appIntent) && gBoxCount < 32) gBoxes[gBoxCount++] = (WGProviderBox){ base, type, intent || appIntent, appIntent };
}

// Finds provider boxes in what a configuration's provider() returned.
static void WGFindBoxes(const void *value, const void *md, int depth) {
    if (!value || !md || depth > 4) return; // as deep as 2.x looked (five levels)
    uintptr_t kind = WGKind(md);
    if (kind == WGKindExistential) {
        uint32_t flags = *(const uint32_t *)((const uint8_t *)md + 8);
        const void *dyn = NULL, *inner = NULL;
        if (!(flags & 0x80000000)) {
            const void *obj = *(const void *const *)value;
            if (obj) { dyn = *(const void *const *)obj; inner = value; }
        } else if ((dyn = ((const void *const *)value)[3])) {
            const WGVWT *vwt = WGValueWitnesses(dyn);
            inner = value;
            if (vwt->flags & WG_VWT_NON_INLINE) {
                size_t mask = vwt->flags & 0xFF;
                inner = *(const uint8_t *const *)value + ((16 + mask) & ~mask);
            }
        }
        if (dyn && inner) WGFindBoxes(inner, dyn, depth + 1);
        return;
    }
    if (WGIsClass(md)) {
        const void *obj = *(const void *const *)value;
        const void *dyn = obj ? *(const void *const *)obj : NULL;
        if (!dyn || !WGClassDescriptor(dyn)) return;
        WGNoteBox(obj, dyn, WGTypeName(dyn));
        WGFields f;
        if (!WGGetFields(dyn, &f)) return;
        for (uint32_t i = 0; i < f.count && f.count <= 32; i++) {
            const void *t = WGFieldType(&f, i);
            if (t) WGFindBoxes((const uint8_t *)obj + WGFieldOffset(&f, i), t, depth + 1);
        }
        return;
    }
    NSString *typeName = WGTypeName(md);
    WGNoteBox(value, md, typeName);
    if (kind != WGKindStruct) return;
    // The standard library's, Foundation's and SwiftUI's own values hold no boxes.
    if ([typeName hasPrefix:@"Swift."] || [typeName hasPrefix:@"Foundation."] || [typeName hasPrefix:@"CoreFoundation."] ||
        [typeName hasPrefix:@"SwiftUI."]) return;
    WGFields f;
    if (!WGGetFields(md, &f) || f.count > 32) return;
    for (uint32_t i = 0; i < f.count; i++) {
        const void *t = WGFieldType(&f, i);
        if (t) WGFindBoxes((const uint8_t *)value + WGFieldOffset(&f, i), t, depth + 1);
    }
}

// Each configuration's provider (its first field, "() -> EntryProviding") is called; its
// result holds the provider box.
static void WGFindProviders(void) {
    for (int i = 0; i < gConfigCount; i++) {
        WGFields f;
        if (!WGGetFields(gConfigs[i].type, &f) || f.count == 0) continue;
        const void *fnType = WGFieldType(&f, 0);
        if (!fnType || WGKind(fnType) != WGKindFunction) continue;
        const void *resultType = NULL;
        void *result = WGCallThunk((const uint8_t *)gConfigs[i].value + WGFieldOffset(&f, 0), fnType, &resultType);
        if (result) WGFindBoxes(result, resultType, 0);
    }
}

typedef struct { int32_t protocol, typeRef, witnessTablePattern; uint32_t flags; } WGConformanceRecord;

// The extension's WidgetBundle and Widget types, from its protocol conformance records.
static void WGScanConformances(const struct mach_header *mh) {
    unsigned long size = 0;
    const int32_t *records = (const int32_t *)getsectiondata((const struct mach_header_64 *)mh, "__TEXT", "__swift5_proto", &size);
    if (!records || !size) {
        WGLogImportant(@"no Swift conformance records in the extension");
        return;
    }
    const void *bundleProto = WGSym("$s7SwiftUI12WidgetBundleMp"), *widgetProto = WGSym("$s7SwiftUI6WidgetMp");
    WGConformsToProtocol conformsTo = WGSym("swift_conformsToProtocol");
    WGGetAssociatedTypeWitness assoc = WGSym("swift_getAssociatedTypeWitness");
    if (!bundleProto || !widgetProto || !conformsTo || !assoc) {
        WGLogImportant(@"SwiftUI's widget protocols were not found");
        return;
    }
    const uint8_t *bundles[8], *widgets[64];
    int nb = 0, nw = 0;
    for (size_t i = 0; i < size / sizeof(int32_t); i++) {
        const WGConformanceRecord *rec = WGRelDirect(&records[i]);
        const void *proto = rec ? WGRelIndirectable(&rec->protocol) : NULL;
        if (proto != bundleProto && proto != widgetProto) continue;
        uint32_t refKind = (rec->flags >> 3) & 7;
        const uint8_t *type = refKind == 0 ? WGRelDirect(&rec->typeRef) : NULL;
        if (refKind == 1) {
            const void *const *slot = WGRelDirect(&rec->typeRef);
            type = slot ? *slot : NULL;
        }
        if (!type || (*(const uint32_t *)type & 0x80)) continue; // generic types are not instantiable here
        if (proto == bundleProto && nb < 8) bundles[nb++] = type;
        if (proto == widgetProto && nw < 64) widgets[nw++] = type;
    }
    for (int w = 0; w < nw; w++) {
        WGMetadataAccessor accessor = (WGMetadataAccessor)WGRelDirect((const int32_t *)(widgets[w] + 12));
        const void *md = accessor ? accessor(0).metadata : NULL;
        const void *const *wt = md ? conformsTo(md, widgetProto) : NULL;
        WGProtocolLayout layout;
        int initIndex = WGFirstRequirement(widgetProto, 2), getterIndex = WGFirstRequirement(widgetProto, 3);
        if (!wt || !WGReadProtocolLayout(widgetProto, &layout) || initIndex < 0 || getterIndex < 0) continue;
        const void *bodyType = assoc(0, wt, md, layout.reqBase, layout.firstAssocType).metadata;
        void *widget = WGAlloc(md), *body = bodyType ? WGAlloc(bodyType) : NULL;
        if (!widget || !body) continue;
        ((WGWitnessInit)wt[initIndex + 1])(widget, md, wt, md);
        ((WGWitnessGetter)wt[getterIndex + 1])(body, md, wt, widget);
        WGExploreConfiguration(body, bodyType, 0);
    }
    // Then the @main WidgetBundle's init() and body, where apps set up their services
    // (Firebase, databases…), before any provider runs. (Widgets first: reading a bundle's body
    // first crashed with some apps in 0.2.)
    for (int b = 0; b < nb; b++) {
        WGMetadataAccessor accessor = (WGMetadataAccessor)WGRelDirect((const int32_t *)(bundles[b] + 12));
        const void *md = accessor ? accessor(0).metadata : NULL;
        const void *const *wt = md ? conformsTo(md, bundleProto) : NULL;
        WGProtocolLayout layout;
        int initIndex = WGFirstRequirement(bundleProto, 2), getterIndex = WGFirstRequirement(bundleProto, 3);
        if (!wt || !WGReadProtocolLayout(bundleProto, &layout) || initIndex < 0 || getterIndex < 0) continue;
        const void *bodyType = assoc(0, wt, md, layout.reqBase, layout.firstAssocType).metadata;
        void *bundle = WGAlloc(md), *body = bodyType ? WGAlloc(bodyType) : NULL;
        if (!bundle || !body) continue;
        ((WGWitnessInit)wt[initIndex + 1])(bundle, md, wt, md);
        ((WGWitnessGetter)wt[getterIndex + 1])(body, md, wt, bundle);
    }
    WGFindProviders();
}

// Reads the widgets: one entry per provider box, named from the descriptors.
static NSArray<NSDictionary *> *WGReadWidgets(const struct mach_header *mh) {
    gConfigCount = gBoxCount = gTransformCount = 0;
    gDescLeaves = [NSMutableArray array];
    // Applying the descriptor transforms runs the app's code: if that ever crashed a host,
    // the widgets are listed without names from then on.
    NSString *descMarker = [@"descriptor-" stringByAppendingString:gExt.extensionID];
    gDescDisabled = WGMarkerTripped(descMarker);
    if (!gDescDisabled) WGMarkerBegin(descMarker);
    WGScanConformances(mh);
    WGMarkerEnd(descMarker);

    NSBundle *bundle = [NSBundle bundleWithPath:gExt.extensionPath];
    NSMutableDictionary *infoByKind = [NSMutableDictionary dictionary];
    NSMutableArray *infoList = [NSMutableArray array];
    for (NSArray *leaves in gDescLeaves) {
        NSDictionary *info = WGDescriptorInfo(leaves, bundle);
        [infoList addObject:info];
        if (info[@"kind"]) infoByKind[info[@"kind"]] = info;
    }
    NSMutableArray *list = [NSMutableArray array];
    gBoxByKind = [NSMutableDictionary dictionary];
    for (int b = 0; b < gBoxCount; b++) {
        WGProviderBox *box = malloc(sizeof *box);
        *box = gBoxes[b];
        size_t configOffset = 0;
        NSString *kind = nil;
        if (WGStructField(box->type, "config", &configOffset, NULL)) kind = WGSwiftString((const uint8_t *)box->base + configOffset);
        if (!kind.length) kind = [NSString stringWithFormat:@"widget%d", b];
        if (gBoxByKind[kind]) {
            free(box);
            continue;
        }
        gBoxByKind[kind] = [NSValue valueWithPointer:box];
        NSDictionary *info = infoByKind[kind] ?: ((int)infoList.count == gBoxCount ? infoList[b] : nil);
        NSMutableDictionary *w = [NSMutableDictionary dictionaryWithObject:kind forKey:@"kind"];
        for (NSString *key in @[ @"name", @"description", @"families" ]) if (info[key]) w[key] = info[key];
        w[@"configurable"] = @(box->isIntent);
        w[@"editable"] = @(box->isIntent); // Edit Widget: SiriKit intents and AppIntents
        [list addObject:w];
        WGLog(@"widget %@ \"%@\" %@%@", kind, info[@"name"] ?: @"", info[@"families"] ? [info[@"families"] componentsJoinedByString:@"/"] : @"(sizes unknown)",
              box->isAppIntent ? @", AppIntent configuration" : box->isIntent ? @", intent configuration" : @"");
    }
    return list;
}

#pragma mark - Configuration of configurable widgets

// Both extensions carry their own copy of the generated intent classes (same names). The
// widget's code expects its own image's classes, so objects from the Intents extension are
// rebuilt as instances of the first-registered class of that name.
static id WGCanonical(id value, int depth) {
    if (!value || depth > 4) return value;
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id v in value) [out addObject:WGCanonical(v, depth + 1) ?: v];
        return out;
    }
    Class actual = [value class], canonical = NSClassFromString(NSStringFromClass(actual));
    if (!canonical || canonical == actual) return value;
    id copy = nil;
    if ([value respondsToSelector:@selector(identifier)] && [canonical instancesRespondToSelector:@selector(initWithIdentifier:displayString:)]) {
        copy = ((id (*)(id, SEL, id, id))objc_msgSend)([canonical alloc], @selector(initWithIdentifier:displayString:),
                                                      [value valueForKey:@"identifier"], [value valueForKey:@"displayString"]);
    } else {
        copy = [[canonical alloc] init];
    }
    for (Class c = actual; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        if ([NSStringFromClass(c) hasPrefix:@"IN"]) break; // the Intents framework's own classes
        unsigned int count = 0;
        objc_property_t *props = class_copyPropertyList(c, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = @(property_getName(props[i]));
            @try {
                [copy setValue:WGCanonical([value valueForKey:name], depth + 1) forKey:name];
            } @catch (NSException *e) {
            }
        }
        free(props);
    }
    return copy ?: value;
}

static NSString *WGIntentsExtensionPath(NSDictionary **infoOut, NSString *intentName) {
    NSString *plugins = [gExt.appPath stringByAppendingPathComponent:@"PlugIns"];
    NSString *found = nil;
    for (NSString *item in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:plugins error:nil]) {
        NSString *path = [plugins stringByAppendingPathComponent:item];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
        NSDictionary *ext = info[@"NSExtension"];
        if (![ext isKindOfClass:[NSDictionary class]] || ![ext[@"NSExtensionPointIdentifier"] isEqual:@"com.apple.intents-service"]) continue;
        // Without an intent name (loading it ahead), the first Intents extension will do.
        BOOL matches = !intentName.length;
        NSDictionary *attributes = [ext[@"NSExtensionAttributes"] isKindOfClass:[NSDictionary class]] ? ext[@"NSExtensionAttributes"] : nil;
        NSArray *supported = [attributes[@"IntentsSupported"] isKindOfClass:[NSArray class]] && !matches ? attributes[@"IntentsSupported"] : @[];
        for (NSString *name in supported) {
            if ([name isKindOfClass:[NSString class]] && ([name hasSuffix:intentName] || [intentName hasSuffix:name])) matches = YES;
        }
        if (matches || !found) {
            found = path;
            if (infoOut) *infoOut = info;
        }
        if (matches) break;
    }
    return found;
}

static const struct mach_header *WGLoadIntentsExtension(NSString *path, NSDictionary *info) {
    NSString *exe = info[@"CFBundleExecutable"] ?: path.lastPathComponent.stringByDeletingPathExtension;
    NSString *bundleID = info[@"CFBundleIdentifier"] ?: path.lastPathComponent;
    NSString *copy = nil;
    const struct mach_header *mh = WGLoadBundleCopy(path, exe, WGWorkPath(bundleID), &copy);
    if (mh) {
        if ([NSThread isMainThread]) WGAddBundleRedirect(mh, copy);
        else dispatch_async(dispatch_get_main_queue(), ^{ WGAddBundleRedirect(mh, copy); });
    }
    return mh;
}

// What iOS does when such a widget is added: asks the app's Intents extension for the intent's
// default values — handlerForIntent: → default<Parameter>For<Intent>:.
static void WGApplyIntentDefaults(id intent) {
    NSString *shortName = [NSStringFromClass([intent class]) componentsSeparatedByString:@"."].lastObject;
    NSDictionary *info = nil;
    NSString *path = WGIntentsExtensionPath(&info, shortName);
    if (!path || !WGLoadIntentsExtension(path, info)) return;
    NSString *principal = [info[@"NSExtension"][@"NSExtensionPrincipalClass"] stringByReplacingOccurrencesOfString:@"$(PRODUCT_MODULE_NAME)." withString:@""];
    Class principalClass = principal ? NSClassFromString(principal) : Nil;
    if (!principalClass) return;
    id object = [[principalClass alloc] init];
    id handler = object;
    if ([object respondsToSelector:@selector(handlerForIntent:)]) {
        handler = ((id (*)(id, SEL, id))objc_msgSend)(object, @selector(handlerForIntent:), intent) ?: object;
    }
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
            @try {
                id value = WGCanonical(((id (*)(id, SEL, id))objc_msgSend)(handler, method_getName(methods[i]), intent), 0);
                if (value) [intent setValue:value forKey:param];
                WGLog(@"intent default .%@ = %@", param, value ?: @"nil");
            } @catch (NSException *e) {
                WGLog(@"intent default %@: %@", sel, e.reason);
            }
        }
        free(methods);
    }
}

static NSString *WGIntentCachePath(NSString *kind) {
    NSString *name = [[NSString stringWithFormat:@"%@|%@", gExt.extensionID, kind] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [[WGExtensionWorkDir() stringByAppendingPathComponent:@"intents"] stringByAppendingPathComponent:[name stringByAppendingString:@".plist"]];
}

static NSMutableDictionary *gIntents;       // kind, or kind|configuration → INIntent
static NSMutableArray *gRetiredIntents;     // replaced ones, kept alive (a render may still use one)
static NSString *WGConfigFilePath(NSString *kind, NSString *config);

// A configured widget's own intent (Edit Widget), as saved; nil when it has none.
static id WGSavedIntent(NSString *kind, NSString *config, Class intentClass) {
    if (!config.length) return nil;
    NSString *key = [NSString stringWithFormat:@"%@|%@", kind, config];
    if (gIntents[key]) return gIntents[key];
    NSData *data = [NSData dataWithContentsOfFile:WGConfigFilePath(kind, config)];
    if (!data) return nil;
    NSKeyedUnarchiver *u = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:nil];
    u.requiresSecureCoding = NO;
    id intent = nil;
    @try { intent = [u decodeObjectForKey:NSKeyedArchiveRootObjectKey]; } @catch (NSException *e) { intent = nil; }
    [u finishDecoding];
    if (![intent isKindOfClass:intentClass]) return nil;
    return gIntents[key] = intent;
}

// A SiriKit-configured widget's intent (an INIntent subclass): the one its configuration saved
// (Edit Widget), else the kind's, made once with its defaults.
static id WGIntentForKind(NSString *kind, const void *proto, const void *const *wt, const void *providerType);
static id WGIntentForConfig(NSString *kind, NSString *config, const void *proto, const void *const *wt, const void *providerType) {
    id base = WGIntentForKind(kind, proto, wt, providerType);
    return (base ? WGSavedIntent(kind, config, [base class]) : nil) ?: base;
}

static id WGIntentForKind(NSString *kind, const void *proto, const void *const *wt, const void *providerType) {
    if (!gIntents) gIntents = [NSMutableDictionary dictionary];
    NSMutableDictionary *intents = gIntents;
    id intent = intents[kind];
    if (intent) return intent;
    WGGetAssociatedTypeWitness assoc = WGSym("swift_getAssociatedTypeWitness");
    WGProtocolLayout layout;
    int assocs[4];
    int n = WGRequirementsOfKind(proto, 7, assocs, 4);
    if (!assoc || !WGReadProtocolLayout(proto, &layout)) return nil;
    const void *intentType = NULL;
    for (int a = 0; a < n; a++) {
        const void *t = assoc(0, wt, providerType, layout.reqBase, (const uint8_t *)layout.reqBase + 8 + assocs[a] * 8).metadata;
        if (t && WGIsClass(t)) intentType = t;
    }
    if (!intentType) return nil;
    // The defaults the Intents extension gave last time (until the build changes): then that
    // extension need not be loaded at all.
    NSString *cachePath = WGIntentCachePath(kind);
    NSDictionary *cached = [NSDictionary dictionaryWithContentsOfFile:cachePath];
    if ([cached[@"stamp"] isEqual:gExt.buildStamp] && [cached[@"intent"] isKindOfClass:[NSData class]]) {
        NSKeyedUnarchiver *u = [[NSKeyedUnarchiver alloc] initForReadingFromData:cached[@"intent"] error:nil];
        u.requiresSecureCoding = NO;
        @try { intent = [u decodeObjectForKey:NSKeyedArchiveRootObjectKey]; } @catch (NSException *e) { intent = nil; }
        [u finishDecoding];
        if ([intent isKindOfClass:(__bridge Class)intentType]) return intents[kind] = intent;
    }
    intent = [[(__bridge Class)intentType alloc] init];
    if (!intent) return nil;
    NSString *marker = [@"intent-defaults-" stringByAppendingString:gExt.extensionID];
    if (!WGMarkerTripped(marker)) {
        WGMarkerBegin(marker);
        WGApplyIntentDefaults(intent);
        WGMarkerEnd(marker);
        NSData *data = nil;
        @try { data = [NSKeyedArchiver archivedDataWithRootObject:intent requiringSecureCoding:NO error:nil]; } @catch (NSException *e) {}
        if (data) {
            [[NSFileManager defaultManager] createDirectoryAtPath:cachePath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            [@{ @"stamp" : gExt.buildStamp, @"intent" : data } writeToFile:cachePath atomically:NO];
        }
    } else {
        WGLog(@"Intents extension defaults: not used (crashed before)");
    }
    return intents[kind] = intent;
}

static BOOL WGHasIntentCache(void) {
    NSString *dir = WGIntentCachePath(@"x").stringByDeletingLastPathComponent;
    return [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil].count > 0;
}

#pragma mark - Edit Widget (SiriKit intents)

static NSString *WGConfigFilePath(NSString *kind, NSString *config) {
    NSString *name = [[NSString stringWithFormat:@"%@|%@|%@", gExt.extensionID, kind, config] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [[WGExtensionWorkDir() stringByAppendingPathComponent:@"configurations"] stringByAppendingPathComponent:[name stringByAppendingString:@".intent"]];
}

static NSString *WGIntentShortName(id intent) {
    NSString *name = [NSStringFromClass([intent class]) componentsSeparatedByString:@"."].lastObject;
    return [name hasSuffix:@"Intent"] && name.length > 6 ? [name substringToIndex:name.length - 6] : name;
}

// The intent's definition (from the .intentdefinition the app carries) and its localized
// strings: {parameters: {name: definition}, enums: {name: definition}, strings: {id: text}}.
static NSDictionary *WGIntentDefinition(id intent) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *shortName = WGIntentShortName(intent);
    if (cache[shortName]) return cache[shortName];
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *root in @[ gExt.extensionPath ?: @"", gExt.appPath ?: @"" ]) {
        if (!root.length) continue;
        NSDirectoryEnumerator *e = [[NSFileManager defaultManager] enumeratorAtPath:root];
        for (NSString *f in e) {
            if (e.level > 3) [e skipDescendants];
            if ([f.pathExtension isEqualToString:@"intentdefinition"]) [files addObject:[root stringByAppendingPathComponent:f]];
        }
    }
    NSDictionary *result = @{};
    for (NSString *file in files) {
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:file];
        NSArray *intents = [plist[@"INIntents"] isKindOfClass:[NSArray class]] ? plist[@"INIntents"] : nil;
        NSDictionary *found = nil;
        for (NSDictionary *i in intents) {
            if (![i isKindOfClass:[NSDictionary class]]) continue;
            NSString *n = i[@"INIntentName"];
            if ([n isEqual:shortName] || [[n stringByAppendingString:@"Intent"] isEqual:shortName]) found = i;
        }
        if (!found) continue;
        NSMutableDictionary *params = [NSMutableDictionary dictionary], *enums = [NSMutableDictionary dictionary];
        for (NSDictionary *p in found[@"INIntentParameters"]) {
            if ([p isKindOfClass:[NSDictionary class]] && [p[@"INIntentParameterName"] isKindOfClass:[NSString class]]) params[p[@"INIntentParameterName"]] = p;
        }
        for (NSDictionary *en in plist[@"INEnums"]) {
            if ([en isKindOfClass:[NSDictionary class]] && [en[@"INEnumName"] isKindOfClass:[NSString class]]) enums[en[@"INEnumName"]] = en;
        }
        // The strings: <language>.lproj/<definition>.strings next to it, in the user's language.
        NSString *dir = file.stringByDeletingLastPathComponent, *table = file.lastPathComponent.stringByDeletingPathExtension;
        NSDictionary *strings = nil;
        NSMutableArray *languages = [NSMutableArray array];
        for (NSString *l in NSLocale.preferredLanguages) {
            [languages addObject:l];
            [languages addObject:[l componentsSeparatedByString:@"-"].firstObject];
        }
        [languages addObjectsFromArray:@[ @"Base", @"en" ]];
        for (NSString *l in languages) {
            strings = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingFormat:@"/%@.lproj/%@.strings", l, table]];
            if (strings.count) break;
        }
        result = @{ @"parameters" : params, @"enums" : enums, @"strings" : strings ?: @{} };
        WGLog(@"Edit Widget: %@ defined in %@ (%lu parameter(s), %lu string(s))", shortName, [file substringFromIndex:MIN(file.length, gExt.appPath.length)],
              (unsigned long)params.count, (unsigned long)strings.count);
        break;
    }
    return cache[shortName] = result;
}

static NSString *WGDefinitionText(NSDictionary *def, NSDictionary *item, NSString *key) {
    NSString *idKey = [key stringByAppendingString:@"ID"];
    NSString *localized = [item[idKey] isKindOfClass:[NSString class]] ? def[@"strings"][item[idKey]] : nil;
    return localized ?: ([item[key] isKindOfClass:[NSString class]] ? item[key] : nil);
}

// The enum's values, as {title, value} in order.
static NSArray *WGEnumValues(NSDictionary *def, NSDictionary *param) {
    NSDictionary *en = [param[@"INIntentParameterEnumType"] isKindOfClass:[NSString class]] ? def[@"enums"][param[@"INIntentParameterEnumType"]] : nil;
    NSMutableArray *values = [NSMutableArray array];
    NSInteger position = 0;
    for (NSDictionary *v in en[@"INEnumValues"]) {
        if (![v isKindOfClass:[NSDictionary class]]) continue;
        NSInteger value = [v[@"INEnumValueIndex"] respondsToSelector:@selector(integerValue)] ? [v[@"INEnumValueIndex"] integerValue] : position;
        position++;
        NSString *title = WGDefinitionText(def, v, @"INEnumValueDisplayName") ?: v[@"INEnumValueName"];
        if (value == 0 && [v[@"INEnumValueName"] isEqual:@"unknown"]) continue;
        [values addObject:@{ @"title" : title ?: [NSString stringWithFormat:@"%ld", (long)value], @"value" : @(value) }];
    }
    return values;
}

// The parameters of an intent as the sheet shows them.
static NSArray *WGIntentParameters(id intent) {
    NSDictionary *def = WGIntentDefinition(intent);
    NSMutableArray *list = [NSMutableArray array];
    for (Class c = [intent class]; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        if ([NSStringFromClass(c) hasPrefix:@"IN"]) break;
        unsigned int count = 0;
        objc_property_t *props = class_copyPropertyList(c, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = @(property_getName(props[i]));
            NSString *attrs = @(property_getAttributes(props[i]));
            NSDictionary *pd = def[@"parameters"][name];
            id value = nil;
            @try { value = [intent valueForKey:name]; } @catch (NSException *e) {}
            NSString *kind = @"other", *shown = nil;
            NSArray *values = nil;
            if ([attrs hasPrefix:@"Tq"] || [attrs hasPrefix:@"Tl"] || [attrs hasPrefix:@"Ti"]) {
                values = pd ? WGEnumValues(def, pd) : nil;
                kind = values.count ? @"enum" : @"other";
                for (NSDictionary *v in values) if ([v[@"value"] isEqual:value]) shown = v[@"title"];
            } else if ([attrs hasPrefix:@"T@\"NSNumber\""] && [pd[@"INIntentParameterType"] isEqual:@"Boolean"]) {
                kind = @"bool";
                shown = [value boolValue] ? @"1" : @"0";
            } else if ([attrs hasPrefix:@"T@\"NSString\""]) {
                kind = @"string";
                shown = value;
            } else if ([attrs hasPrefix:@"T@\"NSArray\""]) {
                kind = @"objects";
                NSMutableArray *names = [NSMutableArray array];
                for (id o in value) [names addObject:[o respondsToSelector:@selector(displayString)] ? [o valueForKey:@"displayString"] : [o description]];
                shown = [names componentsJoinedByString:@", "];
            } else if ([attrs hasPrefix:@"T@\""]) {
                kind = @"object";
                shown = [value respondsToSelector:@selector(displayString)] ? [value valueForKey:@"displayString"] : [value description];
            }
            NSMutableDictionary *p = [@{ @"name" : name, @"kind" : kind,
                                         @"title" : WGDefinitionText(def, pd, @"INIntentParameterDisplayName") ?: name } mutableCopy];
            if ([shown isKindOfClass:[NSString class]]) p[@"value"] = shown;
            if (values) p[@"values"] = [values valueForKey:@"title"];
            [list addObject:p];
        }
        free(props);
    }
    return list;
}

// The intent being edited for this configuration: its own, or a copy of the kind's.
static id WGEditableIntent(NSString *kind, NSString *config) {
    id base = gIntents[kind];
    if (!base) return nil;
    id own = WGSavedIntent(kind, config, [base class]);
    if (own) return own;
    NSData *data = nil;
    @try { data = [NSKeyedArchiver archivedDataWithRootObject:base requiringSecureCoding:NO error:nil]; } @catch (NSException *e) {}
    NSKeyedUnarchiver *u = data ? [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:nil] : nil;
    u.requiresSecureCoding = NO;
    id copy = nil;
    @try { copy = [u decodeObjectForKey:NSKeyedArchiveRootObjectKey]; } @catch (NSException *e) {}
    [u finishDecoding];
    return [copy isKindOfClass:[base class]] ? copy : nil;
}

// The Intents extension's handler for the intent (it gives the choices), or nil.
static id WGIntentHandler(id intent) {
    NSDictionary *info = nil;
    NSString *path = WGIntentsExtensionPath(&info, WGIntentShortName(intent));
    if (!path || !WGLoadIntentsExtension(path, info)) return nil;
    NSString *principal = [info[@"NSExtension"][@"NSExtensionPrincipalClass"] stringByReplacingOccurrencesOfString:@"$(PRODUCT_MODULE_NAME)." withString:@""];
    Class principalClass = principal ? NSClassFromString(principal) : Nil;
    if (!principalClass) return nil;
    id object = [[principalClass alloc] init];
    if ([object respondsToSelector:@selector(handlerForIntent:)]) return ((id (*)(id, SEL, id))objc_msgSend)(object, @selector(handlerForIntent:), intent) ?: object;
    return object;
}

static NSMutableArray *gLastOptions; // the objects behind the last options listed

static BOOL WGIsAppIntentKind(NSString *kind);
static NSArray *WGAppIntentParameters(NSString *kind, NSString *config, NSString **error);
static NSString *WGAppIntentSetParameter(NSString *kind, NSString *config, NSString *name, NSDictionary *value);

@implementation WGRuntime (EditWidget)

+ (void)parametersForKind:(NSString *)kind config:(NSString *)config reply:(void (^)(NSDictionary *))reply {
    if (WGIsAppIntentKind(kind)) {
        NSString *error = nil;
        NSArray *params = WGAppIntentParameters(kind, config, &error);
        reply(params ? @{ @"params" : params } : @{ @"error" : error ?: @"This widget has nothing to edit." });
        return;
    }
    id intent = WGEditableIntent(kind, config);
    if (!intent) {
        reply(@{ @"error" : @"This widget has nothing to edit (or has not been drawn yet)." });
        return;
    }
    NSArray *params = WGIntentParameters(intent);
    WGLog(@"Edit Widget: %@ (%@): %@", kind, config, [params valueForKey:@"kind"]);
    reply(@{ @"params" : params, @"title" : WGIntentShortName(intent) });
}

+ (void)optionsForKind:(NSString *)kind config:(NSString *)config parameter:(NSString *)name reply:(void (^)(NSDictionary *))reply {
    id intent = WGEditableIntent(kind, config);
    if (!intent || !name.length) {
        reply(@{ @"error" : @"Nothing to choose from." });
        return;
    }
    NSString *marker = [@"intent-options-" stringByAppendingString:gExt.extensionID];
    if (WGMarkerTripped(marker)) {
        reply(@{ @"error" : @"The app's choices could not be read (it crashed before)." });
        return;
    }
    WGMarkerBegin(marker);
    id handler = WGIntentHandler(intent);
    NSString *cap = [[[name substringToIndex:1] uppercaseString] stringByAppendingString:[name substringFromIndex:1]];
    SEL chosen = NULL;
    NSUInteger arguments = 0;
    BOOL collection = NO;
    for (Class c = [handler class]; c && c != [NSObject class] && !chosen; c = class_getSuperclass(c)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(c, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *sel = NSStringFromSelector(method_getName(methods[i]));
            if (![sel hasPrefix:[NSString stringWithFormat:@"provide%@Options", cap]] || ![sel hasSuffix:@"withCompletion:"]) continue;
            NSUInteger n = [sel componentsSeparatedByString:@":"].count - 1;
            if (n != 2 && n != 3) continue;
            BOOL isCollection = [sel containsString:@"OptionsCollection"];
            if (!chosen || (isCollection && !collection)) {
                chosen = method_getName(methods[i]);
                arguments = n;
                collection = isCollection;
            }
        }
        free(methods);
    }
    if (!chosen) {
        WGMarkerEnd(marker);
        WGLog(@"Edit Widget: no choices for .%@ in %@", name, handler ? NSStringFromClass([handler class]) : @"(no Intents extension)");
        reply(@{ @"error" : @"The app gives no choices for this." });
        return;
    }
    __block BOOL answered = NO;
    void (^done)(id, NSError *) = ^(id result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (answered) return;
            answered = YES;
            WGMarkerEnd(marker);
            NSArray *items = nil;
            if ([result isKindOfClass:[NSArray class]]) items = result;
            else if ([result respondsToSelector:NSSelectorFromString(@"allItems")]) items = [result valueForKey:@"allItems"];
            gLastOptions = [NSMutableArray array];
            NSMutableArray *options = [NSMutableArray array];
            for (id o in items) {
                [gLastOptions addObject:o];
                NSMutableDictionary *d = [NSMutableDictionary dictionary];
                d[@"title"] = [o respondsToSelector:@selector(displayString)] ? ([o valueForKey:@"displayString"] ?: @"?") : [o description];
                if ([o respondsToSelector:NSSelectorFromString(@"subtitleString")] && [o valueForKey:@"subtitleString"]) d[@"subtitle"] = [o valueForKey:@"subtitleString"];
                [options addObject:d];
            }
            WGLog(@"Edit Widget: %lu choice(s) for .%@ (%@)%@", (unsigned long)options.count, name, NSStringFromSelector(chosen),
                  error ? [@" error " stringByAppendingString:error.localizedDescription] : @"");
            reply(options.count || !error ? @{ @"options" : options } : @{ @"error" : error.localizedDescription ?: @"No choices." });
        });
    };
    @try {
        if (arguments == 2) ((void (*)(id, SEL, id, id))objc_msgSend)(handler, chosen, intent, done);
        else ((void (*)(id, SEL, id, id, id))objc_msgSend)(handler, chosen, intent, nil, done); // no search term
    } @catch (NSException *e) {
        done(nil, [NSError errorWithDomain:@"WG" code:1 userInfo:@{ NSLocalizedDescriptionKey : e.reason ?: @"failed" }]);
    }
}

+ (NSString *)setParameter:(NSString *)name kind:(NSString *)kind config:(NSString *)config value:(NSDictionary *)value {
    if (WGIsAppIntentKind(kind)) return WGAppIntentSetParameter(kind, config, name, value);
    id intent = WGEditableIntent(kind, config);
    if (!intent || !config.length) return @"Nothing to edit.";
    NSDictionary *param = nil;
    for (NSDictionary *p in WGIntentParameters(intent)) if ([p[@"name"] isEqual:name]) param = p;
    if (!param) return @"No such setting.";
    NSString *kindOf = param[@"kind"];
    id newValue = nil;
    if ([kindOf isEqual:@"bool"]) newValue = @([value[@"bool"] boolValue]);
    else if ([kindOf isEqual:@"string"]) newValue = [value[@"string"] isKindOfClass:[NSString class]] ? value[@"string"] : nil;
    else if ([kindOf isEqual:@"enum"]) {
        NSArray *values = WGEnumValues(WGIntentDefinition(intent), WGIntentDefinition(intent)[@"parameters"][name]);
        NSUInteger i = [value[@"index"] unsignedIntegerValue];
        if (i >= values.count) return @"No such choice.";
        newValue = values[i][@"value"];
    } else if ([kindOf isEqual:@"object"]) {
        NSUInteger i = [value[@"index"] unsignedIntegerValue];
        if (i >= gLastOptions.count) return @"No such choice.";
        newValue = WGCanonical(gLastOptions[i], 0);
    } else if ([kindOf isEqual:@"objects"]) {
        NSMutableArray *chosen = [NSMutableArray array];
        for (NSNumber *n in value[@"indexes"]) {
            if (n.unsignedIntegerValue < gLastOptions.count) [chosen addObject:WGCanonical(gLastOptions[n.unsignedIntegerValue], 0)];
        }
        newValue = chosen;
    } else {
        return @"This setting cannot be changed here.";
    }
    @try {
        [intent setValue:newValue forKey:name];
    } @catch (NSException *e) {
        return e.reason ?: @"Could not be set.";
    }
    NSData *data = nil;
    @try { data = [NSKeyedArchiver archivedDataWithRootObject:intent requiringSecureCoding:NO error:nil]; } @catch (NSException *e) {}
    NSString *path = WGConfigFilePath(kind, config);
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    if (!data || ![data writeToFile:path atomically:YES]) return @"Could not be saved.";
    NSString *key = [NSString stringWithFormat:@"%@|%@", kind, config];
    if (!gRetiredIntents) gRetiredIntents = [NSMutableArray array];
    if (gIntents[key] && gIntents[key] != intent) [gRetiredIntents addObject:gIntents[key]];
    gIntents[key] = intent;
    WGLog(@"Edit Widget: %@ (%@) .%@ = %@", kind, config, name, newValue);
    return nil;
}

@end

// An AppIntent configuration made with its init(), so its @Parameter defaults apply.
static NSMutableDictionary<NSString *, NSValue *> *gAppIntentTypes;   // kind → the configuration intent's type (and its AppIntent witness table)
static NSMutableDictionary<NSString *, NSValue *> *gAppIntentWitnesses;
static NSMutableDictionary<NSString *, NSValue *> *gAppIntentsMade;   // kind, or kind|configuration → the value
static void WGApplyAppIntentConfiguration(NSString *kind, NSString *config, void *value, const void *type);

static void *WGAppIntentForKind(NSString *kind, const void *proto, const void *const *wt, const void *providerType) {
    if (!gAppIntentsMade) gAppIntentsMade = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSValue *> *made = gAppIntentsMade;
    if (made[kind]) return made[kind].pointerValue;
    WGGetAssociatedTypeWitness assoc = WGSym("swift_getAssociatedTypeWitness");
    WGConformsToProtocol conformsTo = WGSym("swift_conformsToProtocol");
    const void *appIntentProto = WGSym("$s10AppIntents0A6IntentMp");
    WGWitnessInit initThunk = WGSym("$s10AppIntents0A6IntentPxycfCTj");
    WGProtocolLayout layout;
    if (!assoc || !conformsTo || !appIntentProto || !initThunk || !WGReadProtocolLayout(proto, &layout)) return NULL;
    int assocs[4];
    int n = WGRequirementsOfKind(proto, 7, assocs, 4);
    for (int a = 0; a < n; a++) {
        const void *t = assoc(0, wt, providerType, layout.reqBase, (const uint8_t *)layout.reqBase + 8 + assocs[a] * 8).metadata;
        const void *w = t ? conformsTo(t, appIntentProto) : NULL;
        if (!w) continue;
        void *value = WGAlloc(t);
        if (!value) return NULL;
        initThunk(value, t, w, t);
        made[kind] = [NSValue valueWithPointer:value];
        if (!gAppIntentTypes) gAppIntentTypes = [NSMutableDictionary dictionary], gAppIntentWitnesses = [NSMutableDictionary dictionary];
        gAppIntentTypes[kind] = [NSValue valueWithPointer:t];
        gAppIntentWitnesses[kind] = [NSValue valueWithPointer:w];
        return value;
    }
    return NULL;
}

// The configuration of one widget (Edit Widget): a fresh intent with the values it saved.
static void *WGAppIntentForConfig(NSString *kind, NSString *config, const void *proto, const void *const *wt, const void *providerType) {
    void *base = WGAppIntentForKind(kind, proto, wt, providerType);
    if (!base || !config.length) return base;
    NSString *key = [NSString stringWithFormat:@"%@|%@", kind, config];
    if (gAppIntentsMade[key]) return gAppIntentsMade[key].pointerValue;
    const void *t = gAppIntentTypes[kind].pointerValue, *w = gAppIntentWitnesses[kind].pointerValue;
    WGWitnessInit initThunk = WGSym("$s10AppIntents0A6IntentPxycfCTj");
    void *value = t && w && initThunk ? WGAlloc(t) : NULL;
    if (!value) return base;
    initThunk(value, t, w, t);
    WGApplyAppIntentConfiguration(kind, config, value, t);
    gAppIntentsMade[key] = [NSValue valueWithPointer:value]; // kept for good: a render may hold it
    return value;
}

#pragma mark - Edit Widget (AppIntents)

// A WidgetConfigurationIntent keeps each @Parameter in a stored property "_name" holding an
// AppIntents.IntentParameter<Value> (a final class); its wrappedValue getter and setter are
// called directly. Values that can be made here: Bool, Int, Double, String, enums without
// payloads (AppEnum), and optionals of those. Entities (AppEntity) are listed, not editable.

typedef void (*WGParameterGet)(void *out SWIFT_INDIRECT, void *parameter SWIFT_CONTEXT) SWIFTCALL;
typedef void (*WGParameterSet)(void *value, void *parameter SWIFT_CONTEXT) SWIFTCALL;
typedef struct { uint64_t w0, w1; } WGSwiftStringValue;
typedef WGSwiftStringValue (*WGBridgeString)(id string) SWIFTCALL;
typedef void (*WGInjectEnumTag)(void *value, unsigned tag, const void *type) SWIFTCALL;

static BOOL WGIsAppIntentKind(NSString *kind) {
    return gAppIntentTypes[kind] != nil;
}

static NSString *WGAppIntentConfigPath(NSString *kind, NSString *config) {
    return [WGConfigFilePath(kind, config) stringByAppendingString:@".json"];
}

// The generic argument of an IntentParameter<Value> class metadata.
static const void *WGParameterValueType(const void *parameterClass) {
    const uint8_t *desc = WGClassDescriptor(parameterClass);
    if (!desc) return NULL;
    uint32_t positive = *(const uint32_t *)(desc + 28), immediate = *(const uint32_t *)(desc + 32);
    if (positive <= immediate || positive > 512) return NULL;
    return ((const void *const *)parameterClass)[positive - immediate];
}

// What a value type is, for the sheet: bool, int, double, string, enum (cases), entity, other.
static NSString *WGValueKind(const void *md, BOOL *optional, const void **inner, NSArray<NSString *> **cases) {
    *optional = NO;
    *inner = md;
    *cases = nil;
    if (WGKind(md) == WGKindOptional) {
        *optional = YES;
        md = ((const void *const *)md)[2];
        *inner = md;
    }
    NSString *name = WGTypeName(md);
    if ([name isEqualToString:@"Swift.Bool"]) return @"bool";
    if ([name isEqualToString:@"Swift.Int"]) return @"int";
    if ([name isEqualToString:@"Swift.Double"]) return @"double";
    if ([name isEqualToString:@"Swift.String"]) return @"string";
    if (WGKind(md) == WGKindEnum) {
        const uint8_t *desc = ((const uint8_t *const *)md)[1];
        const uint8_t *fd = WGRelDirect((const int32_t *)(desc + 16));
        uint32_t payloadCases = *(const uint32_t *)(desc + 20) & 0x00FFFFFF;
        if (!fd || payloadCases) return @"other";
        uint16_t recordSize = *(const uint16_t *)(fd + 10);
        uint32_t count = *(const uint32_t *)(fd + 12);
        if (recordSize < 12 || count == 0 || count > 256) return @"other";
        NSMutableArray *names = [NSMutableArray array];
        for (uint32_t i = 0; i < count; i++) {
            const char *caseName = WGRelDirect((const int32_t *)(fd + 16 + i * recordSize + 8));
            [names addObject:caseName ? @(caseName) : [NSString stringWithFormat:@"%u", i]];
        }
        *cases = names;
        return @"enum";
    }
    return WGIsClass(md) || WGKind(md) == WGKindStruct ? @"entity" : @"other";
}

// The intent's entry in the extension's Metadata.appintents (titles), or nil.
static NSDictionary *WGActionMetadata(const void *intentType, NSDictionary **rootOut) {
    static NSDictionary *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *data = [NSData dataWithContentsOfFile:[gExt.extensionPath stringByAppendingPathComponent:@"Metadata.appintents/extract.actionsdata"]];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        root = [json isKindOfClass:[NSDictionary class]] ? json : @{};
    });
    if (rootOut) *rootOut = root;
    NSString *full = WGTypeName(intentType), *shortName = [full componentsSeparatedByString:@"."].lastObject;
    NSDictionary *actions = [root[@"actions"] isKindOfClass:[NSDictionary class]] ? root[@"actions"] : @{};
    for (NSString *key in actions) {
        NSDictionary *a = actions[key];
        if (![a isKindOfClass:[NSDictionary class]]) continue;
        if ([a[@"fullyQualifiedTypeName"] isEqual:full] || [key isEqual:shortName] || [a[@"identifier"] isEqual:shortName]) return a;
    }
    return nil;
}

// A localized string from the metadata ({key, table?, alternatives?}).
static NSString *WGMetadataText(id title) {
    if ([title isKindOfClass:[NSString class]]) return title;
    if (![title isKindOfClass:[NSDictionary class]]) return nil;
    NSString *key = [title[@"key"] isKindOfClass:[NSString class]] ? title[@"key"] : nil;
    if (!key) return nil;
    NSString *table = [title[@"table"] isKindOfClass:[NSString class]] ? title[@"table"] : nil;
    NSBundle *bundle = [NSBundle bundleWithPath:gExt.extensionPath];
    return [bundle localizedStringForKey:key value:key table:table] ?: key;
}

typedef struct {
    NSString *name;
    void *object;          // the IntentParameter
    const void *valueType; // Value
} WGAppIntentParameter;

static NSArray<NSValue *> *WGAppIntentParameterList(void *intent, const void *intentType, NSMutableArray *names) {
    NSMutableArray *list = [NSMutableArray array];
    WGFields f;
    if (!WGGetFields(intentType, &f)) return list;
    for (uint32_t i = 0; i < f.count; i++) {
        const char *field = WGFieldName(&f, i);
        const void *t = WGFieldType(&f, i);
        if (!field || field[0] != '_' || !t || ![WGTypeName(t) hasPrefix:@"AppIntents.IntentParameter<"]) continue;
        void *object = *(void **)((uint8_t *)intent + WGFieldOffset(&f, i));
        const void *valueType = object ? WGParameterValueType(t) : NULL;
        if (!valueType) continue;
        [names addObject:@(field + 1)];
        WGAppIntentParameter p = { nil, object, valueType };
        [list addObject:[NSValue valueWithBytes:&p objCType:@encode(WGAppIntentParameter)]];
    }
    return list;
}

static WGParameterGet WGParameterGetter(void) {
    return WGSym("$s10AppIntents15IntentParameterC12wrappedValuexvg") ?: WGSym("$s10AppIntents15IntentParameterC12wrappedValuexvgTj");
}
static WGParameterSet WGParameterSetter(void) {
    return WGSym("$s10AppIntents15IntentParameterC12wrappedValuexvs") ?: WGSym("$s10AppIntents15IntentParameterC12wrappedValuexvsTj");
}

// The parameter's value as text (and, for an enum, its case index; -1 for none).
static NSString *WGDescribeParameter(WGAppIntentParameter *p, NSString *kind, BOOL optional, const void *inner, NSInteger *caseOut) {
    *caseOut = -1;
    WGParameterGet get = WGParameterGetter();
    if (!get) return nil;
    void *buf = WGAlloc(p->valueType);
    get(buf, p->object);
    if (optional && ((WGGetEnumTagSinglePayload)WGValueWitnesses(inner)->functions[6])(buf, 1, inner) != 0) return @"";
    if ([kind isEqual:@"bool"]) return *(uint8_t *)buf ? @"1" : @"0";
    if ([kind isEqual:@"int"]) return [NSString stringWithFormat:@"%lld", *(long long *)buf];
    if ([kind isEqual:@"double"]) return [NSString stringWithFormat:@"%g", *(double *)buf];
    if ([kind isEqual:@"string"]) return WGSwiftString(buf);
    if ([kind isEqual:@"enum"]) {
        *caseOut = ((WGEnumTagFn)((const void *const *)WGValueWitnesses(inner))[11])(buf, inner);
        return nil;
    }
    return nil;
}

static NSArray *WGAppIntentParameters(NSString *kind, NSString *config, NSString **error) {
    const void *t = gAppIntentTypes[kind].pointerValue;
    void *intent = t ? WGAppIntentForConfig(kind, config, NULL, NULL, NULL) : NULL;
    if (!intent) {
        *error = @"This widget has not been drawn yet.";
        return nil;
    }
    if (!WGParameterGetter() || !WGParameterSetter()) {
        *error = @"AppIntents' parameters cannot be reached on this system.";
        WGLog(@"Edit Widget: IntentParameter.wrappedValue not found");
        return nil;
    }
    // Reading them calls into AppIntents directly: a crash doing so turns it off for this app.
    NSString *marker = [@"appintent-params-" stringByAppendingString:gExt.extensionID];
    if (WGMarkerTripped(marker)) {
        *error = @"This widget's settings could not be read (it crashed before). Reset Widget Safety Guards in the settings to try again.";
        return nil;
    }
    WGMarkerBegin(marker);
    NSDictionary *root = nil;
    NSDictionary *action = WGActionMetadata(t, &root);
    NSMutableDictionary *metaParams = [NSMutableDictionary dictionary];
    for (NSDictionary *mp in [action[@"parameters"] isKindOfClass:[NSArray class]] ? action[@"parameters"] : @[]) {
        if ([mp isKindOfClass:[NSDictionary class]] && [mp[@"name"] isKindOfClass:[NSString class]]) metaParams[mp[@"name"]] = mp;
    }
    NSMutableArray *names = [NSMutableArray array];
    NSArray *list = WGAppIntentParameterList(intent, t, names);
    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger i = 0; i < list.count; i++) {
        WGAppIntentParameter p;
        [list[i] getValue:&p];
        BOOL optional = NO;
        const void *inner = NULL;
        NSArray *cases = nil;
        NSString *kindOf = WGValueKind(p.valueType, &optional, &inner, &cases);
        NSDictionary *meta = metaParams[names[i]];
        NSMutableDictionary *d = [@{ @"name" : names[i], @"title" : WGMetadataText(meta[@"title"]) ?: names[i] } mutableCopy];
        NSInteger caseIndex = -1;
        NSString *value = [@[ @"bool", @"int", @"double", @"string", @"enum" ] containsObject:kindOf]
                              ? WGDescribeParameter(&p, kindOf, optional, inner, &caseIndex) : nil;
        if ([kindOf isEqual:@"enum"]) {
            NSMutableArray *titles = [NSMutableArray array];
            if (optional) [titles addObject:@"None"];
            for (NSString *c in cases) [titles addObject:c];
            d[@"kind"] = @"enum";
            d[@"values"] = titles;
            if (caseIndex >= 0 && caseIndex < (NSInteger)cases.count) d[@"value"] = cases[caseIndex];
            else if (optional) d[@"value"] = @"None";
        } else if ([kindOf isEqual:@"int"] || [kindOf isEqual:@"double"]) {
            d[@"kind"] = @"string"; // typed in; read as a number here
            if (value) d[@"value"] = value;
        } else if ([kindOf isEqual:@"bool"] || [kindOf isEqual:@"string"]) {
            d[@"kind"] = kindOf;
            if (value) d[@"value"] = value;
        } else {
            d[@"kind"] = @"other";
            d[@"value"] = @"Not editable yet";
        }
        [out addObject:d];
        WGLog(@"Edit Widget: .%@ %@ (%@) = %@; metadata %@", names[i], WGTypeName(p.valueType), kindOf, d[@"value"] ?: @"?",
              meta ? [[meta.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","] : @"none");
    }
    WGMarkerEnd(marker);
    if (!out.count) *error = @"This widget has no settings.";
    return out.count ? out : nil;
}

// Makes the value for a saved choice in buf (storage for the parameter's Value type).
static BOOL WGMakeParameterValue(NSDictionary *saved, NSString *kind, BOOL optional, const void *inner, NSArray *cases, void *buf) {
    BOOL none = [saved[@"none"] boolValue];
    if (!none) {
        if ([kind isEqual:@"bool"]) *(uint8_t *)buf = [saved[@"bool"] boolValue] ? 1 : 0;
        else if ([kind isEqual:@"int"]) *(long long *)buf = [saved[@"number"] longLongValue];
        else if ([kind isEqual:@"double"]) *(double *)buf = [saved[@"number"] doubleValue];
        else if ([kind isEqual:@"string"]) {
            WGBridgeString bridge = WGSym("$sSS10FoundationE36_unconditionallyBridgeFromObjectiveCySSSo8NSStringCSgFZ");
            if (!bridge) return NO;
            WGSwiftStringValue v = bridge([saved[@"string"] description] ?: @"");
            memcpy(buf, &v, sizeof v);
        } else if ([kind isEqual:@"enum"]) {
            NSUInteger c = [saved[@"case"] unsignedIntegerValue];
            if (c >= cases.count) return NO;
            ((WGInjectEnumTag)((const void *const *)WGValueWitnesses(inner))[13])(buf, (unsigned)c, inner);
        } else {
            return NO;
        }
    } else if (!optional) {
        return NO;
    }
    if (optional) ((WGStoreEnumTagSinglePayload)WGValueWitnesses(inner)->functions[7])(buf, none ? 1 : 0, 1, inner);
    return YES;
}

// Sets the saved values on a fresh intent. A crash doing so turns it off for this extension.
static void WGApplyAppIntentConfiguration(NSString *kind, NSString *config, void *value, const void *type) {
    NSData *data = [NSData dataWithContentsOfFile:WGAppIntentConfigPath(kind, config)];
    NSDictionary *saved = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![saved isKindOfClass:[NSDictionary class]] || !saved.count) return;
    NSString *marker = [@"appintent-config-" stringByAppendingString:gExt.extensionID];
    if (WGMarkerTripped(marker)) {
        WGLog(@"Edit Widget: saved settings not applied (applying them crashed before)");
        return;
    }
    WGParameterSet set = WGParameterSetter();
    if (!set) return;
    WGMarkerBegin(marker);
    NSMutableArray *names = [NSMutableArray array];
    NSArray *list = WGAppIntentParameterList(value, type, names);
    for (NSUInteger i = 0; i < list.count; i++) {
        NSDictionary *choice = saved[names[i]];
        if (![choice isKindOfClass:[NSDictionary class]]) continue;
        WGAppIntentParameter p;
        [list[i] getValue:&p];
        BOOL optional = NO;
        const void *inner = NULL;
        NSArray *cases = nil;
        NSString *kindOf = WGValueKind(p.valueType, &optional, &inner, &cases);
        void *buf = WGAlloc(p.valueType);
        if (buf && WGMakeParameterValue(choice, kindOf, optional, inner, cases, buf)) set(buf, p.object); // takes the value
    }
    WGMarkerEnd(marker);
}

static NSString *WGAppIntentSetParameter(NSString *kind, NSString *config, NSString *name, NSDictionary *value) {
    const void *t = gAppIntentTypes[kind].pointerValue;
    void *intent = t && config.length ? WGAppIntentForConfig(kind, config, NULL, NULL, NULL) : NULL;
    if (!intent) return @"Nothing to edit.";
    NSMutableArray *names = [NSMutableArray array];
    NSArray *list = WGAppIntentParameterList(intent, t, names);
    NSUInteger i = [names indexOfObject:name ?: @""];
    if (i == NSNotFound) return @"No such setting.";
    WGAppIntentParameter p;
    [list[i] getValue:&p];
    BOOL optional = NO;
    const void *inner = NULL;
    NSArray *cases = nil;
    NSString *kindOf = WGValueKind(p.valueType, &optional, &inner, &cases);
    NSMutableDictionary *choice = [NSMutableDictionary dictionary];
    if ([kindOf isEqual:@"bool"]) choice[@"bool"] = @([value[@"bool"] boolValue]);
    else if ([kindOf isEqual:@"string"]) choice[@"string"] = [value[@"string"] description] ?: @"";
    else if ([kindOf isEqual:@"int"] || [kindOf isEqual:@"double"]) {
        NSString *text = [value[@"string"] description] ?: @"";
        if (!text.length && optional) choice[@"none"] = @YES;
        else choice[@"number"] = @([text doubleValue]);
    } else if ([kindOf isEqual:@"enum"]) {
        NSInteger index = [value[@"index"] integerValue];
        if (optional && index == 0) choice[@"none"] = @YES;
        else choice[@"case"] = @(index - (optional ? 1 : 0));
    } else {
        return @"This setting cannot be changed here yet.";
    }
    NSString *path = WGAppIntentConfigPath(kind, config);
    NSData *old = [NSData dataWithContentsOfFile:path];
    NSMutableDictionary *saved = [(old ? [NSJSONSerialization JSONObjectWithData:old options:0 error:nil] : nil) mutableCopy] ?: [NSMutableDictionary dictionary];
    if (![saved isKindOfClass:[NSMutableDictionary class]]) saved = [NSMutableDictionary dictionary];
    saved[name] = choice;
    NSData *data = [NSJSONSerialization dataWithJSONObject:saved options:0 error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    if (!data || ![data writeToFile:path atomically:YES]) return @"Could not be saved.";
    // The next drawing makes the intent again with every saved value.
    [gAppIntentsMade removeObjectForKey:[NSString stringWithFormat:@"%@|%@", kind, config]];
    WGLog(@"Edit Widget: %@ (%@) .%@ = %@", kind, config, name, choice);
    return nil;
}

#pragma mark - TimelineProviderContext

typedef void *(*WGAllocObject)(const void *metadata, size_t size, size_t alignMask);
static BOOL WGDefaultInit(void *dst, const void *md, int depth);

// A fresh class instance whose stored properties all get default values.
static void *WGDefaultObject(const void *md, int depth) {
    const uint8_t *desc = WGClassDescriptor(md);
    if (!desc) return (__bridge_retained void *)[[(__bridge Class)md alloc] init];
    WGAllocObject allocObject = WGSym("swift_allocObject");
    if (!allocObject) return NULL;
    uint32_t size = *(const uint32_t *)((const uint8_t *)md + 48);
    uint16_t alignMask = *(const uint16_t *)((const uint8_t *)md + 52);
    void *obj = allocObject(md, size, alignMask);
    if (!obj) return NULL;
    memset((uint8_t *)obj + 16, 0, size > 16 ? size - 16 : 0);
    WGFields f;
    if (!WGGetFields(md, &f)) return obj;
    for (uint32_t i = 0; i < f.count; i++) {
        const void *t = WGFieldType(&f, i);
        if (!t || !WGDefaultInit((uint8_t *)obj + WGFieldOffset(&f, i), t, depth + 1)) return NULL;
    }
    return obj;
}

// A valid "empty" value: zero for plain data, empty strings and collections, nil for
// optionals, EnvironmentValues(), recursively for structs and classes.
static BOOL WGDefaultInit(void *dst, const void *md, int depth) {
    if (depth > 8) return NO;
    const WGVWT *vwt = WGValueWitnesses(md);
    NSString *name = WGTypeName(md);
    uintptr_t kind = WGKind(md);
    if ([name isEqualToString:@"SwiftUI.EnvironmentValues"]) {
        WGIndirectInit init = WGSym("$s7SwiftUI17EnvironmentValuesVACycfC");
        if (!init) return NO;
        init(dst);
        return YES;
    }
    if (WGIsClass(md)) {
        void *obj = WGDefaultObject(md, depth);
        if (!obj) return NO;
        memcpy(dst, &obj, sizeof obj);
        return YES;
    }
    if (!(vwt->flags & WG_VWT_NON_POD)) {
        memset(dst, 0, vwt->size);
        return YES;
    }
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
        void *p = WGSym(singleton);
        memcpy(dst, &p, sizeof p);
        return p != NULL;
    }
    if (kind == WGKindOptional) {
        const void *payload = ((const void *const *)md)[2];
        ((WGStoreEnumTag)WGValueWitnesses(payload)->functions[7])(dst, 1, 1, payload);
        return YES;
    }
    if (kind == WGKindStruct) {
        WGFields f;
        if (!WGGetFields(md, &f)) return NO;
        for (uint32_t i = 0; i < f.count; i++) {
            const void *t = WGFieldType(&f, i);
            if (!t || !WGDefaultInit((uint8_t *)dst + WGFieldOffset(&f, i), t, depth + 1)) return NO;
        }
        return YES;
    }
    return NO;
}

// TimelineProviderContext as WidgetKit passes it: family and display size.
static void *WGMakeContext(WGFamily family, CGSize size) {
    WGMetadataAccessor accessor = WGSym("$s9WidgetKit23TimelineProviderContextVMa");
    const void *md = accessor ? accessor(0).metadata : NULL;
    void *ctx = md ? WGAlloc(md) : NULL;
    if (!ctx || !WGDefaultInit(ctx, md, 0)) return NULL;
    // WidgetFamily: 0 systemSmall, 1 systemMedium, 2 systemLarge, 3 systemExtraLarge.
    size_t off;
    if (WGStructField(md, "family", &off, NULL)) *((uint8_t *)ctx + off) = (uint8_t)family;
    if (WGStructField(md, "internalFamily", &off, NULL)) *((uint8_t *)ctx + off) = (uint8_t)family;
    if (WGStructField(md, "displaySize", &off, NULL)) memcpy((uint8_t *)ctx + off, &size, sizeof size);
    return ctx;
}

#pragma mark - Hosting the widget's view

typedef void *(*WGHostingInit)(void *rootView, const void *metatype SWIFT_CONTEXT) SWIFTCALL;
typedef void (*WGSetSafeAreaRegions)(uintptr_t regions, void *controller SWIFT_CONTEXT) SWIFTCALL;

static UIViewController *WGHostView(void *view, const void *viewType) {
    const void *viewProto = WGSym("$s7SwiftUI4ViewMp");
    WGConformsToProtocol conformsTo = WGSym("swift_conformsToProtocol");
    WGGenericAccessor2 hostingAccessor = WGSym("$s7SwiftUI19UIHostingControllerCMa");
    WGHostingInit hostingInit = WGSym("$s7SwiftUI19UIHostingControllerC8rootViewACyxGx_tcfC");
    if (!viewProto || !conformsTo || !hostingAccessor || !hostingInit) return nil;
    const void *viewWT = conformsTo(viewType, viewProto);
    if (!viewWT) return nil;
    void *controller = hostingInit(view, hostingAccessor(0, viewType, viewWT).metadata); // takes the view
    if (!controller) return nil;
    // A widget has no safe area (the host's window sits at the top of the screen, under the
    // status bar area): UIHostingController.safeAreaRegions = [].
    WGSetSafeAreaRegions setRegions = WGSym("$s7SwiftUI19UIHostingControllerC15safeAreaRegionsAA04SafefG0Vvs");
    if (setRegions) setRegions(0, controller);
    return (__bridge_transfer UIViewController *)controller;
}

// The widget's container background. Since iOS 17 a widget sets its background with
// .containerBackground(…, for: .widget); it is handed to the widget's container, which draws it
// behind the view. This host is the container: View.applyContainerBackground(for:isEnabled:)
// with WidgetKit's placement key draws it. (The key protocol is a marker protocol: the generic
// arguments are Self, Key and Self's View conformance.)
typedef void (*WGApplyContainerBackground)(void *out SWIFT_INDIRECT, const void *keyMetatype, bool isEnabled, const void *selfType,
                                           const void *keyType, const void *selfViewWT, const void *selfValue SWIFT_CONTEXT) SWIFTCALL;
typedef WGMetadataResponse (*WGGetOpaqueTypeMetadata)(size_t request, const void *const *arguments, const void *descriptor, uintptr_t index) SWIFTCALL;

typedef struct {
    WGApplyContainerBackground apply;
    const void *opaqueDescriptor, *keyType, *viewProto;
    WGGetOpaqueTypeMetadata opaqueMetadata;
    WGConformsToProtocol conformsTo;
} WGContainerBackgroundCalls;

// The result type's generic signature must be the one the call is made for: parameters x
// (Self), qd__ (Key), qd0__ (the result); requirements x: View, qd0__: View.
static BOOL WGContainerSignatureMatches(const uint8_t *d) {
    uint32_t flags = *(const uint32_t *)d;
    uint16_t numParams = *(const uint16_t *)(d + 8), numReqs = *(const uint16_t *)(d + 10);
    if ((flags & 0x1F) != 4 || !(flags & 0x80) || numParams != 3 || numReqs > 8) return NO;
    NSMutableArray *reqs = [NSMutableArray array];
    const uint8_t *r = d + 16 + ((numParams + 3) & ~3u);
    for (uint16_t i = 0; i < numReqs; i++, r += 12) {
        const char *param = WGRelDirect((const int32_t *)(r + 4));
        const uint8_t *proto = (*(const uint32_t *)r & 0x1F) == 0 ? WGRelIndirectable((const int32_t *)(r + 8)) : NULL;
        const char *protoName = proto ? WGRelDirect((const int32_t *)(proto + 8)) : NULL;
        [reqs addObject:[NSString stringWithFormat:@"%.8s: %s", param ?: "?", protoName ?: "?"]];
    }
    return [[reqs componentsJoinedByString:@", "] isEqualToString:@"x: View, qd0__: View"];
}

typedef void (*WGStaticIndirectGetter)(void *out SWIFT_INDIRECT) SWIFTCALL;

static const WGContainerBackgroundCalls *WGContainerBackground(void) {
    static WGContainerBackgroundCalls calls;
    static const WGContainerBackgroundCalls *result;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        calls.apply = WGSym("$s7SwiftUI4ViewPAAE24applyContainerBackground3for9isEnabledQrqd__m_SbtAA0eF18PlacementCustomKeyRd__lF");
        calls.opaqueDescriptor = WGSym("$s7SwiftUI4ViewPAAE24applyContainerBackground3for9isEnabledQrqd__m_SbtAA0eF18PlacementCustomKeyRd__lFQOMQ");
        calls.opaqueMetadata = WGSym("swift_getOpaqueTypeMetadata2");
        calls.viewProto = WGSym("$s7SwiftUI4ViewMp");
        calls.conformsTo = WGSym("swift_conformsToProtocol");
        WGStaticIndirectGetter widgetPlacement = WGSym("$s7SwiftUI28ContainerBackgroundPlacementV9WidgetKitE6widgetACvgZ");
        WGMetadataAccessor placementAccessor = WGSym("$s7SwiftUI28ContainerBackgroundPlacementVMa");
        NSString *problem = nil;
        if (!calls.apply || !calls.opaqueDescriptor || !widgetPlacement || !placementAccessor || !calls.opaqueMetadata || !calls.viewProto ||
            !calls.conformsTo) {
            problem = @"not available (before iOS 17)";
        } else if (!WGContainerSignatureMatches(calls.opaqueDescriptor)) {
            problem = @"unexpected signature";
        } else {
            // The key type, held by the .widget placement value (a struct or enum metadata in a
            // loaded image).
            const void *placementType = placementAccessor(0).metadata;
            void *placement = placementType && WGValueWitnesses(placementType)->size >= sizeof(void *) ? WGAlloc(placementType) : NULL;
            if (placement) widgetPlacement(placement);
            const uintptr_t *candidate = placement ? *(const uintptr_t *const *)placement : NULL;
            Dl_info where;
            if ((uintptr_t)candidate > 0x100000000 && dladdr(candidate, &where) && where.dli_fbase &&
                (candidate[0] == WGKindStruct || candidate[0] == WGKindEnum) && candidate[1]) {
                calls.keyType = candidate;
            } else {
                problem = @"no key in the widget placement";
            }
        }
        if (problem) WGLog(@"container backgrounds: %@", problem);
        else result = &calls;
    });
    return result;
}

static void *WGWithContainerBackground(void *view, const void *viewType, const void **outType) {
    const WGContainerBackgroundCalls *c = WGContainerBackground();
    const void *viewWT = c ? c->conformsTo(viewType, c->viewProto) : NULL;
    if (!viewWT) return NULL;
    // Self's conformance after two or after three type arguments: present in both places.
    const void *arguments[5] = { viewType, c->keyType, viewWT, viewWT, NULL };
    const void *resultType = c->opaqueMetadata(0, arguments, c->opaqueDescriptor, 0).metadata;
    void *result = resultType ? WGAlloc(resultType) : NULL;
    if (!result) return NULL;
    c->apply(result, c->keyType, true, viewType, c->keyType, viewWT, view);
    ((WGDestroyValue)WGValueWitnesses(viewType)->functions[1])(view, viewType);
    free(view);
    *outType = resultType;
    return result;
}

// WidgetKit's accented rendering mode. With clear or tinted icons, iOS draws widgets in the
// accented mode without their container background (the home screen draws glass behind
// them); widgets read \.widgetRenderingMode and \.showsWidgetContainerBackground to adapt.
// The values go to the widget through _UIHostingView.environmentOverride (values set there win
// over the ones the hosting view derives), built with WidgetKit's own setters.
// EnvironmentValues and WidgetRenderingMode are resilient: passed and returned indirectly.
typedef void (*WGIndirectGetter)(void *out SWIFT_INDIRECT, const void *selfValue SWIFT_CONTEXT) SWIFTCALL;
typedef void (*WGIndirectSetter)(void *newValue, void *selfValue SWIFT_CONTEXT) SWIFTCALL;
typedef void (*WGKeySubscriptSetter)(void *newValue, const void *keyMetatype, const void *keyType, const void *keyWT,
                                     void *selfValue SWIFT_CONTEXT) SWIFTCALL;

typedef struct {
    WGIndirectInit environmentInit;
    const void *environmentType, *optionalType, *modeType, *backgroundKeyType, *backgroundKeyWT;
    WGIndirectGetter overrideGet;
    WGIndirectSetter overrideSet, modeSet;
    WGStaticIndirectGetter accented;
    WGKeySubscriptSetter keySet;
} WGEnvironmentCalls;

static const WGEnvironmentCalls *WGEnvironment(void) {
    static WGEnvironmentCalls calls;
    static const WGEnvironmentCalls *result;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        calls.environmentInit = WGSym("$s7SwiftUI17EnvironmentValuesVACycfC");
        WGMetadataAccessor environmentAccessor = WGSym("$s7SwiftUI17EnvironmentValuesVMa");
        WGGenericAccessor1 optionalAccessor = WGSym("$sSqMa");
        calls.overrideGet = WGSym("$s7SwiftUI14_UIHostingViewC19environmentOverrideAA17EnvironmentValuesVSgvg");
        calls.overrideSet = WGSym("$s7SwiftUI14_UIHostingViewC19environmentOverrideAA17EnvironmentValuesVSgvs");
        calls.modeSet = WGSym("$s7SwiftUI17EnvironmentValuesV9WidgetKitE19widgetRenderingModeAD0ehI0Vvs");
        WGMetadataAccessor modeAccessor = WGSym("$s9WidgetKit0A13RenderingModeVMa");
        calls.accented = WGSym("$s9WidgetKit0A13RenderingModeV8accentedACvgZ");
        calls.keySet = WGSym("$s7SwiftUI17EnvironmentValuesVy5ValueQzxmcAA0C3KeyRzluis");
        WGMetadataAccessor keyAccessor = WGSym("$s7SwiftUI17EnvironmentValuesV9WidgetKitE05ShowsE13BackgroundKeyVMa");
        const void *keyProto = WGSym("$s7SwiftUI14EnvironmentKeyMp");
        WGConformsToProtocol conformsTo = WGSym("swift_conformsToProtocol");
        if (!calls.environmentInit || !environmentAccessor || !optionalAccessor || !calls.overrideGet || !calls.overrideSet || !calls.modeSet ||
            !modeAccessor || !calls.accented) {
            WGLog(@"accented mode: not available");
            return;
        }
        calls.environmentType = environmentAccessor(0).metadata;
        calls.optionalType = calls.environmentType ? optionalAccessor(0, calls.environmentType).metadata : NULL;
        calls.modeType = modeAccessor(0).metadata;
        if (!calls.environmentType || !calls.optionalType || !calls.modeType) return;
        // \.showsWidgetContainerBackground = false is optional (only read by the widget).
        calls.backgroundKeyType = keyAccessor ? keyAccessor(0).metadata : NULL;
        calls.backgroundKeyWT = calls.backgroundKeyType && keyProto && conformsTo ? conformsTo(calls.backgroundKeyType, keyProto) : NULL;
        result = &calls;
    });
    return result;
}

// Gives the hosting view the accented mode; NO when it cannot (drawn in full color then). A
// crash here turns it off for this extension (crash marker).
static BOOL WGApplyAccentedMode(UIViewController *controller) {
    static BOOL failed;
    NSString *marker = [@"accented-" stringByAppendingString:gExt.extensionID];
    if (failed || WGMarkerTripped(marker)) return NO;
    const WGEnvironmentCalls *c = WGEnvironment();
    UIView *view = controller.view;
    BOOL hostingView = NO;
    for (Class k = view.class; k && !hostingView; k = class_getSuperclass(k)) hostingView = [NSStringFromClass(k) hasPrefix:@"_TtGC7SwiftUI14_UIHostingView"];
    if (!c || !hostingView) {
        failed = YES;
        return NO;
    }
    const WGVWT *envVWT = WGValueWitnesses(c->environmentType), *optVWT = WGValueWitnesses(c->optionalType);
    WGMarkerBegin(marker);
    // The current override (none expected), read into a buffer filled with a pattern: checks the
    // getter takes its result the way it is called here.
    void *current = WGAlloc(c->optionalType);
    memset(current, 0xA5, optVWT->stride);
    c->overrideGet(current, (__bridge void *)view);
    unsigned tag = ((WGGetEnumTagSinglePayload)envVWT->functions[6])(current, 1, c->environmentType);
    BOOL untouched = YES;
    for (size_t i = 0; i < optVWT->size; i++) if (((uint8_t *)current)[i] != 0xA5) untouched = NO;
    if (untouched || tag > 1) {
        WGMarkerEnd(marker);
        WGLogImportant(@"accented mode: unexpected environment override (tag %u)", tag);
        failed = YES;
        free(current);
        return NO;
    }
    if (tag == 0) ((WGDestroyValue)optVWT->functions[1])(current, c->optionalType);
    free(current);

    void *environment = WGAlloc(c->environmentType);
    c->environmentInit(environment);
    void *mode = WGAlloc(c->modeType);
    c->accented(mode);
    c->modeSet(mode, environment); // takes the value
    free(mode);
    if (c->keySet && c->backgroundKeyWT) {
        bool shows = false;
        c->keySet(&shows, c->backgroundKeyType, c->backgroundKeyType, c->backgroundKeyWT, environment);
    }
    void *override = WGAlloc(c->optionalType);
    ((WGInitializeWithTake)envVWT->functions[4])(override, environment, c->environmentType);
    ((WGStoreEnumTagSinglePayload)envVWT->functions[7])(override, 0, 1, c->environmentType);
    free(environment);
    c->overrideSet(override, (__bridge void *)view); // takes the value
    free(override);
    WGMarkerEnd(marker);
    return YES;
}

typedef void (*WGContentFn)(void *out SWIFT_INDIRECT, const void *entry, const void *ctx SWIFT_CONTEXT) SWIFTCALL;

// The entry through the widget's view builder ("(Entry) -> Content"): full color with its
// container background, or accented without it.
static UIViewController *WGRenderEntry(const void *generator, const void *generatorType, const void *entry, WGRenderMode mode) {
    const void *resultType = ((const void *const *)generatorType)[2];
    void *view = WGAlloc(resultType);
    if (!view) return nil;
    const void *const *pair = generator;
    ((WGContentFn)pair[0])(view, entry, pair[1]);
    if (mode == WGRenderModeAccented) {
        UIViewController *controller = WGHostView(view, resultType);
        if (controller) WGApplyAccentedMode(controller);
        return controller;
    }
    const void *backgroundType = NULL;
    void *withBackground = WGWithContainerBackground(view, resultType, &backgroundType);
    return withBackground ? WGHostView(withBackground, backgroundType) : WGHostView(view, resultType);
}

#pragma mark - Timeline requests

// Completion closures get a real Swift heap object as their context (WidgetKit retains and
// releases it) carrying the request number. Its metadata is a minimal HeapLocalVariable record
// whose destroy function frees it.
typedef struct { const void *metadata; uint64_t refCounts; uint64_t requestID; } WGCtxObject;
typedef void (*WGHeapDestroy)(void *object SWIFT_CONTEXT) SWIFTCALL;

static struct {
    WGHeapDestroy destroy;
    const void *valueWitnesses;
    uintptr_t kind;
    uint32_t offsetToFirstCapture, pad;
    const void *captureDescription;
} gCtxMetadata;

static void WGCtxDestroy(void *object SWIFT_CONTEXT) SWIFTCALL {
    void (*dealloc)(void *, size_t, size_t) = WGSym("swift_deallocObject");
    if (dealloc) dealloc(object, sizeof(WGCtxObject), 7);
}

static void *WGMakeCtx(uint64_t requestID) {
    void *(*alloc)(const void *, size_t, size_t) = WGSym("swift_allocObject");
    if (!alloc) return NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gCtxMetadata.destroy = WGCtxDestroy;
        gCtxMetadata.valueWitnesses = WGSym("$sBoWV");
        gCtxMetadata.kind = 0x400; // HeapLocalVariable
        gCtxMetadata.offsetToFirstCapture = 16;
    });
    WGCtxObject *o = alloc(&gCtxMetadata.kind, sizeof(WGCtxObject), 7);
    if (o) o->requestID = requestID;
    return o;
}

static void WGReleaseCtx(void *o) {
    void (*release)(void *) = WGSym("swift_release");
    if (o && release) release(o);
}

typedef void (^WGEntriesHandler)(NSArray<NSValue *> *entries); // copied entries, main queue

@interface WGRequest : NSObject
@property (nonatomic) const void *entryType;
@property (nonatomic) size_t entriesOffset;
@property (nonatomic, copy) WGEntriesHandler handler;
@end
@implementation WGRequest
@end

static NSMutableDictionary<NSNumber *, WGRequest *> *gRequests;
static os_unfair_lock gRequestsLock = OS_UNFAIR_LOCK_INIT;
static uint64_t gNextRequest = 1;

static uint64_t WGAddRequest(const void *entryType, size_t entriesOffset, WGEntriesHandler handler) {
    WGRequest *r = [WGRequest new];
    r.entryType = entryType;
    r.entriesOffset = entriesOffset;
    r.handler = handler;
    os_unfair_lock_lock(&gRequestsLock);
    if (!gRequests) gRequests = [NSMutableDictionary dictionary];
    uint64_t rid = gNextRequest++;
    gRequests[@(rid)] = r;
    os_unfair_lock_unlock(&gRequestsLock);
    return rid;
}

static WGRequest *WGTakeRequest(uint64_t rid) {
    os_unfair_lock_lock(&gRequestsLock);
    WGRequest *r = gRequests[@(rid)];
    [gRequests removeObjectForKey:@(rid)];
    os_unfair_lock_unlock(&gRequestsLock);
    return r;
}

static void *WGCopyEntry(const void *entry, const void *type) {
    void *copy = WGAlloc(type);
    if (copy) ((WGCopyValue)WGValueWitnesses(type)->functions[2])(copy, entry, type);
    return copy;
}

static void WGDeliverTimeline(WGRequest *r, const void *timeline) {
    NSMutableArray *entries = [NSMutableArray array];
    intptr_t count = 0;
    const uint8_t *elements = WGArrayElements((const uint8_t *)timeline + r.entriesOffset, r.entryType, &count);
    size_t stride = WGValueWitnesses(r.entryType)->stride;
    for (intptr_t i = 0; elements && i < count && i < 64; i++) {
        void *copy = WGCopyEntry(elements + i * stride, r.entryType);
        if (copy) [entries addObject:[NSValue valueWithPointer:copy]];
    }
    WGEntriesHandler handler = r.handler;
    dispatch_async(dispatch_get_main_queue(), ^{ handler(entries); });
}

static void WGDeliverEntry(WGRequest *r, const void *entry) {
    void *copy = WGCopyEntry(entry, r.entryType);
    NSArray *entries = copy ? @[ [NSValue valueWithPointer:copy] ] : @[];
    WGEntriesHandler handler = r.handler;
    dispatch_async(dispatch_get_main_queue(), ^{ handler(entries); });
}

static void WGTimelineCompletion(const void *timeline, const void *ctx SWIFT_CONTEXT) SWIFTCALL {
    WGRequest *r = ctx ? WGTakeRequest(((const WGCtxObject *)ctx)->requestID) : nil;
    if (r) WGDeliverTimeline(r, timeline);
}

static void WGSnapshotCompletion(const void *entry, const void *ctx SWIFT_CONTEXT) SWIFTCALL {
    WGRequest *r = ctx ? WGTakeRequest(((const WGCtxObject *)ctx)->requestID) : nil;
    if (r) WGDeliverEntry(r, entry);
}

#pragma mark Swift async calls (AppIntentTimelineProvider)

// A task is created whose entry (WGAsync.s) tail-calls the async function as Swift code does;
// its resume function hands the result back here. The request number travels in the task's
// closure context.
typedef struct { int32_t function; uint32_t contextSize; } WGAsyncFunctionPointer;
extern void WGAsyncEntry(void);
extern void WGAsyncResume(void);

typedef struct {
    const WGAsyncFunctionPointer *afp;
    void *args[5]; // x0…x4: result buffer, configuration, context, Self, witness table
    const void *selfValue;
    BOOL isTimeline;
    uint64_t rid;
} WGAsyncCall;

typedef struct { uint64_t magic; WGAsyncCall *call; void *callee; } WGAsyncTaskState;
#define WG_ASYNC_MAGIC 0x5747415359434E33ULL
#define WG_ASYNC_STATE(ctx) ((WGAsyncTaskState *)((uint8_t *)(ctx) + 64))

static NSMutableDictionary<NSNumber *, NSValue *> *gAsyncCalls;
static os_unfair_lock gAsyncLock = OS_UNFAIR_LOCK_INIT;
static WGAsyncFunctionPointer gEntryAFP;

// Called by WGAsyncEntry with this task's context; fills out[0…7]: x0…x4, x20, x22, function.
void WGAsyncPrepare(void *ctx, void *closure, void **out) {
    uint64_t rid = closure ? ((WGCtxObject *)closure)->requestID : 0;
    os_unfair_lock_lock(&gAsyncLock);
    WGAsyncCall *call = [gAsyncCalls[@(rid)] pointerValue];
    os_unfair_lock_unlock(&gAsyncLock);
    void *(*taskAlloc)(size_t) = WGSym("swift_task_alloc");
    WGAsyncTaskState *state = WG_ASYNC_STATE(ctx);
    state->magic = WG_ASYNC_MAGIC;
    state->call = call;
    void **callee = taskAlloc(call->afp->contextSize < 32 ? 32 : call->afp->contextSize);
    callee[0] = ctx;                   // Parent
    callee[1] = (void *)WGAsyncResume; // ResumeParent
    state->callee = callee;
    for (int i = 0; i < 5; i++) out[i] = call->args[i];
    out[5] = (void *)call->selfValue;
    out[6] = callee;
    out[7] = (void *)((const uint8_t *)&call->afp->function + call->afp->function);
}

// Called by WGAsyncResume with x22 (the callee's context or ours); fills out[0…1]: this task's
// context and resume function.
void WGAsyncFinish(void *x22, void **out) {
    void *ctx = WG_ASYNC_STATE(x22)->magic == WG_ASYNC_MAGIC ? x22 : ((void **)x22)[0];
    WGAsyncTaskState *state = WG_ASYNC_STATE(ctx);
    void (*taskDealloc)(void *) = WGSym("swift_task_dealloc");
    taskDealloc(state->callee);
    WGAsyncCall *call = state->call;
    WGRequest *r = WGTakeRequest(call->rid);
    if (r) {
        if (call->isTimeline) WGDeliverTimeline(r, call->args[0]);
        else WGDeliverEntry(r, call->args[0]);
    }
    os_unfair_lock_lock(&gAsyncLock);
    [gAsyncCalls removeObjectForKey:@(call->rid)];
    os_unfair_lock_unlock(&gAsyncLock);
    out[0] = ctx;
    out[1] = ((void **)ctx)[1]; // this task's ResumeParent
}

typedef struct { void *task, *context; } WGTaskAndContext;
typedef WGTaskAndContext (*WGTaskCreate)(size_t flags, void *options, const void *resultType, void *entry, void *closureContext) SWIFTCALL;

static BOOL WGStartAsyncCall(const char *afpSymbol, BOOL isTimeline, void *result, void *configuration, void *context,
                             const void *selfType, const void *wt, const void *selfValue, uint64_t rid) {
    const WGAsyncFunctionPointer *afp = WGSym(afpSymbol);
    WGTaskCreate create = WGSym("swift_task_create");
    // "$sytN" (metadata of ()) is a full-metadata symbol: the metadata is 8 bytes in.
    const uint8_t *emptyTupleFull = WGSym("$sytN");
    void (*release)(void *) = WGSym("swift_release");
    if (!afp || !create || !emptyTupleFull) return NO;
    const void *voidType = emptyTupleFull + 8;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gAsyncCalls = [NSMutableDictionary dictionary];
        gEntryAFP.function = (int32_t)((intptr_t)WGAsyncEntry - (intptr_t)&gEntryAFP.function);
        gEntryAFP.contextSize = 160;
    });
    WGAsyncCall *call = calloc(1, sizeof *call);
    call->afp = afp;
    call->args[0] = result;
    call->args[1] = configuration;
    call->args[2] = context;
    call->args[3] = (void *)selfType;
    call->args[4] = (void *)wt;
    call->selfValue = selfValue;
    call->isTimeline = isTimeline;
    call->rid = rid;
    os_unfair_lock_lock(&gAsyncLock);
    gAsyncCalls[@(rid)] = [NSValue valueWithPointer:call];
    os_unfair_lock_unlock(&gAsyncLock);
    // As compiled code creates a detached task: enqueue the job (bit 12), the closure context is
    // handed over (bit 15). From a background thread (the main thread may have a current task).
    size_t flags = (1u << 12) | (1u << 15);
    void *closure = WGMakeCtx(rid);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        WGTaskAndContext t = create(flags, NULL, voidType, &gEntryAFP, closure);
        if (t.task && release) release(t.task);
    });
    return YES;
}

#pragma mark - Rendering

typedef void (*WGPlaceholderFn)(void *out SWIFT_INDIRECT, const void *context, const void *selfType, const void *wt, const void *self SWIFT_CONTEXT) SWIFTCALL;
typedef void (*WGTimelineFn)(const void *context, const void *cbFn, const void *cbCtx, const void *selfType, const void *wt, const void *self SWIFT_CONTEXT) SWIFTCALL;
typedef void (*WGIntentTimelineFn)(const void *intent, const void *context, const void *cbFn, const void *cbCtx, const void *selfType, const void *wt,
                                   const void *self SWIFT_CONTEXT) SWIFTCALL;

// TimelineEntry's date, as seconds since 2001, or NAN.
static double WGEntryDate(const void *entry, const void *entryType) {
    size_t off = 0;
    double d;
    if (!entry || !WGStructField(entryType, "date", &off, NULL)) return NAN;
    memcpy(&d, (const uint8_t *)entry + off, sizeof d);
    return d;
}

static void WGRender(NSString *kind, NSString *config, WGFamily family, CGSize size, BOOL wantPlaceholder, WGRenderMode mode, WGRenderUpdate update) {
    const WGProviderBox *found = [gBoxByKind[kind] pointerValue];
    if (!found) {
        WGLog(@"render %@: no such widget", kind);
        update(nil, nil, YES);
        return;
    }
    WGProviderBox box = *found;
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    WGSharedDataWillRender();
    WGConformsToProtocol conformsTo = WGSym("swift_conformsToProtocol");
    const void *proto = WGSym(box.isAppIntent ? "$s9WidgetKit25AppIntentTimelineProviderMp"
                              : box.isIntent  ? "$s9WidgetKit22IntentTimelineProviderMp" : "$s9WidgetKit16TimelineProviderMp");
    const void *entryProto = WGSym("$s9WidgetKit13TimelineEntryMp");
    WGGenericAccessor2 timelineAccessor = WGSym("$s9WidgetKit8TimelineVMa");
    size_t providerOff = 0, generatorOff = 0;
    const void *providerType = NULL, *generatorType = NULL;
    if (!conformsTo || !proto || !WGStructField(box.type, "provider", &providerOff, &providerType) ||
        !WGStructField(box.type, "generator", &generatorOff, &generatorType) || !providerType || !generatorType) {
        WGLogImportant(@"render %@: provider or view builder not found", kind);
        update(nil, nil, YES);
        return;
    }
    const void *provider = (const uint8_t *)box.base + providerOff;
    const void *generator = (const uint8_t *)box.base + generatorOff;
    const void *entryType = ((const void *const *)generatorType)[3];
    const void *const *wt = conformsTo(providerType, proto);
    int methods[8];
    int nmethods = wt ? WGRequirementsOfKind(proto, 1, methods, 8) : 0;
    int base = box.isIntent ? 1 : 0;
    const void *placeholderFn = NULL, *snapshotFn = NULL, *timelineFn = NULL;
    if (box.isAppIntent && wt) {
        // Its data methods are async; placeholder(in:) and the completion-handler getSnapshot
        // are called through their dispatch thunks.
        placeholderFn = WGSym("$s9WidgetKit25AppIntentTimelineProviderP11placeholder2in5EntryQzAA0eF7ContextV_tFTj");
        snapshotFn = WGSym("$s9WidgetKit25AppIntentTimelineProviderP11getSnapshot3for2in10completiony0D0Qz_AA0eF7ContextVy5EntryQzctFTj");
        timelineFn = WGSym("$s9WidgetKit25AppIntentTimelineProviderP03getE03for2in10completiony0D0Qz_AA0eF7ContextVyAA0E0Vy5EntryQzGctFTj");
    } else if (nmethods >= base + 3) {
        placeholderFn = wt[methods[base] + 1];
        snapshotFn = wt[methods[base + 1] + 1];
        timelineFn = wt[methods[base + 2] + 1];
    }
    void *context = placeholderFn && snapshotFn && timelineFn ? WGMakeContext(family, size) : NULL;
    void *configuration = NULL;
    if (context && box.isAppIntent) configuration = WGAppIntentForConfig(kind, config, proto, wt, providerType);
    else if (context && box.isIntent) configuration = (__bridge void *)WGIntentForConfig(kind, config, proto, wt, providerType); // kept alive there
    if (!context || (box.isIntent && !configuration)) {
        WGLogImportant(@"render %@: setup failed (requirements %d, configuration %p)", kind, nmethods, configuration);
        update(nil, nil, YES);
        return;
    }

    // 1. placeholder(in:): synchronous, shown at once. A refresh skips it (what is shown stays
    //    until the new entry is drawn).
    if (wantPlaceholder) {
        void *placeholder = WGAlloc(entryType);
        ((WGPlaceholderFn)placeholderFn)(placeholder, context, providerType, wt, provider);
        update(WGRenderEntry(generator, generatorType, placeholder, mode), nil, NO);
    }

    // 2. The timeline: asynchronous; the provider may take its time.
    const void *timelineType = timelineAccessor ? timelineAccessor(0, entryType, conformsTo(entryType, entryProto)).metadata : NULL;
    size_t entriesOffset = 0;
    if (!timelineType || !WGStructField(timelineType, "entries", &entriesOffset, NULL)) {
        WGLogImportant(@"render %@: unexpected Timeline layout", kind);
        update(nil, nil, YES);
        return;
    }
    __block BOOL answered = NO;
    void (^show)(NSArray<NSValue *> *, NSString *) = ^(NSArray<NSValue *> *entries, NSString *source) {
        double now = CFAbsoluteTimeGetCurrent(), next = NAN;
        const void *current = entries.count ? entries[0].pointerValue : NULL;
        for (NSValue *v in entries) {
            double d = WGEntryDate(v.pointerValue, entryType);
            if (isnan(d) || d <= now) current = v.pointerValue;
            else if (isnan(next) || d < next) next = d;
        }
        UIViewController *vc = current ? WGRenderEntry(generator, generatorType, current, mode) : nil;
        WGLog(@"%@: %@ with %lu entries, drawn %.0f ms after the request%@", kind, source, (unsigned long)entries.count,
              (CFAbsoluteTimeGetCurrent() - start) * 1000, isnan(next) ? @"" : [NSString stringWithFormat:@" (next in %.0f s)", next - now]);
        update(vc, isnan(next) ? nil : [NSDate dateWithTimeIntervalSinceReferenceDate:next], YES);
    };
    void (^snapshot)(void) = ^{
        uint64_t rid = WGAddRequest(entryType, 0, ^(NSArray<NSValue *> *entries) {
            if (answered) return;
            answered = YES;
            show(entries, @"snapshot");
        });
        if (box.isAppIntent) {
            void *out = WGAlloc(entryType);
            WGStartAsyncCall("$s9WidgetKit25AppIntentTimelineProviderP8snapshot3for2in5EntryQz0D0Qz_AA0eF7ContextVtYaFTjTu", NO, out,
                             configuration, context, providerType, wt, provider, rid);
            return;
        }
        void *ctx = WGMakeCtx(rid);
        if (box.isIntent) ((WGIntentTimelineFn)snapshotFn)(configuration, context, (const void *)WGSnapshotCompletion, ctx, providerType, wt, provider);
        else ((WGTimelineFn)snapshotFn)(context, (const void *)WGSnapshotCompletion, ctx, providerType, wt, provider);
        WGReleaseCtx(ctx);
    };
    NSString *asyncMarker = [NSString stringWithFormat:@"async2-%@-%@", gExt.extensionID, kind];
    if (box.isAppIntent && WGMarkerTripped(asyncMarker)) {
        WGLog(@"%@: its async timeline crashed before; keeping the placeholder", kind);
        update(nil, nil, YES);
        return;
    }
    uint64_t rid = WGAddRequest(entryType, entriesOffset, ^(NSArray<NSValue *> *entries) {
        if (box.isAppIntent) WGMarkerEnd(asyncMarker); // it came back (and is drawn below) without a crash
        if (answered) return;
        if (entries.count == 0) {
            snapshot();
            return;
        }
        answered = YES;
        show(entries, @"timeline");
    });
    if (box.isAppIntent) {
        // timeline(for:in:), in a task of its own. The crash marker goes when it comes back, or
        // after 15 s (a call still waiting has not crashed).
        WGMarkerBegin(asyncMarker);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WGMarkerEnd(asyncMarker); });
        void *out = WGAlloc(timelineType);
        if (!WGStartAsyncCall("$s9WidgetKit25AppIntentTimelineProviderP8timeline3for2inAA0E0Vy5EntryQzG0D0Qz_AA0eF7ContextVtYaFTjTu", YES, out,
                              configuration, context, providerType, wt, provider, rid)) {
            WGMarkerEnd(asyncMarker);
            WGLogImportant(@"%@: cannot start timeline(for:in:)", kind);
        }
    } else {
        void *ctx = WGMakeCtx(rid);
        if (box.isIntent) ((WGIntentTimelineFn)timelineFn)(configuration, context, (const void *)WGTimelineCompletion, ctx, providerType, wt, provider);
        else ((WGTimelineFn)timelineFn)(context, (const void *)WGTimelineCompletion, ctx, providerType, wt, provider);
        WGReleaseCtx(ctx);
    }
    // No answer: a snapshot after 10 s; after 40 s give up and keep what is shown.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!answered) snapshot();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (answered) return;
        answered = YES;
        WGLog(@"%@: no data came back", kind);
        update(nil, nil, YES);
    });
}

#pragma mark - Crash records

static int gCrashFD = -1;
static struct sigaction gOldActions[NSIG];
static NSUncaughtExceptionHandler *gOldExceptionHandler;

static void WGCrashWrite(const char *s) {
    if (gCrashFD >= 0 && s) write(gCrashFD, s, strlen(s));
}

static void WGCrashAddress(const char *label, uintptr_t addr) {
    char line[512];
    Dl_info info;
    if (addr && dladdr((const void *)addr, &info) && info.dli_fname) {
        const char *image = strrchr(info.dli_fname, '/');
        snprintf(line, sizeof line, "  %s %s+0x%lx %s\n", label, image ? image + 1 : info.dli_fname, (unsigned long)(addr - (uintptr_t)info.dli_fbase),
                 info.dli_sname ?: "");
    } else {
        snprintf(line, sizeof line, "  %s 0x%lx\n", label, (unsigned long)addr);
    }
    WGCrashWrite(line);
}

static void WGCrashHandler(int sig, siginfo_t *info, void *uap) {
    char line[256];
    snprintf(line, sizeof line, "\n!! [%s %d] crash: signal %d at %p\n", gExt.appName.UTF8String ?: "?", getpid(), sig, info ? info->si_addr : NULL);
    WGCrashWrite(line);
    ucontext_t *uc = uap;
    if (uc && uc->uc_mcontext) {
        WGCrashAddress("pc", (uintptr_t)uc->uc_mcontext->__ss.__pc & 0x0000000FFFFFFFFFULL);
        WGCrashAddress("lr", (uintptr_t)uc->uc_mcontext->__ss.__lr & 0x0000000FFFFFFFFFULL);
        uintptr_t fp = (uintptr_t)uc->uc_mcontext->__ss.__fp;
        for (int i = 0; i < 24 && fp && (fp & 7) == 0; i++) {
            uintptr_t next = ((uintptr_t *)fp)[0], ret = ((uintptr_t *)fp)[1] & 0x0000000FFFFFFFFFULL;
            if (!ret) break;
            snprintf(line, sizeof line, "#%02d", i);
            WGCrashAddress(line, ret);
            if (next <= fp) break;
            fp = next;
        }
    }
    // Messages left for the crash reporter (Swift's "Fatal error: …").
    for (uint32_t i = 0; i < _dyld_image_count() && i < 4000; i++) {
        unsigned long size = 0;
        const uint8_t *ci = getsectiondata((const struct mach_header_64 *)_dyld_get_image_header(i), "__DATA", "__crash_info", &size);
        if (!ci || size < 40) continue;
        const char *msgs[2] = { *(const char *const *)(ci + 8), *(const char *const *)(ci + 32) };
        for (int k = 0; k < 2; k++) {
            if (!msgs[k] || !msgs[k][0]) continue;
            char m[700];
            snprintf(m, sizeof m, "  message: %.600s\n", msgs[k]);
            WGCrashWrite(m);
        }
    }
    if (sig > 0 && sig < NSIG) sigaction(sig, &gOldActions[sig], NULL);
    raise(sig);
}

static void WGExceptionHandler(NSException *e) {
    char line[700];
    snprintf(line, sizeof line, "\n!! [%s %d] exception %s: %.500s\n", gExt.appName.UTF8String ?: "?", getpid(), e.name.UTF8String ?: "?",
             e.reason.UTF8String ?: "");
    WGCrashWrite(line);
    NSArray *symbols = e.callStackSymbols;
    for (NSUInteger i = 0; i < MIN(symbols.count, (NSUInteger)20); i++) {
        snprintf(line, sizeof line, "  %s\n", [symbols[i] UTF8String]);
        WGCrashWrite(line);
    }
    if (gOldExceptionHandler) gOldExceptionHandler(e);
}

#pragma mark - API

@implementation WGRuntime

+ (void)loadExtension:(WGExtension *)extension completion:(void (^)(NSArray<NSDictionary *> *, NSString *))completion {
    gExt = extension;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        NSString *exe = extension.executablePath.lastPathComponent, *copy = nil;
        const struct mach_header *mh = WGLoadBundleCopy(extension.extensionPath, exe, WGExtensionWorkDir(), &copy);
        WGSharedDataFindGroups(extension, WGExtensionWorkDir());
        // The Intents extension is only for its defaults: not loaded when they are cached, or
        // when that crashed before.
        if (mh && !WGHasIntentCache() && !WGMarkerTripped([@"intent-defaults-" stringByAppendingString:extension.extensionID])) {
            NSDictionary *info = nil;
            NSString *path = WGIntentsExtensionPath(&info, nil);
            if (path) WGLoadIntentsExtension(path, info);
        }
        double loadMS = (CFAbsoluteTimeGetCurrent() - t0) * 1000;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!mh) {
                completion(@[], @"the extension could not be loaded");
                return;
            }
            gCopyPath = copy;
            WGInstallMainBundle(copy);
            WGSharedDataSetUp(extension, WGExtensionWorkDir());
            CFAbsoluteTime t1 = CFAbsoluteTimeGetCurrent();
            gWidgets = WGReadWidgets(mh);
            WGLog(@"loaded in %.0f ms, %lu widget(s) read in %.0f ms", loadMS, (unsigned long)gWidgets.count, (CFAbsoluteTimeGetCurrent() - t1) * 1000);
            completion(gWidgets, nil);
        });
    });
}

+ (NSArray<NSDictionary *> *)widgets {
    return gWidgets ?: @[];
}

+ (void)renderKind:(NSString *)kind config:(NSString *)config family:(WGFamily)family size:(CGSize)size placeholder:(BOOL)placeholder
              mode:(WGRenderMode)mode update:(WGRenderUpdate)update {
    WGRender(kind, config, family, size, placeholder, mode, update);
}

// Where iOS performs a widget button's intent: in the extension's process, unless the intent
// has openAppWhenRun (the app opens and runs it), or adopts LiveActivityIntent,
// AudioPlaybackIntent or PushToTalkTransmissionIntent (it runs in the app's process, in the
// background: the app does not open). A ForegroundContinuableIntent may continue in the app
// (listed apart: the widget host treats it as the app's). The extension's
// Metadata.appintents lists its intents with those traits.
+ (NSDictionary<NSString *, NSArray<NSString *> *> *)intentPlacement {
    static NSDictionary *result;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *data = [NSData dataWithContentsOfFile:[gExt.extensionPath stringByAppendingPathComponent:@"Metadata.appintents/extract.actionsdata"]];
        NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *actions = [root isKindOfClass:[NSDictionary class]] ? root[@"actions"] : nil;
        NSMutableArray *opensApp = [NSMutableArray array], *inAppBackground = [NSMutableArray array], *here = [NSMutableArray array],
                       *continuable = [NSMutableArray array];
        for (NSString *name in [actions isKindOfClass:[NSDictionary class]] ? actions : @{}) {
            NSDictionary *a = actions[name];
            if (![a isKindOfClass:[NSDictionary class]]) continue;
            NSArray *protocols = [a[@"systemProtocols"] isKindOfClass:[NSArray class]] ? a[@"systemProtocols"] : @[];
            NSString *joined = [protocols componentsJoinedByString:@" "];
            // Widget / control configuration intents are settings, not actions.
            if ([joined containsString:@"WidgetConfiguration"] || [joined containsString:@"ControlConfiguration"]) continue;
            if ([a[@"openAppWhenRun"] boolValue]) [opensApp addObject:name];
            else if ([joined containsString:@"LiveActivity"] || [joined containsString:@"AudioPlayback"] || [joined containsString:@"PushToTalk"])
                [inAppBackground addObject:name];
            else [here addObject:name];
            if ([joined containsString:@"ForegroundContinuable"]) [continuable addObject:name];
            WGLog(@"intent %@: %@%@", name, [a[@"openAppWhenRun"] boolValue] ? @"opens the app; " : @"", joined.length ? joined : @"-");
        }
        result = @{ @"opensApp" : [opensApp sortedArrayUsingSelector:@selector(compare:)],
                    @"inAppBackground" : [inAppBackground sortedArrayUsingSelector:@selector(compare:)],
                    @"here" : [here sortedArrayUsingSelector:@selector(compare:)],
                    @"foregroundContinuable" : [continuable sortedArrayUsingSelector:@selector(compare:)] };
    });
    return result;
}

+ (void)installCrashLog {
    if (gCrashFD >= 0) return;
    gCrashFD = open(WGLogPath().fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = WGCrashHandler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    const int signals[] = { SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE };
    for (size_t i = 0; i < sizeof signals / sizeof signals[0]; i++) sigaction(signals[i], &sa, &gOldActions[signals[i]]);
    gOldExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(WGExceptionHandler);
}

@end
