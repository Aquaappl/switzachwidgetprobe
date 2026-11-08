// The settings, as set on the SwitzachWidgetProbe page (TweakSettings or Settings, prefs/).
//
//   DiagnosticLog   bool, off   a detailed log in runtime.txt (SpringBoard and the hosts)
//   RestartRequest  seconds     "Restart Widgets" was tapped at that time
//   ResetRequest    seconds     "Reset Widget Safety Guards" was tapped at that time
//
// A settings app may keep its own copy of the domain in its data container, so the values are
// read with CFPreferences and from those files too; the newest wins. The page posts a Darwin
// notification on each change; in case that does not reach SpringBoard, the files' dates are
// looked at every 10 seconds (a stat, nothing more).

#import "WGSpringBoard.h"
#import <sys/stat.h>

static NSArray<NSString *> *WGSettingsFiles(void) {
    static NSArray *files;
    if (files) return files;
    NSString *name = [@"Library/Preferences" stringByAppendingPathComponent:[WGSettingsDomain stringByAppendingPathExtension:@"plist"]];
    NSMutableArray *list = [NSMutableArray arrayWithObject:[NSHomeDirectory() stringByAppendingPathComponent:name]];
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    for (NSString *app in @[ @"com.creaturecoding.tweaksettings", @"com.apple.Preferences" ]) {
        id proxy = WGCall1(proxyClass, @"applicationProxyForIdentifier:", app);
        NSURL *data = nil;
        @try { data = [proxy valueForKey:@"dataContainerURL"]; } @catch (NSException *e) {}
        if ([data isKindOfClass:[NSURL class]] && data.path.length && ![data.path isEqualToString:NSHomeDirectory()]) {
            [list addObject:[data.path stringByAppendingPathComponent:name]];
        }
    }
    files = list;
    return files;
}

static NSTimeInterval WGNewestSettingsDate(NSString **pathOut) {
    NSTimeInterval newest = 0;
    for (NSString *path in WGSettingsFiles()) {
        struct stat st;
        if (stat(path.fileSystemRepresentation, &st) != 0) continue;
        NSTimeInterval t = st.st_mtimespec.tv_sec + st.st_mtimespec.tv_nsec / 1e9;
        if (t <= newest) continue;
        newest = t;
        if (pathOut) *pathOut = path;
    }
    return newest;
}

static NSDictionary *WGReadSettings(void) {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    CFPreferencesAppSynchronize((__bridge CFStringRef)WGSettingsDomain);
    for (NSString *key in @[ @"DiagnosticLog", @"RestartRequest", @"ResetRequest" ]) {
        id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)WGSettingsDomain));
        if (v) values[key] = v;
    }
    NSString *path = nil;
    WGNewestSettingsDate(&path);
    NSDictionary *file = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    if (file) [values addEntriesFromDictionary:file];
    return values;
}

// A button's request not yet acted on (the time it was tapped, against the last one handled).
static BOOL WGNewRequest(NSDictionary *values, NSString *key, NSString *handledFile) {
    double request = [values[key] doubleValue];
    NSString *path = WGWorkPath(handledFile);
    double handled = [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] doubleValue];
    if (request <= handled) return NO;
    [[NSString stringWithFormat:@"%.3f", request] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return YES;
}

static void WGApplySettings(void) {
    NSDictionary *values = WGReadSettings();
    BOOL log = [values[@"DiagnosticLog"] boolValue];
    if (log != WGLogEnabled()) {
        WGLogSetEnabled(log);
        [WGHost diagnosticLogChanged];
        WGLogImportant(@"Diagnostic log %@", log ? @"on" : @"off");
    }
    if (WGNewRequest(values, @"ResetRequest", @"reset-handled")) {
        WGLogImportant(@"Safety guards reset (%lu record(s))", (unsigned long)WGMarkersReset());
        [WGHost restartAll]; // hosts stopped after crashing start again
    } else if (WGNewRequest(values, @"RestartRequest", @"restart-handled")) {
        WGLogImportant(@"Widgets restarted");
        [WGHost restartAll];
    }
}

static void WGSettingsChangedCallback(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ WGApplySettings(); });
}

void WGSettingsInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        WGApplySettings();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, WGSettingsChangedCallback, (__bridge CFStringRef)WGSettingsChanged,
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        __block NSTimeInterval last = WGNewestSettingsDate(NULL);
        static dispatch_source_t timer; // as long as SpringBoard runs
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC, 3 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{
            NSTimeInterval newest = WGNewestSettingsDate(NULL);
            if (newest <= last) return;
            last = newest;
            dispatch_async(dispatch_get_main_queue(), ^{ WGApplySettings(); });
        });
        dispatch_resume(timer);
    });
}
