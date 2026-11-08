// SwitzachWidgetHost: one app's widget extension, in a process of its own.
//
// SpringBoard starts one host per widget extension (WGHostConnection.m) and talks to it over
// pipes, one JSON object per line. The host loads the extension (WGRuntime) and draws each
// widget SpringBoard asks for in a UIWindow of its own (SwiftUI only draws in a window). The
// layer of the window's root view is moved into a Core Animation remote context, which
// SpringBoard shows with a CALayerHost: what SpringBoard shows is the widget itself, kept up to
// date by SwiftUI here (timers, progress), not a picture of it. Touches stay with SpringBoard,
// which sends taps here. The app's code never runs in SpringBoard: a crash ends this process.
//
// Requests (stdin)                                         Answers / events (stdout)
//   {op:list}                                                {op:widgets, list:[…], problem?}
//   {op:show, view, kind, family, w, h,                      {op:context, view, id}
//    scheme: light|dark, mode: fullColor|accented,           {op:drawn, view}
//    matrix?: [20 floats], visible}                          {op:failed, view, reason}
//   {op:visible, view, on}
//   {op:tap, view, x, y}                                     {op:tapped, view, result: button|link|none|app, …}
//                                                            {op:open, url}            (a link)
//   {op:hide, view}
//   {op:log, on}
//                                                            {op:ready, pid, blocked}  (at start)
//
//   blocked: this process cannot reach its files (Nyxian's filesystem sandbox is on); every
//   show then fails with the reason "filesystem-sandbox".
//
//   SwitzachWidgetHost <extension id> <app id> <app name> <app path> <extension path>
//                      <executable> <data container or "">
//
// Ends when SpringBoard closes the pipe, or after a minute without a widget to show.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>
#import "WGRuntime.h"

static WGExtension *gExt;
static BOOL gBlocked;
static int gOut = STDOUT_FILENO; // the pipe to SpringBoard (stdout itself goes to stderr: see main)

#pragma mark - Talking to SpringBoard

static void WGSend(NSDictionary *message) {
    NSData *data = WGEncodeMessage(message);
    const uint8_t *p = data.bytes;
    size_t left = data.length;
    while (left > 0) {
        ssize_t n = write(gOut, p, left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) exit(0); // SpringBoard is gone
        p += n;
        left -= (size_t)n;
    }
}

#pragma mark - Views

@interface WGHostedView : NSObject
@property (nonatomic) NSNumber *viewID;
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *config; // the widget's own configuration (Edit Widget), or nil
@property (nonatomic) WGFamily family;
@property (nonatomic) CGSize size;
@property (nonatomic) UIUserInterfaceStyle scheme;
@property (nonatomic) WGRenderMode mode;
@property (nonatomic, copy) NSArray<NSNumber *> *matrix;
@property (nonatomic) BOOL visible;
@property (nonatomic, strong) id context;      // CAContext (remote)
@property (nonatomic, strong) CALayer *root;   // the context's layer; holds the container's layer
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIViewController *container; // the window's root: holds the widget
@property (nonatomic, strong) UIViewController *shown;
@property (nonatomic) BOOL drawnOnce, rendering, renderAgain, refreshWhenVisible;
@property (nonatomic) BOOL modeChanged; // drawn again even off screen: what shows must match the style
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation WGHostedView
@end

static NSMutableDictionary<NSNumber *, WGHostedView *> *gViews;
static void WGRender(WGHostedView *v, BOOL placeholder);
static void WGUpdateFlushTimer(void);

// The window's root view (the container) has its layer moved into the remote context. Only
// that layer moves: the widget's views stay ordinary subviews of the container, so putting a new
// drawing in and taking the old one out is plain UIKit. SwiftUI draws nothing in a view laid out
// while its layers are not under the window's, so the container's layer goes back under the
// window while a drawing is put in, and out again in the same transaction (SpringBoard never
// sees it gone).
static void WGShowController(WGHostedView *v, UIViewController *vc) {
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
    v.window.overrideUserInterfaceStyle = v.scheme;
    v.container.view.frame = v.window.bounds;
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
    [CATransaction commit];
    [CATransaction flush];
}

// A 4×5 color matrix on the context's root layer: clear and tinted icons draw the widget in
// their colors (SpringBoard computes the matrix). A new matrix needs no new drawing.
// The same layout (and type encoding) as Core Animation's CAColorMatrix.
typedef struct { float m11, m12, m13, m14, m15, m21, m22, m23, m24, m25, m31, m32, m33, m34, m35, m41, m42, m43, m44, m45; } CAColorMatrix;

static void WGApplyMatrix(WGHostedView *v) {
    NSArray *filters = nil;
    if (v.matrix.count == 20) {
        id filter = ((id (*)(id, SEL, id))objc_msgSend)(NSClassFromString(@"CAFilter"), NSSelectorFromString(@"filterWithType:"), @"colorMatrix");
        if (filter) {
            CAColorMatrix cm;
            float *values = (float *)&cm;
            for (int i = 0; i < 20; i++) values[i] = v.matrix[i].floatValue;
            [filter setValue:[NSValue value:&cm withObjCType:@encode(CAColorMatrix)] forKey:@"inputColorMatrix"];
            filters = @[ filter ];
        }
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    v.root.filters = filters;
    [CATransaction commit];
}

static void WGScheduleRefresh(WGHostedView *v, NSDate *next) {
    [v.refreshTimer invalidate];
    NSTimeInterval delay = next ? MAX(60, next.timeIntervalSinceNow) : 30 * 60;
    __weak WGHostedView *weak = v;
    v.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *t) {
        WGHostedView *view = weak;
        if (view) WGRender(view, NO);
    }];
    v.refreshTimer.tolerance = MIN(30, delay * 0.1);
}

static void WGRenderFinished(WGHostedView *v) {
    v.rendering = NO;
    if (!v.renderAgain) return;
    v.renderAgain = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ WGRender(v, NO); });
}

// Draws again. A widget off screen waits until it is shown; a refresh asked for while the
// timeline is still being fetched becomes one more drawing after it.
static void WGRender(WGHostedView *v, BOOL placeholder) {
    if (gViews[v.viewID] != v) return;
    if (!v.visible && v.drawnOnce && !placeholder && !v.modeChanged) {
        v.refreshWhenVisible = YES;
        return;
    }
    if (v.rendering) {
        v.renderAgain = YES;
        return;
    }
    v.rendering = YES;
    v.refreshWhenVisible = NO;
    __weak WGHostedView *weak = v;
    WGRenderMode mode = v.mode;
    @try {
        [WGRuntime renderKind:v.kind config:v.config family:v.family size:v.size placeholder:(placeholder || !v.drawnOnce) mode:mode
                       update:^(UIViewController *vc, NSDate *next, BOOL final) {
            WGHostedView *view = weak;
            if (!view || gViews[view.viewID] != view) return;
            // A drawing made for the other rendering mode is not shown (one in the current mode
            // follows: the mode change asked for it).
            BOOL stale = view.mode != mode;
            if (vc && !stale) {
                if (final) view.modeChanged = NO;
                WGShowController(view, vc);
                view.drawnOnce = YES;
                WGSend(@{ WGOp : @"drawn", WGView : view.viewID, @"final" : @(final) });
            } else if (final && !stale && !view.drawnOnce) {
                WGSend(@{ WGOp : @"failed", WGView : view.viewID, @"reason" : @"nothing to draw" });
            }
            if (final) {
                WGScheduleRefresh(view, next);
                WGRenderFinished(view);
            }
        }];
    } @catch (NSException *e) {
        WGLogImportant(@"exception while drawing %@: %@", v.kind, e.reason);
        WGSend(@{ WGOp : @"failed", WGView : v.viewID, @"reason" : e.reason ?: @"exception" });
        WGRenderFinished(v);
    }
}

#pragma mark - Requests

static NSTimer *gIdleTimer;

// No widget to show for a minute: this process is not needed (SpringBoard starts it again).
static void WGCheckIdle(void) {
    [gIdleTimer invalidate];
    gIdleTimer = nil;
    if (gViews.count) return;
    gIdleTimer = [NSTimer scheduledTimerWithTimeInterval:60 repeats:NO block:^(NSTimer *t) {
        if (gViews.count == 0) exit(0);
    }];
}

// The extension is loaded once, on the first request that needs it.
static void WGWhenLoaded(void (^block)(NSString *problem)) {
    static NSMutableArray *waiting;
    static BOOL loaded;
    static NSString *problem;
    if (loaded) {
        block(problem);
        return;
    }
    BOOL first = !waiting;
    if (first) waiting = [NSMutableArray array];
    [waiting addObject:[block copy]];
    if (!first) return;
    if (gBlocked) {
        loaded = YES;
        problem = @"filesystem-sandbox";
        for (void (^b)(NSString *) in waiting) b(problem);
        waiting = [NSMutableArray array];
        return;
    }
    [WGRuntime loadExtension:gExt completion:^(NSArray *widgets, NSString *loadProblem) {
        loaded = YES;
        problem = loadProblem;
        NSArray *blocks = waiting;
        waiting = [NSMutableArray array];
        for (void (^b)(NSString *) in blocks) b(problem);
    }];
}

static void WGList(void) {
    WGWhenLoaded(^(NSString *problem) {
        NSMutableDictionary *m = [@{ WGOp : @"widgets", @"list" : [WGRuntime widgets] } mutableCopy];
        if (problem) m[@"problem"] = problem;
        WGSend(m);
    });
}

static void WGShow(NSDictionary *m) {
    NSNumber *viewID = [m[WGView] isKindOfClass:[NSNumber class]] ? m[WGView] : nil;
    NSString *kind = [m[@"kind"] isKindOfClass:[NSString class]] ? m[@"kind"] : nil;
    CGSize size = CGSizeMake([m[@"w"] doubleValue], [m[@"h"] doubleValue]);
    if (!viewID || !kind || size.width < 1 || size.height < 1) return;
    WGHostedView *v = gViews[viewID];
    BOOL fresh = !v;
    if (fresh) {
        // Touches over a hosted context would go to the process that owns it: they stay with
        // SpringBoard, which sends taps here.
        NSString *const *ignoresHitTest = (NSString *const *)dlsym(RTLD_DEFAULT, "kCAContextIgnoresHitTest");
        id context = ((id (*)(id, SEL, id))objc_msgSend)(NSClassFromString(@"CAContext"), NSSelectorFromString(@"remoteContextWithOptions:"),
                                                         ignoresHitTest ? @{ *ignoresHitTest : @YES } : @{});
        if (!context) {
            WGSend(@{ WGOp : @"failed", WGView : viewID, @"reason" : @"no remote context" });
            return;
        }
        v = [WGHostedView new];
        v.viewID = viewID;
        v.context = context;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        v.root = [CALayer layer];
        ((void (*)(id, SEL, id))objc_msgSend)(context, NSSelectorFromString(@"setLayer:"), v.root);
        [CATransaction commit];
        gViews[viewID] = v;
    }
    WGLog(@"show %@ %@ %@ %.0fx%.0f %@ %@%@%@", viewID, kind, WGFamilyName((WGFamily)[m[@"family"] intValue]), size.width, size.height, m[@"scheme"],
          m[@"mode"], m[@"matrix"] ? @" (matrix)" : @"", fresh ? @" (new)" : @"");
    WGFamily family = (WGFamily)[m[@"family"] intValue];
    BOOL resized = fresh || ![v.kind isEqualToString:kind] || v.family != family || !CGSizeEqualToSize(v.size, size);
    WGRenderMode mode = [m[@"mode"] isEqual:@"accented"] ? WGRenderModeAccented : WGRenderModeFullColor;
    BOOL remoded = !fresh && mode != v.mode;
    UIUserInterfaceStyle scheme = [m[@"scheme"] isEqual:@"light"] ? UIUserInterfaceStyleLight : UIUserInterfaceStyleDark;
    NSArray *matrix = [m[@"matrix"] isKindOfClass:[NSArray class]] && [m[@"matrix"] count] == 20 ? m[@"matrix"] : nil;
    BOOL wasVisible = v.visible;
    NSString *config = [m[@"config"] isKindOfClass:[NSString class]] ? m[@"config"] : nil;
    BOOL reconfigured = !fresh && !(config == v.config || [config isEqualToString:v.config]);
    v.config = config;
    v.kind = kind;
    v.family = family;
    v.size = size;
    v.mode = mode;
    v.visible = m[@"visible"] ? [m[@"visible"] boolValue] : YES;
    if (fresh || v.scheme != scheme) {
        v.scheme = scheme;
        v.window.overrideUserInterfaceStyle = scheme; // SwiftUI follows without a new timeline
    }
    if (fresh || !(matrix == v.matrix || [matrix isEqualToArray:v.matrix])) {
        v.matrix = matrix;
        WGApplyMatrix(v);
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    v.root.frame = CGRectMake(0, 0, size.width, size.height);
    [CATransaction commit];
    [CATransaction flush];
    uint32_t contextID = ((uint32_t (*)(id, SEL))objc_msgSend)(v.context, NSSelectorFromString(@"contextId"));
    WGSend(@{ WGOp : @"context", WGView : viewID, @"id" : @(contextID) });
    WGCheckIdle();
    WGUpdateFlushTimer();
    if (gBlocked) {
        WGSend(@{ WGOp : @"failed", WGView : viewID, @"reason" : @"filesystem-sandbox" });
        return;
    }
    if (resized) {
        if (!fresh) v.drawnOnce = NO; // a new size starts from its placeholder
        WGWhenLoaded(^(NSString *problem) {
            if (problem) WGSend(@{ WGOp : @"failed", WGView : viewID, @"reason" : problem });
            else WGRender(v, YES);
        });
    } else if (remoded || reconfigured) {
        v.modeChanged = YES;
        WGRender(v, NO); // drawn again in the other mode; the current drawing stays until then
    } else if (v.visible && !wasVisible && v.refreshWhenVisible) {
        WGRender(v, NO);
    } else if (v.drawnOnce) {
        WGSend(@{ WGOp : @"drawn", WGView : viewID, @"final" : @YES });
    }
}

#pragma mark Edit Widget

static void WGReply(NSDictionary *m, NSDictionary *answer) {
    NSMutableDictionary *r = [answer mutableCopy] ?: [NSMutableDictionary dictionary];
    r[WGOp] = @"reply";
    if (m[@"req"]) r[@"req"] = m[@"req"];
    WGSend(r);
}

static void WGConfigure(NSDictionary *m) {
    NSString *op = m[WGOp];
    NSString *kind = [m[@"kind"] isKindOfClass:[NSString class]] ? m[@"kind"] : nil;
    NSString *config = [m[@"config"] isKindOfClass:[NSString class]] ? m[@"config"] : nil;
    if (!kind || !config) {
        WGReply(m, @{ @"error" : @"Nothing to edit." });
        return;
    }
    WGWhenLoaded(^(NSString *problem) {
        if (problem) {
            WGReply(m, @{ @"error" : problem });
        } else if ([op isEqual:@"config-params"]) {
            [WGRuntime parametersForKind:kind config:config reply:^(NSDictionary *a) { WGReply(m, a); }];
        } else if ([op isEqual:@"config-options"]) {
            [WGRuntime optionsForKind:kind config:config parameter:m[@"param"] reply:^(NSDictionary *a) { WGReply(m, a); }];
        } else {
            NSString *error = [WGRuntime setParameter:m[@"param"] kind:kind config:config value:[m[@"value"] isKindOfClass:[NSDictionary class]] ? m[@"value"] : @{}];
            WGReply(m, error ? @{ @"error" : error } : @{ @"ok" : @YES });
            if (error) return;
            // Every view of this widget draws its new configuration, even out of sight.
            for (WGHostedView *v in gViews.allValues) {
                if (![v.kind isEqualToString:kind] || ![v.config isEqualToString:config]) continue;
                v.modeChanged = YES;
                WGRender(v, NO);
            }
        }
    });
}

static void WGVisible(NSDictionary *m) {
    WGHostedView *v = gViews[m[WGView]];
    if (!v) return;
    BOOL on = [m[@"on"] boolValue];
    WGLog(@"view %@ %@", v.viewID, on ? @"visible" : @"out of sight");
    if (on == v.visible) return;
    v.visible = on;
    WGUpdateFlushTimer();
    if (on && v.refreshWhenVisible) WGRender(v, NO);
}

static void WGHide(NSDictionary *m) {
    WGHostedView *v = gViews[m[WGView]];
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
    [gViews removeObjectForKey:v.viewID];
    WGCheckIdle();
    WGUpdateFlushTimer();
}

static void WGRefreshAll(void) {
    for (WGHostedView *v in gViews.allValues) WGRender(v, NO);
}

#pragma mark - Committing what SwiftUI changes

// Without UIApplication nothing commits the implicit transactions SwiftUI opens when it updates
// by itself (Text timers, animations): a run loop observer does, after each pass that did work,
// as UIKit's would. A slow timer keeps a visible widget moving if nothing else wakes the run loop.
static void WGInstallCommitObserver(void) {
    CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopBeforeWaiting, true, 2000000,
                                                                       ^(CFRunLoopObserverRef o, CFRunLoopActivity a) { [CATransaction flush]; });
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
}

static void WGUpdateFlushTimer(void) {
    static NSTimer *timer;
    BOOL anyVisible = NO;
    for (WGHostedView *v in gViews.allValues) anyVisible = anyVisible || v.visible;
    if (anyVisible && !timer) {
        timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { [CATransaction flush]; }];
        timer.tolerance = 0.2;
    } else if (!anyVisible && timer) {
        [timer invalidate];
        timer = nil;
    }
}

#pragma mark - Taps

static void WGCollectAXElements(id node, NSMutableArray *out, int depth) {
    if (!node || depth > 12 || out.count > 400) return;
    if ([node isAccessibilityElement]) [out addObject:node];
    NSArray *children = nil;
    @try { children = [node accessibilityElements]; } @catch (NSException *e) {}
    if (children.count) {
        for (id c in children) WGCollectAXElements(c, out, depth + 1);
    } else if ([node respondsToSelector:@selector(accessibilityElementCount)]) {
        NSInteger n = [node accessibilityElementCount];
        for (NSInteger i = 0; n != NSNotFound && i < n && i < 100; i++) WGCollectAXElements([node accessibilityElementAtIndex:i], out, depth + 1);
    }
    if ([node isKindOfClass:[UIView class]] && !children.count) {
        for (UIView *sub in ((UIView *)node).subviews) WGCollectAXElements(sub, out, depth + 1);
    }
}

// The smallest button or link under the point; else, as iOS does, the nearest one whose 44 pt
// target holds it.
static id WGControlAtPoint(UIView *view, CGPoint p) {
    NSMutableArray *elements = [NSMutableArray array];
    WGCollectAXElements(view, elements, 0);
    CGPoint sp = [view convertPoint:p toCoordinateSpace:UIScreen.mainScreen.coordinateSpace];
    id best = nil;
    CGFloat bestArea = CGFLOAT_MAX, bestDistance = CGFLOAT_MAX;
    for (id e in elements) {
        if (!([e accessibilityTraits] & (UIAccessibilityTraitButton | UIAccessibilityTraitLink))) continue;
        CGRect f = [e accessibilityFrame];
        if (CGRectContainsPoint(f, sp) && f.size.width * f.size.height < bestArea) {
            best = e;
            bestArea = f.size.width * f.size.height;
        }
    }
    if (best) return best;
    for (id e in elements) {
        if (!([e accessibilityTraits] & (UIAccessibilityTraitButton | UIAccessibilityTraitLink))) continue;
        CGRect f = [e accessibilityFrame];
        CGRect target = CGRectInset(f, MIN(0, (f.size.width - 44) / 2), MIN(0, (f.size.height - 44) / 2));
        CGFloat d = hypot(sp.x - CGRectGetMidX(f), sp.y - CGRectGetMidY(f));
        if (CGRectContainsPoint(target, sp) && d < bestDistance) {
            best = e;
            bestDistance = d;
        }
    }
    return best;
}

// This process has no UIApplication. While a link runs, UIApplication.shared answers with this
// stand-in: SwiftUI opens the link's URL through it, and the URL goes to SpringBoard.
@interface WGApplicationStandIn : NSObject
@end

@implementation WGApplicationStandIn
- (void)openURL:(NSURL *)url options:(NSDictionary *)options completionHandler:(void (^)(BOOL))completion {
    if (url.absoluteString) WGSend(@{ WGOp : @"open", @"url" : url.absoluteString });
    if (completion) completion(url != nil);
}
- (BOOL)openURL:(NSURL *)url {
    if (url.absoluteString) WGSend(@{ WGOp : @"open", @"url" : url.absoluteString });
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
    NSUInteger len = invocation.methodSignature.methodReturnLength;
    if (!len) return;
    void *zero = calloc(1, len);
    [invocation setReturnValue:zero];
    free(zero);
}
@end

static id gStandIn;
static int gStandInDepth;
static IMP gOrigSharedApplication;

static id WGSharedApplication(id self, SEL _cmd) {
    return gStandInDepth > 0 ? gStandIn : ((id (*)(id, SEL))gOrigSharedApplication)(self, _cmd);
}

static void WGWithStandIn(void (^block)(void)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gStandIn = [WGApplicationStandIn new];
        Method m = class_getClassMethod([UIApplication class], @selector(sharedApplication));
        gOrigSharedApplication = method_setImplementation(m, (IMP)WGSharedApplication);
    });
    gStandInDepth++;
    block();
    // SwiftUI may open the URL a moment later.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ gStandInDepth--; });
}

static void WGTap(NSDictionary *m) {
    NSNumber *viewID = [m[WGView] isKindOfClass:[NSNumber class]] ? m[WGView] : @0;
    WGHostedView *v = gViews[viewID];
    id control = v.shown ? WGControlAtPoint(v.shown.view, CGPointMake([m[@"x"] doubleValue], [m[@"y"] doubleValue])) : nil;
    if (!control) {
        WGSend(@{ WGOp : @"tapped", WGView : viewID, @"result" : @"none" });
        return;
    }
    UIAccessibilityTraits traits = [control accessibilityTraits];
    BOOL link = (traits & UIAccessibilityTraitLink) && !(traits & UIAccessibilityTraitButton);
    NSString *label = [control accessibilityLabel] ?: @"";
    if (!link) {
        // Intents iOS runs in the app's process (it opens, or runs them in the background, or
        // may continue them there) need the app: its code expects the app's own setup and
        // could not run here (ToDo's "complete" took this process down). When the extension's
        // button intents are all of that kind, the app opens.
        NSDictionary *placement = [WGRuntime intentPlacement];
        NSMutableOrderedSet *inApp = [NSMutableOrderedSet orderedSetWithArray:placement[@"opensApp"]];
        [inApp addObjectsFromArray:placement[@"inAppBackground"]];
        [inApp addObjectsFromArray:placement[@"foregroundContinuable"]];
        NSMutableArray *here = [placement[@"here"] mutableCopy];
        [here removeObjectsInArray:placement[@"foregroundContinuable"]];
        if (inApp.count && !here.count) {
            WGSend(@{ WGOp : @"tapped", WGView : viewID, @"result" : @"app", @"label" : label, @"intents" : [inApp.array componentsJoinedByString:@", "] });
            return;
        }
    }
    __block BOOL ok = NO;
    void (^activate)(void) = ^{
        @try {
            ok = [control accessibilityActivate];
        } @catch (NSException *e) {
            WGLogImportant(@"exception while running \"%@\": %@", label, e.reason);
        }
    };
    if (link) WGWithStandIn(activate);
    else activate();
    WGSend(@{ WGOp : @"tapped", WGView : viewID, @"result" : ok ? (link ? @"link" : @"button") : @"none", @"label" : label });
    if (!ok || link) return;
    // The button's intent ran: the widgets reload their timelines, as on iOS.
    for (NSNumber *d in @[ @0.7, @2.5 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WGRefreshAll(); });
    }
}

#pragma mark - The pipe

static void WGHandle(NSDictionary *m) {
    NSString *op = m[WGOp];
    if ([op isEqual:@"show"]) WGShow(m);
    else if ([op isEqual:@"visible"]) WGVisible(m);
    else if ([op isEqual:@"tap"]) WGTap(m);
    else if ([op isEqual:@"hide"]) WGHide(m);
    else if ([op isEqual:@"list"]) WGList();
    else if ([op hasPrefix:@"config-"]) WGConfigure(m);
    else if ([op isEqual:@"quit"]) exit(0);
    else if ([op isEqual:@"log"]) WGLogSetEnabled([m[@"on"] boolValue]);
}

static void WGReadRequests(void) {
    static dispatch_source_t source;
    static WGLineReader *reader;
    reader = [WGLineReader new];
    fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK);
    source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, ^{
        uint8_t buf[8192];
        for (;;) {
            ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
            if (n == 0) exit(0); // SpringBoard closed the pipe
            if (n < 0) {
                if (errno == EINTR) continue;
                if (errno != EAGAIN) exit(0);
                return;
            }
            [reader appendBytes:buf length:(size_t)n handler:^(NSDictionary *message) { WGHandle(message); }];
        }
    });
    dispatch_resume(source);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSMutableArray *args = [NSMutableArray array];
        for (int i = 1; i < argc; i++) [args addObject:@(argv[i])];
        gExt = [WGExtension extensionWithArguments:args];
        if (!gExt) {
            fprintf(stderr, "usage: SwitzachWidgetHost <extension id> <app id> <app name> <app path> <extension path> <executable> <data container>\n");
            return 1;
        }
        signal(SIGPIPE, SIG_IGN);
        // The app's code may print (Swift's print() writes to stdout): the messages get a
        // descriptor of their own, and stdout goes where stderr goes.
        int out = dup(STDOUT_FILENO);
        if (out >= 0) {
            fcntl(out, F_SETFD, FD_CLOEXEC);
            gOut = out;
            dup2(STDERR_FILENO, STDOUT_FILENO);
        }
        const char *log = getenv("WG_DIAGNOSTIC_LOG");
        WGLogSetEnabled(log && atoi(log));
        WGLogSetTag([NSString stringWithFormat:@"[%@ %d] ", gExt.appName, getpid()]);
        gViews = [NSMutableDictionary dictionary];
        [WGRuntime installCrashLog];

        // SwiftUI builds the accessibility tree (where buttons and links are found) only when
        // accessibility is in use.
        void *ax = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW);
        void (*setEnabled)(BOOL) = ax ? (void (*)(BOOL))dlsym(ax, "_AXSApplicationAccessibilitySetEnabled") : NULL;
        if (setEnabled) setEnabled(YES);

        [[NSNotificationCenter defaultCenter] addObserverForName:WGRuntimeDataChangedNotification object:nil queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *note) { WGRefreshAll(); }];
        WGInstallCommitObserver();

        // With Nyxian's filesystem sandbox on, a process SpringBoard starts gets no file access
        // of its own: it can read neither the app's extension nor its work folder.
        gBlocked = access(WGWorkDirectory().fileSystemRepresentation, W_OK) != 0 || access(gExt.extensionPath.fileSystemRepresentation, R_OK) != 0;
        if (gBlocked) WGLogImportant(@"cannot reach its files: Nyxian's filesystem sandbox is on");

        WGReadRequests();
        WGCheckIdle();
        WGSend(@{ WGOp : @"ready", @"pid" : @(getpid()), @"blocked" : @(gBlocked), @"version" : @WG_VERSION });
        WGLog(@"host %s started", WG_VERSION);
        CFRunLoopRun();
    }
    return 0;
}
