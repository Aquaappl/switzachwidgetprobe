// The app's shared data, for its widget.
//
// Switzach has no shared containers: App Groups, suite defaults and CFPreferences of a group
// resolve per process. The widget host is not the app, so these are pointed at the app's own
// data container, where the app keeps them — the widget then reads what the app wrote. Writes
// to that data are watched: the widgets refresh as if the app had called
// WidgetCenter.reloadTimelines (Switzach has no chronod to tell).

#import "WGSharedData.h"
#import "WGRuntime.h"
#import <fcntl.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSDictionary<NSString *, NSString *> *gGroupData; // group → app data container
static NSArray<NSString *> *gGroups;
static CFAbsoluteTime gLastRender;

#pragma mark - Finding the groups

// From the signature's entitlements, when the re-signed binary still has them.
static NSArray<NSString *> *WGGroupsInEntitlements(NSData *data) {
    NSData *key = [@"<key>com.apple.security.application-groups</key>" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange r = [data rangeOfData:key options:NSDataSearchBackwards range:NSMakeRange(0, data.length)];
    if (r.location == NSNotFound) return @[];
    NSUInteger start = NSMaxRange(r);
    NSRange e = [data rangeOfData:[@"</array>" dataUsingEncoding:NSUTF8StringEncoding] options:0
                            range:NSMakeRange(start, MIN((NSUInteger)4096, data.length - start))];
    if (e.location == NSNotFound) return @[];
    NSString *chunk = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(start, e.location - start)] encoding:NSUTF8StringEncoding];
    NSMutableArray *groups = [NSMutableArray array];
    for (NSString *part in [chunk componentsSeparatedByString:@"<string>"]) {
        NSRange close = [part rangeOfString:@"</string>"];
        if (close.location != NSNotFound) [groups addObject:[part substringToIndex:close.location]];
    }
    return groups;
}

// "group.…" identifiers named in a binary: the code that opens a shared container names it.
static void WGGroupStrings(NSData *data, NSMutableSet *found) {
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
}

// Reading every binary of the app takes a while: the answer is kept until the build changes.
static NSArray<NSString *> *WGFindGroups(WGExtension *ext, NSString *workDir) {
    NSString *cachePath = [workDir stringByAppendingPathComponent:@".wg-groups"];
    NSString *stamp = ext.buildStamp;
    NSArray *lines = [[NSString stringWithContentsOfFile:cachePath encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"];
    if (lines.count >= 1 && [lines[0] isEqualToString:stamp]) {
        return [[lines subarrayWithRange:NSMakeRange(1, lines.count - 1)] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    }
    NSMutableSet *groups = [NSMutableSet set];
    NSData *exe = [NSData dataWithContentsOfFile:ext.executablePath options:NSDataReadingMappedIfSafe error:nil];
    if (exe) {
        [groups addObjectsFromArray:WGGroupsInEntitlements(exe)];
        WGGroupStrings(exe, groups);
    }
    NSString *frameworks = [ext.appPath stringByAppendingPathComponent:@"Frameworks"];
    for (NSString *fw in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:frameworks error:nil]) {
        if (![fw.pathExtension isEqualToString:@"framework"]) continue;
        NSString *bin = [[frameworks stringByAppendingPathComponent:fw] stringByAppendingPathComponent:fw.stringByDeletingPathExtension];
        NSData *d = [NSData dataWithContentsOfFile:bin options:NSDataReadingMappedIfSafe error:nil];
        if (d) WGGroupStrings(d, groups);
    }
    NSArray *sorted = [groups.allObjects sortedArrayUsingSelector:@selector(compare:)];
    [[NSFileManager defaultManager] createDirectoryAtPath:workDir withIntermediateDirectories:YES attributes:nil error:nil];
    [[[@[ stamp ] arrayByAddingObjectsFromArray:sorted] componentsJoinedByString:@"\n"] writeToFile:cachePath atomically:NO
                                                                                          encoding:NSUTF8StringEncoding error:nil];
    return sorted;
}

// Where Nyxian keeps an app's group container inside its data container.
static NSString *WGGroupPath(NSString *dataPath, NSString *group) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *nyxian = [NSString stringWithFormat:@"%@/Documents/(null)/Documents/AppGroup/%@", dataPath, group];
    NSString *plain = [NSString stringWithFormat:@"%@/Documents/AppGroup/%@", dataPath, group];
    if ([fm fileExistsAtPath:plain] && ![fm fileExistsAtPath:nyxian]) return plain;
    return nyxian;
}

#pragma mark - Redirecting

static IMP gOrigContainerURL, gOrigPrefsInit, gOrigSuiteInit;

static NSURL *WGContainerURLHook(id self, SEL _cmd, NSString *group) {
    NSString *data = group ? gGroupData[group] : nil;
    if (!data) return ((NSURL * (*)(id, SEL, NSString *)) gOrigContainerURL)(self, _cmd, group);
    NSString *path = WGGroupPath(data, group);
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

// Replacements of init methods follow init's ownership: self consumed, result retained.
#define WG_INIT_ATTRS __attribute__((ns_returns_retained))
typedef id (*WGPrefsInitFn)(__attribute__((ns_consumed)) id, SEL, CFStringRef, CFStringRef, bool, CFStringRef, id) WG_INIT_ATTRS;

static id WGPrefsInitHook(__attribute__((ns_consumed)) id self, SEL _cmd, CFStringRef domain, CFStringRef user, bool byHost,
                          CFStringRef containerPath, id containing) WG_INIT_ATTRS {
    NSString *data = domain ? gGroupData[(__bridge NSString *)domain] : nil;
    if (!data) return ((WGPrefsInitFn)gOrigPrefsInit)(self, _cmd, domain, user, byHost, containerPath, containing);
    if (user == kCFPreferencesAnyUser) user = kCFPreferencesCurrentUser;
    // Nyxian's own hook replaces the container path with the process home; its original
    // implementation is kept under the hook's selector.
    SEL original = NSSelectorFromString(@"hook_initWithDomain:user:byHost:containerPath:containingPreferences:");
    if ([self respondsToSelector:original]) {
        return ((WGPrefsInitFn)objc_msgSend)(self, original, domain, user, byHost, (__bridge CFStringRef)data, containing);
    }
    return ((WGPrefsInitFn)gOrigPrefsInit)(self, _cmd, domain, user, byHost, (__bridge CFStringRef)data, containing);
}

// Suite defaults of an App Group, read from and written to the app's own plist file, so
// nothing goes through CFPreferences' per-process view.
@interface WGGroupDefaults : NSUserDefaults
@end

@implementation WGGroupDefaults {
    NSString *_path;
    NSMutableDictionary *_values;
    NSDate *_loaded;
    NSLock *_lock;
}

- (instancetype)initWithGroup:(NSString *)group path:(NSString *)path {
    if ((self = [super initWithSuiteName:[@"com.rinapple.widgetprobe.shadow." stringByAppendingString:group]])) {
        _path = [path copy];
        _lock = [NSLock new];
    }
    return self;
}

- (NSDictionary *)wg_values {
    [_lock lock];
    NSDate *m = [[NSFileManager defaultManager] attributesOfItemAtPath:_path error:nil][NSFileModificationDate];
    if (!_values || (m && ![m isEqualToDate:_loaded])) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:_path];
        _values = d ? [d mutableCopy] : (_values ?: [NSMutableDictionary dictionary]);
        _loaded = m;
    }
    NSDictionary *copy = [_values copy];
    [_lock unlock];
    return copy;
}

- (void)wg_change:(void (^)(NSMutableDictionary *values))change {
    [self wg_values];
    [_lock lock];
    change(_values);
    [[NSFileManager defaultManager] createDirectoryAtPath:_path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:_values format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    [data writeToFile:_path atomically:YES];
    _loaded = [[NSFileManager defaultManager] attributesOfItemAtPath:_path error:nil][NSFileModificationDate];
    [_lock unlock];
}

- (id)objectForKey:(NSString *)key { return key ? [self wg_values][key] : nil; }
- (void)setObject:(id)value forKey:(NSString *)key {
    if (!key) return;
    [self wg_change:^(NSMutableDictionary *v) {
        if (value) v[key] = value;
        else [v removeObjectForKey:key];
    }];
}
- (void)removeObjectForKey:(NSString *)key { [self setObject:nil forKey:key]; }
- (NSDictionary *)dictionaryRepresentation { return [self wg_values]; }
- (BOOL)synchronize { [self wg_values]; return YES; }
- (NSString *)stringForKey:(NSString *)key {
    id v = [self objectForKey:key];
    return [v isKindOfClass:[NSString class]] ? v : [v isKindOfClass:[NSNumber class]] ? [v stringValue] : nil;
}
- (NSData *)dataForKey:(NSString *)key { id v = [self objectForKey:key]; return [v isKindOfClass:[NSData class]] ? v : nil; }
- (NSArray *)arrayForKey:(NSString *)key { id v = [self objectForKey:key]; return [v isKindOfClass:[NSArray class]] ? v : nil; }
- (NSDictionary *)dictionaryForKey:(NSString *)key { id v = [self objectForKey:key]; return [v isKindOfClass:[NSDictionary class]] ? v : nil; }
- (NSArray *)stringArrayForKey:(NSString *)key { return [self arrayForKey:key]; }
- (BOOL)boolForKey:(NSString *)key { id v = [self objectForKey:key]; return [v respondsToSelector:@selector(boolValue)] && [v boolValue]; }
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
    [self wg_values];
    [_lock lock];
    for (NSString *k in defaults) if (!_values[k]) _values[k] = defaults[k];
    [_lock unlock];
}
@end

typedef id (*WGSuiteInitFn)(__attribute__((ns_consumed)) id, SEL, NSString *) WG_INIT_ATTRS;

static id WGSuiteInitHook(__attribute__((ns_consumed)) NSUserDefaults *self, SEL _cmd, NSString *suite) WG_INIT_ATTRS {
    NSString *data = [suite isKindOfClass:[NSString class]] ? gGroupData[suite] : nil;
    if (!data || [self isKindOfClass:[WGGroupDefaults class]]) return ((WGSuiteInitFn)gOrigSuiteInit)(self, _cmd, suite);
    // self (the allocated NSUserDefaults) is released by ARC; the replacement is returned +1.
    NSString *path = [NSString stringWithFormat:@"%@/Library/Preferences/%@.plist", data, suite];
    return [[WGGroupDefaults alloc] initWithGroup:suite path:path];
}

static void WGInstallHooks(void) {
    Method m = class_getInstanceMethod([NSFileManager class], @selector(containerURLForSecurityApplicationGroupIdentifier:));
    if (m) gOrigContainerURL = method_setImplementation(m, (IMP)WGContainerURLHook);
    Class prefs = NSClassFromString(@"CFPrefsPlistSource");
    Method p = prefs ? class_getInstanceMethod(prefs, NSSelectorFromString(@"initWithDomain:user:byHost:containerPath:containingPreferences:")) : NULL;
    if (p) gOrigPrefsInit = method_setImplementation(p, (IMP)WGPrefsInitHook);
    Method s = class_getInstanceMethod([NSUserDefaults class], @selector(initWithSuiteName:));
    if (s) gOrigSuiteInit = method_setImplementation(s, (IMP)WGSuiteInitHook);
    WGLog(@"shared data: container %d, preferences %d, suites %d", m != NULL, p != NULL, s != NULL);
}

#pragma mark - Watching

static void WGWatch(NSString *path) {
    static NSMutableArray *sources;
    if (!sources) sources = [NSMutableArray array];
    int fd = open(path.fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) return;
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd,
                                                   DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_ATTRIB,
                                                   dispatch_get_main_queue());
    __block BOOL pending = NO;
    dispatch_source_set_event_handler(src, ^{
        if (pending) return;
        pending = YES;
        // Writes come in bursts: once, a moment after the first.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            pending = NO;
            // What the widget itself writes while it draws is not news.
            if (CFAbsoluteTimeGetCurrent() - gLastRender < 5) return;
            for (NSString *g in gGroups) CFPreferencesAppSynchronize((__bridge CFStringRef)g);
            WGLog(@"the app's shared data changed");
            [[NSNotificationCenter defaultCenter] postNotificationName:WGRuntimeDataChangedNotification object:nil];
        });
    });
    dispatch_source_set_cancel_handler(src, ^{ close(fd); });
    dispatch_resume(src);
    [sources addObject:src];
}

#pragma mark - API

void WGSharedDataFindGroups(WGExtension *ext, NSString *workDir) {
    WGFindGroups(ext, workDir);
}

void WGSharedDataSetUp(WGExtension *ext, NSString *workDir) {
    if (gGroups || !ext.dataPath.length) return;
    gGroups = WGFindGroups(ext, workDir);
    if (gGroups.count == 0) return;
    WGLog(@"App Groups: %@", [gGroups componentsJoinedByString:@", "]);
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (NSString *g in gGroups) map[g] = ext.dataPath;
    gGroupData = map;
    WGInstallHooks();
    WGWatch([ext.dataPath stringByAppendingPathComponent:@"Library/Preferences"]);
    for (NSString *g in gGroups) {
        NSString *path = WGGroupPath(ext.dataPath, g);
        [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
        WGWatch(path);
    }
}

void WGSharedDataWillRender(void) {
    gLastRender = CFAbsoluteTimeGetCurrent();
    for (NSString *g in gGroups) CFPreferencesAppSynchronize((__bridge CFStringRef)g);
}
