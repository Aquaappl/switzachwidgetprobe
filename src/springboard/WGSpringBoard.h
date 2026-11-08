// SpringBoard's side of SwitzachWidgetProbe. Nothing of an app's code runs here: SpringBoard
// finds the widget extensions, starts a widget host per extension and shows what the hosts draw.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "../common/WGShared.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Objective-C helpers

// Sends a message only when the object answers it.
FOUNDATION_EXPORT id _Nullable WGCall(id _Nullable obj, NSString *selector);
FOUNDATION_EXPORT id _Nullable WGCall1(id _Nullable obj, NSString *selector, id _Nullable arg);
FOUNDATION_EXPORT BOOL WGCallBool(id _Nullable obj, NSString *selector);
// For methods that return nothing (WGCall would take their garbage return register as an object).
FOUNDATION_EXPORT void WGSend1(id _Nullable obj, NSString *selector, id _Nullable arg);
// Replaces an instance method (added to the class first, so a superclass is not changed).
FOUNDATION_EXPORT BOOL WGHook(NSString *className, NSString *selector, IMP replacement, IMP _Nullable *_Nonnull original);

#pragma mark - Extensions (WGExtensions.m)

@interface WGExtensions : NSObject
// The widget extensions of the installed apps, by extension id. Answered from a saved list
// (the first time ever: found right away), refreshed in the background.
+ (NSDictionary<NSString *, WGExtension *> *)all;
+ (nullable WGExtension *)extensionWithID:(nullable NSString *)extensionID;
// Looks again (LaunchServices on the main thread, the bundles in the background).
+ (void)refresh:(nullable void (^)(void))completion;
// The app a URL opens (its scheme), among the apps with widgets.
+ (nullable WGExtension *)extensionForURL:(NSURL *)url;
@end

#pragma mark - Appearance (WGAppearance.m)

// The home screen's icon style, as the ROM applies it: NXIconStyle's style configuration and
// SpringBoardHome's SBHTraitIconTint trait (written into the windows' trait overrides).
typedef NS_ENUM(NSInteger, WGIconMode) {
    WGIconModeDefault, // colored icons: widgets in full color, light or dark with the system
    WGIconModeDark,    // dark icons: full color, dark
    WGIconModeClear,   // clear icons (Liquid Glass): accented, on clear glass
    WGIconModeTinted,  // tinted icons: accented, in the tint, on tinted glass
};

@interface WGAppearance : NSObject
@property (nonatomic, readonly) WGIconMode mode;
@property (nonatomic, readonly) BOOL darkGlass;                 // clear / tinted: the glass's dark variant
@property (nonatomic, readonly, nullable) UIColor *tint;        // tinted: the tint (sRGB)
@property (nonatomic, readonly) UIUserInterfaceStyle scheme;    // the widget's own light / dark
@property (nonatomic, readonly) BOOL accented;                  // WidgetKit's accented rendering mode
@property (nonatomic, readonly, nullable) NSArray<NSNumber *> *colorMatrix; // drawn in these colors (4×5)
@property (nonatomic, readonly) NSString *key;                  // equal keys look the same
+ (instancetype)appearanceForTraits:(nullable UITraitCollection *)traits;
@end

// Posted (main thread) when the icon style may have changed.
FOUNDATION_EXPORT NSNotificationName const WGAppearanceDidChangeNotification;
FOUNDATION_EXPORT void WGAppearanceInstall(void);
// Calls action on the controller when the style or light / dark changes.
FOUNDATION_EXPORT void WGAppearanceObserve(UIViewController *controller, SEL action);

// What is behind a widget: nothing for colored icons, glass for clear and tinted ones.
@interface WGBackdropView : UIView
- (void)applyAppearance:(WGAppearance *)appearance cornerRadius:(CGFloat)radius;
@end

#pragma mark - Widget hosts (WGHostConnection.m)

@interface WGHost : NSObject
+ (instancetype)hostForExtension:(WGExtension *)extension;
@property (nonatomic, readonly) WGExtension *extension;
// The host's widgets ({kind, name?, description?, families?}); nil until it listed them.
@property (nonatomic, readonly, nullable) NSArray<NSDictionary *> *widgets;
@property (nonatomic, readonly) BOOL blocked;   // Nyxian's filesystem sandbox keeps it from its files
@property (nonatomic, readonly) BOOL disabled;  // it kept crashing: not started again
// Starts the host if needed and asks for its widgets; completion on the main thread.
- (void)loadWidgets:(nullable void (^)(void))completion;

+ (NSInteger)newViewID;
// events gets the host's messages for the view: context / drawn / failed, and {op: lost} when
// the host ended (it is started and the view shown again by itself).
- (void)showView:(NSInteger)viewID request:(NSDictionary *)request events:(void (^)(NSDictionary *message))events;
- (void)setView:(NSInteger)viewID visible:(BOOL)visible;
- (void)hideView:(NSInteger)viewID;
// A view whose controller went away is kept for a few seconds under a key (kind and size):
// SpringBoardHome makes a new icon view after a drag or in edit mode, and the new controller
// takes over what is already drawn instead of starting from "Loading…".
- (void)parkView:(NSInteger)viewID key:(NSString *)key;
// {view, request, context?, drawn} of a parked view with that key (it is the caller's now), or nil.
- (nullable NSDictionary *)adoptViewWithKey:(NSString *)key events:(void (^)(NSDictionary *message))events;
// result: button | link (the widget took the tap), none, app (an action iOS runs in the app),
// failed (no answer).
- (void)tapView:(NSInteger)viewID point:(CGPoint)point result:(void (^)(NSString *result, NSDictionary *message))result;

// A question to the host ({op, …}); reply gets its answer ({op: reply, …}), or nil when there
// was none in time. Main thread.
- (void)request:(NSDictionary *)message timeout:(NSTimeInterval)timeout reply:(void (^)(NSDictionary *_Nullable reply))reply;

+ (void)diagnosticLogChanged;
// Every host is started again (also those stopped after crashing) and redraws its widgets.
+ (void)restartAll;
@end

#pragma mark - Opening apps (WGActions.m)

FOUNDATION_EXPORT void WGLaunchApp(NSString *bundleID);
// A widget's link: left for the app (SwitzachWidgetLinks hands it over) and the app opened.
FOUNDATION_EXPORT void WGOpenWidgetURL(NSURL *url, WGExtension *source);

#pragma mark - Home screen (WGHome.m)

FOUNDATION_EXPORT void WGHomeInstall(void);
FOUNDATION_EXPORT void WGWidgetViewsInstall(void); // SpringBoardHome's widget containers with ours
FOUNDATION_EXPORT BOOL WGHomeDrawingStopped(void); // the launch guard tripped
FOUNDATION_EXPORT id _Nullable WGIconManager(void);  // SBHIconManager
FOUNDATION_EXPORT BOOL WGIsEditing(void);
FOUNDATION_EXPORT BOOL WGIsOurWidgetIcon(id _Nullable icon);
FOUNDATION_EXPORT NSArray *WGIconWidgets(id _Nullable icon);
FOUNDATION_EXPORT NSString *_Nullable WGGridClassForFamily(WGFamily family);
FOUNDATION_EXPORT WGFamily WGFamilyForGridClass(NSString *_Nullable gridClass);
// Inserts a widget at the top of the current page. nil, or why it could not.
FOUNDATION_EXPORT NSString *_Nullable WGInsertWidget(WGExtension *extension, NSString *kind, WGFamily family);
FOUNDATION_EXPORT void WGSaveIconState(void);

#pragma mark - Edit Stack (WGStackEditor.m)

// Our sheet: the stack's widgets, to reorder or remove.
FOUNDATION_EXPORT void WGEditStack(UIView *iconView, id icon);
// The stack's widgets become these, in this order (removed ones are left out).
FOUNDATION_EXPORT void WGApplyStackOrder(id icon, NSArray *widgets);

#pragma mark - Edit Widget (WGWidgetEditor.m)

// The widget's settings (a SiriKit intent's parameters), as iOS shows them on its back.
FOUNDATION_EXPORT BOOL WGWidgetIsEditable(id _Nullable widget);
FOUNDATION_EXPORT void WGEditWidget(UIView *iconView, id widget);
// The key under which a widget's configuration is kept: its unique identifier.
FOUNDATION_EXPORT NSString *_Nullable WGWidgetConfigKey(id _Nullable widget);

// A widget's size and corner radius on the home screen (SpringBoardHome's layout).
typedef struct { CGSize size; double scale; double continuousCornerRadius; } WGIconImageInfo;
FOUNDATION_EXPORT WGIconImageInfo WGImageInfoForFamily(WGFamily family);

#pragma mark - Widget views (WGWidgetViews.m)

FOUNDATION_EXPORT NSString *const WGFilesystemSandboxMessage;
FOUNDATION_EXPORT NSString *const WGFilesystemSandboxHint;

@interface WGWidgetViewController : UIViewController
- (instancetype)initWithExtension:(WGExtension *)extension kind:(NSString *)kind family:(WGFamily)family;
@property (nonatomic, readonly) WGExtension *extension;
@property (nonatomic, readonly) NSString *kind;
@property (nonatomic) WGFamily family;
@property (nonatomic) BOOL preview;    // in the gallery: drawn only
@property (nonatomic) BOOL inStack;    // the stack draws the glass behind its pages
// The widget's own configuration (Edit Widget): its SBHWidget's unique identifier.
@property (nonatomic, copy, nullable) NSString *configKey;
- (void)setImageInfo:(WGIconImageInfo)info;
- (void)tapAtPoint:(CGPoint)point;
@end

@interface WGStackViewController : UIViewController
- (instancetype)initWithIcon:(id)icon iconView:(id)iconView;
@end

// SpringBoardHome calls methods of SBIconViewCustomImageViewControlling (and of its own widget
// view controllers) without asking first: our controllers answer the others with zero.
FOUNDATION_EXPORT NSMethodSignature *_Nullable WGFallbackSignature(SEL selector);
FOUNDATION_EXPORT void WGForwardAsZero(NSInvocation *invocation, UIViewController *controller, CGSize imageSize);

#pragma mark - Gallery (WGGallery.m)

FOUNDATION_EXPORT void WGGalleryOpen(UIViewController *home);
FOUNDATION_EXPORT UIImage *WGAppIcon(WGExtension *extension);

#pragma mark - Settings (WGSettings.m)

FOUNDATION_EXPORT void WGSettingsInstall(void);

NS_ASSUME_NONNULL_END
