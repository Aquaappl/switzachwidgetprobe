#import <UIKit/UIKit.h>
#import "WPProbe.h"

NS_ASSUME_NONNULL_BEGIN

// SpringBoard's side of the widget host processes (WPHost.m): one host per widget extension,
// started when its widgets are first needed and started again after it ends. Everything here
// runs on the main thread.
@interface WPRemote : NSObject

// Asks the extension's host for its widgets ({kind, name?, description?, families?, …});
// completion runs once they are known (right away if they were).
+ (void)prepareExtension:(WPWidgetExtension *)extension completion:(nullable void (^)(void))completion;
// The widgets, if the host has listed them already (nothing is started for it here).
+ (nullable NSArray<NSDictionary *> *)loadedWidgetsForExtension:(WPWidgetExtension *)extension;
+ (NSArray<NSDictionary *> *)widgetsForExtension:(WPWidgetExtension *)extension;

// A view is one widget drawn by the host into a context of its own. events receives the host's
// messages for it: {"op":"context","id":…} (show it with a CALayerHost), {"op":"drawn"},
// {"op":"failed","reason":…}, and {"op":"lost"} when the host ended (it is started again and
// the view drawn again by itself). accented: the home screen's icons are clear or tinted, so
// the widget is drawn as iOS draws it then (WidgetKit's accented rendering mode, without its
// container background). tint: [r, g, b] (0–1) for tinted icons: the widget is drawn in that
// color, from its brightness.
+ (NSInteger)newViewID;
+ (void)showView:(NSInteger)viewID extension:(WPWidgetExtension *)extension kind:(NSString *)kind family:(int)family size:(CGSize)size
            dark:(BOOL)dark accented:(BOOL)accented tint:(nullable NSArray<NSNumber *> *)tint events:(void (^)(NSDictionary *message))events;
+ (void)hideView:(NSInteger)viewID extension:(WPWidgetExtension *)extension;
// A tap in the view's points. result: "button" or "link" (the widget took it), "none" (no
// control there), "app" (an action iOS performs inside the app), or "failed" (no answer).
+ (void)tapView:(NSInteger)viewID extension:(WPWidgetExtension *)extension point:(CGPoint)point
         result:(void (^)(NSString *result, NSDictionary *message))result;

// A widget's link: SpringBoard opens the URL (set by WPHome).
+ (void)setOpenURLHandler:(void (^)(NSURL *url, WPWidgetExtension *extension))handler;
+ (void)setLogger:(void (^)(NSString *line))logger;
// The diagnostic log setting changed: hosts follow it.
+ (void)diagnosticLogChanged;

@end

NS_ASSUME_NONNULL_END
