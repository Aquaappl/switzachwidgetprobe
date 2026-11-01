// SwitzachWidgetHost: runs one app's widget extension in its own process.
//
// SpringBoard starts one host per widget extension (WPRemote.m) and talks to it over a pipe:
// one JSON object per line on stdin (requests) and stdout (answers and events). The host
// loads the extension with WPProbe (the same loader as before) and draws each widget
// SpringBoard asks for in a UIWindow of its own (SwiftUI only draws in a window). The layer of
// the window's root view is moved into a Core Animation remote context — the views stay in the
// window, so SwiftUI keeps updating them — and SpringBoard shows that context with a
// CALayerHost. Taps come from SpringBoard (a hosted context does not receive touches) and run
// the widget's buttons and links here. The app's code never runs inside SpringBoard: when it
// crashes, only this process ends.
//
// Requests (stdin)                                     Answers / events (stdout)
//   {"op":"list"}                                        {"op":"widgets","list":[…]}
//   {"op":"show","view":n,"kind":…,"family":0-2,          {"op":"context","view":n,"id":…}
//    "w":…,"h":…,"style":"dark"|"light"}                  {"op":"drawn","view":n}
//                                                         {"op":"failed","view":n,"reason":…}
//   {"op":"tap","view":n,"x":…,"y":…}                    {"op":"tapped","view":n,"result":
//                                                           "button"|"link"|"none"|"app",…}
//                                                         {"op":"open","url":…}  (a link)
//   {"op":"hide","view":n}
//   {"op":"log","on":true|false}
//
//   SwitzachWidgetHost <extension id> <app id> <app name> <app path> <extension path>
//                      <executable> <data container or "">
//
// Exits when SpringBoard closes stdin, or after a minute without any widget to show.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import "WPProbe.h"

static BOOL gWPHostLog;
BOOL WPDiagnosticLogEnabled(void) { return gWPHostLog; }

static WPWidgetExtension *gExt;

#pragma mark - Talking to SpringBoard

static void WPSend(NSDictionary *message) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    if (!json) return;
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    const uint8_t *p = line.bytes;
    size_t left = line.length;
    while (left > 0) {
        ssize_t n = write(STDOUT_FILENO, p, left);
        if (n <= 0) {
            if (errno == EINTR) continue;
            exit(0); // SpringBoard is gone
        }
        p += n;
        left -= (size_t)n;
    }
}

static void WPHostLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void WPHostLog(NSString *fmt, ...) {
    if (!gWPHostLog) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    WPSend(@{ @"op" : @"log", @"text" : line });
}

#pragma mark - One widget view

@interface WPHostedView : NSObject
@property (nonatomic) NSInteger viewID;
@property (nonatomic, copy) NSString *kind;
@property (nonatomic) int family;
@property (nonatomic) CGSize size;
@property (nonatomic) UIUserInterfaceStyle style;
@property (nonatomic, strong) id context;      // CAContext (remote)
@property (nonatomic, strong) CALayer *root;   // its layer: holds the container's layer
@property (nonatomic, strong) UIWindow *window; // where SwiftUI draws
@property (nonatomic, strong) UIViewController *container; // the window's root: holds the widget
@property (nonatomic, strong) UIViewController *shown;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) BOOL rendering;
@property (nonatomic) BOOL renderAgain;
@property (nonatomic) BOOL drawnOnce;
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation WPHostedView
@end

static NSMutableDictionary<NSNumber *, WPHostedView *> *gViews;

static void WPRender(WPHostedView *v, BOOL placeholder);

static NSUInteger WPCountLayers(CALayer *layer) {
    NSUInteger n = 0;
    for (CALayer *l in layer.sublayers) n += 1 + WPCountLayers(l);
    return n;
}

// The window's root view (the container) has its layer moved into the remote context, so what
// SpringBoard shows is the widget itself, still drawn and updated by SwiftUI in the window
// (timers, progress, pressed buttons). Only this one layer is moved: the widget's own views are
// ordinary subviews of the container, so putting a new drawing in and taking the old one out is
// plain UIKit. (A widget view whose layer is moved by itself is left with a dangling superview
// when it is released, and SwiftUI crashed on that.) SwiftUI draws nothing in a view laid out
// while its layers are not under the window's, so the container's layer goes back under the
// window while a new drawing is put in, and out again in the same transaction (SpringBoard
// never sees it gone).
static void WPShowController(WPHostedView *v, UIViewController *vc) {
    if (!v.window) {
        v.window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, v.size.width, v.size.height)];
        v.window.backgroundColor = UIColor.clearColor;
        v.container = [UIViewController new];
        v.container.view.backgroundColor = UIColor.clearColor;
        v.window.rootViewController = v.container;
        v.window.hidden = NO;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [v.window.layer addSublayer:v.container.view.layer];
    v.window.frame = CGRectMake(0, 0, v.size.width, v.size.height);
    v.container.view.frame = v.window.bounds;
    v.window.overrideUserInterfaceStyle = v.style;
    UIViewController *old = v.shown;
    vc.view.backgroundColor = UIColor.clearColor;
    [v.container addChildViewController:vc];
    vc.view.frame = v.container.view.bounds;
    [v.container.view addSubview:vc.view];
    [vc didMoveToParentViewController:v.container];
    [vc.view layoutIfNeeded];
    if (old) {
        [old willMoveToParentViewController:nil];
        [old.view removeFromSuperview];
        [old removeFromParentViewController];
    }
    [v.root addSublayer:v.container.view.layer];
    v.shown = vc;
    v.generation++;
    [CATransaction commit];
    [CATransaction flush];
    if (gWPHostLog) {
        NSUInteger generation = v.generation;
        __weak WPHostedView *weakView = v;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WPHostedView *strong = weakView;
            if (strong && strong.generation == generation) WPHostLog(@"%@: %lu layer(s) drawn", strong.kind, (unsigned long)WPCountLayers(strong.shown.view.layer));
        });
    }
}

static void WPScheduleRefresh(WPHostedView *v, NSDate *next) {
    [v.refreshTimer invalidate];
    NSTimeInterval delay = next ? MAX(60, next.timeIntervalSinceNow) : 30 * 60;
    __weak WPHostedView *weakView = v;
    v.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *t) {
        WPHostedView *strong = weakView;
        if (strong) WPRender(strong, NO);
    }];
    v.refreshTimer.tolerance = 10;
}

static void WPRenderFinished(WPHostedView *v) {
    v.rendering = NO;
    if (!v.renderAgain) return;
    v.renderAgain = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ WPRender(v, NO); });
}

// Draws (again). A refresh asked for while the app's timeline is still being fetched becomes
// one more drawing after it.
static void WPRender(WPHostedView *v, BOOL placeholder) {
    if (!gViews[@(v.viewID)]) return;
    if (v.rendering) {
        v.renderAgain = YES;
        return;
    }
    v.rendering = YES;
    __weak WPHostedView *weakView = v;
    @try {
        [WPProbe renderWidgetKind:v.kind extension:gExt family:v.family size:v.size placeholder:(placeholder || !v.drawnOnce)
                           update:^(UIViewController *vc, NSDate *next, BOOL final) {
            WPHostedView *strong = weakView;
            if (!strong || !gViews[@(strong.viewID)]) return;
            if (vc) {
                WPShowController(strong, vc);
                if (!strong.drawnOnce || final) WPSend(@{ @"op" : @"drawn", @"view" : @(strong.viewID), @"final" : @(final) });
                strong.drawnOnce = YES;
            } else if (final && !strong.drawnOnce) {
                WPSend(@{ @"op" : @"failed", @"view" : @(strong.viewID), @"reason" : @"nothing to draw" });
            }
            if (final) {
                WPScheduleRefresh(strong, next);
                WPRenderFinished(strong);
            }
        }];
    } @catch (NSException *e) {
        WPHostLog(@"exception while drawing %@: %@", v.kind, e.reason);
        WPSend(@{ @"op" : @"failed", @"view" : @(v.viewID), @"reason" : e.reason ?: @"exception" });
        WPRenderFinished(v);
    }
}

#pragma mark - Requests

static NSTimer *gIdleTimer;

// No widget to show for a minute: this process is not needed (SpringBoard starts it again).
static void WPCheckIdle(void) {
    [gIdleTimer invalidate];
    gIdleTimer = nil;
    if (gViews.count) return;
    gIdleTimer = [NSTimer scheduledTimerWithTimeInterval:60 repeats:NO block:^(NSTimer *t) {
        if (gViews.count == 0) exit(0);
    }];
}

static void WPShow(NSDictionary *m) {
    NSNumber *viewID = m[@"view"];
    NSString *kind = m[@"kind"];
    if (![viewID isKindOfClass:[NSNumber class]] || ![kind isKindOfClass:[NSString class]]) return;
    CGSize size = CGSizeMake([m[@"w"] doubleValue], [m[@"h"] doubleValue]);
    if (size.width < 1 || size.height < 1) return;
    WPHostedView *v = gViews[viewID];
    BOOL fresh = (v == nil);
    if (fresh) {
        v = [WPHostedView new];
        v.viewID = viewID.integerValue;
        gViews[viewID] = v;
        // Touches over a hosted context would go to the process that owns it: they are left to
        // SpringBoard, which sends taps here itself.
        NSString *const *ignoresHitTest = (NSString *const *)dlsym(RTLD_DEFAULT, "kCAContextIgnoresHitTest");
        NSDictionary *options = ignoresHitTest ? @{ *ignoresHitTest : @YES } : @{};
        v.context = ((id (*)(id, SEL, id))objc_msgSend)(NSClassFromString(@"CAContext"), NSSelectorFromString(@"remoteContextWithOptions:"), options);
        if (!v.context) {
            [gViews removeObjectForKey:viewID];
            WPSend(@{ @"op" : @"failed", @"view" : viewID, @"reason" : @"no remote context" });
            return;
        }
        [CATransaction begin];
        v.root = [CALayer layer];
        v.root.contentsGravity = kCAGravityTopLeft;
        ((void (*)(id, SEL, id))objc_msgSend)(v.context, NSSelectorFromString(@"setLayer:"), v.root);
        [CATransaction commit];
    }
    BOOL changed = fresh || ![v.kind isEqualToString:kind] || v.family != [m[@"family"] intValue] || !CGSizeEqualToSize(v.size, size);
    v.kind = kind;
    v.family = [m[@"family"] intValue];
    v.size = size;
    UIUserInterfaceStyle style = [m[@"style"] isEqual:@"light"] ? UIUserInterfaceStyleLight : UIUserInterfaceStyleDark;
    BOOL restyled = !fresh && style != v.style;
    v.style = style;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    v.root.frame = CGRectMake(0, 0, size.width, size.height);
    [CATransaction commit];
    [CATransaction flush];
    uint32_t contextID = ((uint32_t (*)(id, SEL))objc_msgSend)(v.context, NSSelectorFromString(@"contextId"));
    WPSend(@{ @"op" : @"context", @"view" : viewID, @"id" : @(contextID) });
    WPCheckIdle();
    if (changed) {
        if (!fresh) v.drawnOnce = NO; // a new size starts from its placeholder
        WPRender(v, YES);
    } else if (restyled && v.shown) {
        v.window.overrideUserInterfaceStyle = style;
    } else if (v.drawnOnce) {
        WPSend(@{ @"op" : @"drawn", @"view" : viewID, @"final" : @YES });
    }
}

static void WPHide(NSDictionary *m) {
    NSNumber *viewID = m[@"view"];
    WPHostedView *v = [viewID isKindOfClass:[NSNumber class]] ? gViews[viewID] : nil;
    if (!v) return;
    [v.refreshTimer invalidate];
    // The container's layer goes back under the window before UIKit takes the window apart.
    if (v.window) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [v.window.layer addSublayer:v.container.view.layer];
        [CATransaction commit];
    }
    v.window.hidden = YES;
    v.window.rootViewController = nil;
    [gViews removeObjectForKey:viewID];
    WPCheckIdle();
}

// The app wrote its shared data (WPProbe watches it): every widget is drawn again.
static void WPDataChanged(void) {
    for (WPHostedView *v in gViews.allValues) WPRender(v, NO);
}

#pragma mark - Taps

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

// The smallest button or link under the point; else, like iOS, the nearest one whose 44 pt
// target holds it.
static id WPControlAtPoint(UIView *view, CGPoint p) {
    NSMutableArray *elements = [NSMutableArray array];
    WPCollectAXElements(view, elements, 0);
    CGPoint sp = [view convertPoint:p toCoordinateSpace:UIScreen.mainScreen.coordinateSpace];
    id best = nil;
    CGFloat bestArea = CGFLOAT_MAX;
    for (id e in elements) {
        if (!([e accessibilityTraits] & (UIAccessibilityTraitButton | UIAccessibilityTraitLink))) continue;
        CGRect f = [e accessibilityFrame];
        if (!CGRectContainsPoint(f, sp)) continue;
        CGFloat area = f.size.width * f.size.height;
        if (area < bestArea) { best = e; bestArea = area; }
    }
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
    WPHostLog(@"tap at %@: %lu accessibility element(s), %@", NSStringFromCGPoint(sp), (unsigned long)elements.count,
              best ? [NSString stringWithFormat:@"\"%@\"", [best accessibilityLabel] ?: @""] : @"no control");
    return best;
}

// This process has no UIApplication. While a link runs, UIApplication.shared answers with this
// stand-in: SwiftUI opens the link's URL through it, and the URL goes to SpringBoard.
@interface WPApplicationStandIn : NSObject
@end

@implementation WPApplicationStandIn
- (void)openURL:(NSURL *)url options:(NSDictionary *)options completionHandler:(void (^)(BOOL))completion {
    if (url) WPSend(@{ @"op" : @"open", @"url" : url.absoluteString });
    if (completion) completion(url != nil);
}
- (BOOL)openURL:(NSURL *)url {
    if (url) WPSend(@{ @"op" : @"open", @"url" : url.absoluteString });
    return url != nil;
}
- (BOOL)canOpenURL:(NSURL *)url {
    return YES;
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSMethodSignature *sig = [super methodSignatureForSelector:sel];
    if (sig) return sig;
    Method m = class_getInstanceMethod([UIApplication class], sel);
    return m ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)] : nil;
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    WPHostLog(@"link: UIApplication stand-in answered %@ with zero", NSStringFromSelector(invocation.selector));
    NSUInteger len = invocation.methodSignature.methodReturnLength;
    if (len) {
        void *zero = calloc(1, len);
        [invocation setReturnValue:zero];
        free(zero);
    }
}
@end

static id gStandIn;
static int gStandInDepth;
static IMP gOrigSharedApplication;

static id WPSharedApplication(id self, SEL _cmd) {
    return gStandInDepth > 0 ? gStandIn : ((id (*)(id, SEL))gOrigSharedApplication)(self, _cmd);
}

static void WPWithStandIn(void (^block)(void)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gStandIn = [WPApplicationStandIn new];
        Method m = class_getClassMethod([UIApplication class], @selector(sharedApplication));
        gOrigSharedApplication = method_setImplementation(m, (IMP)WPSharedApplication);
    });
    gStandInDepth++;
    block();
    // SwiftUI may open the URL a moment later.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ gStandInDepth--; });
}

static void WPTap(NSDictionary *m) {
    NSNumber *viewID = m[@"view"];
    WPHostedView *v = [viewID isKindOfClass:[NSNumber class]] ? gViews[viewID] : nil;
    id control = v.shown ? WPControlAtPoint(v.shown.view, CGPointMake([m[@"x"] doubleValue], [m[@"y"] doubleValue])) : nil;
    if (!control) {
        WPSend(@{ @"op" : @"tapped", @"view" : viewID ?: @0, @"result" : @"none" });
        return;
    }
    UIAccessibilityTraits traits = [control accessibilityTraits];
    BOOL link = (traits & UIAccessibilityTraitLink) && !(traits & UIAccessibilityTraitButton);
    NSString *label = [control accessibilityLabel] ?: @"";
    if (!link) {
        // iOS performs these actions inside the app, not in the widget's process: the app opens.
        NSString *inApp = [WPProbe appProcessIntentsForExtension:gExt];
        if (inApp) {
            WPSend(@{ @"op" : @"tapped", @"view" : viewID, @"result" : @"app", @"label" : label, @"intents" : inApp });
            return;
        }
    }
    __block BOOL ok = NO;
    void (^activate)(void) = ^{
        @try { ok = [control accessibilityActivate]; } @catch (NSException *e) { WPHostLog(@"exception while running \"%@\": %@", label, e.reason); }
    };
    if (link) WPWithStandIn(activate);
    else activate();
    WPSend(@{ @"op" : @"tapped", @"view" : viewID, @"result" : ok ? (link ? @"link" : @"button") : @"none", @"label" : label });
    if (!ok) return;
    if (!link) {
        // The button's intent has run: the widget reloads its timeline, as on iOS.
        for (NSNumber *d in @[ @0.7, @2.5 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                for (WPHostedView *each in gViews.allValues) WPRender(each, NO);
            });
        }
    }
}

#pragma mark - The pipe

static void WPHandle(NSDictionary *m) {
    NSString *op = m[@"op"];
    if (![op isKindOfClass:[NSString class]]) return;
    if ([op isEqualToString:@"show"]) {
        WPShow(m);
    } else if ([op isEqualToString:@"tap"]) {
        WPTap(m);
    } else if ([op isEqualToString:@"hide"]) {
        WPHide(m);
    } else if ([op isEqualToString:@"log"]) {
        gWPHostLog = [m[@"on"] boolValue];
    } else if ([op isEqualToString:@"list"]) {
        [WPProbe prepareExtension:gExt completion:^{
            // Only what can be sent (the provider box stays here).
            NSMutableArray *list = [NSMutableArray array];
            for (NSDictionary *w in [WPProbe widgetsForExtension:gExt]) {
                NSMutableDictionary *d = [NSMutableDictionary dictionary];
                for (NSString *key in w) {
                    id value = w[key];
                    if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) d[key] = value;
                    else if ([value isKindOfClass:[NSArray class]] && [NSJSONSerialization isValidJSONObject:value]) d[key] = value;
                }
                if (d[@"kind"]) [list addObject:d];
            }
            WPSend(@{ @"op" : @"widgets", @"list" : list });
        }];
    }
}

static void WPReadRequests(void) {
    static dispatch_source_t source;
    static NSMutableData *pending;
    pending = [NSMutableData data];
    fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK);
    source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, ^{
        uint8_t buf[4096];
        ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
        if (n == 0) exit(0); // SpringBoard closed the pipe
        if (n < 0) {
            if (errno != EAGAIN && errno != EINTR) exit(0);
            return;
        }
        [pending appendBytes:buf length:(NSUInteger)n];
        for (;;) {
            const uint8_t *bytes = pending.bytes;
            const uint8_t *nl = memchr(bytes, '\n', pending.length);
            if (!nl) break;
            NSUInteger len = (NSUInteger)(nl - bytes);
            NSData *line = [pending subdataWithRange:NSMakeRange(0, len)];
            [pending replaceBytesInRange:NSMakeRange(0, len + 1) withBytes:NULL length:0];
            id m = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
            if ([m isKindOfClass:[NSDictionary class]]) WPHandle(m);
        }
    });
    dispatch_resume(source);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc < 8) {
            fprintf(stderr, "usage: SwitzachWidgetHost <extension id> <app id> <app name> <app path> <extension path> <executable> <data container>\n");
            return 1;
        }
        signal(SIGPIPE, SIG_IGN);
        gWPHostLog = getenv("WP_DIAGNOSTIC_LOG") && atoi(getenv("WP_DIAGNOSTIC_LOG"));
        // This process cannot use LaunchServices; SpringBoard passes what it found there.
        gExt = [WPWidgetExtension new];
        gExt.extensionBundleID = @(argv[1]);
        gExt.appBundleID = @(argv[2]);
        gExt.appName = @(argv[3]);
        gExt.appPath = @(argv[4]);
        gExt.extensionPath = @(argv[5]);
        gExt.executablePath = @(argv[6]);
        gExt.dataContainerPath = argv[7][0] ? @(argv[7]) : nil;
        WPSetLogTag([NSString stringWithFormat:@"[%@ %d] ", gExt.appName, getpid()]);
        gViews = [NSMutableDictionary dictionary];

        [WPProbe installRuntimeCrashLog];
        // SwiftUI builds the accessibility tree (where buttons and links are found) only when
        // accessibility is in use.
        void *ax = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW);
        void (*setEnabled)(BOOL) = ax ? (void (*)(BOOL))dlsym(ax, "_AXSApplicationAccessibilitySetEnabled") : NULL;
        if (setEnabled) setEnabled(YES);
        [[NSNotificationCenter defaultCenter] addObserverForName:@"WPWidgetDataChanged" object:nil queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *note) {
            if ([note.object isEqual:gExt.extensionBundleID]) WPDataChanged();
        }];
        // Commit what SwiftUI changes (no UIApplication run loop does it here).
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { [CATransaction flush]; }];

        WPReadRequests();
        WPCheckIdle();
        WPSend(@{ @"op" : @"ready", @"pid" : @(getpid()) });
        CFRunLoopRun();
    }
    return 0;
}
