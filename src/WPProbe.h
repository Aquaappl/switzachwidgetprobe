#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// One widget extension found inside an app installed in the ROM (a sideloaded app).
@interface WPWidgetExtension : NSObject
@property (nonatomic, copy) NSString *appName;
@property (nonatomic, copy) NSString *appBundleID;
@property (nonatomic, copy) NSString *appPath;
@property (nonatomic, copy) NSString *extensionPath;
@property (nonatomic, copy) NSString *extensionBundleID;
@property (nonatomic, copy) NSString *executablePath;
@property (nonatomic, copy, nullable) NSString *dataContainerPath; // the app's data container
@end

@interface WPProbe : NSObject
// Lists apps known to the ROM and the widget extensions inside them. The log
// receives a line per app/extension that was inspected.
+ (NSArray<WPWidgetExtension *> *)findWidgetExtensionsWithLog:(NSMutableString *)log;

+ (NSString *)workDirectory;
+ (NSString *)reportPath;
@end

// Used by the home screen: load an extension once and render its widgets.
@interface WPProbe (Runtime)
+ (NSString *)runtimeLogPath;
// { kind, name?, description?, families? ("small"/"medium"/"large"), intent, box } for each widget the extension declares.
+ (NSArray<NSDictionary *> *)widgetsForExtension:(WPWidgetExtension *)extension;
// Loads the extension's code in the background, then reads its widgets on the main thread;
// completion runs on the main thread (right away if that was done before).
+ (void)prepareExtension:(WPWidgetExtension *)extension completion:(nullable void (^)(void))completion;
// The same, only if the extension is already loaded (nothing is run for it here).
+ (nullable NSArray<NSDictionary *> *)loadedWidgetsForExtension:(WPWidgetExtension *)extension;
// Draws the widget with the app's own view code. update is called on the main queue: first
// with the placeholder (final = NO; only when placeholder is YES), then with the current
// timeline entry (final = YES; a nil controller means keep what is shown).
// family: 0 small, 1 medium, 2 large.
+ (void)renderWidgetKind:(NSString *)kind extension:(WPWidgetExtension *)extension family:(int)family size:(CGSize)size
             placeholder:(BOOL)placeholder
                  update:(void (^)(UIViewController *_Nullable controller, NSDate *_Nullable nextRefresh, BOOL final))update;
// Crash, exception and main-thread stall reports go to runtime.txt from now on (always,
// whether or not the diagnostic log is on).
+ (void)installRuntimeCrashLog;
// Reports where the main thread is when it stalls (started with the diagnostic log).
+ (void)startStallWatchdog;
// Non-nil (a short description) when iOS would perform this widget's button intents in the
// app's own process rather than the widget extension's.
+ (nullable NSString *)appProcessIntentsForExtension:(WPWidgetExtension *)extension;
@end

// Crash markers in the work directory: "<name>.running" while something risky runs (it holds
// this SpringBoard's process id), "<name>.bad" once it took SpringBoard down. A .running
// marker only counts as a crash when an earlier SpringBoard left it behind.
FOUNDATION_EXPORT BOOL WPMarkerTripped(NSString *name); // crashed before (turns a stale .running into .bad)
FOUNDATION_EXPORT void WPMarkerBegin(NSString *name);
FOUNDATION_EXPORT void WPMarkerEnd(NSString *name);

// Written before each log line (a widget host process names itself this way).
FOUNDATION_EXPORT void WPSetLogTag(NSString *tag);

NS_ASSUME_NONNULL_END
