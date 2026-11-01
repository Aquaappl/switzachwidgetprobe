// SwitzachWidgetLinks
// The app side of widget links. On iOS, a Link inside a widget opens its app with the URL
// (for example youtube://feed/subscriptions). The ROM (Nyxian) can only open an app, not hand
// it a URL, so SwitzachWidgetProbe in SpringBoard leaves the URL for the app and opens it;
// this library, loaded into apps, picks the URL up when the app comes to the front and gives
// it to the app the way iOS would (scene:openURLContexts: / application:openURL:options:).

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const kWLFile = @"Library/Caches/com.rinapple.widgetlink.plist";
static NSString *const kWLSeen = @"Library/Caches/com.rinapple.widgetlink.seen";

// Where SpringBoard may have left the URL: the app's own data container, and the shared
// folder next to it (…/var/mobile/Library/Caches/SwitzachWidgetProbe/links/<bundle>.plist).
static NSArray<NSString *> *WLCandidates(void) {
    NSString *home = NSHomeDirectory();
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSString *mobile = home.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent
                           .stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    NSString *shared = [mobile stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"Library/Caches/SwitzachWidgetProbe/links/%@.plist", bundleID]];
    return @[ [home stringByAppendingPathComponent:kWLFile], shared ];
}

// The URL waiting for this app (a fresh one, left for this bundle), and the files holding it.
static NSURL *WLPendingURL(NSMutableArray<NSString *> *files) {
    NSURL *found = nil;
    double newest = 0;
    for (NSString *path in WLCandidates()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        if (!d) continue;
        [files addObject:path];
        double at = [d[@"time"] doubleValue];
        NSString *app = d[@"app"];
        if ([app isKindOfClass:[NSString class]] && ![app isEqualToString:NSBundle.mainBundle.bundleIdentifier]) continue;
        if (CFAbsoluteTimeGetCurrent() - at > 45 || at <= newest) continue;
        NSURL *url = [d[@"url"] isKindOfClass:[NSString class]] ? [NSURL URLWithString:d[@"url"]] : nil;
        if (url) {
            found = url;
            newest = at;
        }
    }
    return found;
}

static BOOL WLDeliverToScenes(NSURL *url) {
    Class contextClass = NSClassFromString(@"UIOpenURLContext");
    Class optionsClass = NSClassFromString(@"UISceneOpenURLOptions");
    if (!contextClass) return NO;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        id delegate = scene.delegate;
        if (![delegate respondsToSelector:@selector(scene:openURLContexts:)]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive && UIApplication.sharedApplication.connectedScenes.count > 1) continue;
        @try {
            // UIOpenURLContext has no public initializer; fill in its read-only properties.
            id context = ((id (*)(id, SEL))objc_msgSend)([contextClass alloc], @selector(init));
            [context setValue:url forKey:@"URL"];
            id options = optionsClass ? ((id (*)(id, SEL))objc_msgSend)([optionsClass alloc], @selector(init)) : nil;
            if (options) [context setValue:options forKey:@"options"];
            [delegate scene:scene openURLContexts:[NSSet setWithObject:context]];
            NSLog(@"[WidgetLinks] scene:openURLContexts: %@", url);
            return YES;
        } @catch (NSException *e) {
            NSLog(@"[WidgetLinks] scene delivery failed: %@", e.reason);
        }
    }
    return NO;
}

static BOOL WLDeliverToAppDelegate(NSURL *url) {
    id<UIApplicationDelegate> delegate = UIApplication.sharedApplication.delegate;
    if (![delegate respondsToSelector:@selector(application:openURL:options:)]) return NO;
    @try {
        [delegate application:UIApplication.sharedApplication openURL:url options:@{}];
        NSLog(@"[WidgetLinks] application:openURL:options: %@", url);
        return YES;
    } @catch (NSException *e) {
        NSLog(@"[WidgetLinks] app delegate delivery failed: %@", e.reason);
        return NO;
    }
}

// Delivered once: the files go when the app took the URL (or when it is stale).
static void WLDeliverPending(void) {
    NSMutableArray *files = [NSMutableArray array];
    NSURL *url = WLPendingURL(files);
    BOOL done = !url || WLDeliverToScenes(url) || WLDeliverToAppDelegate(url);
    if (done) for (NSString *f in files) [[NSFileManager defaultManager] removeItemAtPath:f error:nil];
}

// After the app (or its scene) becomes active: a moment later, so a freshly launched app has
// set up its windows and routing first.
static void WLSchedule(NSNotification *note) {
    for (NSNumber *delay in @[ @0.4, @1.5 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WLDeliverPending();
        });
    }
}

__attribute__((constructor)) static void WLInit(void) {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    // SpringBoard (the ROM's home screen) is the sender, not a receiver; nor is a widget host.
    if (!bundleID || [bundleID isEqualToString:@"com.apple.springboard"] || objc_getClass("NXHomeScreenViewController") ||
        [bundleID isEqualToString:@"com.rinapple.switzachwidgetprobe.host"]) return;
    // Tells SpringBoard that links can reach this app.
    NSString *seen = [NSHomeDirectory() stringByAppendingPathComponent:kWLSeen];
    [[NSFileManager defaultManager] createDirectoryAtPath:seen.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [@"1" writeToFile:seen atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { WLSchedule(n); }];
    [nc addObserverForName:UISceneDidActivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { WLSchedule(n); }];
}
