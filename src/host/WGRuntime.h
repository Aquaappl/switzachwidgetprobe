// The widget host's runtime: loads one app's WidgetKit extension into this process and calls
// its own Swift code the way WidgetKit does on iOS (WGRuntime.m). Host only — never in
// SpringBoard.

#import <UIKit/UIKit.h>
#import "../common/WGShared.h"

NS_ASSUME_NONNULL_BEGIN

// Posted (main thread, object = nil) when the app wrote its shared data: the widgets should
// fetch their timelines again (iOS: WidgetCenter.reloadTimelines).
FOUNDATION_EXPORT NSNotificationName const WGRuntimeDataChangedNotification;

// How a widget is drawn (WidgetKit's rendering modes on the home screen).
typedef NS_ENUM(NSInteger, WGRenderMode) {
    WGRenderModeFullColor = 0, // the widget's own colors and container background
    WGRenderModeAccented = 1,  // clear / tinted icons: \.widgetRenderingMode = .accented, no container background
};

// Called on the main thread. controller nil: keep what is shown. final NO: a placeholder.
typedef void (^WGRenderUpdate)(UIViewController *_Nullable controller, NSDate *_Nullable nextRefresh, BOOL final);

@interface WGRuntime : NSObject

// Copying, signing and loading the extension (background), then reading its widgets (main
// thread: a WidgetBundle's body is main-actor isolated). completion runs on the main thread.
+ (void)loadExtension:(WGExtension *)extension completion:(void (^)(NSArray<NSDictionary *> *widgets, NSString *_Nullable problem))completion;

// The widgets read by loadExtension: {kind, name?, description?, families?: ["small", …]}.
+ (NSArray<NSDictionary *> *)widgets;

// Draws a widget with the app's own code: placeholder(in:) first when asked, then the
// timeline entry for now.
// config: the widget's own configuration (Edit Widget), nil for the kind's defaults.
+ (void)renderKind:(NSString *)kind config:(nullable NSString *)config family:(WGFamily)family size:(CGSize)size placeholder:(BOOL)placeholder
              mode:(WGRenderMode)mode update:(WGRenderUpdate)update;


// The extension's button intents by where iOS runs them: opensApp (the app opens and runs it),
// inAppBackground (the app's process, without opening it), here (the extension's process);
// foregroundContinuable: those of them that may ask to continue in the app.
+ (NSDictionary<NSString *, NSArray<NSString *> *> *)intentPlacement;

// Signals and uncaught exceptions are written to runtime.txt.
+ (void)installCrashLog;

@end

@interface WGRuntime (EditWidget)

// Edit Widget, for a widget configured with a SiriKit intent. reply: {params: [{name, title,
// kind (enum, bool, string, object, objects, other), value, values?}]} or {error}.
+ (void)parametersForKind:(NSString *)kind config:(NSString *)config reply:(void (^)(NSDictionary *answer))reply;
// The choices for a parameter: {options: [{title, subtitle?}]} (kept for setParameter) or {error}.
+ (void)optionsForKind:(NSString *)kind config:(NSString *)config parameter:(NSString *)name reply:(void (^)(NSDictionary *answer))reply;
// value: {index} (of the last options, or of an enum's values), {indexes} (several), {bool},
// {string}. Saved for this configuration. nil, or what went wrong.
+ (nullable NSString *)setParameter:(NSString *)name kind:(NSString *)kind config:(NSString *)config value:(NSDictionary *)value;

@end

NS_ASSUME_NONNULL_END
