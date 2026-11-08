// Small helpers, opening apps, and handing a widget link to its app.

#import "WGSpringBoard.h"

#pragma mark - Objective-C helpers

id WGCall(id obj, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

id WGCall1(id obj, NSString *selector, id arg) {
    SEL sel = NSSelectorFromString(selector);
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(obj, sel, arg);
}

void WGSend1(id obj, NSString *selector, id arg) {
    SEL sel = NSSelectorFromString(selector);
    if (obj && [obj respondsToSelector:sel]) ((void (*)(id, SEL, id))objc_msgSend)(obj, sel, arg);
}

BOOL WGCallBool(id obj, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (!obj || ![obj respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(obj, sel);
}

BOOL WGHook(NSString *className, NSString *selector, IMP replacement, IMP *original) {
    Class cls = NSClassFromString(className);
    SEL sel = NSSelectorFromString(selector);
    Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!m) {
        WGLog(@"Not hooked (not found): -[%@ %@]", className, selector);
        return NO;
    }
    class_addMethod(cls, sel, method_getImplementation(m), method_getTypeEncoding(m));
    m = class_getInstanceMethod(cls, sel);
    *original = method_setImplementation(m, replacement);
    return YES;
}

#pragma mark - Opening apps

// As the ROM opens an app: from its icon.
void WGLaunchApp(NSString *bundleID) {
    static CFAbsoluteTime last;
    static NSString *lastID;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - last < 0.8 && [lastID isEqualToString:bundleID]) return; // one tap, seen twice
    last = now;
    lastID = bundleID;
    id manager = WGIconManager();
    id leaf = WGCall1(WGCall(manager, @"delegate"), @"nativeIconForBundleIdentifier:", bundleID) ?:
              WGCall1(WGCall(manager, @"iconModel"), @"leafIconForIdentifier:", bundleID);
    SEL launch = NSSelectorFromString(@"performLaunchFromLocation:context:");
    if (![leaf respondsToSelector:launch]) {
        WGLogImportant(@"Cannot open %@", bundleID);
        return;
    }
    WGLog(@"Open %@", bundleID);
    ((void (*)(id, SEL, id, id))objc_msgSend)(leaf, launch, @"SBIconLocationRoot", nil);
}

#pragma mark - Widget links

// Switzach can open an app but cannot hand it a URL. The URL is left where
// SwitzachWidgetLinks (loaded into the app) picks it up once the app is in front — in the app's
// data container and in a shared folder — and the app is opened.
void WGOpenWidgetURL(NSURL *url, WGExtension *source) {
    WGExtension *target = [WGExtensions extensionForURL:url] ?: source;
    if (!target || !url.absoluteString) return;
    NSDictionary *entry = @{ @"url" : url.absoluteString, @"app" : target.appID, @"time" : @(CFAbsoluteTimeGetCurrent()) };
    NSString *appID = target.appID, *dataPath = target.dataPath;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *shared = WGWorkPath(@"links");
        [fm createDirectoryAtPath:shared withIntermediateDirectories:YES attributes:nil error:nil];
        [entry writeToFile:[shared stringByAppendingPathComponent:[appID stringByAppendingString:@".plist"]] atomically:YES];
        BOOL receiver = NO;
        if (dataPath) {
            NSString *caches = [dataPath stringByAppendingPathComponent:@"Library/Caches"];
            [fm createDirectoryAtPath:caches withIntermediateDirectories:YES attributes:nil error:nil];
            [entry writeToFile:[caches stringByAppendingPathComponent:@"com.rinapple.widgetlink.plist"] atomically:YES];
            receiver = [fm fileExistsAtPath:[caches stringByAppendingPathComponent:@"com.rinapple.widgetlink.seen"]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            WGLog(@"Widget link %@ → %@%@", url, appID, receiver ? @"" : @" (SwitzachWidgetLinks has not run in that app yet)");
            WGLaunchApp(appID);
        });
    });
}
