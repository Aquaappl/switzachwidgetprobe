// Places widgets of ROM-installed apps on the Switzach home screen.
//
// SpringBoardHome already models widgets as grid icons (SBWidgetIcon holding SBHWidget
// data sources). What the ROM lacks is the system widget renderer (chronod), so:
//   - "+ > Add Widget" inserts a native SBWidgetIcon into the current page,
//   - SBHIconManager's custom image view controller for those icons is replaced with one
//     that loads the app's widget extension in-process and draws its timeline entry,
//   - widget validation hooks keep SpringBoardHome from discarding widgets that chronod
//     does not know about.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import "WPProbe.h"

typedef struct {
    CGSize size;
    double scale;
    double continuousCornerRadius;
} SBIconImageInfo;

#pragma mark - Logging

BOOL WPDiagnosticLogEnabled(void); // WPSettings.m

static void WPHLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void WPHLog(NSString *fmt, ...) {
    if (!WPDiagnosticLogEnabled()) return; // the diagnostic log is off (the default)
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[WidgetProbe] %@", line);
    static NSDateFormatter *df;
    if (!df) {
        df = [NSDateFormatter new];
        df.dateFormat = @"HH:mm:ss.SSS";
    }
    NSString *stamped = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], line];
    int fd = open([WPProbe runtimeLogPath].fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        NSData *d = [stamped dataUsingEncoding:NSUTF8StringEncoding];
        write(fd, d.bytes, d.length);
        close(fd);
    }
}

static id WPMsg(id obj, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

#pragma mark - Boot guard

// If SpringBoard keeps dying soon after starting, stop drawing widgets for one boot so
// they can be removed from the home screen.
static BOOL gWPGuardTripped;

static NSString *WPGuardPath(void) {
    return [[[WPProbe reportPath] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"boot-guard"];
}

static void WPGuardBoot(void) {
    NSString *path = WPGuardPath();
    int count = [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] intValue];
    gWPGuardTripped = count >= 2;
    // Plain writes: an atomic one also changes file modes, and the ROM's system call relay
    // has been seen to hold that up for 12 seconds.
    [[NSString stringWithFormat:@"%d", count + 1] writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    WPHLog(@"==== Launch (unfinished launches just before: %d%@)", count, gWPGuardTripped ? @"; widgets are not drawn this time, for safety" : @"");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [@"0" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ WPHLog(@"Launch is stable"); });
    });
}

#pragma mark - Known widget extensions

static NSDictionary<NSString *, WPWidgetExtension *> *WPKnownExtensions(BOOL refresh) {
    static NSDictionary *cache;
    if (!cache || refresh) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (WPWidgetExtension *e in [WPProbe findWidgetExtensionsWithLog:[NSMutableString string]]) d[e.extensionBundleID] = e;
        cache = d;
    }
    return cache;
}

static WPWidgetExtension *WPExtensionForID(NSString *extID) {
    if (![extID isKindOfClass:[NSString class]]) return nil;
    WPWidgetExtension *e = WPKnownExtensions(NO)[extID];
    return e;
}

static NSString *WPExtIDOf(id widgetLike) {
    id v = WPMsg(widgetLike, @"extensionBundleIdentifier");
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static id WPPrimaryWidget(id icon) {
    if (![icon respondsToSelector:NSSelectorFromString(@"isWidgetIcon")]) return nil;
    if (!((BOOL (*)(id, SEL))objc_msgSend)(icon, NSSelectorFromString(@"isWidgetIcon"))) return nil;
    id w = WPMsg(icon, @"activeWidget");
    if (!w) {
        NSArray *ws = WPMsg(icon, @"widgets");
        if ([ws isKindOfClass:[NSArray class]]) w = ws.firstObject;
    }
    return w;
}

// All widgets of a widget icon, top of the stack first (a single widget is a stack of one).
static NSArray *WPIconWidgets(id icon) {
    if (![icon respondsToSelector:NSSelectorFromString(@"isWidgetIcon")]) return @[];
    if (!((BOOL (*)(id, SEL))objc_msgSend)(icon, NSSelectorFromString(@"isWidgetIcon"))) return @[];
    NSArray *ws = WPMsg(icon, @"widgets");
    if ([ws isKindOfClass:[NSArray class]] && ws.count) return ws;
    id w = WPMsg(icon, @"activeWidget");
    return w ? @[ w ] : @[];
}

static BOOL WPIsOurWidgetIcon(id icon) {
    for (id w in WPIconWidgets(icon)) if (WPExtensionForID(WPExtIDOf(w))) return YES;
    return NO;
}

static NSString *WPWidgetKey(id widget) {
    id u = WPMsg(widget, @"uniqueIdentifier");
    return [u isKindOfClass:[NSString class]] && [u length] ? u : [NSString stringWithFormat:@"%p", widget];
}

#pragma mark - Grid sizes

static NSString *WPGridClass(const char *symbol, NSString *fallback) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *cached = cache[@(symbol)];
    if (cached) return cached;
    void *raw = dlsym(RTLD_DEFAULT, symbol);
    NSString *const __unsafe_unretained *p = (NSString *const __unsafe_unretained *)raw;
    NSString *result = (p && *p) ? *p : fallback;
    cache[@(symbol)] = result;
    return result;
}

static NSString *WPGridSmall(void) { return WPGridClass("SBHIconGridSizeClassSmall", @"SBHIconGridSizeClassSmall"); }
static NSString *WPGridMedium(void) { return WPGridClass("SBHIconGridSizeClassMedium", @"SBHIconGridSizeClassMedium"); }
static NSString *WPGridLarge(void) { return WPGridClass("SBHIconGridSizeClassLarge", @"SBHIconGridSizeClassLarge"); }

static int WPFamilyForGridClass(NSString *c) {
    if ([c isEqualToString:WPGridMedium()]) return 1;
    if ([c isEqualToString:WPGridLarge()]) return 2;
    if ([c rangeOfString:@"ExtraLarge" options:NSCaseInsensitiveSearch].location != NSNotFound) return 3;
    return 0;
}

// small / medium / large, as SpringBoardHome's grid size class set.
static id WPWidgetGridSet(void) {
    static id set;
    if (set) return set;
    Class mutableClass = NSClassFromString(@"SBHMutableIconGridSizeClassSet");
    SEL add = NSSelectorFromString(@"addGridSizeClass:");
    if (mutableClass && [mutableClass instancesRespondToSelector:add]) {
        id m = [mutableClass new];
        for (NSString *c in @[ WPGridSmall(), WPGridMedium(), WPGridLarge() ]) ((void (*)(id, SEL, id))objc_msgSend)(m, add, c);
        set = [m respondsToSelector:@selector(copyWithZone:)] ? [m copy] : m;
        WPHLog(@"Size set: %@", set);
        return set;
    }
    WPHLog(@"SBHMutableIconGridSizeClassSet is not available");
    return nil;
}

#pragma mark - Opening the app

static __weak id gWPManager; // SBHIconManager

static BOOL WPIsEditing(void) {
    id m = gWPManager;
    SEL sel = NSSelectorFromString(@"isEditing");
    return m && [m respondsToSelector:sel] && ((BOOL (*)(id, SEL))objc_msgSend)(m, sel);
}

// Opens the widget's app the same way the ROM opens it from its icon.
static void WPLaunchApp(NSString *bundleID) {
    static CFAbsoluteTime last;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - last < 0.8) return;
    last = now;
    id manager = gWPManager;
    id home = WPMsg(manager, @"delegate");
    id leaf = nil;
    SEL nativeSel = NSSelectorFromString(@"nativeIconForBundleIdentifier:");
    if ([home respondsToSelector:nativeSel]) leaf = ((id (*)(id, SEL, id))objc_msgSend)(home, nativeSel, bundleID);
    SEL leafSel = NSSelectorFromString(@"leafIconForIdentifier:");
    id model = WPMsg(manager, @"iconModel");
    if (!leaf && [model respondsToSelector:leafSel]) leaf = ((id (*)(id, SEL, id))objc_msgSend)(model, leafSel, bundleID);
    SEL launchSel = NSSelectorFromString(@"performLaunchFromLocation:context:");
    if ([leaf respondsToSelector:launchSel]) {
        WPHLog(@"Open app: %@ (via icon)", bundleID);
        ((void (*)(id, SEL, id, id))objc_msgSend)(leaf, launchSel, @"SBIconLocationRoot", nil);
        return;
    }
    Class server = NSClassFromString(@"NXSBWindowServer");
    id instance = nil;
    for (NSString *name in @[ @"sharedInstance", @"shared" ]) {
        if (!instance && [server respondsToSelector:NSSelectorFromString(name)]) instance = WPMsg(server, name);
    }
    SEL openSel = NSSelectorFromString(@"openApplicationWithBundleIdentifier:");
    if ([instance respondsToSelector:openSel]) {
        WPHLog(@"Open app: %@ (via window server)", bundleID);
        ((void (*)(id, SEL, id))objc_msgSend)(instance, openSel, bundleID);
        return;
    }
    WPHLog(@"Cannot open app: %@ (leaf=%@)", bundleID, leaf);
}

#pragma mark - Controls inside widgets

// SwiftUI buttons and links inside the widget are found through the accessibility tree
// (every Button / Link is an element with the button or link trait) and activated
// directly, so the widget behaves like on iOS: a tap on a control runs it, a tap
// anywhere else opens the app.
static CFAbsoluteTime gWPLastControlAt;   // a control was activated (suppresses the app launch)
static NSString *gWPControlApp;            // app of the widget whose control was activated

static void WPCollectAXElements(id node, NSMutableArray *out, int depth) {
    if (!node || depth > 10 || out.count > 300) return;
    if ([node isAccessibilityElement]) [out addObject:node];
    NSArray *children = nil;
    @try { children = [node accessibilityElements]; } @catch (NSException *e) {}
    if (children.count) {
        for (id c in children) WPCollectAXElements(c, out, depth + 1);
    } else if ([node respondsToSelector:@selector(accessibilityElementCount)]) {
        NSInteger n = [node accessibilityElementCount];
        for (NSInteger i = 0; i < n && i < 100 && n != NSNotFound; i++) WPCollectAXElements([node accessibilityElementAtIndex:i], out, depth + 1);
    }
    if ([node isKindOfClass:[UIView class]] && !children.count) {
        for (UIView *sub in ((UIView *)node).subviews) WPCollectAXElements(sub, out, depth + 1);
    }
}

static NSString *WPTraitsText(UIAccessibilityTraits t) {
    NSMutableArray *a = [NSMutableArray array];
    if (t & UIAccessibilityTraitButton) [a addObject:@"button"];
    if (t & UIAccessibilityTraitLink) [a addObject:@"link"];
    if (t & UIAccessibilityTraitImage) [a addObject:@"image"];
    if (t & UIAccessibilityTraitStaticText) [a addObject:@"text"];
    if (t & UIAccessibilityTraitSelected) [a addObject:@"selected"];
    return a.count ? [a componentsJoinedByString:@"/"] : @"-";
}

// The smallest button or link under the point (in the view's coordinates), or nil.
static id WPControlAtPoint(UIView *view, CGPoint p, BOOL logTree) {
    NSMutableArray *elements = [NSMutableArray array];
    WPCollectAXElements(view, elements, 0);
    CGPoint sp = [view convertPoint:p toCoordinateSpace:UIScreen.mainScreen.coordinateSpace];
    id best = nil;
    CGFloat bestArea = CGFLOAT_MAX;
    for (id e in elements) {
        CGRect f = [e accessibilityFrame];
        UIAccessibilityTraits t = [e accessibilityTraits];
        if (logTree) WPHLog(@"    element: %@ \"%@\" %@", WPTraitsText(t), [e accessibilityLabel] ?: @"", NSStringFromCGRect(f));
        if (!(t & (UIAccessibilityTraitButton | UIAccessibilityTraitLink))) continue;
        if (!CGRectContainsPoint(f, sp)) continue;
        CGFloat area = f.size.width * f.size.height;
        if (area < bestArea) { best = e; bestArea = area; }
    }
    // Like iOS, a small button takes taps around it too (a 44 pt target): the nearest one whose
    // enlarged frame holds the point.
    if (!best) {
        CGFloat bestDistance = CGFLOAT_MAX;
        for (id e in elements) {
            if (!([e accessibilityTraits] & (UIAccessibilityTraitButton | UIAccessibilityTraitLink))) continue;
            CGRect f = [e accessibilityFrame];
            CGRect target = CGRectInset(f, MIN(0, (f.size.width - 44) / 2), MIN(0, (f.size.height - 44) / 2));
            if (!CGRectContainsPoint(target, sp)) continue;
            CGFloat d = hypot(sp.x - CGRectGetMidX(f), sp.y - CGRectGetMidY(f));
            if (d < bestDistance) { best = e; bestDistance = d; }
        }
    }
    if (logTree) WPHLog(@"  %lu accessibility element(s) (tap at %@)", (unsigned long)elements.count, NSStringFromCGPoint(sp));
    return best;
}

// SwiftUI builds the accessibility tree (where the widget's buttons and links are found) only
// when accessibility is in use: it is turned on for this process when the first widget shows.
static void WPEnableAccessibility(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *lib = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW);
        void (*setEnabled)(BOOL) = lib ? dlsym(lib, "_AXSApplicationAccessibilitySetEnabled") : NULL;
        if (setEnabled) setEnabled(YES);
        WPHLog(@"Turned accessibility on (%@)", setEnabled ? @"done" : @"function missing");
    });
}

// Opens the app shortly after a tap unless a control inside the widget took the tap.
static void WPRequestLaunch(NSString *bundleID) {
    CFAbsoluteTime requested = CFAbsoluteTimeGetCurrent();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gWPLastControlAt > requested - 0.6) return;
        WPLaunchApp(bundleID);
    });
}

// SwiftUI's Link opens its URL through UIApplication. Nyxian can only open an app (no URL
// delivery), so the URL is left for the app (see WPLinks.m) and the app is opened.
static IMP orig_appOpenURL;

static NSString *WPAppForURL(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    if (!scheme.length) return nil;
    for (WPWidgetExtension *e in WPKnownExtensions(NO).allValues) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[e.appPath stringByAppendingPathComponent:@"Info.plist"]];
        for (NSDictionary *type in info[@"CFBundleURLTypes"]) {
            for (NSString *sch in type[@"CFBundleURLSchemes"]) {
                if ([sch isKindOfClass:[NSString class]] && [sch.lowercaseString isEqualToString:scheme]) return e.appBundleID;
            }
        }
    }
    return nil;
}

// Leaves the URL where SwitzachWidgetLinks (loaded into the app) picks it up once the app
// is in front: in the app's data container and in a shared folder. Returns whether that
// app has shown it can receive links.
static BOOL WPHandOffURL(NSURL *url, NSString *appBundleID) {
    NSDictionary *entry = @{ @"url" : url.absoluteString ?: @"", @"app" : appBundleID, @"time" : @(CFAbsoluteTimeGetCurrent()) };
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dataPath = nil;
    for (WPWidgetExtension *e in WPKnownExtensions(NO).allValues) {
        if ([e.appBundleID isEqualToString:appBundleID] && e.dataContainerPath) dataPath = e.dataContainerPath;
    }
    NSString *shared = [[[WPProbe reportPath] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"links"];
    [fm createDirectoryAtPath:shared withIntermediateDirectories:YES attributes:nil error:nil];
    [entry writeToFile:[shared stringByAppendingPathComponent:[appBundleID stringByAppendingString:@".plist"]] atomically:YES];
    BOOL receiver = NO;
    if (dataPath) {
        NSString *caches = [dataPath stringByAppendingPathComponent:@"Library/Caches"];
        [fm createDirectoryAtPath:caches withIntermediateDirectories:YES attributes:nil error:nil];
        [entry writeToFile:[caches stringByAppendingPathComponent:@"com.rinapple.widgetlink.plist"] atomically:YES];
        receiver = [fm fileExistsAtPath:[caches stringByAppendingPathComponent:@"com.rinapple.widgetlink.seen"]];
    }
    return receiver;
}

static void hook_appOpenURL(id self, SEL _cmd, NSURL *url, NSDictionary *options, void (^completion)(BOOL)) {
    BOOL fromWidget = CFAbsoluteTimeGetCurrent() - gWPLastControlAt < 3;
    NSString *app = WPAppForURL(url) ?: (fromWidget ? gWPControlApp : nil);
    if (app) {
        BOOL receiver = WPHandOffURL(url, app);
        WPHLog(@"Widget link: %@ → opening %@ and handing over the URL%@", url, app,
               receiver ? @"" : @" (the app-side receiver has not been seen yet)");
        dispatch_async(dispatch_get_main_queue(), ^{ WPLaunchApp(app); });
        if (completion) completion(YES);
        return;
    }
    ((void (*)(id, SEL, NSURL *, NSDictionary *, id))orig_appOpenURL)(self, _cmd, url, options, completion);
}

#pragma mark - Widget view controller

@interface WPHomeWidgetViewController : UIViewController
@property (nonatomic, strong) WPWidgetExtension *extension;
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *gridSizeClass;
@property (nonatomic) BOOL preview; // in the add sheet: drawn only, taps do nothing
- (BOOL)activateControlAtPoint:(CGPoint)pointInSelf;
- (void)setIconImageInfo:(SBIconImageInfo)info;
@end

// SpringBoardHome calls methods of SBIconViewCustomImageViewControlling (and, for widget
// content, of its own widget host view controller) without asking first. Our controllers
// answer the ones they do not implement with zero instead of crashing.
static NSMethodSignature *WPFallbackSignature(SEL sel) {
    Protocol *p = objc_getProtocol("SBIconViewCustomImageViewControlling");
    if (p) {
        struct objc_method_description d = protocol_getMethodDescription(p, sel, NO, YES);
        if (!d.types) d = protocol_getMethodDescription(p, sel, YES, YES);
        if (d.types) return [NSMethodSignature signatureWithObjCTypes:d.types];
    }
    for (NSString *name in @[ @"SBHWidgetViewController", @"CHUISWidgetHostViewController" ]) {
        Method m = class_getInstanceMethod(NSClassFromString(name), sel);
        if (m) return [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)];
    }
    return nil;
}

// visibleBounds: the part of the icon's content that shows. The ROM asks for it in edit mode;
// a widget shows its whole view. Answered here, with the protocol's own return type, so a
// different type in another ROM build still gets the zero fallback.
static BOOL WPAnswerVisibleBounds(NSInvocation *invocation, UIViewController *vc, CGSize imageSize) {
    if (invocation.selector != NSSelectorFromString(@"visibleBounds")) return NO;
    if (strncmp(invocation.methodSignature.methodReturnType, "{CGRect=", 8) != 0) return NO;
    CGRect r = vc.isViewLoaded ? vc.view.bounds : CGRectZero;
    if (r.size.width < 1 || r.size.height < 1) r = (CGRect){ CGPointZero, imageSize };
    [invocation setReturnValue:&r];
    return YES;
}

static void WPForwardAsZero(NSInvocation *invocation) {
    static NSMutableSet *seen;
    if (!seen) seen = [NSMutableSet set];
    NSString *name = NSStringFromSelector(invocation.selector);
    if (![seen containsObject:name]) {
        [seen addObject:name];
        WPHLog(@"Ignored unimplemented call: %@", name);
    }
    NSUInteger len = invocation.methodSignature.methodReturnLength;
    if (len) {
        void *zero = calloc(1, len);
        [invocation setReturnValue:zero];
        free(zero);
    }
}


// Whether the view shows on its window right now (not hidden, not on another page).
static BOOL WPViewOnScreen(UIView *view) {
    UIWindow *window = view.window;
    if (!window || window.hidden || window.alpha < 0.01) return NO;
    for (UIView *v = view; v; v = v.superview) {
        if (v.hidden || v.alpha < 0.01) return NO;
    }
    CGRect r = CGRectIntersection([view convertRect:view.bounds toView:nil], window.bounds);
    return !CGRectIsNull(r) && r.size.width > 1 && r.size.height > 1;
}

@implementation WPHomeWidgetViewController {
    SBIconImageInfo _info;
    UIViewController *_hosted;
    UILabel *_status;
    BOOL _renderScheduled;
    CGSize _renderedSize;
    int _attempts;
    NSUInteger _generation;
    NSTimer *_refreshTimer;
    int _renderedFamily;
    BOOL _rendering;            // a render waits for the app's timeline
    BOOL _refreshAgain;         // another reload was asked for meanwhile
    CFAbsoluteTime _hiddenSince; // a reload waits for the widget to be on screen
    BOOL _hiddenCheck;
}

- (void)dealloc {
    [_refreshTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleTap:(UITapGestureRecognizer *)tap {
    if (self.preview || WPIsEditing()) return;
    if (![self activateControlAtPoint:[tap locationInView:self.view]]) WPRequestLaunch(self.extension.appBundleID);
}

// Runs the button / link under the point. Returns YES if there was one.
- (BOOL)activateControlAtPoint:(CGPoint)pointInSelf {
    if (!_hosted) return NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gWPLastControlAt < 0.5) return YES; // the same tap seen through another path
    static NSMutableSet *logged;
    if (!logged) logged = [NSMutableSet set];
    BOOL logTree = ![logged containsObject:self.kind];
    if (logTree) [logged addObject:self.kind];
    if (logTree) WPHLog(@"%@ buttons and links:", self.kind);
    CGPoint p = [self.view convertPoint:pointInSelf toView:_hosted.view];
    id control = WPControlAtPoint(_hosted.view, p, logTree);
    if (!control) {
        if (logTree) [logged removeObject:self.kind]; // list the elements again once accessibility is on
        return NO;
    }
    // A control whose action crashed SpringBoard before (the marker survived) is not run
    // again; the tap opens the app instead.
    // A link only opens its URL (see hook_appOpenURL), so only buttons, which run the app's
    // code, are guarded.
    UIAccessibilityTraits traits = [control accessibilityTraits];
    BOOL linkOnly = (traits & UIAccessibilityTraitLink) && !(traits & UIAccessibilityTraitButton);
    NSString *marker = [NSString stringWithFormat:@"control2-%@-%@", self.extension.extensionBundleID, self.kind];
    // iOS performs some intents in the app's own process rather than the widget's (see
    // WPProbe appProcessIntentsForExtension:). Here the tap opens the app for those.
    NSString *inApp = linkOnly ? nil : [WPProbe appProcessIntentsForExtension:self.extension];
    if (inApp) {
        WPHLog(@"%@: the button's action (%@) runs inside the app on iOS, so the app is opened", self.kind, inApp);
        return NO;
    }
    if (!linkOnly) {
        if (WPMarkerTripped(marker)) {
            WPHLog(@"%@: the button crashed last time, so it is not run; the app is opened", self.kind);
            return NO;
        }
        WPMarkerBegin(marker);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WPMarkerEnd(marker);
        });
    }
    gWPLastControlAt = now;
    gWPControlApp = self.extension.appBundleID;
    BOOL ok = NO;
    @try { ok = [control accessibilityActivate]; } @catch (NSException *e) { WPHLog(@"  Exception while running: %@", e.reason); }
    WPHLog(@"Ran widget %@ \"%@\" → %@", WPTraitsText([control accessibilityTraits]), [control accessibilityLabel] ?: @"", ok ? @"ok" : @"failed");
    if (!ok) {
        gWPLastControlAt = 0;
        return NO;
    }
    // Interactive widgets reload their timeline after the button's intent has run.
    __weak typeof(self) weakSelf = self;
    for (NSNumber *delay in @[ @0.7, @2.5 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf refresh];
        });
    }
    return YES;
}

// Redraws at the next timeline entry's date, or every 30 minutes (like a reload policy of .atEnd).
- (void)scheduleRefreshAt:(NSDate *)date {
    [_refreshTimer invalidate];
    NSTimeInterval delay = date ? MAX(60, date.timeIntervalSinceNow) : 30 * 60;
    __weak typeof(self) weakSelf = self;
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *t) {
        WPHomeWidgetViewController *strong = weakSelf;
        if (!strong) return;
        WPHLog(@"Refresh: %@", strong.kind);
        [strong refresh];
    }];
    _refreshTimer.tolerance = 10;
}

+ (void)initialize {
    if (self != [WPHomeWidgetViewController class]) return;
    Protocol *p = objc_getProtocol("SBIconViewCustomImageViewControlling");
    if (p) class_addProtocol(self, p);
}

- (SBIconImageInfo)iconImageInfo {
    return _info;
}

- (void)setIconImageInfo:(SBIconImageInfo)info {
    _info = info;
    if (self.isViewLoaded) {
        self.view.layer.cornerRadius = info.continuousCornerRadius;
        [self scheduleRender];
    }
}

- (BOOL)wantsLabelHidden {
    return NO;
}

- (void)loadView {
    UIView *v = [UIView new];
    v.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1];
    v.layer.cornerRadius = _info.continuousCornerRadius > 0 ? _info.continuousCornerRadius : 22;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    v.clipsToBounds = YES;
    // Taps open the app; long press and drags still reach the icon view's own recognizers.
    v.userInteractionEnabled = YES;
    [v addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)]];
    _status = [UILabel new];
    _status.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    _status.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.numberOfLines = 0;
    _status.text = gWPGuardTripped ? @"Drawing is stopped\nafter repeated crashes" : @"Loading…";
    [v addSubview:_status];
    self.view = v;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _status.frame = CGRectInset(self.view.bounds, 8, 8);
    _hosted.view.frame = self.view.bounds;
    CGSize s = self.view.bounds.size;
    if (s.width > 10 && (fabs(s.width - _renderedSize.width) > 4 || fabs(s.height - _renderedSize.height) > 4)) [self scheduleRender];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(dataChanged:) name:@"WPWidgetDataChanged" object:nil];
    [self scheduleRender];
}

// The app wrote to its shared data: reload the timeline (WidgetCenter.reloadTimelines).
- (void)dataChanged:(NSNotification *)note {
    if (![note.object isEqual:self.extension.extensionBundleID]) return;
    WPHLog(@"App data changed, refreshing: %@", self.kind);
    [self refresh];
}

// Reloads what is shown (the next timeline entry, after a button, when the app's data
// changed). While a reload is still waiting for the app's timeline, more requests become one
// reload after it. A widget that is not on screen (another page) waits until it is — at most
// a minute, so it never stops updating.
- (void)refresh {
    if (!_hosted) {
        _renderedSize = CGSizeZero;
        _attempts = 0;
        [self render];
        return;
    }
    if (_rendering) {
        _refreshAgain = YES;
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!WPViewOnScreen(self.view) && (!_hiddenSince || now - _hiddenSince < 60)) {
        if (!_hiddenSince) _hiddenSince = now;
        if (!_hiddenCheck) {
            _hiddenCheck = YES;
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                WPHomeWidgetViewController *strong = weakSelf;
                if (!strong) return;
                strong->_hiddenCheck = NO;
                [strong refresh];
            });
        }
        return;
    }
    _hiddenSince = 0;
    _renderedSize = CGSizeZero;
    _attempts = 0;
    [self render];
}

- (void)scheduleRender {
    if (_renderScheduled || gWPGuardTripped) return;
    _renderScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf render];
    });
}

- (void)render {
    _renderScheduled = NO;
    CGSize size = self.isViewLoaded ? self.view.bounds.size : CGSizeZero;
    if (size.width < 10) size = _info.size;
    if (size.width < 10) return;
    if (fabs(size.width - _renderedSize.width) <= 4 && fabs(size.height - _renderedSize.height) <= 4 && _hosted) return;
    if (![WPProbe loadedWidgetsForExtension:self.extension]) {
        // Its code loads in the background first (the home screen stays responsive meanwhile).
        __weak typeof(self) weakSelf = self;
        [WPProbe prepareExtension:self.extension completion:^{
            WPHomeWidgetViewController *strong = weakSelf;
            if (strong) [strong render];
        }];
        return;
    }
    if (++_attempts > 6) return;
    _renderedSize = size;
    NSUInteger generation = ++_generation;
    int family = WPFamilyForGridClass(self.gridSizeClass);
    __weak typeof(self) weakSelf = self;
    @try {
        // The placeholder only for the first drawing (or a new size); a refresh goes straight
        // from what is shown to the new entry.
        BOOL placeholder = !_hosted || family != _renderedFamily;
        _renderedFamily = family;
        _rendering = YES;
        [WPProbe renderWidgetKind:self.kind extension:self.extension family:family size:size placeholder:placeholder
                           update:^(UIViewController *vc, NSDate *next, BOOL final) {
            WPHomeWidgetViewController *strong = weakSelf;
            if (!strong || generation != strong->_generation) return;
            if (vc) [strong showHosted:vc];
            else if (!strong->_hosted) strong->_status.text = @"Could not draw";
            if (final) {
                [strong scheduleRefreshAt:next];
                [strong renderFinished];
            }
        }];
    } @catch (NSException *e) {
        WPHLog(@"Exception while drawing: %@", e.reason);
        [self renderFinished];
    }
}

- (void)renderFinished {
    _rendering = NO;
    if (!_refreshAgain) return;
    _refreshAgain = NO;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refresh]; });
}

- (void)showHosted:(UIViewController *)vc {
    WPEnableAccessibility();
    if (_hosted) {
        [_hosted willMoveToParentViewController:nil];
        [_hosted.view removeFromSuperview];
        [_hosted removeFromParentViewController];
    }
    _hosted = vc;
    [self addChildViewController:vc];
    vc.view.backgroundColor = UIColor.clearColor;
    vc.view.userInteractionEnabled = NO;
    vc.view.frame = self.view.bounds;
    [self.view addSubview:vc.view];
    [vc didMoveToParentViewController:self];
    _status.hidden = YES;
}

// SpringBoardHome may call optional methods of SBIconViewCustomImageViewControlling without
// asking first; answer those with zero instead of crashing.
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [super methodSignatureForSelector:sel] ?: WPFallbackSignature(sel);
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    if (WPAnswerVisibleBounds(invocation, self, _info.size)) return;
    WPForwardAsZero(invocation);
}

@end

#pragma mark - Stack view controller

// A page for a widget of a stack that is not ours (the ROM cannot draw system widgets).
@interface WPForeignWidgetViewController : UIViewController
@property (nonatomic, copy) NSString *name;
@end

@implementation WPForeignWidgetViewController
- (void)loadView {
    UIView *v = [UIView new];
    v.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1];
    UILabel *l = [UILabel new];
    l.text = self.name.length ? self.name : @"Widget";
    l.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    l.textAlignment = NSTextAlignmentCenter;
    l.numberOfLines = 0;
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [v addSubview:l];
    self.view = v;
}
@end

// SBIcon's observer list (SBLeafIconObserver: widgets added / removed / active one changed).
static void WPIconObserve(id icon, id observer, BOOL add) {
    SEL sel = NSSelectorFromString(add ? @"addObserver:" : @"removeObserver:");
    if (icon && [icon respondsToSelector:sel]) ((void (*)(id, SEL, id))objc_msgSend)(icon, sel, observer);
}

// Vertical paging like SBHWidgetStackScrollView; in edit mode a drag moves the whole stack
// (the icon view's own recognizers), so the scroll view stays out of the way then.
@interface WPStackScrollView : UIScrollView
@end

@implementation WPStackScrollView
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (g == self.panGestureRecognizer && WPIsEditing()) return NO;
    return [super gestureRecognizerShouldBegin:g];
}
@end

// The custom image view controller of our widget icons: one page per widget of the icon
// (SBWidgetIcon.widgets), swiped vertically, with page dots beside it like iOS. Follows the
// icon when widgets are added to / removed from the stack and when the active one changes.
@interface WPHomeStackViewController : UIViewController <UIScrollViewDelegate>
@property (nonatomic, weak) id iconView;
- (instancetype)initWithIcon:(id)icon iconView:(id)iconView;
- (WPHomeWidgetViewController *)currentPage;
@end

@implementation WPHomeStackViewController {
    __weak id _icon;
    SBIconImageInfo _info;
    UIView *_clip;
    WPStackScrollView *_scroll;
    UIView *_dotsView;
    NSArray<UIView *> *_dots;
    NSArray<NSString *> *_keys;
    NSArray<UIViewController *> *_pages;
    NSMutableDictionary<NSString *, UIViewController *> *_pagesByKey;
    NSUInteger _activeIndex;
    BOOL _settingActive;
    NSUInteger _flash;
}

+ (void)initialize {
    if (self != [WPHomeStackViewController class]) return;
    const char *names[] = { "SBIconViewCustomImageViewControlling", "SBIconObserver", "SBLeafIconObserver" };
    for (int i = 0; i < 3; i++) {
        Protocol *p = objc_getProtocol(names[i]);
        if (p) class_addProtocol(self, p);
    }
}

- (instancetype)initWithIcon:(id)icon iconView:(id)iconView {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _pagesByKey = [NSMutableDictionary dictionary];
        _keys = @[];
        _pages = @[];
        self.iconView = iconView;
        [self observeIcon:icon];
    }
    return self;
}

- (void)dealloc {
    id icon = _icon;
    WPIconObserve(icon, self, NO);
}

- (void)observeIcon:(id)icon {
    id old = _icon;
    if (old == icon) return;
    WPIconObserve(old, self, NO);
    _icon = icon;
    WPIconObserve(icon, self, YES);
}

#pragma mark SBIconViewCustomImageViewControlling

- (SBIconImageInfo)iconImageInfo {
    return _info;
}

- (void)setIconImageInfo:(SBIconImageInfo)info {
    _info = info;
    for (UIViewController *page in _pages) {
        if ([page isKindOfClass:[WPHomeWidgetViewController class]]) [(WPHomeWidgetViewController *)page setIconImageInfo:info];
    }
    if (self.isViewLoaded) {
        _clip.layer.cornerRadius = info.continuousCornerRadius > 0 ? info.continuousCornerRadius : 22;
        [self.view setNeedsLayout];
    }
}

- (BOOL)wantsLabelHidden {
    return NO;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [super methodSignatureForSelector:sel] ?: WPFallbackSignature(sel);
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    if (WPAnswerVisibleBounds(invocation, self, _info.size)) return;
    WPForwardAsZero(invocation);
}

#pragma mark SBLeafIconObserver

- (void)leafIcon:(id)icon didAddIconDataSource:(id)dataSource {
    dispatch_async(dispatch_get_main_queue(), ^{ [self rebuildFlashing:YES]; });
}

- (void)leafIcon:(id)icon didRemoveIconDataSource:(id)dataSource {
    dispatch_async(dispatch_get_main_queue(), ^{ [self rebuildFlashing:YES]; });
}

- (void)leafIcon:(id)icon didChangeActiveDataSource:(id)dataSource {
    if (_settingActive) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [self rebuildFlashing:NO]; });
}

#pragma mark Views

- (void)loadView {
    UIView *v = [UIView new];
    v.backgroundColor = UIColor.clearColor;
    v.clipsToBounds = NO; // the page dots sit just outside the widget
    _clip = [UIView new];
    _clip.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1];
    _clip.layer.cornerRadius = _info.continuousCornerRadius > 0 ? _info.continuousCornerRadius : 22;
    _clip.layer.cornerCurve = kCACornerCurveContinuous;
    _clip.clipsToBounds = YES;
    [v addSubview:_clip];
    _scroll = [WPStackScrollView new];
    _scroll.pagingEnabled = YES;
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.showsHorizontalScrollIndicator = NO;
    _scroll.scrollsToTop = NO;
    _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _scroll.delegate = self;
    [_clip addSubview:_scroll];
    _dotsView = [UIView new];
    _dotsView.userInteractionEnabled = NO;
    _dotsView.alpha = 0;
    [v addSubview:_dotsView];
    self.view = v;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self rebuildFlashing:NO];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // SpringBoardHome may hand the icon view a new icon (e.g. a stack made by dropping a
    // widget onto this one); follow it.
    id current = WPMsg(self.iconView, @"icon");
    if (current && current != _icon && WPIsOurWidgetIcon(current)) {
        [self observeIcon:current];
        [self rebuildFlashing:YES];
        return;
    }
    [self layoutPages];
}

- (void)layoutPages {
    CGRect b = self.view.bounds;
    _clip.frame = b;
    _scroll.frame = _clip.bounds;
    CGFloat h = b.size.height;
    for (NSUInteger i = 0; i < _pages.count; i++) _pages[i].view.frame = CGRectMake(0, i * h, b.size.width, h);
    _scroll.contentSize = CGSizeMake(b.size.width, h * MAX(1, _pages.count));
    if (!_scroll.isDragging && !_scroll.isDecelerating) _scroll.contentOffset = CGPointMake(0, _activeIndex * h);
    // Dots: a small vertical column just past the trailing edge, centred.
    CGFloat d = 5, gap = 4;
    CGFloat total = _dots.count * d + (_dots.count ? (_dots.count - 1) * gap : 0);
    _dotsView.frame = CGRectMake(CGRectGetMaxX(b) + 5, CGRectGetMidY(b) - total / 2, d, total);
    for (NSUInteger i = 0; i < _dots.count; i++) _dots[i].frame = CGRectMake(0, i * (d + gap), d, d);
}

- (void)rebuildFlashing:(BOOL)flash {
    if (!self.isViewLoaded) return;
    id icon = _icon;
    NSArray *widgets = WPIconWidgets(icon);
    NSMutableArray *keys = [NSMutableArray array], *pages = [NSMutableArray array];
    NSString *gridClass = WPMsg(icon, @"gridSizeClass");
    for (id w in widgets) {
        NSString *key = WPWidgetKey(w);
        UIViewController *page = _pagesByKey[key];
        if (!page) {
            WPWidgetExtension *ext = WPExtensionForID(WPExtIDOf(w));
            if (ext) {
                WPHomeWidgetViewController *wvc = [WPHomeWidgetViewController new];
                wvc.extension = ext;
                wvc.kind = WPMsg(w, @"kind");
                wvc.gridSizeClass = gridClass;
                if (_info.size.width > 0) [wvc setIconImageInfo:_info];
                page = wvc;
            } else {
                WPForeignWidgetViewController *f = [WPForeignWidgetViewController new];
                id name = WPMsg(w, @"displayName");
                f.name = [name isKindOfClass:[NSString class]] ? name : nil;
                page = f;
            }
            [self addChildViewController:page];
            [_scroll addSubview:page.view];
            [page didMoveToParentViewController:self];
            _pagesByKey[key] = page;
        } else if ([page isKindOfClass:[WPHomeWidgetViewController class]]) {
            ((WPHomeWidgetViewController *)page).gridSizeClass = gridClass;
        }
        [keys addObject:key];
        [pages addObject:page];
    }
    for (NSString *key in _pagesByKey.allKeys) {
        if ([keys containsObject:key]) continue;
        UIViewController *gone = _pagesByKey[key];
        [gone willMoveToParentViewController:nil];
        [gone.view removeFromSuperview];
        [gone removeFromParentViewController];
        [_pagesByKey removeObjectForKey:key];
    }
    BOOL changed = ![keys isEqualToArray:_keys];
    _keys = keys;
    _pages = pages;
    id active = WPMsg(icon, @"activeWidget");
    NSUInteger index = active ? [keys indexOfObject:WPWidgetKey(active)] : NSNotFound;
    _activeIndex = index == NSNotFound ? 0 : index;
    _scroll.scrollEnabled = pages.count > 1;
    _scroll.alwaysBounceVertical = pages.count > 1;
    if (changed) {
        for (UIView *dot in _dots) [dot removeFromSuperview];
        NSMutableArray *dots = [NSMutableArray array];
        if (pages.count > 1) {
            for (NSUInteger i = 0; i < pages.count; i++) {
                UIView *dot = [UIView new];
                dot.layer.cornerRadius = 2.5;
                [_dotsView addSubview:dot];
                [dots addObject:dot];
            }
        }
        _dots = dots;
        if (pages.count > 1) WPHLog(@"Stack: %lu (%@)", (unsigned long)pages.count, [[widgets valueForKey:@"kind"] componentsJoinedByString:@", "]);
    }
    [self updateDots];
    [self.view setNeedsLayout];
    [self layoutPages];
    if (flash || changed) [self flashDots];
}

- (void)updateDots {
    CGFloat h = _scroll.bounds.size.height;
    NSUInteger shown = h > 0 ? (NSUInteger)MAX(0, MIN((CGFloat)_dots.count - 1, round(_scroll.contentOffset.y / h))) : _activeIndex;
    for (NSUInteger i = 0; i < _dots.count; i++) _dots[i].backgroundColor = [UIColor colorWithWhite:1 alpha:i == shown ? 0.95 : 0.35];
}

// iOS shows the stack's page dots while it scrolls and for a moment after.
- (void)flashDots {
    if (_dots.count < 2) return;
    NSUInteger token = ++_flash;
    [UIView animateWithDuration:0.15 animations:^{ self->_dotsView.alpha = 1; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token != self->_flash || self->_scroll.isDragging || self->_scroll.isDecelerating) return;
        [UIView animateWithDuration:0.3 animations:^{ self->_dotsView.alpha = 0; }];
    });
}

#pragma mark Scrolling

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    ++_flash;
    [UIView animateWithDuration:0.15 animations:^{ self->_dotsView.alpha = 1; }];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self updateDots];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate) [self settle];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    [self settle];
}

// The page the user swiped to becomes the icon's active widget, like SBHWidgetStackViewController.
- (void)settle {
    [self flashDots];
    CGFloat h = _scroll.bounds.size.height;
    if (h <= 0 || _pages.count == 0) return;
    NSUInteger index = (NSUInteger)MAX(0, MIN((CGFloat)_pages.count - 1, round(_scroll.contentOffset.y / h)));
    if (index == _activeIndex) return;
    _activeIndex = index;
    id icon = _icon;
    NSArray *widgets = WPIconWidgets(icon);
    if (index >= widgets.count) return;
    id widget = widgets[index];
    _settingActive = YES;
    SEL setActive = NSSelectorFromString(@"setActiveWidget:");
    SEL setUser = NSSelectorFromString(@"setLastUserSelectedDataSource:");
    if ([icon respondsToSelector:setUser]) ((void (*)(id, SEL, id))objc_msgSend)(icon, setUser, widget);
    if ([icon respondsToSelector:setActive]) ((void (*)(id, SEL, id))objc_msgSend)(icon, setActive, widget);
    _settingActive = NO;
    id model = WPMsg(gWPManager, @"iconModel");
    SEL save = NSSelectorFromString(@"saveIconStateIfNeeded");
    if ([model respondsToSelector:save]) ((BOOL (*)(id, SEL))objc_msgSend)(model, save);
}

- (WPHomeWidgetViewController *)currentPage {
    UIViewController *page = _activeIndex < _pages.count ? _pages[_activeIndex] : nil;
    return [page isKindOfClass:[WPHomeWidgetViewController class]] ? (WPHomeWidgetViewController *)page : nil;
}

@end

#pragma mark - Keeping widgets across restarts

// The ROM's store writes widget entries to IconState.plist, but SpringBoardHome drops them
// again while importing the state at startup (chronod does not know these widgets). We keep
// our own record of where they were and put them back after each import.
static id WPMakeWidgetIcon(WPWidgetExtension *ext, NSString *kind, NSString *gridClass);
static id WPMakeStackIcon(NSArray<NSDictionary *> *widgets, NSString *gridClass, NSString *selected);
static __weak id gWPModel;          // the icon model, seen while it unarchives widgets

static NSString *WPGridClassForName(NSString *name) {
    if ([name isEqualToString:@"small"]) return WPGridSmall();
    if ([name isEqualToString:@"large"]) return WPGridLarge();
    return WPGridMedium();
}

// One widget of a saved entry: {ext, kind, container}, or nil.
static NSDictionary *WPSavedWidget(NSDictionary *d) {
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    NSString *ext = d[@"bundleIdentifier"], *kind = d[@"widgetIdentifier"];
    if (![ext isKindOfClass:[NSString class]] || ![kind isKindOfClass:[NSString class]]) return nil;
    NSString *container = [d[@"containerBundleIdentifier"] isKindOfClass:[NSString class]] ? d[@"containerBundleIdentifier"] : @"";
    NSString *unique = [d[@"uniqueIdentifier"] isKindOfClass:[NSString class]] ? d[@"uniqueIdentifier"] : @"";
    return @{ @"ext" : ext, @"kind" : kind, @"container" : container, @"unique" : unique };
}

// The widgets of a saved stack entry (its element list), or nil when it is not a stack.
static NSArray *WPSavedStackElements(NSDictionary *d) {
    for (NSString *key in @[ @"elements", @"widgets" ]) {
        NSArray *list = d[key];
        if (![list isKindOfClass:[NSArray class]] || list.count == 0) continue;
        NSMutableArray *ws = [NSMutableArray array];
        for (NSDictionary *e in list) {
            NSDictionary *w = WPSavedWidget(e);
            if (w) [ws addObject:w];
        }
        if (ws.count) return ws;
    }
    return nil;
}

static NSArray *WPWidgetsInState(id state) {
    NSMutableArray *found = [NSMutableArray array];
    NSArray *lists = [state isKindOfClass:[NSDictionary class]] ? state[@"iconLists"] : nil;
    if (![lists isKindOfClass:[NSArray class]]) return found;
    for (NSUInteger li = 0; li < lists.count; li++) {
        NSArray *items = lists[li];
        if (![items isKindOfClass:[NSArray class]]) continue;
        for (NSUInteger i = 0; i < items.count; i++) {
            NSDictionary *d = items[i];
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            NSArray *stack = WPSavedStackElements(d);
            NSArray *ws = stack ?: ([d[@"elementType"] isEqual:@"widget"] && WPSavedWidget(d) ? @[ WPSavedWidget(d) ] : nil);
            BOOL ours = NO;
            for (NSDictionary *w in ws) if (WPExtensionForID(w[@"ext"])) ours = YES;
            if (!ours) continue;
            NSString *grid = [d[@"gridSize"] isKindOfClass:[NSString class]] ? d[@"gridSize"] : @"medium";
            NSString *selected = [d[@"userSelectedElementIdentifier"] isKindOfClass:[NSString class]] ? d[@"userSelectedElementIdentifier"] : @"";
            [found addObject:@{ @"list" : @(li), @"index" : @(i), @"widgets" : ws, @"gridSize" : grid, @"selected" : selected }];
        }
    }
    return found;
}

static NSUInteger WPCountOurWidgets(id model) {
    NSUInteger have = 0;
    id lists = WPMsg(WPMsg(model, @"rootFolder"), @"lists");
    for (id list in ([lists isKindOfClass:[NSArray class]] ? lists : @[])) {
        for (id icon in (NSArray *)WPMsg(list, @"icons") ?: @[]) if (WPIsOurWidgetIcon(icon)) have++;
    }
    return have;
}

// Puts back the widgets SpringBoardHome dropped while importing the saved layout.
static void WPRestoreWidgets(NSArray *pending) {
    id model = gWPModel;
    if (!model || pending.count == 0) return;
    NSUInteger have = WPCountOurWidgets(model);
    if (have > 0) return; // kept by SpringBoardHome, or already put back
    NSArray *lists = WPMsg(WPMsg(model, @"rootFolder"), @"lists");
    if (![lists isKindOfClass:[NSArray class]] || lists.count == 0) return;
    SEL insertSel = NSSelectorFromString(@"insertIcon:atIndex:");
    for (NSDictionary *r in pending) {
        id icon = WPMakeStackIcon(r[@"widgets"], WPGridClassForName(r[@"gridSize"]), r[@"selected"]);
        if (!icon) continue;
        NSUInteger li = MIN([r[@"list"] unsignedIntegerValue], lists.count - 1);
        id list = lists[li];
        NSUInteger index = MIN([r[@"index"] unsignedIntegerValue], [WPMsg(list, @"icons") count]);
        if ([list respondsToSelector:insertSel]) {
            ((id (*)(id, SEL, id, NSUInteger))objc_msgSend)(list, insertSel, icon, index);
        } else {
            ((id (*)(id, SEL, id))objc_msgSend)(list, NSSelectorFromString(@"addIcon:"), icon);
        }
    }
    WPHLog(@"Restored placement: %lu", (unsigned long)pending.count);
    SEL save = NSSelectorFromString(@"saveIconStateIfNeeded");
    if ([model respondsToSelector:save]) ((BOOL (*)(id, SEL))objc_msgSend)(model, save);
}

static void WPNoteLoadedState(id state) {
    NSArray *widgets = WPWidgetsInState(state);
    if (widgets.count == 0) return; // a later load without them is the copy SpringBoardHome cut down
    // Their code can start loading now, while the home screen is still being built.
    if (!gWPGuardTripped) {
        for (NSDictionary *r in widgets) {
            for (NSDictionary *w in r[@"widgets"]) {
                WPWidgetExtension *ext = WPExtensionForID(w[@"ext"]);
                if (ext) [WPProbe prepareExtension:ext completion:nil];
            }
        }
    }
    // Put back right after this import, and look again a moment later in case SpringBoardHome
    // dropped them only afterwards.
    dispatch_async(dispatch_get_main_queue(), ^{ WPRestoreWidgets(widgets); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WPRestoreWidgets(widgets);
    });
}

#pragma mark - Hooks

static IMP orig_customImageVC, orig_isWidgetValid, orig_validatedIcon, orig_modelValidatedIcon;
static IMP orig_mgrSupported, orig_mgrModelSupported, orig_modelSupported, orig_unarchiverSupported;
static IMP orig_storeLoad, orig_didUnarchive;

static IMP orig_widgetDisplayName, orig_widgetIconDisplayName, orig_iconTapped;

// A tap on a widget icon: SpringBoardHome would ask chronod's host to open it.
static void hook_iconTapped(id self, SEL _cmd, id iconView) {
    gWPManager = self;
    id icon = WPMsg(iconView, @"icon");
    if (WPIsOurWidgetIcon(icon) && !WPIsEditing()) {
        // The widget showing on top of the stack gets the tap.
        id vc = WPMsg(iconView, @"customIconImageViewController");
        WPHomeWidgetViewController *page = nil;
        if ([vc isKindOfClass:[WPHomeStackViewController class]]) page = [(WPHomeStackViewController *)vc currentPage];
        else if ([vc isKindOfClass:[WPHomeWidgetViewController class]]) page = vc;
        if (page && page.isViewLoaded && [iconView isKindOfClass:[UIView class]]) {
            // Where was the tap? The icon view's own tap recognizer knows.
            for (UIGestureRecognizer *g in ((UIView *)iconView).gestureRecognizers) {
                if (![g isKindOfClass:[UITapGestureRecognizer class]]) continue;
                CGPoint p = [g locationInView:page.view];
                if (CGRectContainsPoint(page.view.bounds, p) && [page activateControlAtPoint:p]) return;
                break;
            }
        }
        WPWidgetExtension *ext = page.extension ?: WPExtensionForID(WPExtIDOf(WPPrimaryWidget(icon)));
        if (ext) {
            WPRequestLaunch(ext.appBundleID);
            return;
        }
    }
    ((void (*)(id, SEL, id))orig_iconTapped)(self, _cmd, iconView);
}

// Without chronod the label falls back to "Waiting…"; show the app's name like iOS does.
static id hook_widgetDisplayName(id self, SEL _cmd) {
    WPWidgetExtension *ext = WPExtensionForID(WPExtIDOf(self));
    if (ext.appName) return ext.appName;
    return ((id (*)(id, SEL))orig_widgetDisplayName)(self, _cmd);
}

static id hook_widgetIconDisplayName(id self, SEL _cmd, id icon, id location) {
    WPWidgetExtension *ext = WPExtensionForID(WPExtIDOf(self));
    if (ext.appName) return ext.appName;
    return ((id (*)(id, SEL, id, id))orig_widgetIconDisplayName)(self, _cmd, icon, location);
}

static id hook_didUnarchive(id self, SEL _cmd, id unarchiver, id icon) {
    gWPModel = self;
    id result = ((id (*)(id, SEL, id, id))orig_didUnarchive)(self, _cmd, unarchiver, icon);
    if (!result && WPIsOurWidgetIcon(icon)) return icon;
    return result;
}



static id hook_customImageVC(id self, SEL _cmd, id iconView) {
    gWPManager = self;
    id icon = WPMsg(iconView, @"icon");
    if (!WPIsOurWidgetIcon(icon)) return ((id (*)(id, SEL, id))orig_customImageVC)(self, _cmd, iconView);
    NSArray *widgets = WPIconWidgets(icon);
    WPHLog(@"Showing widget: %@ (%@, %lu)", [[widgets valueForKey:@"kind"] componentsJoinedByString:@", "],
           WPMsg(icon, @"gridSizeClass"), (unsigned long)widgets.count);
    return [[WPHomeStackViewController alloc] initWithIcon:icon iconView:iconView];
}

// One widget's content outside the home grid: the "Edit Stack" card, resizing, previews.
// SpringBoardHome would make a chronod host there, which shows nothing in the ROM.
static IMP orig_makeWidgetVC3, orig_makeWidgetVC4;

static id WPMakeSingleWidgetVC(id icon, id dataSource, id gridClass) {
    WPWidgetExtension *ext = WPExtensionForID(WPExtIDOf(dataSource));
    if (!ext) return nil;
    WPHomeWidgetViewController *vc = [WPHomeWidgetViewController new];
    vc.extension = ext;
    vc.kind = WPMsg(dataSource, @"kind");
    vc.gridSizeClass = [gridClass isKindOfClass:[NSString class]] ? gridClass : WPMsg(icon, @"gridSizeClass");
    static BOOL logged;
    if (!logged) {
        logged = YES;
        WPHLog(@"Showing single widget: %@ (%@)", vc.kind, vc.gridSizeClass);
    }
    return vc;
}

static id hook_makeWidgetVC3(id self, SEL _cmd, id icon, id dataSource, id location) {
    return WPMakeSingleWidgetVC(icon, dataSource, nil) ?: ((id (*)(id, SEL, id, id, id))orig_makeWidgetVC3)(self, _cmd, icon, dataSource, location);
}

static id hook_makeWidgetVC4(id self, SEL _cmd, id icon, id dataSource, id location, id gridClass) {
    return WPMakeSingleWidgetVC(icon, dataSource, gridClass) ?:
           ((id (*)(id, SEL, id, id, id, id))orig_makeWidgetVC4)(self, _cmd, icon, dataSource, location, gridClass);
}



static BOOL hook_isWidgetValid(id self, SEL _cmd, id widget, id sizeClass) {
    if (WPExtensionForID(WPExtIDOf(widget))) return YES;
    return ((BOOL (*)(id, SEL, id, id))orig_isWidgetValid)(self, _cmd, widget, sizeClass);
}

static id hook_validatedIcon(id self, SEL _cmd, id icon) {
    if (WPIsOurWidgetIcon(icon)) return icon;
    return ((id (*)(id, SEL, id))orig_validatedIcon)(self, _cmd, icon);
}

static id hook_modelValidatedIcon(id self, SEL _cmd, id model, id icon) {
    if (WPIsOurWidgetIcon(icon)) return icon;
    return ((id (*)(id, SEL, id, id))orig_modelValidatedIcon)(self, _cmd, model, icon);
}

static id hook_mgrSupported(id self, SEL _cmd, id kind, id extID, id container) {
    if (WPExtensionForID(extID) && WPWidgetGridSet()) return WPWidgetGridSet();
    return ((id (*)(id, SEL, id, id, id))orig_mgrSupported)(self, _cmd, kind, extID, container);
}

static id hook_mgrModelSupported(id self, SEL _cmd, id model, id kind, id extID, id container) {
    if (WPExtensionForID(extID) && WPWidgetGridSet()) return WPWidgetGridSet();
    return ((id (*)(id, SEL, id, id, id, id))orig_mgrModelSupported)(self, _cmd, model, kind, extID, container);
}

static id hook_modelSupported(id self, SEL _cmd, id kind, id extID, id container) {
    if (WPExtensionForID(extID) && WPWidgetGridSet()) return WPWidgetGridSet();
    return ((id (*)(id, SEL, id, id, id))orig_modelSupported)(self, _cmd, kind, extID, container);
}

static id hook_unarchiverSupported(id self, SEL _cmd, id unarchiver, id kind, id extID, id container) {
    if (WPExtensionForID(extID) && WPWidgetGridSet()) return WPWidgetGridSet();
    return ((id (*)(id, SEL, id, id, id, id))orig_unarchiverSupported)(self, _cmd, unarchiver, kind, extID, container);
}

static id hook_storeLoad(id self, SEL _cmd, NSError **error) {
    id state = ((id (*)(id, SEL, NSError **))orig_storeLoad)(self, _cmd, error);
    WPNoteLoadedState(state);
    return state;
}

// Delegate methods SpringBoardHome may ask the ROM's home screen controller.
static BOOL WPDelegateIsWidgetValid(id self, SEL _cmd, id manager, id widget) {
    return WPExtensionForID(WPExtIDOf(widget)) != nil;
}

static void WPDelegateWidgetLaunch(id self, SEL _cmd, id manager, id bundleID, id action) {
    WPHLog(@"Launch request from widget: %@ %@", bundleID, action);
    if ([bundleID isKindOfClass:[NSString class]]) WPLaunchApp(bundleID);
}

static void WPDelegateWidgetLaunch2(id self, SEL _cmd, id manager, id iconView, id bundleID, id action) {
    WPHLog(@"Launch request from widget: %@ %@", bundleID, action);
    if ([bundleID isKindOfClass:[NSString class]]) WPLaunchApp(bundleID);
}

static void WPDelegateWidgetURL(id self, SEL _cmd, id manager, id url) {
    WPHLog(@"Widget URL: %@", url);
}

#pragma mark - Removing a widget (like iOS)

static IMP orig_closeBoxTapped, orig_wantsUninstall;

static BOOL WPHomeContainsIcon(id folder, id icon) {
    for (id list in (NSArray *)WPMsg(folder, @"lists") ?: @[]) {
        for (id i in (NSArray *)WPMsg(list, @"icons") ?: @[]) if (i == icon) return YES;
    }
    return NO;
}

static void WPRemoveIconFromHome(id icon) {
    id manager = gWPManager;
    id folder = WPMsg(manager, @"rootFolder");
    for (id list in (NSArray *)WPMsg(folder, @"lists") ?: @[]) {
        BOOL here = NO;
        for (id i in (NSArray *)WPMsg(list, @"icons") ?: @[]) if (i == icon) here = YES;
        if (!here) continue;
        ((void (*)(id, SEL, id))objc_msgSend)(list, NSSelectorFromString(@"removeIcon:"), icon);
        break;
    }
    // Still there: let the folder remove it (it also tidies the pages).
    SEL folderRemove = NSSelectorFromString(@"removeIcon:options:listGridCellInfoOptions:");
    if (WPHomeContainsIcon(folder, icon) && [folder respondsToSelector:folderRemove]) {
        ((void (*)(id, SEL, id, NSUInteger, NSUInteger))objc_msgSend)(folder, folderRemove, icon, 0, 0);
    }
    BOOL gone = !WPHomeContainsIcon(folder, icon);
    WPHLog(@"Remove widget: %@ → %@", [[WPIconWidgets(icon) valueForKey:@"kind"] componentsJoinedByString:@", "], gone ? @"done" : @"failed");
    id model = WPMsg(manager, @"iconModel");
    SEL save = NSSelectorFromString(@"saveIconStateIfNeeded");
    if ([model respondsToSelector:save]) ((BOOL (*)(id, SEL))objc_msgSend)(model, save);
}

// "Remove “YouTube” Widget?" / "Remove Stack?", then remove it.
// SpringBoardHome reports one tap of the − badge twice (close box tapped, then "uninstall"),
// so only one question per icon is shown at a time.
static __weak UIAlertController *gWPRemovalAlert;
static __weak id gWPRemovalIcon;
static CFAbsoluteTime gWPRemovalAnsweredAt; // the question for gWPRemovalIcon was just answered

static void WPConfirmRemoval(UIViewController *home, id icon) {
    if (gWPRemovalIcon == icon && (gWPRemovalAlert || CFAbsoluteTimeGetCurrent() - gWPRemovalAnsweredAt < 1.5)) return;
    NSArray *widgets = WPIconWidgets(icon);
    BOOL stack = widgets.count > 1;
    WPWidgetExtension *ext = WPExtensionForID(WPExtIDOf(WPPrimaryWidget(icon)));
    NSString *title = stack ? @"Remove Stack?"
                            : [NSString stringWithFormat:@"Remove “%@” Widget?", ext.appName ?: @""];
    NSString *message = stack ? @"Removing this stack will not delete any data." : @"Removing this widget will not delete any data.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        gWPRemovalAnsweredAt = CFAbsoluteTimeGetCurrent();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        gWPRemovalAnsweredAt = CFAbsoluteTimeGetCurrent();
        WPRemoveIconFromHome(icon);
    }]];
    gWPRemovalAlert = alert;
    gWPRemovalIcon = icon;
    UIViewController *top = home;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:alert animated:YES completion:nil];
}

// The − badge in edit mode. The ROM handles it as for apps; widgets get iOS's question.
static void hook_closeBoxTapped(id self, SEL _cmd, id manager, id iconView) {
    if (manager) gWPManager = manager;
    id icon = WPMsg(iconView, @"icon");
    if (WPIsOurWidgetIcon(icon) && [self isKindOfClass:[UIViewController class]]) {
        WPHLog(@"− badge: showing the removal confirmation");
        WPConfirmRemoval(self, icon);
        return;
    }
    ((void (*)(id, SEL, id, id))orig_closeBoxTapped)(self, _cmd, manager, iconView);
}

// Whether the − badge shows in edit mode: the ROM answers for apps it can uninstall only,
// so widgets got none. Like iOS, our widgets and stacks always have one.
static IMP orig_displaysCloseBox, orig_closeBoxType;

static BOOL hook_displaysCloseBox(id self, SEL _cmd, id manager, id iconView) {
    if (WPIsOurWidgetIcon(WPMsg(iconView, @"icon"))) return YES;
    return ((BOOL (*)(id, SEL, id, id))orig_displaysCloseBox)(self, _cmd, manager, iconView);
}

static NSInteger hook_closeBoxType(id self, SEL _cmd, id manager, id iconView, NSInteger proposed) {
    NSInteger type = ((NSInteger (*)(id, SEL, id, id, NSInteger))orig_closeBoxType)(self, _cmd, manager, iconView, proposed);
    if (!WPIsOurWidgetIcon(WPMsg(iconView, @"icon"))) return type;
    static BOOL logged;
    if (!logged) {
        logged = YES;
        WPHLog(@"Widget − badge: proposed %ld / ROM answer %ld", (long)proposed, (long)type);
    }
    if (type != 0) return type;
    return proposed != 0 ? proposed : 1; // 1: the delete (−) badge
}

// "Remove Widget" / "Remove Stack" in the long-press menu.
static void hook_wantsUninstall(id self, SEL _cmd, id manager, id icon, id location) {
    if (manager) gWPManager = manager;
    if (WPIsOurWidgetIcon(icon) && [self isKindOfClass:[UIViewController class]]) {
        WPHLog(@"Menu removal: showing the removal confirmation");
        WPConfirmRemoval(self, icon);
        return;
    }
    ((void (*)(id, SEL, id, id, id))orig_wantsUninstall)(self, _cmd, manager, icon, location);
}

static BOOL WPHook(NSString *className, NSString *selName, IMP replacement, IMP *orig) {
    Class cls = NSClassFromString(className);
    SEL sel = NSSelectorFromString(selName);
    Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!m) {
        WPHLog(@"  Nothing to hook: %@ %@", className, selName);
        return NO;
    }
    class_addMethod(cls, sel, method_getImplementation(m), method_getTypeEncoding(m));
    m = class_getInstanceMethod(cls, sel);
    *orig = method_setImplementation(m, replacement);
    return YES;
}

static void WPAddIfMissing(Class cls, NSString *selName, IMP imp, const char *types) {
    SEL sel = NSSelectorFromString(selName);
    if (cls && !class_getInstanceMethod(cls, sel)) class_addMethod(cls, sel, imp, types);
}

void WPHomeInstall(void) {
    WPGuardBoot();
    [WPProbe installRuntimeCrashLog];
    WPHook(@"SBHIconManager", @"customImageViewControllerForIconView:", (IMP)hook_customImageVC, &orig_customImageVC);
    WPHook(@"SBHIconManager", @"isWidgetValid:iconSizeClass:", (IMP)hook_isWidgetValid, &orig_isWidgetValid);
    WPHook(@"SBHIconManager", @"validatedWidgetIconForWidgetIcon:", (IMP)hook_validatedIcon, &orig_validatedIcon);
    WPHook(@"SBHIconManager", @"iconModel:validatedWidgetIconForWidgetIcon:", (IMP)hook_modelValidatedIcon, &orig_modelValidatedIcon);
    WPHook(@"SBHIconManager", @"supportedGridSizeClassesForWidgetWithKind:extensionBundleIdentifier:containerBundleIdentifier:",
           (IMP)hook_mgrSupported, &orig_mgrSupported);
    WPHook(@"SBHIconManager", @"iconModel:supportedGridSizeClassesForWidgetWithKind:extensionBundleIdentifier:containerBundleIdentifier:",
           (IMP)hook_mgrModelSupported, &orig_mgrModelSupported);
    WPHook(@"SBHIconModel", @"supportedGridSizeClassesForWidgetWithKind:extensionBundleIdentifier:containerBundleIdentifier:",
           (IMP)hook_modelSupported, &orig_modelSupported);
    WPHook(@"SBHIconModel", @"iconStateUnarchiver:supportedGridSizeClassesForWidgetWithKind:extensionBundleIdentifier:containerBundleIdentifier:",
           (IMP)hook_unarchiverSupported, &orig_unarchiverSupported);
    WPHook(@"NXHomeScreenIconStateStore", @"loadCurrentIconState:", (IMP)hook_storeLoad, &orig_storeLoad);
    WPHook(@"SBHIconModel", @"iconStateUnarchiver:didUnarchiveWidgetIcon:", (IMP)hook_didUnarchive, &orig_didUnarchive);
    WPHook(@"SBHWidget", @"displayName", (IMP)hook_widgetDisplayName, &orig_widgetDisplayName);
    WPHook(@"SBHIconManager", @"iconTapped:", (IMP)hook_iconTapped, &orig_iconTapped);
    WPHook(@"SBHIconManager", @"_makeCustomViewControllerForWidgetIcon:dataSource:location:", (IMP)hook_makeWidgetVC3, &orig_makeWidgetVC3);
    WPHook(@"SBHIconManager", @"_makeCustomViewControllerForWidgetIcon:dataSource:location:gridSizeClass:", (IMP)hook_makeWidgetVC4, &orig_makeWidgetVC4);
    WPHook(@"UIApplication", @"openURL:options:completionHandler:", (IMP)hook_appOpenURL, &orig_appOpenURL);
    WPHook(@"SBHWidget", @"icon:displayNameForLocation:", (IMP)hook_widgetIconDisplayName, &orig_widgetIconDisplayName);

    WPHook(@"NXHomeScreenViewController", @"iconManager:iconViewDisplaysCloseBox:", (IMP)hook_displaysCloseBox, &orig_displaysCloseBox);
    WPHook(@"NXHomeScreenViewController", @"iconManager:closeBoxTypeForIconView:proposedType:", (IMP)hook_closeBoxType, &orig_closeBoxType);
    WPHook(@"NXHomeScreenViewController", @"iconManager:iconCloseBoxTapped:", (IMP)hook_closeBoxTapped, &orig_closeBoxTapped);
    WPHook(@"NXHomeScreenViewController", @"iconManager:wantsUninstallForIcon:location:", (IMP)hook_wantsUninstall, &orig_wantsUninstall);

    Class home = NSClassFromString(@"NXHomeScreenViewController");
    WPAddIfMissing(home, @"iconManager:isWidgetValid:", (IMP)WPDelegateIsWidgetValid, "B32@0:8@16@24");
    WPAddIfMissing(home, @"iconManager:widgetWantsLaunchForBundleIdentifier:withAction:", (IMP)WPDelegateWidgetLaunch, "v40@0:8@16@24@32");
    WPAddIfMissing(home, @"iconManager:iconView:widgetWantsLaunchForBundleIdentifier:withAction:", (IMP)WPDelegateWidgetLaunch2, "v48@0:8@16@24@32@40");
    WPAddIfMissing(home, @"iconManager:wantsLaunchForWidgetURL:", (IMP)WPDelegateWidgetURL, "v32@0:8@16@24");
}

#pragma mark - Adding a widget

static id WPMakeWidget(NSString *extID, NSString *kind, NSString *container, NSString *unique) {
    Class widgetClass = NSClassFromString(@"SBHWidget");
    if (!widgetClass || !extID || !kind) return nil;
    WPWidgetExtension *ext = WPExtensionForID(extID);
    if (!container.length) container = ext.appBundleID ?: @"";
    id set = ext ? WPWidgetGridSet() : nil;
    SEL withID = NSSelectorFromString(@"initWithUniqueIdentifier:kind:extensionBundleIdentifier:containerBundleIdentifier:supportedGridSizeClasses:");
    if (unique.length && set && [widgetClass instancesRespondToSelector:withID]) { // keeps its saved identity
        return ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)([widgetClass alloc], withID, unique, kind, extID, container, set);
    }
    if (set) {
        return ((id (*)(id, SEL, id, id, id, id))objc_msgSend)([widgetClass alloc],
               NSSelectorFromString(@"initWithKind:extensionBundleIdentifier:containerBundleIdentifier:supportedGridSizeClasses:"),
               kind, extID, container, set);
    }
    return ((id (*)(id, SEL, id, id, id))objc_msgSend)([widgetClass alloc],
           NSSelectorFromString(@"initWithKind:extensionBundleIdentifier:containerBundleIdentifier:"), kind, extID, container);
}

static id WPMakeWidgetIcon(WPWidgetExtension *ext, NSString *kind, NSString *gridClass) {
    Class iconClass = NSClassFromString(@"SBWidgetIcon");
    id widget = WPMakeWidget(ext.extensionBundleID, kind, ext.appBundleID, nil);
    if (!iconClass || !widget) return nil;
    id icon = ((id (*)(id, SEL, id))objc_msgSend)([iconClass alloc], NSSelectorFromString(@"initWithWidget:"), widget);
    if (!icon) return nil;
    ((void (*)(id, SEL, id))objc_msgSend)(icon, NSSelectorFromString(@"setGridSizeClass:"), gridClass);
    return icon;
}

// A widget icon holding the saved widgets in order (a stack when there are several).
static id WPMakeStackIcon(NSArray<NSDictionary *> *saved, NSString *gridClass, NSString *selected) {
    Class iconClass = NSClassFromString(@"SBWidgetIcon");
    NSMutableArray *widgets = [NSMutableArray array];
    id selectedWidget = nil;
    for (NSDictionary *w in saved) {
        id widget = WPMakeWidget(w[@"ext"], w[@"kind"], w[@"container"], w[@"unique"]);
        if (!widget) continue;
        [widgets addObject:widget];
        if (selected.length && [w[@"unique"] isEqualToString:selected]) selectedWidget = widget;
    }
    if (!iconClass || widgets.count == 0) return nil;
    SEL many = NSSelectorFromString(@"initWithWidgets:");
    id icon = widgets.count > 1 && [iconClass instancesRespondToSelector:many]
                  ? ((id (*)(id, SEL, id))objc_msgSend)([iconClass alloc], many, widgets)
                  : ((id (*)(id, SEL, id))objc_msgSend)([iconClass alloc], NSSelectorFromString(@"initWithWidget:"), widgets.firstObject);
    if (!icon) return nil;
    ((void (*)(id, SEL, id))objc_msgSend)(icon, NSSelectorFromString(@"setGridSizeClass:"), gridClass);
    if (selectedWidget) { // the widget that was on top
        SEL setUser = NSSelectorFromString(@"setLastUserSelectedDataSource:"), setActive = NSSelectorFromString(@"setActiveWidget:");
        if ([icon respondsToSelector:setUser]) ((void (*)(id, SEL, id))objc_msgSend)(icon, setUser, selectedWidget);
        if ([icon respondsToSelector:setActive]) ((void (*)(id, SEL, id))objc_msgSend)(icon, setActive, selectedWidget);
    }
    return icon;
}

// Like iOS: the new widget goes to the top of the page being shown, and the icons it displaces
// move along (SBFolder bumps them onto the following pages). If the ROM's folder cannot do
// that, the widget goes into the first free space instead.
static NSString *WPInsertWidget(UIViewController *home, WPWidgetExtension *ext, NSString *kind, NSString *gridClass) {
    id manager = WPMsg(home, @"iconManager");
    id rootController = WPMsg(manager, @"rootFolderController");
    id list = WPMsg(WPMsg(rootController, @"currentIconListView"), @"model");
    id folder = WPMsg(manager, @"rootFolder");
    NSArray *lists = WPMsg(folder, @"lists");
    if (!list || ![lists isKindOfClass:[NSArray class]]) return @"The current page was not found";
    id icon = WPMakeWidgetIcon(ext, kind, gridClass);
    if (!icon) return @"Could not create the widget icon";
    WPHLog(@"Add: %@ / %@ / %@", ext.extensionBundleID, kind, gridClass);

    BOOL (^placed)(void) = ^BOOL {
        for (id l in (NSArray *)WPMsg(folder, @"lists") ?: @[]) {
            if ([(NSArray *)WPMsg(l, @"icons") ?: @[] containsObject:icon]) return YES;
        }
        return NO;
    };
    NSUInteger listIndex = [lists indexOfObject:list];
    SEL insertAt = NSSelectorFromString(@"insertIcon:atIndexPath:options:");
    if (listIndex != NSNotFound && [folder respondsToSelector:insertAt]) {
        NSUInteger indexes[2] = { listIndex, 0 };
        NSIndexPath *path = [NSIndexPath indexPathWithIndexes:indexes length:2];
        @try {
            ((id (*)(id, SEL, id, id, NSUInteger))objc_msgSend)(folder, insertAt, icon, path, 0);
        } @catch (NSException *e) {
            WPHLog(@"  Exception while inserting at the top: %@", e.reason);
        }
    }
    if (!placed()) {
        // The current page first, then any page with room.
        NSMutableArray *candidates = [NSMutableArray arrayWithObject:list];
        for (id l in lists) if (l != list) [candidates addObject:l];
        SEL allows = NSSelectorFromString(@"allowsAddingIcon:ignoringPlaceholders:");
        for (id target in candidates) {
            BOOL ok = [target respondsToSelector:allows] ? ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(target, allows, icon, NO) : YES;
            if (!ok) continue;
            ((id (*)(id, SEL, id))objc_msgSend)(target, NSSelectorFromString(@"addIcon:"), icon);
            break;
        }
    }
    if (!placed()) return @"No page has room";
    id model = WPMsg(manager, @"iconModel");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SEL save = NSSelectorFromString(@"saveIconStateIfNeeded");
        if ([model respondsToSelector:save]) ((BOOL (*)(id, SEL))objc_msgSend)(model, save);
    });
    return nil;
}

#pragma mark - Add sheet (like iOS's widget gallery)

// Home screen sizes a widget offers: what its descriptor says (supportedFamilies), else what
// its kind name suggests ("….small"), else all three.
static NSArray<NSString *> *WPFamiliesOfWidget(NSDictionary *w) {
    NSArray *f = w[@"families"];
    if ([f isKindOfClass:[NSArray class]]) return f; // empty: only for the lock screen and other places
    NSString *kind = [w[@"kind"] lowercaseString];
    NSMutableArray *guess = [NSMutableArray array];
    for (NSString *size in @[ @"small", @"medium", @"large" ]) {
        if ([kind containsString:size]) [guess addObject:size];
    }
    return guess.count ? guess : @[ @"small", @"medium", @"large" ];
}

// The widgets that can go on the home screen (iOS lists only those in the gallery).
static NSArray<NSDictionary *> *WPHomeScreenWidgets(NSArray<NSDictionary *> *widgets) {
    return [widgets filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *w, NSDictionary *b) {
        return WPFamiliesOfWidget(w).count > 0;
    }]];
}

// An app whose widgets are known (loaded) and are all for other places is not listed.
static BOOL WPAppHasHomeWidgets(WPWidgetExtension *ext) {
    NSArray *loaded = [WPProbe loadedWidgetsForExtension:ext];
    return !loaded || WPHomeScreenWidgets(loaded).count > 0;
}

// A readable name when the descriptor has none: the last meaningful part of the kind.
static NSString *WPWidgetTitle(NSDictionary *w, WPWidgetExtension *ext) {
    NSString *name = w[@"name"];
    if ([name isKindOfClass:[NSString class]] && name.length) return name;
    NSMutableArray *parts = [[[w[@"kind"] ?: @"" componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"._-"]]
                              filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] mutableCopy];
    NSSet *noise = [NSSet setWithArray:@[ @"widget", @"widgets", @"small", @"medium", @"large", @"com", @"jp", @"app", @"extension" ]];
    while (parts.count && [noise containsObject:[parts.lastObject lowercaseString]]) [parts removeLastObject];
    NSString *last = parts.lastObject;
    if (last.length && ![last isEqualToString:ext.appBundleID]) {
        // "TodayTasksWidget" → "Today Tasks"
        NSString *spaced = [last stringByReplacingOccurrencesOfString:@"([a-z])([A-Z])" withString:@"$1 $2"
                                                              options:NSRegularExpressionSearch range:NSMakeRange(0, last.length)];
        spaced = [spaced stringByReplacingOccurrencesOfString:@"Widget" withString:@""];
        spaced = [spaced stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (spaced.length) return [[spaced substringToIndex:1].uppercaseString stringByAppendingString:[spaced substringFromIndex:1]];
    }
    return ext.appName;
}

static NSString *WPGridClassForFamilyName(NSString *f) {
    if ([f isEqualToString:@"small"]) return WPGridSmall();
    if ([f isEqualToString:@"large"]) return WPGridLarge();
    return WPGridMedium();
}

// The size and corner radius of a widget of that size on the current page, as SpringBoardHome
// lays it out; fallback: iPhone sizes for this screen width.
static SBIconImageInfo WPImageInfoForGridClass(UIViewController *home, NSString *gridClass) {
    SBIconImageInfo info = { CGSizeZero, UIScreen.mainScreen.scale, 0 };
    id listView = WPMsg(WPMsg(WPMsg(home, @"iconManager"), @"rootFolderController"), @"currentIconListView");
    SEL sel = NSSelectorFromString(@"iconImageInfoForGridSizeClass:");
    if ([listView respondsToSelector:sel]) info = ((SBIconImageInfo (*)(id, SEL, id))objc_msgSend)(listView, sel, gridClass);
    if (info.size.width < 40) {
        CGFloat w = MIN(UIScreen.mainScreen.bounds.size.width, UIScreen.mainScreen.bounds.size.height);
        CGFloat small = w >= 428 ? 170 : w >= 390 ? 158 : w >= 375 ? 148 : 141;
        CGFloat wide = w >= 428 ? 364 : w >= 390 ? 338 : w >= 375 ? 321 : 292;
        CGFloat tall = w >= 428 ? 382 : w >= 390 ? 354 : w >= 375 ? 324 : 311;
        info.size = [gridClass isEqualToString:WPGridSmall()] ? CGSizeMake(small, small)
                  : [gridClass isEqualToString:WPGridLarge()] ? CGSizeMake(wide, tall) : CGSizeMake(wide, small);
        info.scale = UIScreen.mainScreen.scale;
    }
    if (info.continuousCornerRadius <= 0) info.continuousCornerRadius = 22;
    return info;
}

// The app's icon as the home screen draws it, or from its bundle.
static UIImage *WPAppIcon(WPWidgetExtension *ext, UIViewController *home) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    UIImage *img = cache[ext.appBundleID];
    if (img) return img;
    @try {
        id model = WPMsg(WPMsg(home, @"iconManager"), @"iconModel");
        SEL leafSel = NSSelectorFromString(@"leafIconForIdentifier:");
        id leaf = [model respondsToSelector:leafSel] ? ((id (*)(id, SEL, id))objc_msgSend)(model, leafSel, ext.appBundleID) : nil;
        id dataSource = WPMsg(leaf, @"activeDataSource") ?: WPMsg(leaf, @"_bestDataSource");
        Class leafClass = NSClassFromString(@"SBLeafIcon");
        SEL imageSel = NSSelectorFromString(@"iconImageForDataSource:ofIcon:info:");
        if (leaf && dataSource && [leafClass respondsToSelector:imageSel]) {
            SBIconImageInfo info = { CGSizeMake(60, 60), UIScreen.mainScreen.scale, 13.5 };
            img = ((id (*)(id, SEL, id, id, SBIconImageInfo))objc_msgSend)(leafClass, imageSel, dataSource, leaf, info);
        }
    } @catch (NSException *e) {
        img = nil;
    }
    if (![img isKindOfClass:[UIImage class]]) img = nil;
    if (!img) {
        NSBundle *bundle = [NSBundle bundleWithPath:ext.appPath];
        NSDictionary *icons = [bundle objectForInfoDictionaryKey:@"CFBundleIcons"][@"CFBundlePrimaryIcon"];
        NSMutableArray *names = [NSMutableArray array];
        if ([icons[@"CFBundleIconFiles"] isKindOfClass:[NSArray class]]) [names addObjectsFromArray:[icons[@"CFBundleIconFiles"] reverseObjectEnumerator].allObjects];
        if ([icons[@"CFBundleIconName"] isKindOfClass:[NSString class]]) [names addObject:icons[@"CFBundleIconName"]];
        for (NSString *n in names) {
            img = [UIImage imageNamed:n inBundle:bundle compatibleWithTraitCollection:nil];
            if (img) break;
        }
    }
    if (!img) img = [UIImage systemImageNamed:@"app.fill"];
    cache[ext.appBundleID] = img;
    return img;
}

static UIImageView *WPIconView(UIImage *image, CGFloat size) {
    UIImageView *v = [[UIImageView alloc] initWithImage:image];
    v.contentMode = UIViewContentModeScaleAspectFill;
    v.layer.cornerRadius = size * 0.225;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    v.clipsToBounds = YES;
    v.tintColor = UIColor.secondaryLabelColor;
    return v;
}

// A widget preview at its real size (drawn by the app's own code, not interactive).
static WPHomeWidgetViewController *WPMakePreview(WPWidgetExtension *ext, NSString *kind, NSString *gridClass, SBIconImageInfo info) {
    WPHomeWidgetViewController *vc = [WPHomeWidgetViewController new];
    vc.extension = ext;
    vc.kind = kind;
    vc.gridSizeClass = gridClass;
    vc.preview = YES;
    [vc setIconImageInfo:info];
    return vc;
}

@class WPGalleryViewController;

#pragma mark Detail: one app's widgets, page by page

@interface WPGalleryDetailViewController : UIViewController <UIScrollViewDelegate>
@property (nonatomic, weak) UIViewController *home;
@property (nonatomic, strong) WPWidgetExtension *extension;
@property (nonatomic, copy) NSArray<NSDictionary *> *widgets;
@property (nonatomic, copy) NSString *startKind;
@end

@implementation WPGalleryDetailViewController {
    NSArray<NSDictionary *> *_pages; // { widget, gridClass }
    UIScrollView *_scroll;
    UIPageControl *_dots;
    UIButton *_add;
    NSMutableDictionary<NSNumber *, UIView *> *_pageViews;
    NSInteger _current;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    NSMutableArray *pages = [NSMutableArray array];
    NSInteger start = 0;
    for (NSDictionary *w in self.widgets) {
        if (self.startKind && [w[@"kind"] isEqualToString:self.startKind] && start == 0) start = pages.count;
        for (NSString *f in WPFamiliesOfWidget(w)) [pages addObject:@{ @"widget" : w, @"gridClass" : WPGridClassForFamilyName(f) }];
    }
    _pages = pages;
    _pageViews = [NSMutableDictionary dictionary];

    // Header: the app, and a close button.
    UIImageView *icon = WPIconView(WPAppIcon(self.extension, self.home), 26);
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *appName = [UILabel new];
    appName.text = self.extension.appName;
    appName.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    appName.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeClose];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    for (UIView *v in @[ icon, appName, close ]) [self.view addSubview:v];

    _scroll = [UIScrollView new];
    _scroll.pagingEnabled = YES;
    _scroll.showsHorizontalScrollIndicator = NO;
    _scroll.delegate = self;
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_scroll];

    _dots = [UIPageControl new];
    _dots.numberOfPages = pages.count;
    _dots.hidesForSinglePage = YES;
    _dots.currentPageIndicatorTintColor = UIColor.labelColor;
    _dots.pageIndicatorTintColor = UIColor.tertiaryLabelColor;
    _dots.translatesAutoresizingMaskIntoConstraints = NO;
    [_dots addTarget:self action:@selector(dotsChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_dots];

    UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
    config.title = @"Add Widget";
    config.image = [UIImage systemImageNamed:@"plus.circle.fill"];
    config.imagePadding = 6;
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    config.baseBackgroundColor = UIColor.systemBlueColor;
    config.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attrs) {
        NSMutableDictionary *a = [attrs mutableCopy];
        a[NSFontAttributeName] = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        return a;
    };
    _add = [UIButton buttonWithConfiguration:config primaryAction:nil];
    _add.translatesAutoresizingMaskIntoConstraints = NO;
    _add.enabled = pages.count > 0;
    [_add addTarget:self action:@selector(addCurrent) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_add];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [icon.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:22],
        [icon.widthAnchor constraintEqualToConstant:26], [icon.heightAnchor constraintEqualToConstant:26],
        [appName.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:10],
        [appName.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
        [appName.trailingAnchor constraintLessThanOrEqualToAnchor:close.leadingAnchor constant:-10],
        [close.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-18],
        [close.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
        [_scroll.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:18],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:_dots.topAnchor constant:-6],
        [_dots.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_dots.bottomAnchor constraintEqualToAnchor:_add.topAnchor constant:-14],
        [_add.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_add.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [_add.heightAnchor constraintEqualToConstant:50],
        [_add.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
    ]];
    _current = start;
    _dots.currentPage = start;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize s = _scroll.bounds.size;
    if (s.width < 10) return;
    _scroll.contentSize = CGSizeMake(s.width * _pages.count, s.height);
    for (NSNumber *key in _pageViews) [self layoutPage:_pageViews[key] index:key.integerValue];
    if (!_scroll.isDragging && !_scroll.isDecelerating) _scroll.contentOffset = CGPointMake(_current * s.width, 0);
    [self loadPagesAround:_current];
}

// Pages are built when they come near (each one draws the widget).
- (void)loadPagesAround:(NSInteger)index {
    for (NSInteger i = index - 1; i <= index + 1; i++) {
        if (i < 0 || i >= (NSInteger)_pages.count || _pageViews[@(i)]) continue;
        UIView *page = [self makePage:i];
        _pageViews[@(i)] = page;
        [_scroll addSubview:page];
        [self layoutPage:page index:i];
    }
}

- (UIView *)makePage:(NSInteger)index {
    NSDictionary *p = _pages[index];
    NSDictionary *w = p[@"widget"];
    UIView *page = [UIView new];
    UILabel *title = [UILabel new];
    title.text = WPWidgetTitle(w, self.extension);
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.6;
    title.tag = 1;
    UILabel *desc = [UILabel new];
    desc.text = [w[@"description"] isKindOfClass:[NSString class]] ? w[@"description"] : @"";
    desc.font = [UIFont systemFontOfSize:15];
    desc.textColor = UIColor.secondaryLabelColor;
    desc.textAlignment = NSTextAlignmentCenter;
    desc.numberOfLines = 3;
    desc.tag = 2;
    [page addSubview:title];
    [page addSubview:desc];
    SBIconImageInfo info = WPImageInfoForGridClass(self.home, p[@"gridClass"]);
    WPHomeWidgetViewController *preview = WPMakePreview(self.extension, w[@"kind"], p[@"gridClass"], info);
    [self addChildViewController:preview];
    preview.view.tag = 3;
    preview.view.bounds = CGRectMake(0, 0, info.size.width, info.size.height);
    // A soft shadow under the widget, as in the gallery.
    UIView *shadow = [UIView new];
    shadow.tag = 4;
    shadow.layer.shadowColor = UIColor.blackColor.CGColor;
    shadow.layer.shadowOpacity = 0.18;
    shadow.layer.shadowRadius = 14;
    shadow.layer.shadowOffset = CGSizeMake(0, 6);
    [shadow addSubview:preview.view];
    [page addSubview:shadow];
    [preview didMoveToParentViewController:self];
    return page;
}

- (void)layoutPage:(UIView *)page index:(NSInteger)index {
    CGSize s = _scroll.bounds.size;
    page.frame = CGRectMake(index * s.width, 0, s.width, s.height);
    UILabel *title = [page viewWithTag:1], *desc = [page viewWithTag:2];
    UIView *shadow = [page viewWithTag:4], *preview = [page viewWithTag:3];
    CGFloat inset = 28;
    title.frame = CGRectMake(inset, 4, s.width - inset * 2, 36);
    CGSize d = [desc sizeThatFits:CGSizeMake(s.width - inset * 2, 80)];
    desc.frame = CGRectMake(inset, 46, s.width - inset * 2, MIN(d.height, 60));
    CGFloat top = CGRectGetMaxY(desc.frame) + 16;
    CGSize real = preview.bounds.size;
    CGFloat room = MAX(40, s.height - top - 8);
    CGFloat scale = MIN(1, MIN((s.width - 32) / MAX(real.width, 1), room / MAX(real.height, 1)));
    shadow.bounds = CGRectMake(0, 0, real.width, real.height);
    shadow.center = CGPointMake(s.width / 2, top + room / 2);
    shadow.transform = CGAffineTransformMakeScale(scale, scale);
    preview.frame = shadow.bounds;
    shadow.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:shadow.bounds cornerRadius:preview.layer.cornerRadius].CGPath;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    CGFloat w = scrollView.bounds.size.width;
    if (w < 1) return;
    NSInteger page = (NSInteger)lround(scrollView.contentOffset.x / w);
    page = MAX(0, MIN((NSInteger)_pages.count - 1, page));
    if (page != _current) {
        _current = page;
        _dots.currentPage = page;
        [self loadPagesAround:page];
    }
}

- (void)dotsChanged {
    _current = _dots.currentPage;
    [_scroll setContentOffset:CGPointMake(_current * _scroll.bounds.size.width, 0) animated:YES];
    [self loadPagesAround:_current];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)addCurrent {
    if (_current < 0 || _current >= (NSInteger)_pages.count) return;
    NSDictionary *p = _pages[_current];
    NSString *error = WPInsertWidget(self.home, self.extension, p[@"widget"][@"kind"], p[@"gridClass"]);
    if (error) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Could Not Add" message:error
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    // Close the whole gallery (and this sheet on it), like iOS.
    UIViewController *gallery = self.presentingViewController;
    [(gallery.presentingViewController ?: gallery) dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark Gallery: suggestions and the apps with widgets

@interface WPGalleryViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, weak) UIViewController *home;
@end

@implementation WPGalleryViewController {
    UISearchBar *_search;
    UITableView *_table;
    NSArray<WPWidgetExtension *> *_apps;
    NSArray<WPWidgetExtension *> *_shownApps;
    NSArray<NSDictionary *> *_suggestions; // { ext, widget, gridClass }, from apps already loaded
    UIView *_suggestionsView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    _apps = [[WPKnownExtensions(YES).allValues filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WPWidgetExtension *e, NSDictionary *b) {
        return WPAppHasHomeWidgets(e);
    }]] sortedArrayUsingComparator:^NSComparisonResult(WPWidgetExtension *a, WPWidgetExtension *b) {
        return [a.appName localizedStandardCompare:b.appName];
    }];
    _shownApps = _apps;

    _search = [UISearchBar new];
    _search.searchBarStyle = UISearchBarStyleMinimal;
    _search.placeholder = @"Search Widgets";
    _search.delegate = self;
    _search.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_search];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _table.dataSource = self;
    _table.delegate = self;
    _table.backgroundColor = UIColor.clearColor;
    _table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    _table.rowHeight = 52;
    _table.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_table];
    [NSLayoutConstraint activateConstraints:@[
        [_search.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:18],
        [_search.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:10],
        [_search.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-10],
        [_table.topAnchor constraintEqualToAnchor:_search.bottomAnchor constant:4],
        [_table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [self buildSuggestions];
}

// Suggestions: one widget per app (its first for the home screen), from apps whose extension
// is already loaded (no app code runs just for opening the gallery). The app's row lists all of
// them. Small ones two to a row, larger ones full width, like iOS.
- (void)buildSuggestions {
    NSMutableArray *items = [NSMutableArray array];
    NSString *q = _search.text.length ? _search.text : nil;
    for (WPWidgetExtension *ext in _apps) {
        NSArray *widgets = [WPProbe loadedWidgetsForExtension:ext];
        for (NSDictionary *w in widgets) {
            NSString *title = WPWidgetTitle(w, ext);
            if (q && [title rangeOfString:q options:NSCaseInsensitiveSearch].location == NSNotFound &&
                [ext.appName rangeOfString:q options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
            NSString *family = WPFamiliesOfWidget(w).firstObject;
            if (!family) continue; // not for the home screen
            [items addObject:@{ @"ext" : ext, @"widget" : w, @"gridClass" : WPGridClassForFamilyName(family) }];
            break;
        }
        if (items.count >= 8) break;
    }
    _suggestions = items;
    for (UIViewController *c in self.childViewControllers.copy) {
        [c willMoveToParentViewController:nil];
        [c.view removeFromSuperview];
        [c removeFromParentViewController];
    }
    UIView *container = [UIView new];
    CGFloat width = self.view.bounds.size.width > 10 ? self.view.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    CGFloat inset = 20, gap = 14, y = 8;
    CGFloat column = (width - inset * 2 - gap) / 2;
    NSInteger col = 0;
    for (NSUInteger i = 0; i < items.count; i++) {
        NSDictionary *it = items[i];
        BOOL small = [it[@"gridClass"] isEqualToString:WPGridSmall()];
        if (!small && col == 1) { y += column + 46; col = 0; }
        SBIconImageInfo info = WPImageInfoForGridClass(self.home, it[@"gridClass"]);
        CGFloat w = small ? column : width - inset * 2;
        CGFloat scale = w / MAX(info.size.width, 1);
        CGFloat h = info.size.height * scale;
        CGFloat x = small ? inset + col * (column + gap) : inset;
        UIButton *tile = [UIButton buttonWithType:UIButtonTypeCustom];
        tile.frame = CGRectMake(x, y, w, h + 40);
        tile.tag = (NSInteger)i;
        [tile addTarget:self action:@selector(openSuggestion:) forControlEvents:UIControlEventTouchUpInside];
        WPHomeWidgetViewController *preview = WPMakePreview(it[@"ext"], it[@"widget"][@"kind"], it[@"gridClass"], info);
        [self addChildViewController:preview];
        preview.view.bounds = CGRectMake(0, 0, info.size.width, info.size.height);
        preview.view.transform = CGAffineTransformMakeScale(scale, scale);
        preview.view.center = CGPointMake(w / 2, h / 2);
        preview.view.userInteractionEnabled = NO;
        [tile addSubview:preview.view];
        [preview didMoveToParentViewController:self];
        UILabel *app = [UILabel new];
        app.text = ((WPWidgetExtension *)it[@"ext"]).appName;
        app.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        app.textAlignment = NSTextAlignmentCenter;
        app.frame = CGRectMake(0, h + 6, w, 17);
        UILabel *sub = [UILabel new];
        sub.text = WPWidgetTitle(it[@"widget"], it[@"ext"]);
        sub.font = [UIFont systemFontOfSize:12];
        sub.textColor = UIColor.secondaryLabelColor;
        sub.textAlignment = NSTextAlignmentCenter;
        sub.frame = CGRectMake(0, h + 22, w, 16);
        [tile addSubview:app];
        [tile addSubview:sub];
        [container addSubview:tile];
        if (small && col == 0) {
            col = 1;
        } else {
            y += h + 46;
            col = 0;
        }
    }
    if (col == 1) y += column + 46;
    container.frame = CGRectMake(0, 0, width, items.count ? y : 0);
    _suggestionsView = container;
    _table.tableHeaderView = items.count ? container : nil;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (_suggestionsView && fabs(_suggestionsView.bounds.size.width - self.view.bounds.size.width) > 1) [self buildSuggestions];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)text {
    if (!text.length) {
        _shownApps = _apps;
    } else {
        _shownApps = [_apps filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WPWidgetExtension *e, NSDictionary *b) {
            if ([e.appName rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
            for (NSDictionary *w in [WPProbe loadedWidgetsForExtension:e]) {
                if ([WPWidgetTitle(w, e) rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
            }
            return NO;
        }]];
    }
    [self buildSuggestions];
    [_table reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return MAX(1, (NSInteger)_shownApps.count);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return gWPGuardTripped ? @"Widgets are not drawn during this launch because of repeated crashes just before." : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    if (_shownApps.count == 0) {
        cell.textLabel.text = _search.text.length ? @"No Results" : @"No apps with widgets";
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    WPWidgetExtension *e = _shownApps[indexPath.row];
    UIListContentConfiguration *c = [UIListContentConfiguration cellConfiguration];
    c.text = e.appName;
    c.image = WPAppIcon(e, self.home);
    c.imageProperties.maximumSize = CGSizeMake(32, 32);
    c.imageProperties.cornerRadius = 7.5;
    c.imageToTextPadding = 14;
    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_shownApps.count == 0) return;
    WPWidgetExtension *e = _shownApps[indexPath.row];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    cell.accessoryView = spinner;
    [spinner startAnimating];
    tableView.userInteractionEnabled = NO;
    [WPProbe prepareExtension:e completion:^{
        tableView.userInteractionEnabled = YES;
        cell.accessoryView = nil;
        [self openApp:e widgets:[WPProbe widgetsForExtension:e] startKind:nil];
        [self buildSuggestions];
    }];
}

- (void)openSuggestion:(UIButton *)tile {
    if (tile.tag < 0 || tile.tag >= (NSInteger)_suggestions.count) return;
    NSDictionary *it = _suggestions[tile.tag];
    WPWidgetExtension *ext = it[@"ext"];
    [self openApp:ext widgets:[WPProbe widgetsForExtension:ext] startKind:it[@"widget"][@"kind"]];
}

- (void)openApp:(WPWidgetExtension *)ext widgets:(NSArray *)allWidgets startKind:(NSString *)kind {
    NSArray *widgets = WPHomeScreenWidgets(allWidgets);
    if (widgets.count == 0) {
        NSString *message = allWidgets.count ? @"This app's widgets are for the Lock Screen and cannot be placed on the Home Screen." : @"No widgets were found";
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:ext.appName message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    WPGalleryDetailViewController *detail = [WPGalleryDetailViewController new];
    detail.home = self.home;
    detail.extension = ext;
    detail.widgets = widgets;
    detail.startKind = kind;
    detail.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *sheet = detail.sheetPresentationController;
    sheet.detents = @[ UISheetPresentationControllerDetent.largeDetent ];
    sheet.preferredCornerRadius = 38;
    [self presentViewController:detail animated:YES completion:nil];
}

@end

void WPHomeOpenAddSheet(UIViewController *home) {
    if (!home) return;
    UIViewController *top = home;
    while (top.presentedViewController) top = top.presentedViewController;
    WPGalleryViewController *gallery = [WPGalleryViewController new];
    gallery.home = home;
    gallery.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *sheet = gallery.sheetPresentationController;
    sheet.detents = @[ UISheetPresentationControllerDetent.largeDetent ];
    sheet.prefersGrabberVisible = YES;
    sheet.preferredCornerRadius = 38;
    [top presentViewController:gallery animated:YES completion:nil];
}
