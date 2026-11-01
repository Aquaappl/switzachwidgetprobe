// SwitzachWidgetProbe settings, as set in TweakSettings (or Settings) through the
// SwitzachWidgetProbe preference bundle (prefs/).
//
//   DiagnosticLog  (bool, default off)  a detailed log in runtime.txt / report.txt
//   ResetRequest   (date as seconds)     "Reset Widget Safety Guards" was tapped at that time
//
// The values are read with CFPreferences and, as the settings app may keep its own copy of
// the domain in its data container (a sandboxed app), from those plist files too; the newest
// wins. The settings app posts a Darwin notification on each change; SpringBoard also looks
// again every few seconds (a file date check) in case notifications do not cross processes.

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import "WPProbe.h"
#import "WPRemote.h"

static NSString *const kWPDomain = @"com.rinapple.switzachwidgetprobe";
static NSString *const kWPChanged = @"com.rinapple.switzachwidgetprobe/settings";

static BOOL gWPDiagnosticLog;

BOOL WPDiagnosticLogEnabled(void) {
    return gWPDiagnosticLog;
}

// Deletes the crash markers (.bad / .running) so stopped buttons, settings and data fetches
// are tried again. Intents-extension defaults stay off: loading a second copy of an app's code
// (e.g. its own Firebase) in the same process cannot work.
NSUInteger WPResetSafetyRecords(void) {
    NSString *dir = [WPProbe workDirectory];
    NSUInteger removed = 0;
    for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil]) {
        if (([f hasSuffix:@".bad"] || [f hasSuffix:@".running"]) && ![f hasPrefix:@"intent-defaults-"]) {
            if ([[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:f] error:nil]) removed++;
        }
    }
    return removed;
}

// The plist files that may hold the domain: SpringBoard's own preferences, and the data
// containers of the apps that show preference bundles.
static NSArray<NSString *> *WPSettingsFiles(void) {
    static NSArray *files;
    if (files) return files;
    NSString *name = [kWPDomain stringByAppendingPathExtension:@"plist"];
    NSMutableArray *list = [NSMutableArray arrayWithObject:
                            [NSHomeDirectory() stringByAppendingPathComponent:[@"Library/Preferences" stringByAppendingPathComponent:name]]];
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL forID = NSSelectorFromString(@"applicationProxyForIdentifier:");
    for (NSString *app in @[ @"com.creaturecoding.tweaksettings", @"com.apple.Preferences" ]) {
        id proxy = [proxyClass respondsToSelector:forID] ? ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, forID, app) : nil;
        NSURL *data = nil;
        @try { data = [proxy valueForKey:@"dataContainerURL"]; } @catch (NSException *e) {}
        if ([data isKindOfClass:[NSURL class]] && data.path.length && ![data.path isEqualToString:NSHomeDirectory()])
            [list addObject:[data.path stringByAppendingPathComponent:[@"Library/Preferences" stringByAppendingPathComponent:name]]];
    }
    files = list;
    return files;
}

static NSDictionary *WPReadSettings(NSDate **newestOut) {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    CFPreferencesAppSynchronize((__bridge CFStringRef)kWPDomain);
    for (NSString *key in @[ @"DiagnosticLog", @"ResetRequest" ]) {
        id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kWPDomain));
        if (v) values[key] = v;
    }
    NSDate *newest = nil;
    NSDictionary *newestFile = nil;
    for (NSString *path in WPSettingsFiles()) {
        NSDate *date = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil][NSFileModificationDate];
        if (!date || (newest && [date compare:newest] != NSOrderedDescending)) continue;
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        if (!d) continue;
        newest = date;
        newestFile = d;
    }
    if (newestFile) [values addEntriesFromDictionary:newestFile];
    if (newestOut) *newestOut = newest;
    return values;
}

static NSString *WPHandledResetPath(void) {
    return [[WPProbe workDirectory] stringByAppendingPathComponent:@"reset-handled"];
}

static void WPApplySettings(void) {
    NSDictionary *values = WPReadSettings(NULL);
    BOOL log = [values[@"DiagnosticLog"] boolValue];
    if (log != gWPDiagnosticLog) {
        gWPDiagnosticLog = log;
        if (log) [WPProbe startStallWatchdog];
        [WPRemote diagnosticLogChanged];
        NSLog(@"[WidgetProbe] diagnostic log %@", log ? @"on" : @"off");
    }
    double request = [values[@"ResetRequest"] doubleValue];
    double handled = [[NSString stringWithContentsOfFile:WPHandledResetPath() encoding:NSUTF8StringEncoding error:nil] doubleValue];
    if (request > handled) {
        [[NSString stringWithFormat:@"%.3f", request] writeToFile:WPHandledResetPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSUInteger removed = WPResetSafetyRecords();
        NSLog(@"[WidgetProbe] safety guards reset from settings (%lu record(s))", (unsigned long)removed);
    }
}

static void WPSettingsChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object,
                              CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ WPApplySettings(); });
}

void WPSettingsInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        WPApplySettings();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, WPSettingsChanged,
                                        (__bridge CFStringRef)kWPChanged, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        // In case the notification does not reach SpringBoard: the files' dates, every 5 s.
        __block NSDate *last = nil;
        WPReadSettings(&last);
        static dispatch_source_t timer; // lives as long as SpringBoard
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{
            NSDate *newest = nil;
            for (NSString *path in WPSettingsFiles()) {
                NSDate *d = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil][NSFileModificationDate];
                if (d && (!newest || [d compare:newest] == NSOrderedDescending)) newest = d;
            }
            if (newest && (!last || [newest compare:last] == NSOrderedDescending)) {
                last = newest;
                WPApplySettings();
            }
        });
        dispatch_resume(timer);
    });
}
