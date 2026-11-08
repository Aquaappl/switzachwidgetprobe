// The home screen's icon style, and the glass behind widgets.
//
// The ROM keeps the style in NXIconStyle (styleConfiguration: an SBHIconImageStyleConfiguration
// from SpringBoardHome's style picker). When it changes, NXIconStyleDidChangeNotification is
// posted and the appearance tweak writes the style into the trait overrides of each window's
// root view controller (SBHTraitIconTint and UITraitUserInterfaceStyle), which is what icons
// draw with. Widgets read the same two sources — the trait that reaches their own view first,
// NXIconStyle's configuration second — so they look like the icons around them, also in a sheet
// that the trait does not reach.
//
// How iOS shows widgets for each style, and what is done here:
//
//   colored (default) full color, the widget's own background; light or dark with the system
//   dark              full color, dark
//   clear             accented rendering mode, no container background, on clear glass;
//                     content in white tones (light or dark glass variant)
//   tinted            accented, on glass in the tint; content in light tones of the tint
//
// SpringBoardHome's classes are read by name and by what they answer, never assumed, and the
// result is logged when it changes (diagnostic log), so another ROM build can be checked.

#import "WGSpringBoard.h"
#import <dlfcn.h>

NSNotificationName const WGAppearanceDidChangeNotification = @"WGAppearanceDidChange";

#pragma mark - Tuning

// Clear icons: content in white tones (its brightness), slightly see-through like the icons'
// glyphs. Tinted icons: content in a lighter version of the tint, from its brightness.
static const CGFloat kWGClearContentOpacity = 0.92;
static const CGFloat kWGTintLightening = 0.35;  // 0: the tint itself, 1: white
// Glass: a shade over clear glass (light / dark variant), and the tint over tinted glass.
static const CGFloat kWGClearShadeLight = 0.08, kWGClearShadeDark = 0.40;
static const CGFloat kWGTintAlphaLight = 0.45, kWGTintAlphaDark = 0.60, kWGTintDarkening = 0.35;

#pragma mark - Reading the style

static id WGIconStyleConfiguration(void) {
    Class style = NSClassFromString(@"NXIconStyle");
    id shared = [style respondsToSelector:@selector(shared)] ? WGCall(style, @"shared") : nil;
    id config = WGCall(shared, @"styleConfiguration");
    if (!config) config = WGCall(WGIconManager(), @"iconImageStyleConfiguration");
    return config;
}

static id WGTraitValue(UITraitCollection *traits) {
    static Class trait;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ trait = NSClassFromString(@"SBHTraitIconTint"); });
    SEL objectForTrait = NSSelectorFromString(@"objectForTrait:"); // iOS 17
    if (!trait || !traits || ![traits respondsToSelector:objectForTrait]) return nil;
    @try {
        return ((id (*)(id, SEL, Class))objc_msgSend)(traits, objectForTrait, trait);
    } @catch (NSException *e) {
        return nil;
    }
}

static NSString *WGClassChain(id obj) {
    NSMutableArray *names = [NSMutableArray array];
    for (Class c = [obj class]; c && c != [NSObject class] && names.count < 4; c = class_getSuperclass(c)) [names addObject:NSStringFromClass(c)];
    return [names componentsJoinedByString:@">"];
}

static UIColor *WGColorOf(id obj) {
    for (NSString *sel in @[ @"tintColor", @"iconTintColor", @"color" ]) {
        id c = WGCall(obj, sel);
        if ([c isKindOfClass:[UIColor class]]) return c;
    }
    return nil;
}

// A UIUserInterfaceStyle-like answer (1 light, 2 dark) from the first selector that has one.
static UIUserInterfaceStyle WGStyleAnswer(id obj, NSArray<NSString *> *selectors) {
    for (NSString *name in selectors) {
        SEL sel = NSSelectorFromString(name);
        if (![obj respondsToSelector:sel]) continue;
        NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
        if (sig.numberOfArguments != 2 || strlen(sig.methodReturnType) != 1 || !strchr("qlicsQLICSB", sig.methodReturnType[0])) continue;
        NSInteger v = ((NSInteger (*)(id, SEL))objc_msgSend)(obj, sel);
        if (v == UIUserInterfaceStyleLight || v == UIUserInterfaceStyleDark) return (UIUserInterfaceStyle)v;
    }
    return UIUserInterfaceStyleUnspecified;
}

static BOOL WGHas(NSString *haystack, NSString *word) {
    return [haystack rangeOfString:word options:NSCaseInsensitiveSearch].location != NSNotFound;
}

// sRGB components of a color as the given traits resolve it, clamped to 0…1.
static UIColor *WGResolvedSRGB(UIColor *color, UITraitCollection *traits) {
    if (!color) return nil;
    if (traits) color = [color resolvedColorWithTraitCollection:traits];
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorRef converted = CGColorCreateCopyByMatchingToColorSpace(srgb, kCGRenderingIntentDefault, color.CGColor, NULL);
    CGColorSpaceRelease(srgb);
    CGFloat rgb[3] = { 0.5, 0.5, 0.5 };
    if (converted && CGColorGetNumberOfComponents(converted) >= 3) {
        const CGFloat *c = CGColorGetComponents(converted);
        for (int i = 0; i < 3; i++) rgb[i] = MIN(1, MAX(0, c[i]));
    } else {
        CGFloat r, g, b, a;
        if ([color getRed:&r green:&g blue:&b alpha:&a]) {
            rgb[0] = MIN(1, MAX(0, r)), rgb[1] = MIN(1, MAX(0, g)), rgb[2] = MIN(1, MAX(0, b));
        }
    }
    if (converted) CGColorRelease(converted);
    return [UIColor colorWithRed:rgb[0] green:rgb[1] blue:rgb[2] alpha:1];
}

@implementation WGAppearance

+ (instancetype)appearanceForTraits:(UITraitCollection *)traits {
    WGAppearance *a = [WGAppearance new];
    id config = WGIconStyleConfiguration();
    id trait = WGTraitValue(traits);
    // Read from the classes themselves; their superclasses are only logged.
    NSString *configName = config ? NSStringFromClass([config class]) : @"";
    NSString *traitName = trait ? NSStringFromClass([trait class]) : @"";
    BOOL systemDark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;

    // The mode: the configuration's class first (what was chosen), then the trait's class (what
    // is applied), then their descriptions.
    NSString *mode = nil;
    for (NSString *source in @[ configName, traitName ]) {
        if (mode) break;
        if (WGHas(source, @"Tinted")) mode = @"tinted";
        else if (WGHas(source, @"Clear")) mode = @"clear";
        else if (WGHas(source, @"Automatic")) mode = @"automatic";
        else if (WGHas(source, @"Dark")) mode = @"dark";
        else if (WGHas(source, @"Light")) mode = @"light";
    }
    if (!mode) {
        NSString *text = [NSString stringWithFormat:@"%@ %@", config ? [config description] : @"", trait ? [trait description] : @""];
        if (WGHas(text, @"tinted")) mode = @"tinted";
        else if (WGHas(text, @"clear")) mode = @"clear";
        else if (WGHas(text, @"dark")) mode = @"dark";
    }
    UIColor *tint = WGColorOf(config) ?: WGColorOf(trait);
    if (!mode && tint) mode = @"tinted";

    if ([mode isEqual:@"tinted"]) a->_mode = WGIconModeTinted;
    else if ([mode isEqual:@"clear"]) a->_mode = WGIconModeClear;
    else if ([mode isEqual:@"dark"]) a->_mode = WGIconModeDark;
    else if ([mode isEqual:@"automatic"] && (WGHas(traitName, @"Dark") || (!trait && systemDark))) a->_mode = WGIconModeDark;
    else a->_mode = WGIconModeDefault;

    switch (a->_mode) {
        case WGIconModeDefault:
            // Colored icons follow the system, unless the style asks for light ones.
            a->_scheme = [mode isEqual:@"light"] ? UIUserInterfaceStyleLight : systemDark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
            break;
        case WGIconModeDark:
            a->_scheme = UIUserInterfaceStyleDark;
            break;
        case WGIconModeClear:
        case WGIconModeTinted: {
            // Accented content is light on the glass. The glass itself: the variant the style
            // names (light / dark / automatic = the system's).
            a->_scheme = UIUserInterfaceStyleDark;
            a->_accented = YES;
            NSArray *selectors = @[ @"iconGlassUserInterfaceStyle", @"glassUserInterfaceStyle", @"userInterfaceStyle" ];
            UIUserInterfaceStyle glass = WGStyleAnswer(config, selectors);
            if (glass == UIUserInterfaceStyleUnspecified) glass = WGStyleAnswer(trait, selectors);
            if (glass == UIUserInterfaceStyleUnspecified) {
                NSString *names = [configName stringByAppendingString:traitName];
                if (WGHas(names, @"Dark")) glass = UIUserInterfaceStyleDark;
                else if (WGHas(names, @"Light") && !WGHas(names, @"Automatic")) glass = UIUserInterfaceStyleLight;
            }
            a->_darkGlass = glass == UIUserInterfaceStyleDark || (glass == UIUserInterfaceStyleUnspecified && systemDark);
            break;
        }
    }
    if (a->_mode == WGIconModeTinted) a->_tint = WGResolvedSRGB(tint ?: UIColor.systemGrayColor, traits);

    // The content's colors (luminance weights of sRGB).
    const float lr = 0.2126f, lg = 0.7152f, lb = 0.0722f;
    if (a->_mode == WGIconModeClear) {
        float o = (float)kWGClearContentOpacity;
        a->_colorMatrix = @[ @(lr), @(lg), @(lb), @0, @0,  @(lr), @(lg), @(lb), @0, @0,  @(lr), @(lg), @(lb), @0, @0,  @0, @0, @0, @(o), @0 ];
    } else if (a->_mode == WGIconModeTinted) {
        CGFloat r = 0.5, g = 0.5, b = 0.5, al = 1;
        [a->_tint getRed:&r green:&g blue:&b alpha:&al];
        float t[3] = { (float)(r + (1 - r) * kWGTintLightening), (float)(g + (1 - g) * kWGTintLightening), (float)(b + (1 - b) * kWGTintLightening) };
        a->_colorMatrix = @[ @(lr * t[0]), @(lg * t[0]), @(lb * t[0]), @0, @0,
                             @(lr * t[1]), @(lg * t[1]), @(lb * t[1]), @0, @0,
                             @(lr * t[2]), @(lg * t[2]), @(lb * t[2]), @0, @0,
                             @0, @0, @0, @1, @0 ];
    }
    CGFloat r = 0, g = 0, b = 0, al = 0;
    [a->_tint getRed:&r green:&g blue:&b alpha:&al];
    a->_key = [NSString stringWithFormat:@"%ld|%d|%ld|%.3f,%.3f,%.3f", (long)a->_mode, a->_darkGlass, (long)a->_scheme, r, g, b];

    static NSString *lastLogged;
    NSString *summary = [NSString stringWithFormat:@"%@ ← configuration %@, trait %@", a, config ? WGClassChain(config) : @"-",
                                                  trait ? WGClassChain(trait) : @"-"];
    if (WGLogEnabled() && ![summary isEqualToString:lastLogged]) {
        lastLogged = summary;
        WGLog(@"Icon style: %@", summary);
    }
    return a;
}

- (NSString *)description {
    NSArray *names = @[ @"colored", @"dark", @"clear", @"tinted" ];
    NSString *s = names[self.mode];
    if (self.accented) s = [s stringByAppendingString:self.darkGlass ? @" (dark glass)" : @" (light glass)"];
    else s = [s stringByAppendingString:self.scheme == UIUserInterfaceStyleDark ? @" (dark)" : @" (light)"];
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if ([self.tint getRed:&r green:&g blue:&b alpha:&a]) s = [s stringByAppendingFormat:@" tint %.2f %.2f %.2f", r, g, b];
    return s;
}

@end

#pragma mark - Change notifications

static void WGPostAppearanceChange(void) {
    static BOOL pending;
    if (pending) return;
    pending = YES;
    // After the other observers: the appearance tweak writes the traits on the same notification.
    dispatch_async(dispatch_get_main_queue(), ^{
        pending = NO;
        [[NSNotificationCenter defaultCenter] postNotificationName:WGAppearanceDidChangeNotification object:nil];
    });
}

void WGAppearanceInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *name = @"NXIconStyleDidChangeNotification";
        NSString *const *exported = (NSString *const *)dlsym(RTLD_DEFAULT, "NXIconStyleDidChangeNotification");
        if (exported && *exported) name = *exported;
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *note) { WGPostAppearanceChange(); }];
    });
}

void WGAppearanceObserve(UIViewController *vc, SEL action) {
    [[NSNotificationCenter defaultCenter] addObserver:vc selector:action name:WGAppearanceDidChangeNotification object:nil];
    // iOS 17's trait registration (before it: traitCollectionDidChange: only).
    SEL registerSel = NSSelectorFromString(@"registerForTraitChanges:withAction:");
    Class style = NSClassFromString(@"UITraitUserInterfaceStyle"), tint = NSClassFromString(@"SBHTraitIconTint");
    if (![vc respondsToSelector:registerSel] || !style) return;
    @try {
        ((id (*)(id, SEL, id, SEL))objc_msgSend)(vc, registerSel, tint ? @[ style, tint ] : @[ style ], action);
    } @catch (NSException *e) {
        ((id (*)(id, SEL, id, SEL))objc_msgSend)(vc, registerSel, @[ style ], action);
    }
}

#pragma mark - The glass

@implementation WGBackdropView {
    UIVisualEffectView *_effect;
    NSString *_key;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.hidden = YES;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _effect.frame = self.bounds;
}

// Liquid Glass: UIGlassEffect (iOS 26), clear or regular, tinted as the icons are.
- (void)applyAppearance:(WGAppearance *)appearance cornerRadius:(CGFloat)radius {
    self.layer.cornerRadius = radius;
    _effect.layer.cornerRadius = radius;
    BOOL glass = appearance.mode == WGIconModeClear || appearance.mode == WGIconModeTinted;
    self.hidden = !glass;
    if (!glass) return;
    NSString *key = [appearance.key stringByAppendingFormat:@"|%.1f", radius];
    if ([key isEqualToString:_key]) return;
    _key = key;
    BOOL dark = appearance.darkGlass;
    UIColor *tint;
    if (appearance.mode == WGIconModeTinted) {
        CGFloat r = 0.5, g = 0.5, b = 0.5, a = 1;
        [appearance.tint getRed:&r green:&g blue:&b alpha:&a];
        CGFloat k = dark ? kWGTintDarkening : 1;
        tint = [UIColor colorWithRed:r * k green:g * k blue:b * k alpha:dark ? kWGTintAlphaDark : kWGTintAlphaLight];
    } else {
        tint = [UIColor colorWithWhite:0 alpha:dark ? kWGClearShadeDark : kWGClearShadeLight];
    }
    // UIGlassEffectStyle: 0 regular, 1 clear.
    Class glassClass = NSClassFromString(@"UIGlassEffect");
    SEL withStyle = NSSelectorFromString(@"effectWithStyle:");
    if (![glassClass respondsToSelector:withStyle]) return;
    UIVisualEffect *effect = ((id (*)(id, SEL, NSInteger))objc_msgSend)(glassClass, withStyle, appearance.mode == WGIconModeClear ? 1 : 0);
    WGSend1(effect, @"setTintColor:", tint);
    if (!_effect) {
        _effect = [[UIVisualEffectView alloc] initWithEffect:nil];
        _effect.layer.cornerCurve = kCACornerCurveContinuous;
        _effect.layer.cornerRadius = radius;
        [self addSubview:_effect];
    }
    _effect.effect = effect;
    _effect.overrideUserInterfaceStyle = dark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
    [self setNeedsLayout];
}

@end
