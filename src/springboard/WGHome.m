// The home screen integration.
//
// SpringBoardHome already models widgets as grid icons: an SBWidgetIcon holding SBHWidgets
// (extension id, kind, app, sizes). The ROM lacks what iOS draws them with (chronod's widget
// host), so the tweak supplies the content: SpringBoardHome's request for an icon's content view
// controller gets ours for our widgets, and the questions SpringBoardHome would ask chronod
// (is this widget valid, which sizes, its name, its long-press items) are answered here. Moving,
// edit mode, folders of pages and icons making room stay the ROM's own.
//
// Hooks go through the Objective-C runtime only (Switzach does not allow patching code), and
// each one passes everything that is not one of our widgets straight to the original.

#import "WGSpringBoard.h"
#import <dlfcn.h>

static __weak id gManager;                // SBHIconManager
static __weak UIViewController *gHome;    // NXHomeScreenViewController

id WGIconManager(void) {
    id m = gManager;
    if (m) return m;
    UIViewController *home = gHome;
    if (!home) {
        Class homeClass = NSClassFromString(@"NXHomeScreenViewController");
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                UIViewController *root = w.rootViewController;
                if ([root isKindOfClass:homeClass]) home = root;
                for (UIViewController *child in root.childViewControllers) if (!home && [child isKindOfClass:homeClass]) home = child;
            }
        }
        gHome = home;
    }
    m = WGCall(home, @"iconManager");
    gManager = m;
    return m;
}

BOOL WGIsEditing(void) {
    return WGCallBool(WGIconManager(), @"isEditing");
}

void WGSaveIconState(void) {
    id model = WGCall(WGIconManager(), @"iconModel");
    SEL save = NSSelectorFromString(@"saveIconStateIfNeeded");
    if ([model respondsToSelector:save]) ((BOOL (*)(id, SEL))objc_msgSend)(model, save);
}

#pragma mark - Launch guard

// If SpringBoard keeps ending soon after it starts, widgets are not drawn for one launch, so
// they can be removed.
static BOOL gStopped;

BOOL WGHomeDrawingStopped(void) {
    return gStopped;
}

static void WGGuardLaunch(void) {
    NSString *path = WGWorkPath(@"boot-guard");
    int count = [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] intValue];
    gStopped = count >= 2;
    [[NSString stringWithFormat:@"%d", count + 1] writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    WGLog(@"==== SwitzachWidgetProbe %s (unfinished launches before: %d)%@", WG_VERSION, count,
          gStopped ? @": widgets are not drawn this time" : @"");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [@"0" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    });
}

#pragma mark - Our widget icons

NSArray *WGIconWidgets(id icon) {
    if (!WGCallBool(icon, @"isWidgetIcon")) return @[];
    NSArray *ws = WGCall(icon, @"widgets");
    if ([ws isKindOfClass:[NSArray class]] && ws.count) return ws;
    id w = WGCall(icon, @"activeWidget");
    return w ? @[ w ] : @[];
}

static NSString *WGExtensionIDOf(id widgetLike) {
    id v = WGCall(widgetLike, @"extensionBundleIdentifier");
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static BOOL WGIsOurWidget(id widget) {
    return [WGExtensions extensionWithID:WGExtensionIDOf(widget)] != nil;
}

BOOL WGIsOurWidgetIcon(id icon) {
    for (id w in WGIconWidgets(icon)) if (WGIsOurWidget(w)) return YES;
    return NO;
}

static id WGTopWidget(id icon) {
    return WGCall(icon, @"activeWidget") ?: WGIconWidgets(icon).firstObject;
}

#pragma mark Grid sizes

static NSString *WGGridConstant(const char *symbol) {
    void *p = dlsym(RTLD_DEFAULT, symbol);
    NSString *value = p ? *(NSString *__unsafe_unretained *)p : nil;
    return value ?: @(symbol);
}

static NSString *WGGridSmall(void) { static NSString *v; return v ?: (v = WGGridConstant("SBHIconGridSizeClassSmall")); }
static NSString *WGGridMedium(void) { static NSString *v; return v ?: (v = WGGridConstant("SBHIconGridSizeClassMedium")); }
static NSString *WGGridLarge(void) { static NSString *v; return v ?: (v = WGGridConstant("SBHIconGridSizeClassLarge")); }
static NSString *WGGridExtraLarge(void) { static NSString *v; return v ?: (v = WGGridConstant("SBHIconGridSizeClassExtraLarge")); }

NSString *WGGridClassForFamily(WGFamily family) {
    switch (family) {
        case WGFamilySmall: return WGGridSmall();
        case WGFamilyMedium: return WGGridMedium();
        case WGFamilyLarge: return WGGridLarge();
        case WGFamilyExtraLarge: return WGGridExtraLarge();
    }
    return WGGridMedium();
}

WGFamily WGFamilyForGridClass(NSString *c) {
    if (![c isKindOfClass:[NSString class]]) return WGFamilyMedium;
    if ([c isEqualToString:WGGridSmall()]) return WGFamilySmall;
    if ([c isEqualToString:WGGridLarge()]) return WGFamilyLarge;
    if ([c isEqualToString:WGGridExtraLarge()] || [c rangeOfString:@"ExtraLarge" options:NSCaseInsensitiveSearch].location != NSNotFound) return WGFamilyExtraLarge;
    return [c isEqualToString:WGGridMedium()] ? WGFamilyMedium : WGFamilySmall;
}

static id WGGridSet(NSArray<NSString *> *families) {
    Class mutableClass = NSClassFromString(@"SBHMutableIconGridSizeClassSet");
    SEL add = NSSelectorFromString(@"addGridSizeClass:");
    if (![mutableClass instancesRespondToSelector:add]) return nil;
    id set = [mutableClass new];
    for (NSString *f in families) ((void (*)(id, SEL, id))objc_msgSend)(set, add, WGGridClassForFamily(WGFamilyFromName(f)));
    return [set respondsToSelector:@selector(copyWithZone:)] ? [set copy] : set;
}

// What placement accepts for our widgets: every home screen size (the menu offers only the
// ones the widget declares).
static id WGAllSizes(void) {
    static id set;
    if (!set) set = WGGridSet(@[ @"small", @"medium", @"large", @"extraLarge" ]);
    return set;
}

// The family names every widget of an icon declares; nil while unknown.
static NSSet<NSString *> *WGDeclaredFamilyNames(id icon) {
    NSMutableSet *common = nil;
    for (id widget in WGIconWidgets(icon)) {
        WGExtension *ext = [WGExtensions extensionWithID:WGExtensionIDOf(widget)];
        NSString *kind = WGCall(widget, @"kind");
        NSArray *families = nil;
        for (NSDictionary *w in ext ? [WGHost hostForExtension:ext].widgets : nil) {
            if ([w[@"kind"] isEqual:kind]) families = w[@"families"];
        }
        if (![families isKindOfClass:[NSArray class]] || !families.count) return nil;
        if (!common) common = [NSMutableSet setWithArray:families];
        else [common intersectSet:[NSSet setWithArray:families]];
    }
    return common;
}

// The sizes a widget icon offers: those every widget of it declares; nil while unknown.
static id WGDeclaredSizes(id icon) {
    NSSet *common = WGDeclaredFamilyNames(icon);
    return common ? WGGridSet(common.allObjects) : nil;
}

WGIconImageInfo WGImageInfoForFamily(WGFamily family) {
    WGIconImageInfo info = { CGSizeZero, UIScreen.mainScreen.scale, 0 };
    id listView = WGCall(WGCall(WGIconManager(), @"rootFolderController"), @"currentIconListView");
    SEL sel = NSSelectorFromString(@"iconImageInfoForGridSizeClass:");
    if ([listView respondsToSelector:sel]) info = ((WGIconImageInfo (*)(id, SEL, id))objc_msgSend)(listView, sel, WGGridClassForFamily(family));
    if (info.size.width < 40) {
        // iPhone sizes for this screen width.
        CGFloat w = MIN(UIScreen.mainScreen.bounds.size.width, UIScreen.mainScreen.bounds.size.height);
        CGFloat small = w >= 428 ? 170 : w >= 390 ? 158 : w >= 375 ? 148 : 141;
        CGFloat wide = w >= 428 ? 364 : w >= 390 ? 338 : w >= 375 ? 321 : 292;
        CGFloat tall = w >= 428 ? 382 : w >= 390 ? 354 : w >= 375 ? 324 : 311;
        info.size = family == WGFamilySmall ? CGSizeMake(small, small) : family == WGFamilyMedium ? CGSizeMake(wide, small) : CGSizeMake(wide, tall);
        info.scale = UIScreen.mainScreen.scale;
    }
    if (info.continuousCornerRadius <= 0) info.continuousCornerRadius = 22;
    return info;
}

#pragma mark - Making widget icons

static id WGMakeWidget(NSString *extID, NSString *kind, NSString *container, NSString *unique) {
    Class widgetClass = NSClassFromString(@"SBHWidget");
    WGExtension *ext = [WGExtensions extensionWithID:extID];
    if (!widgetClass || !extID || !kind) return nil;
    if (!container.length) container = ext.appID ?: @"";
    id sizes = ext ? WGAllSizes() : nil;
    SEL withID = NSSelectorFromString(@"initWithUniqueIdentifier:kind:extensionBundleIdentifier:containerBundleIdentifier:supportedGridSizeClasses:");
    if (unique.length && sizes && [widgetClass instancesRespondToSelector:withID]) { // keeps its saved identity
        return ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)([widgetClass alloc], withID, unique, kind, extID, container, sizes);
    }
    SEL withSizes = NSSelectorFromString(@"initWithKind:extensionBundleIdentifier:containerBundleIdentifier:supportedGridSizeClasses:");
    if (sizes && [widgetClass instancesRespondToSelector:withSizes]) {
        return ((id (*)(id, SEL, id, id, id, id))objc_msgSend)([widgetClass alloc], withSizes, kind, extID, container, sizes);
    }
    SEL plain = NSSelectorFromString(@"initWithKind:extensionBundleIdentifier:containerBundleIdentifier:");
    if (![widgetClass instancesRespondToSelector:plain]) return nil;
    return ((id (*)(id, SEL, id, id, id))objc_msgSend)([widgetClass alloc], plain, kind, extID, container);
}

// A widget icon holding the widgets in order (a stack when there are several).
static id WGMakeIcon(NSArray<NSDictionary *> *saved, NSString *gridClass, NSString *selected) {
    Class iconClass = NSClassFromString(@"SBWidgetIcon");
    NSMutableArray *widgets = [NSMutableArray array];
    id selectedWidget = nil;
    for (NSDictionary *w in saved) {
        id widget = WGMakeWidget(w[@"ext"], w[@"kind"], w[@"container"], w[@"unique"]);
        if (!widget) continue;
        [widgets addObject:widget];
        if (selected.length && [w[@"unique"] isEqualToString:selected]) selectedWidget = widget;
    }
    if (!iconClass || !widgets.count) return nil;
    SEL many = NSSelectorFromString(@"initWithWidgets:"), one = NSSelectorFromString(@"initWithWidget:");
    id icon = widgets.count > 1 && [iconClass instancesRespondToSelector:many] ? ((id (*)(id, SEL, id))objc_msgSend)([iconClass alloc], many, widgets)
              : [iconClass instancesRespondToSelector:one] ? ((id (*)(id, SEL, id))objc_msgSend)([iconClass alloc], one, widgets.firstObject) : nil;
    if (!icon) return nil;
    WGSend1(icon, @"setGridSizeClass:", gridClass);
    if (selectedWidget) { // the widget that was on top
        WGSend1(icon, @"setLastUserSelectedDataSource:", selectedWidget);
        WGSend1(icon, @"setActiveWidget:", selectedWidget);
    }
    return icon;
}

static BOOL WGFolderContains(id folder, id icon) {
    for (id list in (NSArray *)WGCall(folder, @"lists") ?: @[]) {
        if ([(NSArray *)WGCall(list, @"icons") ?: @[] containsObject:icon]) return YES;
    }
    return NO;
}

// As iOS: the new widget goes to the top of the page being shown and the icons it displaces move
// along (SBFolder bumps them onto the following pages); else into the first space it fits.
NSString *WGInsertWidget(WGExtension *ext, NSString *kind, WGFamily family) {
    id manager = WGIconManager();
    id list = WGCall(WGCall(WGCall(manager, @"rootFolderController"), @"currentIconListView"), @"model");
    id folder = WGCall(manager, @"rootFolder");
    NSArray *lists = WGCall(folder, @"lists");
    if (!list || ![lists isKindOfClass:[NSArray class]]) return @"The current page was not found.";
    id icon = WGMakeIcon(@[ @{ @"ext" : ext.extensionID, @"kind" : kind, @"container" : ext.appID } ], WGGridClassForFamily(family), nil);
    if (!icon) return @"The widget could not be made.";
    WGLog(@"Add: %@ %@ (%@)", ext.extensionID, kind, WGFamilyName(family));
    NSUInteger listIndex = [lists indexOfObject:list];
    SEL insertAt = NSSelectorFromString(@"insertIcon:atIndexPath:options:");
    if (listIndex != NSNotFound && [folder respondsToSelector:insertAt]) {
        NSUInteger indexes[2] = { listIndex, 0 };
        @try {
            ((void (*)(id, SEL, id, id, NSUInteger))objc_msgSend)(folder, insertAt, icon, [NSIndexPath indexPathWithIndexes:indexes length:2], 0);
        } @catch (NSException *e) {
            WGLog(@"Inserting at the top: %@", e.reason);
        }
    }
    if (!WGFolderContains(folder, icon)) {
        NSMutableArray *candidates = [NSMutableArray arrayWithObject:list];
        for (id l in lists) if (l != list) [candidates addObject:l];
        SEL allows = NSSelectorFromString(@"allowsAddingIcon:ignoringPlaceholders:");
        for (id target in candidates) {
            if ([target respondsToSelector:allows] && !((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(target, allows, icon, NO)) continue;
            WGSend1(target, @"addIcon:", icon);
            break;
        }
    }
    if (!WGFolderContains(folder, icon)) return @"No page has room for it.";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WGSaveIconState(); });
    return nil;
}

#pragma mark - Keeping widgets across resprings

// The ROM writes widgets to IconState.plist, but SpringBoardHome drops them while importing it
// at launch (chronod does not know them). Where they were is read from the saved state and they
// are put back after the import, on their pages.
static __weak id gModel;

static NSDictionary *WGSavedWidget(NSDictionary *d) {
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    NSString *ext = d[@"bundleIdentifier"], *kind = d[@"widgetIdentifier"];
    if (![ext isKindOfClass:[NSString class]] || ![kind isKindOfClass:[NSString class]]) return nil;
    NSString *container = [d[@"containerBundleIdentifier"] isKindOfClass:[NSString class]] ? d[@"containerBundleIdentifier"] : @"";
    NSString *unique = [d[@"uniqueIdentifier"] isKindOfClass:[NSString class]] ? d[@"uniqueIdentifier"] : @"";
    return @{ @"ext" : ext, @"kind" : kind, @"container" : container, @"unique" : unique };
}

// The widgets of a saved entry (a stack's elements, or the widget itself), or nil.
static NSArray *WGSavedEntryWidgets(NSDictionary *d) {
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    for (NSString *key in @[ @"elements", @"widgets" ]) {
        NSArray *list = d[key];
        if (![list isKindOfClass:[NSArray class]]) continue;
        NSMutableArray *ws = [NSMutableArray array];
        for (NSDictionary *e in list) {
            NSDictionary *w = WGSavedWidget(e);
            if (w) [ws addObject:w];
        }
        if (ws.count) return ws;
    }
    NSDictionary *w = [d[@"elementType"] isEqual:@"widget"] ? WGSavedWidget(d) : nil;
    return w ? @[ w ] : nil;
}

typedef NS_ENUM(NSInteger, WGSavedPage) {
    WGSavedPageKept,     // has an app or a folder: still there after the import
    WGSavedPageOursOnly, // only widgets, ours among them: gone, to be made again
    WGSavedPageGone,     // only other widgets: gone
    WGSavedPageEmpty,
};

static void WGReadSavedState(id state, NSMutableArray *widgets, NSMutableArray *pages) {
    NSArray *lists = [state isKindOfClass:[NSDictionary class]] ? state[@"iconLists"] : nil;
    for (NSUInteger li = 0; [lists isKindOfClass:[NSArray class]] && li < lists.count; li++) {
        NSArray *items = [lists[li] isKindOfClass:[NSArray class]] ? lists[li] : @[];
        BOOL kept = NO, ours = NO;
        for (NSUInteger i = 0; i < items.count; i++) {
            NSDictionary *d = items[i];
            NSArray *ws = WGSavedEntryWidgets(d);
            if (!ws) {
                kept = YES;
                continue;
            }
            BOOL entryOurs = NO;
            for (NSDictionary *w in ws) if ([WGExtensions extensionWithID:w[@"ext"]]) entryOurs = YES;
            if (!entryOurs) continue;
            ours = YES;
            NSString *grid = [d[@"gridSize"] isKindOfClass:[NSString class]] ? d[@"gridSize"] : @"medium";
            NSString *selected = [d[@"userSelectedElementIdentifier"] isKindOfClass:[NSString class]] ? d[@"userSelectedElementIdentifier"] : @"";
            [widgets addObject:@{ @"list" : @(li), @"index" : @(i), @"widgets" : ws, @"gridSize" : grid, @"selected" : selected }];
        }
        [pages addObject:@(items.count == 0 ? WGSavedPageEmpty : kept ? WGSavedPageKept : ours ? WGSavedPageOursOnly : WGSavedPageGone)];
    }
}

static void WGRestore(NSArray *saved, NSArray<NSNumber *> *pages) {
    id model = gModel;
    id folder = WGCall(model, @"rootFolder");
    NSArray *lists = WGCall(folder, @"lists");
    if (!saved.count || ![lists isKindOfClass:[NSArray class]] || !lists.count) return;
    for (id list in lists) {
        for (id icon in (NSArray *)WGCall(list, @"icons") ?: @[]) if (WGIsOurWidgetIcon(icon)) return; // kept, or put back already
    }
    // The saved page number → the page it is now; pages that held only our widgets are made again.
    NSMutableDictionary<NSNumber *, NSNumber *> *pageNow = [NSMutableDictionary dictionary];
    NSUInteger now = 0, made = 0;
    SEL insertList = NSSelectorFromString(@"insertEmptyListAtIndex:");
    for (NSUInteger li = 0; li < pages.count; li++) {
        WGSavedPage page = (WGSavedPage)pages[li].integerValue;
        BOOL emptyNow = now < lists.count && [(NSArray *)WGCall(lists[now], @"icons") count] == 0;
        if (page == WGSavedPageKept) {
            pageNow[@(li)] = @(now++);
        } else if (page == WGSavedPageOursOnly) {
            if (!emptyNow && now <= lists.count && [folder respondsToSelector:insertList]) {
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(folder, insertList, (NSInteger)now);
                lists = WGCall(folder, @"lists");
                made++;
            }
            pageNow[@(li)] = @(now++);
        } else if (page == WGSavedPageEmpty && emptyNow) {
            now++;
        }
    }
    SEL insertSel = NSSelectorFromString(@"insertIcon:atIndex:");
    for (NSDictionary *r in saved) {
        id icon = WGMakeIcon(r[@"widgets"], WGGridClassForFamily(WGFamilyFromName(r[@"gridSize"])), r[@"selected"]);
        if (!icon) continue;
        NSNumber *at = pageNow[r[@"list"]];
        NSUInteger li = MIN(at ? at.unsignedIntegerValue : [r[@"list"] unsignedIntegerValue], lists.count - 1);
        id list = lists[li];
        NSUInteger index = MIN([r[@"index"] unsignedIntegerValue], [(NSArray *)WGCall(list, @"icons") count]);
        if ([list respondsToSelector:insertSel]) ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(list, insertSel, icon, index);
        else WGSend1(list, @"addIcon:", icon);
    }
    WGLog(@"Put back %lu widget(s) (pages made again: %lu)", (unsigned long)saved.count, (unsigned long)made);
    WGSaveIconState();
}

static IMP orig_storeLoad, orig_didUnarchive;

static id hook_storeLoad(id self, SEL _cmd, NSError **error) {
    id state = ((id (*)(id, SEL, NSError **))orig_storeLoad)(self, _cmd, error);
    NSMutableArray *widgets = [NSMutableArray array], *pages = [NSMutableArray array];
    WGReadSavedState(state, widgets, pages);
    if (!widgets.count) return state; // a later load without them is the copy SpringBoardHome cut down
    // Their hosts can start while the home screen is still being built.
    if (!gStopped) {
        for (NSDictionary *r in widgets) {
            for (NSDictionary *w in r[@"widgets"]) {
                WGExtension *ext = [WGExtensions extensionWithID:w[@"ext"]];
                if (ext) [[WGHost hostForExtension:ext] loadWidgets:nil];
            }
        }
    }
    // Put back right after this import, and look again in case they were dropped only later.
    dispatch_async(dispatch_get_main_queue(), ^{ WGRestore(widgets, pages); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WGRestore(widgets, pages); });
    return state;
}

static id hook_didUnarchive(id self, SEL _cmd, id unarchiver, id icon) {
    gModel = self;
    id result = ((id (*)(id, SEL, id, id))orig_didUnarchive)(self, _cmd, unarchiver, icon);
    return !result && WGIsOurWidgetIcon(icon) ? icon : result;
}

#pragma mark - Hooks: content

static IMP orig_customImageVC, orig_makeWidgetVC3, orig_makeWidgetVC4;

static id hook_customImageVC(id self, SEL _cmd, id iconView) {
    gManager = self;
    id icon = WGCall(iconView, @"icon");
    if (!WGIsOurWidgetIcon(icon)) return ((id (*)(id, SEL, id))orig_customImageVC)(self, _cmd, iconView);
    return [[WGStackViewController alloc] initWithIcon:icon iconView:iconView];
}

// One widget's content outside the grid: the sizes shown while it is resized.
static id WGSingleWidgetVC(id icon, id dataSource, id gridClass) {
    WGExtension *ext = [WGExtensions extensionWithID:WGExtensionIDOf(dataSource)];
    NSString *kind = WGCall(dataSource, @"kind");
    if (!ext || ![kind isKindOfClass:[NSString class]]) return nil;
    WGWidgetViewController *vc = [[WGWidgetViewController alloc] initWithExtension:ext kind:kind
                                                      family:WGFamilyForGridClass([gridClass isKindOfClass:[NSString class]] ? gridClass : WGCall(icon, @"gridSizeClass"))];
    vc.configKey = WGWidgetConfigKey(dataSource);
    return vc;
}

static id hook_makeWidgetVC3(id self, SEL _cmd, id icon, id dataSource, id location) {
    return WGSingleWidgetVC(icon, dataSource, nil) ?: ((id (*)(id, SEL, id, id, id))orig_makeWidgetVC3)(self, _cmd, icon, dataSource, location);
}

static id hook_makeWidgetVC4(id self, SEL _cmd, id icon, id dataSource, id location, id gridClass) {
    return WGSingleWidgetVC(icon, dataSource, gridClass) ?: ((id (*)(id, SEL, id, id, id, id))orig_makeWidgetVC4)(self, _cmd, icon, dataSource, location, gridClass);
}

#pragma mark Hooks: what chronod would answer

static IMP orig_isWidgetValid, orig_validatedIcon, orig_modelValidatedIcon, orig_mgrSupported, orig_mgrModelSupported, orig_modelSupported,
    orig_unarchiverSupported, orig_widgetDisplayName, orig_widgetIconDisplayName;

static BOOL hook_isWidgetValid(id self, SEL _cmd, id widget, id sizeClass) {
    return WGIsOurWidget(widget) || ((BOOL (*)(id, SEL, id, id))orig_isWidgetValid)(self, _cmd, widget, sizeClass);
}

static id hook_validatedIcon(id self, SEL _cmd, id icon) {
    return WGIsOurWidgetIcon(icon) ? icon : ((id (*)(id, SEL, id))orig_validatedIcon)(self, _cmd, icon);
}

static id hook_modelValidatedIcon(id self, SEL _cmd, id model, id icon) {
    return WGIsOurWidgetIcon(icon) ? icon : ((id (*)(id, SEL, id, id))orig_modelValidatedIcon)(self, _cmd, model, icon);
}

static id hook_mgrSupported(id self, SEL _cmd, id kind, id extID, id container) {
    return [WGExtensions extensionWithID:extID] && WGAllSizes() ? WGAllSizes() : ((id (*)(id, SEL, id, id, id))orig_mgrSupported)(self, _cmd, kind, extID, container);
}

static id hook_mgrModelSupported(id self, SEL _cmd, id model, id kind, id extID, id container) {
    return [WGExtensions extensionWithID:extID] && WGAllSizes() ? WGAllSizes()
                                                                 : ((id (*)(id, SEL, id, id, id, id))orig_mgrModelSupported)(self, _cmd, model, kind, extID, container);
}

static id hook_modelSupported(id self, SEL _cmd, id kind, id extID, id container) {
    return [WGExtensions extensionWithID:extID] && WGAllSizes() ? WGAllSizes() : ((id (*)(id, SEL, id, id, id))orig_modelSupported)(self, _cmd, kind, extID, container);
}

static id hook_unarchiverSupported(id self, SEL _cmd, id unarchiver, id kind, id extID, id container) {
    return [WGExtensions extensionWithID:extID] && WGAllSizes() ? WGAllSizes()
                                                                 : ((id (*)(id, SEL, id, id, id, id))orig_unarchiverSupported)(self, _cmd, unarchiver, kind, extID, container);
}

// The label: chronod would provide it, so it stays "Waiting…"; the app's name, as iOS shows.
static id hook_widgetDisplayName(id self, SEL _cmd) {
    WGExtension *ext = [WGExtensions extensionWithID:WGExtensionIDOf(self)];
    return ext.appName ?: ((id (*)(id, SEL))orig_widgetDisplayName)(self, _cmd);
}

static id hook_widgetIconDisplayName(id self, SEL _cmd, id icon, id location) {
    WGExtension *ext = [WGExtensions extensionWithID:WGExtensionIDOf(self)];
    return ext.appName ?: ((id (*)(id, SEL, id, id))orig_widgetIconDisplayName)(self, _cmd, icon, location);
}

// Questions SpringBoardHome may put to the ROM's home screen controller, which has no answer.
static BOOL WGDelegateIsWidgetValid(id self, SEL _cmd, id manager, id widget) {
    return WGIsOurWidget(widget);
}

static void WGDelegateWidgetLaunch(id self, SEL _cmd, id manager, id bundleID, id action) {
    if ([bundleID isKindOfClass:[NSString class]]) WGLaunchApp(bundleID);
}

static void WGDelegateWidgetLaunch2(id self, SEL _cmd, id manager, id iconView, id bundleID, id action) {
    if ([bundleID isKindOfClass:[NSString class]]) WGLaunchApp(bundleID);
}

static void WGDelegateWidgetURL(id self, SEL _cmd, id manager, id url) {
}

#pragma mark Hooks: removing

static IMP orig_closeBoxTapped, orig_wantsUninstall, orig_displaysCloseBox, orig_closeBoxType;

static void WGRemoveIcon(id icon) {
    id folder = WGCall(WGIconManager(), @"rootFolder");
    for (id list in (NSArray *)WGCall(folder, @"lists") ?: @[]) {
        if (![(NSArray *)WGCall(list, @"icons") ?: @[] containsObject:icon]) continue;
        WGSend1(list, @"removeIcon:", icon);
        break;
    }
    // Still there: the folder removes it (and tidies the pages).
    SEL folderRemove = NSSelectorFromString(@"removeIcon:options:listGridCellInfoOptions:");
    if (WGFolderContains(folder, icon) && [folder respondsToSelector:folderRemove]) {
        ((void (*)(id, SEL, id, NSUInteger, NSUInteger))objc_msgSend)(folder, folderRemove, icon, 0, 0);
    }
    WGLog(@"Remove widget: %@", WGFolderContains(folder, icon) ? @"failed" : @"done");
    WGSaveIconState();
}

// "Remove “YouTube” Widget?" / "Remove Stack?". One tap of the − badge reaches us twice (close
// box, then uninstall): one question per icon at a time.
static __weak UIAlertController *gRemovalAlert;
static __weak id gRemovalIcon;
static CFAbsoluteTime gRemovalAnsweredAt;

static void WGConfirmRemoval(UIViewController *presenter, id icon) {
    if (gRemovalIcon == icon && (gRemovalAlert || CFAbsoluteTimeGetCurrent() - gRemovalAnsweredAt < 1.5)) return;
    BOOL stack = WGIconWidgets(icon).count > 1;
    WGExtension *ext = [WGExtensions extensionWithID:WGExtensionIDOf(WGTopWidget(icon))];
    NSString *title = stack ? @"Remove Stack?" : [NSString stringWithFormat:@"Remove “%@” Widget?", ext.appName ?: @""];
    NSString *message = stack ? @"Removing this stack will not delete any data." : @"Removing this widget will not delete any data.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    __weak id weakIcon = icon;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        gRemovalAnsweredAt = CFAbsoluteTimeGetCurrent();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        gRemovalAnsweredAt = CFAbsoluteTimeGetCurrent();
        id i = weakIcon;
        if (i) WGRemoveIcon(i);
    }]];
    gRemovalAlert = alert;
    gRemovalIcon = icon;
    UIViewController *top = presenter;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:alert animated:YES completion:nil];
}

static void hook_closeBoxTapped(id self, SEL _cmd, id manager, id iconView) {
    if (manager) gManager = manager;
    id icon = WGCall(iconView, @"icon");
    if (WGIsOurWidgetIcon(icon) && [self isKindOfClass:[UIViewController class]]) {
        WGConfirmRemoval(self, icon);
        return;
    }
    ((void (*)(id, SEL, id, id))orig_closeBoxTapped)(self, _cmd, manager, iconView);
}

// The ROM shows the − badge only for apps it can remove; like iOS, widgets always have one.
static BOOL hook_displaysCloseBox(id self, SEL _cmd, id manager, id iconView) {
    return WGIsOurWidgetIcon(WGCall(iconView, @"icon")) || ((BOOL (*)(id, SEL, id, id))orig_displaysCloseBox)(self, _cmd, manager, iconView);
}

static NSInteger hook_closeBoxType(id self, SEL _cmd, id manager, id iconView, NSInteger proposed) {
    NSInteger type = ((NSInteger (*)(id, SEL, id, id, NSInteger))orig_closeBoxType)(self, _cmd, manager, iconView, proposed);
    if (type != 0 || !WGIsOurWidgetIcon(WGCall(iconView, @"icon"))) return type;
    return proposed != 0 ? proposed : 1; // 1: the delete (−) badge
}

static void hook_wantsUninstall(id self, SEL _cmd, id manager, id icon, id location) {
    if (manager) gManager = manager;
    if (WGIsOurWidgetIcon(icon) && [self isKindOfClass:[UIViewController class]]) {
        WGConfirmRemoval(self, icon);
        return;
    }
    ((void (*)(id, SEL, id, id, id))orig_wantsUninstall)(self, _cmd, manager, icon, location);
}

#pragma mark Hooks: the long-press menu

// SpringBoardHome gets a widget's long-press items from chronod's widget host, so ours had none
// and the menu did not open. They are composed the way SpringBoardHome does for widgets — sizes,
// Edit Home Screen, Remove Widget — and carried out here.
static IMP orig_itemsWithProposed, orig_shouldActivate, orig_resizeSizes;

static NSString *WGShortcutTypes(id items) {
    if (![items isKindOfClass:[NSArray class]]) return [items description] ?: @"nil";
    NSMutableArray *types = [NSMutableArray array];
    for (id item in items) [types addObject:[WGCall(item, @"type") description] ?: NSStringFromClass([item class])];
    return [NSString stringWithFormat:@"[%@]", [types componentsJoinedByString:@", "]];
}

// A long-press menu item of ours, of SpringBoardHome's kind.
static id WGShortcutItem(NSString *what, NSString *title, NSString *symbol) {
    Class itemClass = NSClassFromString(@"SBSApplicationShortcutItem");
    if (!itemClass) return nil;
    id item = [itemClass new];
    WGSend1(item, @"setType:", [@"com.apple.springboardhome.application-shortcut-item." stringByAppendingString:what]);
    WGSend1(item, @"setLocalizedTitle:", title);
    Class iconClass = NSClassFromString(@"SBSApplicationShortcutSystemIcon");
    SEL withName = NSSelectorFromString(@"initWithSystemImageName:");
    if ([iconClass instancesRespondToSelector:withName]) {
        id glyph = ((id (*)(id, SEL, id))objc_msgSend)([iconClass alloc], withName, symbol);
        if (glyph) WGSend1(item, @"setIcon:", glyph);
    }
    return item;
}

// "Edit Widget" first, for a widget with settings (the one shown, in a stack).
static NSArray *WGWithEditWidgetItem(NSArray *items, id icon) {
    if (!WGWidgetIsEditable(WGCall(icon, @"activeWidget"))) return items;
    id item = WGShortcutItem(@"wg-edit-widget", @"Edit Widget", @"info.circle");
    return item ? [@[ item ] arrayByAddingObjectsFromArray:items] : items;
}


static id hook_itemsWithProposed(id self, SEL _cmd, id iconView, id proposed) {
    id icon = WGCall(iconView, @"icon");
    BOOL ours = WGIsOurWidgetIcon(icon);
    // None proposed (nil or empty: chronod's host would have given them).
    if (ours && (![proposed isKindOfClass:[NSArray class]] || [(NSArray *)proposed count] == 0)) {
        Class composer = NSClassFromString(@"SBHIconApplicationShortcutListComposer");
        SEL compose = NSSelectorFromString(@"composedShortcutsForWidgetIcon:additionalApplicationShortcutItems:widgetIconSupportsConfiguration:"
                                           @"iconManagerAllowsEditing:widgetSettings:");
        if ([composer respondsToSelector:compose]) {
            id settings = WGCall(self, @"widgetSettings");
            @try {
                id composed = ((id (*)(id, SEL, id, id, BOOL, BOOL, id))objc_msgSend)(composer, compose, icon, @[], NO, YES, settings);
                WGLog(@"Menu: proposed %@, composed %@", WGShortcutTypes(proposed), WGShortcutTypes(composed));
                if ([composed isKindOfClass:[NSArray class]]) proposed = WGWithEditWidgetItem(composed, icon);
            } @catch (NSException *e) {
                WGLogImportant(@"Menu: composing failed: %@", e.reason);
            }
        } else {
            WGLog(@"Menu: SBHIconApplicationShortcutListComposer %@ the composing method", composer ? @"lacks" : @"is missing, and so is");
        }
    }
    id result = ((id (*)(id, SEL, id, id))orig_itemsWithProposed)(self, _cmd, iconView, proposed);
    if (ours) WGLog(@"Menu: items %@", WGShortcutTypes(result));
    return result;
}

// Only the sizes the widget declares (a medium-only widget offers none).
static id hook_resizeSizes(id self, SEL _cmd, id iconView) {
    id icon = WGCall(iconView, @"icon");
    id sizes = WGIsOurWidgetIcon(icon) ? WGDeclaredSizes(icon) : nil;
    if (WGIsOurWidgetIcon(icon)) WGLog(@"Resize sizes: %@", sizes ?: @"(SpringBoardHome's)");
    return sizes ?: ((id (*)(id, SEL, id))orig_resizeSizes)(self, _cmd, iconView);
}

static BOOL WGHandleShortcut(id manager, UIView *iconView, NSString *type) {
    NSString *prefix = @"com.apple.springboardhome.application-shortcut-item.";
    if (![type hasPrefix:prefix]) return NO;
    NSString *what = [type substringFromIndex:prefix.length];
    if ([what isEqualToString:@"rearrange-icons"]) {
        // As SpringBoardHome does: once the menu is gone, from this icon view.
        SEL fromIconView = NSSelectorFromString(@"setEditing:fromIconView:"), plain = NSSelectorFromString(@"setEditing:");
        if (![manager respondsToSelector:fromIconView] && ![manager respondsToSelector:plain]) return NO;
        __weak UIView *weakIconView = iconView;
        void (^edit)(void) = ^{
            if ([manager respondsToSelector:fromIconView]) ((void (*)(id, SEL, BOOL, id))objc_msgSend)(manager, fromIconView, YES, weakIconView);
            else ((void (*)(id, SEL, BOOL))objc_msgSend)(manager, plain, YES);
        };
        SEL afterMenu = NSSelectorFromString(@"performAfterIconContextMenuDismissesUsingBlock:");
        if ([manager respondsToSelector:afterMenu]) ((void (*)(id, SEL, id))objc_msgSend)(manager, afterMenu, edit);
        else edit();
        return YES;
    }
    if ([what hasPrefix:@"change-widget-size-"]) {
        NSString *size = [what substringFromIndex:@"change-widget-size-".length];
        NSArray *known = @[ @"small", @"medium", @"large", @"extraLarge", @"extra-large" ];
        SEL resize = NSSelectorFromString(@"iconView:wantsResizeToGridSizeClass:completionHandler:");
        if (![known containsObject:size] || ![manager respondsToSelector:resize]) return NO;
        NSString *grid = WGGridClassForFamily(WGFamilyFromName([size isEqual:@"extra-large"] ? @"extraLarge" : size));
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(manager, resize, iconView, grid, ^{ WGSaveIconState(); });
        return YES;
    }
    if ([what isEqualToString:@"wg-edit-widget"]) {
        __weak UIView *weakIconView = iconView;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *v = weakIconView;
            if (v) WGEditWidget(v, WGCall(WGCall(v, @"icon"), @"activeWidget"));
        });
        return YES;
    }
    if ([what isEqualToString:@"configure-stack"]) { // SpringBoardHome's Edit Stack: our sheet
        __weak UIView *weakIconView = iconView;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *v = weakIconView;
            if (v) WGEditStack(v, WGCall(v, @"icon"));
        });
        return YES;
    }
    if ([what isEqualToString:@"remove-widget"] || [what isEqualToString:@"remove-stack"]) {
        UIViewController *home = iconView.window.rootViewController;
        if (!home) return NO;
        WGConfirmRemoval(home, WGCall(iconView, @"icon"));
        return YES;
    }
    return NO;
}

// NO tells SpringBoardHome it was handled (it would hand it to an app).
static BOOL hook_shouldActivate(id self, SEL _cmd, id iconView, id item, NSUInteger index) {
    NSString *type = WGCall(item, @"type");
    if (WGIsOurWidgetIcon(WGCall(iconView, @"icon")) && [type isKindOfClass:[NSString class]] && WGHandleShortcut(self, iconView, type)) {
        WGLog(@"Menu: %@", type);
        return NO;
    }
    return ((BOOL (*)(id, SEL, id, id, NSUInteger))orig_shouldActivate)(self, _cmd, iconView, item, index);
}

#pragma mark Hooks: the + menu

static IMP orig_addButtonMenu;

static UIMenu *hook_addButtonMenu(UIViewController *self, SEL _cmd) {
    gHome = self;
    UIMenu *menu = ((UIMenu * (*)(id, SEL)) orig_addButtonMenu)(self, _cmd);
    if (![menu isKindOfClass:[UIMenu class]]) return menu;
    __weak UIViewController *weakSelf = self;
    UIAction *add = [UIAction actionWithTitle:@"Add Widget" image:[UIImage systemImageNamed:@"square.grid.2x2"] identifier:nil
                                      handler:^(UIAction *a) {
        UIViewController *home = weakSelf;
        if (home) WGGalleryOpen(home);
    }];
    return [menu menuByReplacingChildren:[menu.children arrayByAddingObject:add]];
}

#pragma mark - Install

static void WGAddIfMissing(Class cls, NSString *selector, IMP imp, const char *types) {
    SEL sel = NSSelectorFromString(selector);
    if (cls && !class_getInstanceMethod(cls, sel)) class_addMethod(cls, sel, imp, types);
}

void WGHomeInstall(void) {
    WGGuardLaunch();
    WGAppearanceInstall();
    [WGExtensions all];

    WGHook(@"NXHomeScreenViewController", @"addButtonMenu", (IMP)hook_addButtonMenu, &orig_addButtonMenu);

    WGHook(@"SBHIconManager", @"customImageViewControllerForIconView:", (IMP)hook_customImageVC, &orig_customImageVC);
    WGHook(@"SBHIconManager", @"_makeCustomViewControllerForWidgetIcon:dataSource:location:", (IMP)hook_makeWidgetVC3, &orig_makeWidgetVC3);
    WGHook(@"SBHIconManager", @"_makeCustomViewControllerForWidgetIcon:dataSource:location:gridSizeClass:", (IMP)hook_makeWidgetVC4, &orig_makeWidgetVC4);

    WGHook(@"SBHIconManager", @"isWidgetValid:iconSizeClass:", (IMP)hook_isWidgetValid, &orig_isWidgetValid);
    WGHook(@"SBHIconManager", @"validatedWidgetIconForWidgetIcon:", (IMP)hook_validatedIcon, &orig_validatedIcon);
    WGHook(@"SBHIconManager", @"iconModel:validatedWidgetIconForWidgetIcon:", (IMP)hook_modelValidatedIcon, &orig_modelValidatedIcon);
    WGHook(@"SBHIconManager", @"supportedGridSizeClassesForWidgetWithKind:extensionBundleIdentifier:containerBundleIdentifier:",
           (IMP)hook_mgrSupported, &orig_mgrSupported);
    WGHook(@"SBHIconManager", @"iconModel:supportedGridSizeClassesForWidgetWithKind:extensionBundleIdentifier:containerBundleIdentifier:",
           (IMP)hook_mgrModelSupported, &orig_mgrModelSupported);
    WGHook(@"SBHIconModel", @"supportedGridSizeClassesForWidgetWithKind:extensionBundleIdentifier:containerBundleIdentifier:",
           (IMP)hook_modelSupported, &orig_modelSupported);
    WGHook(@"SBHIconModel", @"iconStateUnarchiver:supportedGridSizeClassesForWidgetWithKind:extensionBundleIdentifier:containerBundleIdentifier:",
           (IMP)hook_unarchiverSupported, &orig_unarchiverSupported);
    WGHook(@"SBHWidget", @"displayName", (IMP)hook_widgetDisplayName, &orig_widgetDisplayName);
    WGHook(@"SBHWidget", @"icon:displayNameForLocation:", (IMP)hook_widgetIconDisplayName, &orig_widgetIconDisplayName);

    WGHook(@"NXHomeScreenIconStateStore", @"loadCurrentIconState:", (IMP)hook_storeLoad, &orig_storeLoad);
    WGHook(@"SBHIconModel", @"iconStateUnarchiver:didUnarchiveWidgetIcon:", (IMP)hook_didUnarchive, &orig_didUnarchive);

    WGHook(@"SBHIconManager", @"iconView:applicationShortcutItemsWithProposedItems:", (IMP)hook_itemsWithProposed, &orig_itemsWithProposed);
    WGHook(@"SBHIconManager", @"iconView:shouldActivateApplicationShortcutItem:atIndex:", (IMP)hook_shouldActivate, &orig_shouldActivate);
    WGHook(@"SBHIconManager", @"supportedIconGridSizeClassesForResizeOfIconView:", (IMP)hook_resizeSizes, &orig_resizeSizes);

    WGHook(@"NXHomeScreenViewController", @"iconManager:iconViewDisplaysCloseBox:", (IMP)hook_displaysCloseBox, &orig_displaysCloseBox);
    WGHook(@"NXHomeScreenViewController", @"iconManager:closeBoxTypeForIconView:proposedType:", (IMP)hook_closeBoxType, &orig_closeBoxType);
    WGHook(@"NXHomeScreenViewController", @"iconManager:iconCloseBoxTapped:", (IMP)hook_closeBoxTapped, &orig_closeBoxTapped);
    WGHook(@"NXHomeScreenViewController", @"iconManager:wantsUninstallForIcon:location:", (IMP)hook_wantsUninstall, &orig_wantsUninstall);

    Class home = NSClassFromString(@"NXHomeScreenViewController");
    WGAddIfMissing(home, @"iconManager:isWidgetValid:", (IMP)WGDelegateIsWidgetValid, "B32@0:8@16@24");
    WGAddIfMissing(home, @"iconManager:widgetWantsLaunchForBundleIdentifier:withAction:", (IMP)WGDelegateWidgetLaunch, "v40@0:8@16@24@32");
    WGAddIfMissing(home, @"iconManager:iconView:widgetWantsLaunchForBundleIdentifier:withAction:", (IMP)WGDelegateWidgetLaunch2, "v48@0:8@16@24@32@40");
    WGAddIfMissing(home, @"iconManager:wantsLaunchForWidgetURL:", (IMP)WGDelegateWidgetURL, "v32@0:8@16@24");
}
