// Finding the widget extensions of the installed apps.
//
// LaunchServices lists the apps; each app's PlugIns folder is looked through for
// NSExtensionPointIdentifier = com.apple.widgetkit-extension. The list is saved
// (extensions.plist), so SpringBoardHome's questions while it builds the home screen ("is this
// widget valid?") are answered at once; it is refreshed in the background a little after launch
// and whenever the gallery opens.

#import "WGSpringBoard.h"

static NSDictionary<NSString *, WGExtension *> *gAll;
static NSDictionary<NSString *, WGExtension *> *gByScheme;

static NSString *WGListPath(void) {
    return WGWorkPath(@"extensions.plist");
}

static void WGSetAll(NSDictionary<NSString *, WGExtension *> *all) {
    gAll = [all copy];
    NSMutableDictionary *schemes = [NSMutableDictionary dictionary];
    for (WGExtension *e in all.allValues) {
        for (NSString *s in e.urlSchemes) schemes[s] = e;
    }
    gByScheme = schemes;
}

// LaunchServices' view of the apps (main thread): plain values only.
static NSArray<NSDictionary *> *WGInstalledApps(void) {
    NSMutableArray *apps = [NSMutableArray array];
    @try {
        id workspace = WGCall(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
        NSArray *proxies = WGCall(workspace, @"allInstalledApplications") ?: WGCall(workspace, @"allApplications");
        for (id proxy in [proxies isKindOfClass:[NSArray class]] ? proxies : @[]) {
            NSURL *bundle = nil, *data = nil;
            NSString *bundleID = nil, *name = nil;
            @try {
                bundle = [proxy valueForKey:@"bundleURL"];
                bundleID = [proxy valueForKey:@"bundleIdentifier"];
                name = [proxy valueForKey:@"localizedName"];
                data = [proxy valueForKey:@"dataContainerURL"];
            } @catch (NSException *e) {
            }
            if (![bundle isKindOfClass:[NSURL class]] || ![bundleID isKindOfClass:[NSString class]]) continue;
            NSMutableDictionary *app = [@{ @"path" : bundle.path, @"id" : bundleID, @"name" : [name isKindOfClass:[NSString class]] ? name : bundleID } mutableCopy];
            if ([data isKindOfClass:[NSURL class]]) app[@"data"] = data.path;
            [apps addObject:app];
        }
    } @catch (NSException *e) {
        WGLogImportant(@"LaunchServices: %@", e.reason);
    }
    return apps;
}

// The widget extensions in the apps' bundles (any thread).
static NSDictionary<NSString *, WGExtension *> *WGScanApps(NSArray<NSDictionary *> *apps) {
    NSMutableDictionary *found = [NSMutableDictionary dictionary];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSDictionary *app in apps) {
        NSString *plugins = [app[@"path"] stringByAppendingPathComponent:@"PlugIns"];
        NSArray *items = [fm contentsOfDirectoryAtPath:plugins error:nil];
        if (!items.count) continue;
        NSArray *schemes = nil;
        for (NSString *item in items) {
            if (![item.pathExtension isEqualToString:@"appex"]) continue;
            NSString *extPath = [plugins stringByAppendingPathComponent:item];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[extPath stringByAppendingPathComponent:@"Info.plist"]];
            NSDictionary *ns = [info[@"NSExtension"] isKindOfClass:[NSDictionary class]] ? info[@"NSExtension"] : nil;
            if (![ns[@"NSExtensionPointIdentifier"] isEqual:@"com.apple.widgetkit-extension"]) continue;
            if (!schemes) {
                NSMutableArray *list = [NSMutableArray array];
                NSDictionary *appInfo = [NSDictionary dictionaryWithContentsOfFile:[app[@"path"] stringByAppendingPathComponent:@"Info.plist"]];
                for (NSDictionary *type in [appInfo[@"CFBundleURLTypes"] isKindOfClass:[NSArray class]] ? appInfo[@"CFBundleURLTypes"] : @[]) {
                    if (![type isKindOfClass:[NSDictionary class]]) continue;
                    for (NSString *s in [type[@"CFBundleURLSchemes"] isKindOfClass:[NSArray class]] ? type[@"CFBundleURLSchemes"] : @[]) {
                        if ([s isKindOfClass:[NSString class]] && s.length) [list addObject:s.lowercaseString];
                    }
                }
                schemes = list;
            }
            NSString *exe = [info[@"CFBundleExecutable"] isKindOfClass:[NSString class]] ? info[@"CFBundleExecutable"] : item.stringByDeletingPathExtension;
            WGExtension *e = [WGExtension extensionWithPlist:@{
                @"extensionID" : [info[@"CFBundleIdentifier"] isKindOfClass:[NSString class]] ? info[@"CFBundleIdentifier"] : item,
                @"appID" : app[@"id"], @"appName" : app[@"name"], @"appPath" : app[@"path"], @"extensionPath" : extPath,
                @"executablePath" : [extPath stringByAppendingPathComponent:exe], @"dataPath" : app[@"data"] ?: @"", @"urlSchemes" : schemes
            }];
            if (e) found[e.extensionID] = e;
        }
    }
    return found;
}

static void WGSave(NSDictionary<NSString *, WGExtension *> *all) {
    NSMutableArray *list = [NSMutableArray array];
    for (WGExtension *e in all.allValues) [list addObject:e.plist];
    [list writeToFile:WGListPath() atomically:YES];
}

@implementation WGExtensions

+ (NSDictionary<NSString *, WGExtension *> *)all {
    if (gAll) return gAll;
    NSMutableDictionary *saved = [NSMutableDictionary dictionary];
    for (NSDictionary *d in [NSArray arrayWithContentsOfFile:WGListPath()] ?: @[]) {
        WGExtension *e = [WGExtension extensionWithPlist:d];
        if (e) saved[e.extensionID] = e;
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:WGListPath()]) {
        WGSetAll(saved);
    } else {
        // The first launch with the tweak: found right away.
        WGSetAll(WGScanApps(WGInstalledApps()));
        WGSave(gAll);
    }
    // And looked at again once the home screen is up.
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self refresh:nil]; });
    });
    return gAll;
}

+ (WGExtension *)extensionWithID:(NSString *)extensionID {
    return [extensionID isKindOfClass:[NSString class]] ? [self all][extensionID] : nil;
}

+ (void)refresh:(void (^)(void))completion {
    NSArray *apps = WGInstalledApps();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *found = WGScanApps(apps);
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL changed = ![[NSSet setWithArray:found.allKeys] isEqualToSet:[NSSet setWithArray:gAll.allKeys ?: @[]]];
            // Same extensions: keep the objects (hosts are keyed by them), take new paths.
            NSMutableDictionary *merged = [NSMutableDictionary dictionary];
            for (NSString *key in found) {
                WGExtension *old = gAll[key], *now = found[key];
                if (old && [old.plist isEqualToDictionary:now.plist]) merged[key] = old;
                else {
                    merged[key] = now;
                    changed = YES;
                }
            }
            WGSetAll(merged);
            if (changed) {
                WGSave(merged);
                WGLog(@"Widget extensions: %@", [[merged.allValues valueForKey:@"appName"] componentsJoinedByString:@", "]);
            }
            if (completion) completion();
        });
    });
}

+ (WGExtension *)extensionForURL:(NSURL *)url {
    NSString *scheme = url.scheme.lowercaseString;
    if (!scheme.length) return nil;
    [self all];
    return gByScheme[scheme];
}

@end
