#import "WGShared.h"
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

NSString *const WGSettingsDomain = @"com.rinapple.switzachwidgetprobe";
NSString *const WGSettingsChanged = @"com.rinapple.switzachwidgetprobe/settings";
NSString *const WGHostBundleIdentifier = @"com.rinapple.switzachwidgetprobe.host";

#pragma mark - Files

NSString *WGWorkDirectory(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *home = getenv("HOME");
        NSString *base = home && home[0] ? @(home) : NSHomeDirectory();
        dir = [base stringByAppendingPathComponent:@"Library/Caches/SwitzachWidgetProbe"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return dir;
}

NSString *WGWorkPath(NSString *name) {
    return [WGWorkDirectory() stringByAppendingPathComponent:name];
}

#pragma mark - A widget extension

@implementation WGExtension

- (NSDictionary *)plist {
    NSMutableDictionary *d = [@{ @"extensionID" : self.extensionID ?: @"", @"appID" : self.appID ?: @"", @"appName" : self.appName ?: @"",
                                 @"appPath" : self.appPath ?: @"", @"extensionPath" : self.extensionPath ?: @"",
                                 @"executablePath" : self.executablePath ?: @"", @"urlSchemes" : self.urlSchemes ?: @[] } mutableCopy];
    if (self.dataPath) d[@"dataPath"] = self.dataPath;
    return d;
}

static NSString *WGString(id v) {
    return [v isKindOfClass:[NSString class]] && [v length] ? v : nil;
}

+ (instancetype)extensionWithPlist:(NSDictionary *)d {
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    WGExtension *e = [self new];
    e.extensionID = WGString(d[@"extensionID"]);
    e.appID = WGString(d[@"appID"]);
    e.appName = WGString(d[@"appName"]) ?: e.appID;
    e.appPath = WGString(d[@"appPath"]);
    e.extensionPath = WGString(d[@"extensionPath"]);
    e.executablePath = WGString(d[@"executablePath"]);
    e.dataPath = WGString(d[@"dataPath"]);
    NSArray *schemes = [d[@"urlSchemes"] isKindOfClass:[NSArray class]] ? d[@"urlSchemes"] : @[];
    e.urlSchemes = [schemes filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id s, NSDictionary *b) {
        return [s isKindOfClass:[NSString class]];
    }]];
    if (!e.extensionID || !e.appID || !e.appPath || !e.extensionPath || !e.executablePath) return nil;
    return e;
}

- (NSArray<NSString *> *)arguments {
    return @[ self.extensionID ?: @"", self.appID ?: @"", self.appName ?: @"", self.appPath ?: @"", self.extensionPath ?: @"",
              self.executablePath ?: @"", self.dataPath ?: @"" ];
}

+ (instancetype)extensionWithArguments:(NSArray<NSString *> *)a {
    if (a.count < 7) return nil;
    return [self extensionWithPlist:@{ @"extensionID" : a[0], @"appID" : a[1], @"appName" : a[2], @"appPath" : a[3], @"extensionPath" : a[4],
                                       @"executablePath" : a[5], @"dataPath" : a[6] }];
}

- (NSString *)buildStamp {
    struct stat st;
    if (stat(self.executablePath.fileSystemRepresentation, &st) != 0) return @"missing";
    return [NSString stringWithFormat:@"%lld|%ld.%09ld", (long long)st.st_size, (long)st.st_mtimespec.tv_sec, (long)st.st_mtimespec.tv_nsec];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %@>", self.appName, self.extensionID];
}

@end

#pragma mark - Messages

NSData *WGEncodeMessage(NSDictionary *message) {
    if (![NSJSONSerialization isValidJSONObject:message]) return nil;
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:message options:0 error:nil] mutableCopy];
    [data appendBytes:"\n" length:1];
    return data;
}

@implementation WGLineReader {
    NSMutableData *_pending;
}

- (void)appendBytes:(const void *)bytes length:(size_t)length handler:(void (NS_NOESCAPE ^)(NSDictionary *))handler {
    if (!_pending) _pending = [NSMutableData data];
    [_pending appendBytes:bytes length:length];
    // A runaway line (no newline in 4 MB) is dropped rather than kept growing.
    if (_pending.length > 4 * 1024 * 1024 && !memchr(_pending.bytes, '\n', _pending.length)) _pending.length = 0;
    size_t start = 0;
    const uint8_t *p = _pending.bytes;
    size_t total = _pending.length;
    while (start < total) {
        const uint8_t *nl = memchr(p + start, '\n', total - start);
        if (!nl) break;
        size_t len = (size_t)(nl - (p + start));
        if (len) {
            NSData *line = [NSData dataWithBytesNoCopy:(void *)(p + start) length:len freeWhenDone:NO];
            id m = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
            if ([m isKindOfClass:[NSDictionary class]]) handler(m);
        }
        start += len + 1;
    }
    if (start) [_pending replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
}

@end

NSString *WGFamilyName(WGFamily family) {
    switch (family) {
        case WGFamilySmall: return @"small";
        case WGFamilyMedium: return @"medium";
        case WGFamilyLarge: return @"large";
        case WGFamilyExtraLarge: return @"extraLarge";
    }
    return @"medium";
}

WGFamily WGFamilyFromName(NSString *name) {
    if ([name isEqualToString:@"small"]) return WGFamilySmall;
    if ([name isEqualToString:@"large"]) return WGFamilyLarge;
    if ([name isEqualToString:@"extraLarge"]) return WGFamilyExtraLarge;
    return WGFamilyMedium;
}

#pragma mark - Logging

static BOOL gWGLogEnabled;
static NSString *gWGLogTag = @"";

void WGLogSetEnabled(BOOL enabled) { gWGLogEnabled = enabled; }
BOOL WGLogEnabled(void) { return gWGLogEnabled; }
void WGLogSetTag(NSString *tag) { gWGLogTag = [tag copy] ?: @""; }

NSString *WGLogPath(void) {
    return WGWorkPath(@"runtime.txt");
}

static dispatch_queue_t WGLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.rinapple.switzachwidgetprobe.log", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static void WGWriteLine(NSString *line) {
    NSString *tag = gWGLogTag;
    NSDate *now = [NSDate date];
    dispatch_async(WGLogQueue(), ^{
        static NSDateFormatter *df;
        if (!df) {
            df = [NSDateFormatter new];
            df.dateFormat = @"HH:mm:ss.SSS";
        }
        NSString *text = [NSString stringWithFormat:@"%@ %@%@\n", [df stringFromDate:now], tag, line];
        NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
        int fd = open(WGLogPath().fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) return;
        write(fd, data.bytes, data.length);
        close(fd);
    });
}

void WGLog(NSString *format, ...) {
    if (!gWGLogEnabled) return;
    va_list ap;
    va_start(ap, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    WGWriteLine(line);
}

void WGLogImportant(NSString *format, ...) {
    va_list ap;
    va_start(ap, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    WGWriteLine(line);
}

void WGLogRotate(void) {
    NSString *path = WGLogPath();
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0 || st.st_size <= 1024 * 1024) return;
    NSString *old = WGWorkPath(@"runtime-old.txt");
    unlink(old.fileSystemRepresentation);
    rename(path.fileSystemRepresentation, old.fileSystemRepresentation);
}

#pragma mark - Crash markers

static NSString *WGMarkerPath(NSString *name, NSString *suffix) {
    NSString *safe = [name stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return WGWorkPath([safe stringByAppendingString:suffix]);
}

BOOL WGMarkerTripped(NSString *name) {
    NSString *running = WGMarkerPath(name, @".running"), *bad = WGMarkerPath(name, @".bad");
    NSString *owner = [NSString stringWithContentsOfFile:running encoding:NSUTF8StringEncoding error:nil];
    if (owner.length && owner.intValue != getpid()) { // left by an earlier process: that one crashed there
        unlink(bad.fileSystemRepresentation);
        rename(running.fileSystemRepresentation, bad.fileSystemRepresentation);
    }
    return access(bad.fileSystemRepresentation, F_OK) == 0;
}

void WGMarkerBegin(NSString *name) {
    // A plain write: atomic writes also change file modes, which the ROM's system call relay
    // has been seen to hold up for seconds.
    [[NSString stringWithFormat:@"%d", getpid()] writeToFile:WGMarkerPath(name, @".running") atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

void WGMarkerEnd(NSString *name) {
    unlink(WGMarkerPath(name, @".running").fileSystemRepresentation);
}

NSUInteger WGMarkersReset(void) {
    NSUInteger removed = 0;
    for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:WGWorkDirectory() error:nil]) {
        if (![f hasSuffix:@".bad"] && ![f hasSuffix:@".running"]) continue;
        // Intents-extension defaults stay off: a second copy of an app's code (e.g. its own
        // Firebase) in one process cannot work, and resetting would only crash it again.
        if ([f hasPrefix:@"intent-defaults-"]) continue;
        if (unlink(WGWorkPath(f).fileSystemRepresentation) == 0) removed++;
    }
    return removed;
}
