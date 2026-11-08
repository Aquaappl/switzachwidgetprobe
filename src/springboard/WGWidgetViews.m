// The widgets on the home screen: one view controller per widget, and one per widget icon that
// pages through a stack.
//
// A widget's view, from the back:
//
//   root view      clips to the widget's rounded shape; the placeholder color while loading
//   ├ backdrop     glass for clear and tinted icons (WGBackdropView); a stack has one for all pages
//   ├ content      a CALayerHost showing the layers the widget's host process draws
//   └ status       "Loading…", or why the widget cannot be shown
//
// Everything is a view in a fixed order, so the glass can never end up in front of the widget.
// In SpringBoardHome's widget containers (the sizes shown while a widget is resized) the glass
// is the container's background view instead, behind our view, where SpringBoardHome keeps a
// widget's glass (it would put a dark gradient there).
// The look comes from the view's own traits (WGAppearance): it is the style the icons around it
// are drawn with.

#import "WGSpringBoard.h"

NSString *const WGFilesystemSandboxMessage = @"Widgets cannot load: turn off “Filesystem Sandbox” in Nyxian’s recovery settings";
NSString *const WGFilesystemSandboxHint = @"If apps with widgets are installed, turn off “Filesystem Sandbox” in Nyxian’s recovery settings.";
NSNotificationName const WGFilesystemSandboxChangedNotification = @"WGFilesystemSandboxChanged";

static const CGFloat kWGDefaultCornerRadius = 22;
static BOOL gSettingContainerBackground; // our own call of -[SBHWidgetContainerView setBackgroundView:]

static void WGSetContainerBackground(UIView *container, UIView *_Nullable background) {
    gSettingContainerBackground = YES;
    WGSend1(container, @"setBackgroundView:", background);
    gSettingContainerBackground = NO;
}

#pragma mark - Answering SpringBoardHome

NSMethodSignature *WGFallbackSignature(SEL sel) {
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

void WGForwardAsZero(NSInvocation *invocation, UIViewController *vc, CGSize imageSize) {
    // visibleBounds: the part of the icon's content that shows (asked in edit mode): all of it.
    if (invocation.selector == NSSelectorFromString(@"visibleBounds") && strncmp(invocation.methodSignature.methodReturnType, "{CGRect=", 8) == 0) {
        CGRect r = vc.isViewLoaded ? vc.view.bounds : CGRectZero;
        if (r.size.width < 1 || r.size.height < 1) r = (CGRect){ CGPointZero, imageSize };
        [invocation setReturnValue:&r];
        return;
    }
    static NSMutableSet *seen;
    if (!seen) seen = [NSMutableSet set];
    NSString *name = NSStringFromSelector(invocation.selector);
    if (![seen containsObject:name]) {
        [seen addObject:name];
        WGLog(@"Answered with zero: %@", name);
    }
    NSUInteger len = invocation.methodSignature.methodReturnLength;
    if (!len) return;
    void *zero = calloc(1, len);
    [invocation setReturnValue:zero];
    free(zero);
}

// The root view of our controllers: tells its controller when it is put in another view (a
// SpringBoardHome widget container, while resizing).
@interface WGRootView : UIView
@property (nonatomic, weak) id owner; // answers wg_superviewChanged
@end

@implementation WGRootView
- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    id owner = self.owner;
    SEL changed = NSSelectorFromString(@"wg_superviewChanged");
    if ([owner respondsToSelector:changed]) ((void (*)(id, SEL))objc_msgSend)(owner, changed);
}
@end

#pragma mark - Touches

// Remembers when a touch went down (a tap is quick; the end of a long press is not) and steps
// aside at once: the icon view's own recognizers (long press, drag) work as before.
@interface WGTouchTracker : UIGestureRecognizer
@property (nonatomic) CFAbsoluteTime time;
@end

@implementation WGTouchTracker
- (instancetype)init {
    if ((self = [super initWithTarget:nil action:nil])) {
        self.cancelsTouchesInView = NO;
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
    }
    return self;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.time = CFAbsoluteTimeGetCurrent();
    self.state = UIGestureRecognizerStateFailed;
}
- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)other { return NO; }
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)other { return NO; }
@end

#pragma mark - Visibility

@interface WGWidgetViewController ()
- (void)contentWindowChanged;
- (void)wg_superviewChanged;
@end

// Tells its controller when it enters or leaves a window.
@interface WGContentView : UIView
@property (nonatomic, weak) WGWidgetViewController *windowObserver;
@end

@implementation WGContentView
- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self.windowObserver contentWindowChanged];
}
@end

#pragma mark - One widget

@implementation WGWidgetViewController {
    WGIconImageInfo _info;
    WGHost *_host;
    NSInteger _viewID;
    WGBackdropView *_backdrop;
    WGBackdropView *_outerBackdrop; // the glass as a SpringBoardHome container's background
    WGContentView *_content;
    CALayer *_hostLayer;
    UILabel *_status;
    WGTouchTracker *_touches;
    WGAppearance *_appearance;
    NSDictionary *_shownRequest; // the last show sent (without visibility)
    BOOL _drawn, _renderScheduled, _visible;
    NSUInteger _visibilityToken;
    NSHashTable<UIScrollView *> *_observed;
    CFAbsoluteTime _lastTap;
    uint32_t _contextID;
}

static char kWGScrollContext;

+ (void)initialize {
    if (self != [WGWidgetViewController class]) return;
    Protocol *p = objc_getProtocol("SBIconViewCustomImageViewControlling");
    if (p) class_addProtocol(self, p);
}

// What drawing is kept under: the same kind at the same size looks the same.
- (NSString *)reuseKey {
    return [NSString stringWithFormat:@"%@|%d|%@", self.kind, self.family, self.configKey ?: @""];
}

- (instancetype)initWithExtension:(WGExtension *)extension kind:(NSString *)kind family:(WGFamily)family {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _extension = extension;
        _kind = [kind copy];
        _family = family;
        _host = [WGHost hostForExtension:extension];
        _observed = [NSHashTable weakObjectsHashTable];
        _info.continuousCornerRadius = kWGDefaultCornerRadius;
        WGLog(@"Widget controller %p: %@ %@", self, kind, WGFamilyName(family));
    }
    return self;
}

- (void)dealloc {
    WGLog(@"Widget controller %p gone (view %ld, %@)", self, (long)_viewID, _drawn ? @"parked" : @"hidden");
    [self removeOuterGlass];
    [self stopObservingScrollViews];
    if (!_viewID) return;
    if (_drawn) [_host parkView:_viewID key:self.reuseKey];
    else [_host hideView:_viewID];
}

#pragma mark SBIconViewCustomImageViewControlling

- (WGIconImageInfo)iconImageInfo {
    return _info;
}

- (void)setIconImageInfo:(WGIconImageInfo)info {
    [self setImageInfo:info];
}

- (void)setImageInfo:(WGIconImageInfo)info {
    if (info.continuousCornerRadius <= 0) info.continuousCornerRadius = kWGDefaultCornerRadius;
    _info = info;
    if (!self.isViewLoaded) return;
    self.view.layer.cornerRadius = info.continuousCornerRadius;
    [self updateAppearance];
    [self.view setNeedsLayout];
}

- (BOOL)wantsLabelHidden {
    return NO;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [super methodSignatureForSelector:sel] ?: WGFallbackSignature(sel);
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    WGForwardAsZero(invocation, self, _info.size);
}

#pragma mark Views

- (void)loadView {
    WGRootView *v = [WGRootView new];
    v.owner = self;
    v.clipsToBounds = YES;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    v.layer.cornerRadius = _info.continuousCornerRadius;
    _backdrop = [WGBackdropView new];
    [v addSubview:_backdrop];
    _content = [WGContentView new];
    _content.userInteractionEnabled = NO;
    _content.windowObserver = self;
    [v addSubview:_content];
    _status = [UILabel new];
    _status.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.numberOfLines = 0;
    _status.adjustsFontSizeToFitWidth = YES;
    _status.minimumScaleFactor = 0.7;
    _status.text = WGHomeDrawingStopped() ? @"Drawing is stopped\nafter repeated crashes" : @"Loading…";
    [v addSubview:_status];
    _touches = [WGTouchTracker new];
    [v addGestureRecognizer:_touches];
    // Taps: SpringBoardHome on iOS 27 leaves a widget's touches to its content and no longer
    // reports a tap on a widget icon (iconTapped:), so the widget sees them itself.
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)];
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesEnded = NO;
    tap.delegate = (id<UIGestureRecognizerDelegate>)self;
    [v addGestureRecognizer:tap];
    self.view = v;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES; // the icon view's long press and drag, the stack's paging, work as before
}

- (void)tapped:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    // Not the end of a long press (the menu), nor while editing or in a menu's preview.
    BOOL quick = CFAbsoluteTimeGetCurrent() - _touches.time < 0.5;
    id manager = WGIconManager();
    BOOL menu = [manager respondsToSelector:NSSelectorFromString(@"isShowingIconContextMenu")] && WGCallBool(manager, @"isShowingIconContextMenu");
    BOOL onHomeScreen = [self.view.superview isKindOfClass:NSClassFromString(@"SBHTouchPassThroughView")] || self.inStack;
    WGLog(@"Tap: %@ (quick %d, menu %d, editing %d, home screen %d)", self.kind, quick, menu, WGIsEditing(), onHomeScreen);
    if (!quick || menu || WGIsEditing() || !onHomeScreen) return;
    [self tapAtPoint:[g locationInView:self.view]];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WGAppearanceObserve(self, @selector(updateAppearance));
    [self updateAppearance];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self updateAppearance];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    _backdrop.frame = b;
    _content.frame = b;
    _status.frame = CGRectInset(b, 10, 10);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _hostLayer.frame = _content.bounds;
    [CATransaction commit];
    [self scheduleRender];
    [self updateVisibility];
    [self placeGlass];
}

- (void)setFamily:(WGFamily)family {
    if (family == _family) return;
    _family = family;
    if (self.isViewLoaded) [self scheduleRender];
}

- (void)setInStack:(BOOL)inStack {
    _inStack = inStack;
    if (self.isViewLoaded) [self updateAppearance];
}

- (void)updateAppearance {
    if (!self.isViewLoaded) return;
    _appearance = [WGAppearance appearanceForTraits:self.traitCollection];
    BOOL glass = _appearance.mode == WGIconModeClear || _appearance.mode == WGIconModeTinted;
    if (self.inStack) {
        _backdrop.hidden = YES;
        self.view.backgroundColor = UIColor.clearColor;
    } else {
        [_backdrop applyAppearance:_appearance cornerRadius:_info.continuousCornerRadius];
        // While loading (and behind a widget without a background): a neutral color, or the glass.
        self.view.backgroundColor = glass ? UIColor.clearColor
                                          : [UIColor colorWithWhite:_appearance.scheme == UIUserInterfaceStyleDark ? 0.14 : 0.93 alpha:1];
    }
    _status.textColor = glass || _appearance.scheme == UIUserInterfaceStyleDark ? [UIColor colorWithWhite:1 alpha:0.65] : [UIColor colorWithWhite:0 alpha:0.5];
    [self placeGlass];
    [self scheduleRender];
}

#pragma mark Glass in SpringBoardHome's containers

- (void)wg_superviewChanged {
    [self placeGlass];
}

// Our view in an SBHWidgetContainerView: the glass goes to the container (see the top).
- (void)placeGlass {
    if (!self.isViewLoaded || !_appearance) return;
    BOOL glass = _appearance.mode == WGIconModeClear || _appearance.mode == WGIconModeTinted;
    UIView *container = self.view.superview;
    Class containerClass = NSClassFromString(@"SBHWidgetContainerView");
    BOOL outside = glass && !self.inStack && containerClass && [container isKindOfClass:containerClass] &&
                   [container respondsToSelector:NSSelectorFromString(@"setBackgroundView:")] && [container respondsToSelector:NSSelectorFromString(@"backgroundView")];
    if (outside) {
        if (!_outerBackdrop) {
            _outerBackdrop = [WGBackdropView new];
            _outerBackdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        }
        [_outerBackdrop applyAppearance:_appearance cornerRadius:_info.continuousCornerRadius];
        if (WGCall(container, @"backgroundView") != _outerBackdrop) WGSetContainerBackground(container, _outerBackdrop);
        if (_outerBackdrop.superview != container) [container insertSubview:_outerBackdrop atIndex:0];
        else if (container.subviews.firstObject != _outerBackdrop) [container sendSubviewToBack:_outerBackdrop];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _outerBackdrop.frame = container.bounds;
        [CATransaction commit];
    } else {
        [self removeOuterGlass];
    }
    _backdrop.hidden = outside || !glass || self.inStack;
}

- (void)removeOuterGlass {
    if (!_outerBackdrop.superview) return;
    UIView *container = _outerBackdrop.superview;
    if ([container respondsToSelector:NSSelectorFromString(@"backgroundView")] && WGCall(container, @"backgroundView") == _outerBackdrop) {
        WGSetContainerBackground(container, nil);
    }
    [_outerBackdrop removeFromSuperview];
}

#pragma mark Drawing

- (void)scheduleRender {
    if (_renderScheduled || WGHomeDrawingStopped()) return;
    _renderScheduled = YES;
    // Layout and trait changes come in bursts: once, a moment later.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf render]; });
}

// Asks the host to draw at this view's size and look. Only what changed is sent again; the host
// refreshes the widget's timeline by itself.
- (void)render {
    _renderScheduled = NO;
    if (!self.isViewLoaded || !_appearance) return;
    CGSize size = self.view.bounds.size;
    if (size.width < 10 || size.height < 10) size = _info.size;
    if (size.width < 10 || size.height < 10) return;
    NSMutableDictionary *request = [@{ @"kind" : self.kind, @"family" : @(self.family), @"w" : @(round(size.width * 2) / 2),
                                       @"h" : @(round(size.height * 2) / 2), @"scheme" : _appearance.scheme == UIUserInterfaceStyleLight ? @"light" : @"dark",
                                       @"mode" : _appearance.accented ? @"accented" : @"fullColor" } mutableCopy];
    if (_appearance.colorMatrix) request[@"matrix"] = _appearance.colorMatrix;
    if (self.configKey) request[@"config"] = self.configKey;
    __weak typeof(self) weakSelf = self;
    if (!_viewID) [self adoptParkedView];
    if ([request isEqualToDictionary:_shownRequest]) return;
    _shownRequest = [request copy];
    if (!_viewID) _viewID = [WGHost newViewID];
    request[@"visible"] = @(_visible);
    [_host showView:_viewID request:request events:^(NSDictionary *m) { [weakSelf hostEvent:m]; }];
}

// The same widget was just shown by a controller that went away (SpringBoardHome made a new
// icon view): its drawing is taken over at once.
- (void)adoptParkedView {
    __weak typeof(self) weakSelf = self;
    NSDictionary *taken = [_host adoptViewWithKey:self.reuseKey events:^(NSDictionary *m) { [weakSelf hostEvent:m]; }];
    if (!taken) return;
    _viewID = [taken[WGView] integerValue];
    NSMutableDictionary *shown = [taken[@"request"] mutableCopy];
    _visible = [shown[@"visible"] boolValue];
    [shown removeObjectsForKeys:@[ WGOp, WGView, @"visible" ]];
    _shownRequest = shown;
    if (taken[@"context"]) [self hostEvent:@{ WGOp : @"context", @"id" : taken[@"context"] }];
    if ([taken[@"drawn"] boolValue]) [self hostEvent:@{ WGOp : @"drawn" }];
    WGLog(@"%@: took over view %ld", self.kind, (long)_viewID);
    [self updateVisibility];
}

- (void)hostEvent:(NSDictionary *)m {
    NSString *op = m[WGOp];
    if ([op isEqual:@"context"]) {
        if (!_hostLayer) {
            _hostLayer = [NSClassFromString(@"CALayerHost") layer];
            if (!_hostLayer) return;
            [_content.layer addSublayer:_hostLayer];
        }
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _contextID = [m[@"id"] unsignedIntValue];
        ((void (*)(id, SEL, uint32_t))objc_msgSend)(_hostLayer, NSSelectorFromString(@"setContextId:"), _contextID);
        _hostLayer.frame = _content.bounds;
        [CATransaction commit];
    } else if ([op isEqual:@"drawn"]) {
        _drawn = YES;
        _status.hidden = YES;
    } else if ([op isEqual:@"lost"]) {
        _drawn = NO; // started again and shown again by itself
        _contextID = 0;
    } else if ([op isEqual:@"failed"]) {
        NSString *reason = [m[@"reason"] description];
        WGLog(@"%@ could not be drawn: %@", self.kind, reason);
        if ([reason isEqual:@"filesystem-sandbox"]) {
            _status.text = WGFilesystemSandboxMessage;
            _status.hidden = NO;
        } else if (!_drawn) {
            _status.text = [reason isEqual:@"crashing"] ? @"This widget keeps crashing" : @"Could not draw";
            _status.hidden = NO;
        }
    }
}

#pragma mark Visibility

// A widget scrolled out of sight (another page, another widget of its stack) or out of the
// window is not refreshed by its host until it shows again.
- (void)contentWindowChanged {
    [self stopObservingScrollViews];
    if (_content.window) {
        for (UIView *v = _content.superview; v; v = v.superview) {
            if (![v isKindOfClass:[UIScrollView class]]) continue;
            [v addObserver:self forKeyPath:@"contentOffset" options:0 context:&kWGScrollContext];
            [_observed addObject:(UIScrollView *)v];
        }
    }
    [self updateVisibility];
}

- (void)stopObservingScrollViews {
    for (UIScrollView *v in _observed.allObjects) [v removeObserver:self forKeyPath:@"contentOffset" context:&kWGScrollContext];
    [_observed removeAllObjects];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != &kWGScrollContext) return [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    [self updateVisibility];
}

- (void)updateVisibility {
    UIWindow *window = _content.window;
    BOOL visible = NO;
    if (window && !window.hidden && !self.view.hidden) {
        CGRect r = [_content convertRect:_content.bounds toView:window];
        visible = CGRectIntersectsRect(CGRectInset(window.bounds, -8, -8), r) && !CGRectIsEmpty(CGRectIntersection(window.bounds, r));
    }
    if (visible == _visible) {
        _visibilityToken++;
        return;
    }
    if (visible) {
        _visible = YES;
        _visibilityToken++;
        if (_viewID) [_host setView:_viewID visible:YES];
        return;
    }
    // Going out of sight is told a moment later (not while a page is being swiped past).
    NSUInteger token = ++_visibilityToken;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) s = weakSelf;
        if (!s || token != s->_visibilityToken) return;
        s->_visible = NO;
        if (s->_viewID) [s->_host setView:s->_viewID visible:NO];
    });
}

#pragma mark Taps

- (void)tapAtPoint:(CGPoint)point {
    if (self.preview || WGIsEditing()) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _lastTap < 0.3) return;
    _lastTap = now;
    NSString *app = self.extension.appID, *kind = self.kind;
    if (!_viewID || !_drawn) {
        WGLaunchApp(app);
        return;
    }
    [_host tapView:_viewID point:point result:^(NSString *result, NSDictionary *m) {
        WGLog(@"Tap on %@%@: %@%@", kind, [m[@"label"] length] ? [NSString stringWithFormat:@" \"%@\"", m[@"label"]] : @"", result,
              m[@"intents"] ? [NSString stringWithFormat:@" (%@ run in the app)", m[@"intents"]] : @"");
        if (![result isEqual:@"button"] && ![result isEqual:@"link"]) WGLaunchApp(app);
    }];
}

@end

#pragma mark - A page for a widget that is not ours

// The ROM cannot draw system widgets: a stack holding one shows its name.
@interface WGForeignWidgetViewController : UIViewController
@property (nonatomic, copy) NSString *name;
@end

@implementation WGForeignWidgetViewController
- (void)loadView {
    UILabel *l = [UILabel new];
    l.text = self.name.length ? self.name : @"Widget";
    l.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    l.textAlignment = NSTextAlignmentCenter;
    l.numberOfLines = 0;
    self.view = l;
}
@end

#pragma mark - Stacks

// Vertical paging; in edit mode a drag moves the whole stack (the icon view's recognizers).
@interface WGStackScrollView : UIScrollView
@end

@implementation WGStackScrollView
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (g == self.panGestureRecognizer && WGIsEditing()) return NO;
    return [super gestureRecognizerShouldBegin:g];
}
@end

static NSString *WGWidgetKey(id widget) {
    id u = WGCall(widget, @"uniqueIdentifier");
    return [u isKindOfClass:[NSString class]] && [u length] ? u : [NSString stringWithFormat:@"%p", widget];
}

static void WGIconObserve(id icon, id observer, BOOL add) {
    SEL sel = NSSelectorFromString(add ? @"addObserver:" : @"removeObserver:");
    if ([icon respondsToSelector:sel]) ((void (*)(id, SEL, id))objc_msgSend)(icon, sel, observer);
}

// The content of one of our widget icons: a page per widget (SBWidgetIcon.widgets), swiped
// vertically, with page dots beside it, the glass behind all of them. Follows the icon when
// widgets are added to or removed from the stack and when the active one changes.
@implementation WGStackViewController {
    __weak id _icon;
    __weak id _iconView;
    WGIconImageInfo _info;
    UIView *_clip;
    WGBackdropView *_backdrop;
    WGStackScrollView *_scroll;
    UIView *_dotsView;
    NSArray<UIView *> *_dots;
    NSArray<NSString *> *_keys;
    NSArray<UIViewController *> *_pages;
    NSMutableDictionary<NSString *, UIViewController *> *_pagesByKey;
    NSUInteger _activeIndex, _flash;
    BOOL _settingActive;
}

+ (void)initialize {
    if (self != [WGStackViewController class]) return;
    for (NSString *name in @[ @"SBIconViewCustomImageViewControlling", @"SBIconObserver", @"SBLeafIconObserver" ]) {
        Protocol *p = objc_getProtocol(name.UTF8String);
        if (p) class_addProtocol(self, p);
    }
}

// The lift (long press): SpringBoardHome lifts an icon from its content's snapshotView, shaped
// by snapshotViewVisiblePath. The stack's view holds the page dots outside the widget, so the
// clip view is what shows: as a picture taken by the render server (drawViewHierarchyInRect:),
// which has the widget host's layers and the glass in it — a second CALayerHost of the same
// context stayed empty, and UIKit's snapshot views showed the glass black once moved.
- (UIView *)snapshotView {
    CGRect b = self.isViewLoaded && _clip.bounds.size.width > 1 ? _clip.bounds : (CGRect){ CGPointZero, _info.size };
    UIImage *image = [self picture];
    UIView *view = image ? [[UIImageView alloc] initWithImage:image] : [UIView new];
    view.frame = b;
    if (!image) view.backgroundColor = _clip.backgroundColor;
    view.layer.cornerRadius = _info.continuousCornerRadius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.clipsToBounds = YES;
    return view;
}

- (UIImage *)picture {
    if (!self.isViewLoaded || !_clip.window || _clip.bounds.size.width < 1) return nil;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    UIView *clip = _clip;
    __block BOOL drawn = NO;
    UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithBounds:clip.bounds format:format] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        drawn = [clip drawViewHierarchyInRect:clip.bounds afterScreenUpdates:NO];
    }];
    return drawn ? image : nil;
}

- (UIBezierPath *)snapshotViewVisiblePath {
    return [UIBezierPath bezierPathWithRoundedRect:self.isViewLoaded ? self.view.bounds : (CGRect){ CGPointZero, _info.size }
                                      cornerRadius:_info.continuousCornerRadius];
}

- (instancetype)initWithIcon:(id)icon iconView:(id)iconView {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _pagesByKey = [NSMutableDictionary dictionary];
        _keys = @[];
        _pages = @[];
        _iconView = iconView;
        _info.continuousCornerRadius = kWGDefaultCornerRadius;
        [self observeIcon:icon];
        WGLog(@"Stack controller %p for icon view %p (%lu widget(s), %@)", self, iconView, (unsigned long)WGIconWidgets(icon).count,
              WGCall(icon, @"gridSizeClass"));
    }
    return self;
}

- (void)dealloc {
    WGLog(@"Stack controller %p gone", self);
    WGIconObserve(_icon, self, NO);
}

- (void)observeIcon:(id)icon {
    id old = _icon;
    if (old == icon) return;
    WGIconObserve(old, self, NO);
    _icon = icon;
    WGIconObserve(icon, self, YES);
}

- (WGIconImageInfo)iconImageInfo {
    return _info;
}

- (void)setIconImageInfo:(WGIconImageInfo)info {
    if (info.continuousCornerRadius <= 0) info.continuousCornerRadius = kWGDefaultCornerRadius;
    _info = info;
    for (UIViewController *page in _pages) {
        if ([page isKindOfClass:[WGWidgetViewController class]]) [(WGWidgetViewController *)page setImageInfo:info];
    }
    if (!self.isViewLoaded) return;
    _clip.layer.cornerRadius = info.continuousCornerRadius;
    [self updateAppearance];
    [self.view setNeedsLayout];
}

- (BOOL)wantsLabelHidden {
    return NO;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [super methodSignatureForSelector:sel] ?: WGFallbackSignature(sel);
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    WGForwardAsZero(invocation, self, _info.size);
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
    WGRootView *v = [WGRootView new];
    v.owner = self;
    v.clipsToBounds = NO; // the page dots sit just outside the widget
    _clip = [UIView new];
    _clip.clipsToBounds = YES;
    _clip.layer.cornerCurve = kCACornerCurveContinuous;
    _clip.layer.cornerRadius = _info.continuousCornerRadius;
    [v addSubview:_clip];
    _backdrop = [WGBackdropView new];
    [_clip addSubview:_backdrop];
    _scroll = [WGStackScrollView new];
    _scroll.pagingEnabled = YES;
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.showsHorizontalScrollIndicator = NO;
    _scroll.scrollsToTop = NO;
    _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _scroll.delegate = (id<UIScrollViewDelegate>)self;
    [_clip addSubview:_scroll];
    _dotsView = [UIView new];
    _dotsView.userInteractionEnabled = NO;
    _dotsView.alpha = 0;
    [v addSubview:_dotsView];
    self.view = v;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WGAppearanceObserve(self, @selector(updateAppearance));
    [self updateAppearance];
    [self rebuildFlashing:NO];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self updateAppearance];
}

- (void)updateAppearance {
    if (!self.isViewLoaded) return;
    WGAppearance *a = [WGAppearance appearanceForTraits:self.traitCollection];
    [_backdrop applyAppearance:a cornerRadius:_info.continuousCornerRadius];
    BOOL glass = a.mode == WGIconModeClear || a.mode == WGIconModeTinted;
    _clip.backgroundColor = glass ? UIColor.clearColor : [UIColor colorWithWhite:a.scheme == UIUserInterfaceStyleDark ? 0.14 : 0.93 alpha:1];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // SpringBoardHome may give the icon view another icon (a stack made by dropping a widget on
    // this one): follow it.
    id current = WGCall(_iconView, @"icon");
    if (current && current != _icon && WGIsOurWidgetIcon(current)) {
        [self observeIcon:current];
        [self rebuildFlashing:YES];
        return;
    }
    [self layoutPages];
}

- (void)layoutPages {
    CGRect b = self.view.bounds;
    _clip.frame = b;
    _backdrop.frame = _clip.bounds;
    _scroll.frame = _clip.bounds;
    CGFloat h = b.size.height;
    for (NSUInteger i = 0; i < _pages.count; i++) _pages[i].view.frame = CGRectMake(0, i * h, b.size.width, h);
    _scroll.contentSize = CGSizeMake(b.size.width, h * MAX(1, _pages.count));
    if (!_scroll.isDragging && !_scroll.isDecelerating) _scroll.contentOffset = CGPointMake(0, _activeIndex * h);
    CGFloat d = 5, gap = 4, total = _dots.count * d + (_dots.count ? (_dots.count - 1) * gap : 0);
    _dotsView.frame = CGRectMake(CGRectGetMaxX(b) + 5, CGRectGetMidY(b) - total / 2, d, total);
    for (NSUInteger i = 0; i < _dots.count; i++) _dots[i].frame = CGRectMake(0, i * (d + gap), d, d);
}

- (void)rebuildFlashing:(BOOL)flash {
    if (!self.isViewLoaded) return;
    id icon = _icon;
    NSArray *widgets = WGIconWidgets(icon);
    WGFamily family = WGFamilyForGridClass(WGCall(icon, @"gridSizeClass"));
    NSMutableArray *keys = [NSMutableArray array], *pages = [NSMutableArray array];
    for (id w in widgets) {
        NSString *key = WGWidgetKey(w);
        UIViewController *page = _pagesByKey[key];
        if (!page) {
            WGExtension *ext = [WGExtensions extensionWithID:WGCall(w, @"extensionBundleIdentifier")];
            NSString *kind = WGCall(w, @"kind");
            if (ext && [kind isKindOfClass:[NSString class]]) {
                WGWidgetViewController *wvc = [[WGWidgetViewController alloc] initWithExtension:ext kind:kind family:family];
                wvc.inStack = YES;
                wvc.configKey = WGWidgetConfigKey(w);
                if (_info.size.width > 0) [wvc setImageInfo:_info];
                page = wvc;
            } else {
                WGForeignWidgetViewController *f = [WGForeignWidgetViewController new];
                id name = WGCall(w, @"displayName");
                f.name = [name isKindOfClass:[NSString class]] ? name : nil;
                page = f;
            }
            [self addChildViewController:page];
            [_scroll addSubview:page.view];
            [page didMoveToParentViewController:self];
            _pagesByKey[key] = page;
        } else if ([page isKindOfClass:[WGWidgetViewController class]]) {
            ((WGWidgetViewController *)page).family = family; // resized
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
    id active = WGCall(icon, @"activeWidget");
    NSUInteger index = active ? [keys indexOfObject:WGWidgetKey(active)] : NSNotFound;
    _activeIndex = index == NSNotFound ? 0 : index;
    _scroll.scrollEnabled = pages.count > 1;
    _scroll.alwaysBounceVertical = pages.count > 1;
    if (changed) {
        for (UIView *dot in _dots) [dot removeFromSuperview];
        NSMutableArray *dots = [NSMutableArray array];
        for (NSUInteger i = 0; pages.count > 1 && i < pages.count; i++) {
            UIView *dot = [UIView new];
            dot.layer.cornerRadius = 2.5;
            [_dotsView addSubview:dot];
            [dots addObject:dot];
        }
        _dots = dots;
    }
    [self updateDots];
    [self layoutPages];
    if (flash || changed) [self flashDots];
}

- (void)updateDots {
    CGFloat h = _scroll.bounds.size.height;
    NSUInteger shown = h > 0 ? (NSUInteger)MAX(0, MIN((CGFloat)_dots.count - 1, round(_scroll.contentOffset.y / h))) : _activeIndex;
    for (NSUInteger i = 0; i < _dots.count; i++) _dots[i].backgroundColor = [UIColor colorWithWhite:1 alpha:i == shown ? 0.95 : 0.35];
}

// As iOS: the dots show while the stack scrolls and for a moment after.
- (void)flashDots {
    if (_dots.count < 2) return;
    NSUInteger token = ++_flash;
    [UIView animateWithDuration:0.15 animations:^{ self->_dotsView.alpha = 1; }];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) s = weakSelf;
        if (!s || token != s->_flash || s->_scroll.isDragging || s->_scroll.isDecelerating) return;
        [UIView animateWithDuration:0.3 animations:^{ s->_dotsView.alpha = 0; }];
    });
}

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

// The page swiped to becomes the icon's active widget, as SBHWidgetStackViewController does.
- (void)settle {
    [self flashDots];
    CGFloat h = _scroll.bounds.size.height;
    if (h <= 0 || _pages.count == 0) return;
    NSUInteger index = (NSUInteger)MAX(0, MIN((CGFloat)_pages.count - 1, round(_scroll.contentOffset.y / h)));
    if (index == _activeIndex) return;
    _activeIndex = index;
    id icon = _icon;
    NSArray *widgets = WGIconWidgets(icon);
    if (index >= widgets.count) return;
    _settingActive = YES;
    WGSend1(icon, @"setLastUserSelectedDataSource:", widgets[index]);
    WGSend1(icon, @"setActiveWidget:", widgets[index]);
    _settingActive = NO;
    WGSaveIconState();
}


@end

#pragma mark - SpringBoardHome's widget containers with ours

// SpringBoardHome gives a container whose widget draws no background of its own (ours, as far
// as it knows) a dark gradient (PUIGradientView): behind clear and tinted widgets it was what
// showed black while they were resized. Containers of ours keep our glass, or nothing.
static IMP orig_containerSetBackground;

static void hook_containerSetBackground(UIView *self, SEL _cmd, UIView *background) {
    UIView *widgetView = [self respondsToSelector:NSSelectorFromString(@"widgetView")] ? WGCall(self, @"widgetView") : nil;
    BOOL ours = [widgetView isKindOfClass:[WGRootView class]];
    for (UIView *v in self.subviews) ours = ours || [v isKindOfClass:[WGRootView class]];
    if (ours && !background && !gSettingContainerBackground && [WGCall(self, @"backgroundView") isKindOfClass:[WGBackdropView class]]) {
        return; // SpringBoardHome taking away its gradient: our glass stays
    }
    if (ours && background && ![background isKindOfClass:[WGBackdropView class]]) {
        [background removeFromSuperview];
        if ([WGCall(self, @"backgroundView") isKindOfClass:[WGBackdropView class]]) return; // our glass stays
        background = nil;
    }
    ((void (*)(id, SEL, id))orig_containerSetBackground)(self, _cmd, background);
}

void WGWidgetViewsInstall(void) {
    WGHook(@"SBHWidgetContainerView", @"setBackgroundView:", (IMP)hook_containerSetBackground, &orig_containerSetBackground);
}
