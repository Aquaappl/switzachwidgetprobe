// Shared by SpringBoard (SwitzachWidgetProbe.dylib) and the widget hosts (SwitzachWidgetHost).
//
// What both sides agree on: where files live, the model of a widget extension, how messages
// are framed on the pipes, logging and crash markers.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

#ifndef WG_VERSION
#define WG_VERSION "dev"
#endif

FOUNDATION_EXPORT NSString *const WGSettingsDomain;        // com.rinapple.switzachwidgetprobe
FOUNDATION_EXPORT NSString *const WGSettingsChanged;       // Darwin notification posted by the settings page
FOUNDATION_EXPORT NSString *const WGHostBundleIdentifier;  // the widget host app

#pragma mark - Files

// $HOME/Library/Caches/SwitzachWidgetProbe (SpringBoard's home; the hosts inherit it). Made on
// first use.
FOUNDATION_EXPORT NSString *WGWorkDirectory(void);
FOUNDATION_EXPORT NSString *WGWorkPath(NSString *name);

#pragma mark - A widget extension

// One WidgetKit extension inside an app installed in the ROM. Found by SpringBoard
// (LaunchServices); the host gets it on its command line (it cannot ask LaunchServices).
@interface WGExtension : NSObject
@property (nonatomic, copy) NSString *extensionID;
@property (nonatomic, copy) NSString *appID;
@property (nonatomic, copy) NSString *appName;
@property (nonatomic, copy) NSString *appPath;
@property (nonatomic, copy) NSString *extensionPath;
@property (nonatomic, copy) NSString *executablePath;
@property (nonatomic, copy, nullable) NSString *dataPath; // the app's data container
@property (nonatomic, copy) NSArray<NSString *> *urlSchemes; // the app's, lowercased

- (NSDictionary *)plist;
+ (nullable instancetype)extensionWithPlist:(NSDictionary *)plist;
- (NSArray<NSString *> *)arguments;
+ (nullable instancetype)extensionWithArguments:(NSArray<NSString *> *)arguments;
// Size and date of the extension's executable: a new build of the app changes it.
- (NSString *)buildStamp;
@end

#pragma mark - Messages

// One JSON object per line, both ways.
FOUNDATION_EXPORT NSData *_Nullable WGEncodeMessage(NSDictionary *message);

// Splits a byte stream into messages.
@interface WGLineReader : NSObject
- (void)appendBytes:(const void *)bytes length:(size_t)length handler:(void (NS_NOESCAPE ^)(NSDictionary *message))handler;
@end

// Message keys (requests to the host, answers and events from it). See WGHostMain.m.
#define WGOp @"op"
#define WGView @"view"

// Widget families, as WidgetKit numbers them for the home screen.
typedef NS_ENUM(int, WGFamily) { WGFamilySmall = 0, WGFamilyMedium = 1, WGFamilyLarge = 2, WGFamilyExtraLarge = 3 };
FOUNDATION_EXPORT NSString *WGFamilyName(WGFamily family);   // "small" / "medium" / "large" / "extraLarge"
FOUNDATION_EXPORT WGFamily WGFamilyFromName(NSString *_Nullable name);

#pragma mark - Logging

// The diagnostic log (off by default) goes to runtime.txt. Lines are written on a background
// queue: logging never blocks the caller. WGLogImportant lines are written even with the log
// off (crashes, a host that keeps ending).
FOUNDATION_EXPORT void WGLogSetEnabled(BOOL enabled);
FOUNDATION_EXPORT BOOL WGLogEnabled(void);
FOUNDATION_EXPORT void WGLogSetTag(NSString *tag);
FOUNDATION_EXPORT void WGLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
FOUNDATION_EXPORT void WGLogImportant(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
FOUNDATION_EXPORT NSString *WGLogPath(void);
// runtime.txt past 1 MB moves to runtime-old.txt (SpringBoard, at launch).
FOUNDATION_EXPORT void WGLogRotate(void);

#pragma mark - Crash markers

// "<name>.running" holds the process id while something risky runs; a later process that
// finds one left by another process knows that step crashed and turns it into "<name>.bad".
FOUNDATION_EXPORT BOOL WGMarkerTripped(NSString *name);
FOUNDATION_EXPORT void WGMarkerBegin(NSString *name);
FOUNDATION_EXPORT void WGMarkerEnd(NSString *name);
// Removes the markers (except the Intents-extension ones). Returns how many.
FOUNDATION_EXPORT NSUInteger WGMarkersReset(void);

NS_ASSUME_NONNULL_END
