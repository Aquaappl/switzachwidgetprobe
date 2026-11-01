// SpringBoard's side of the widget host processes (see WPHost.m for the host and the messages).
//
// A host is SwitzachWidgetHost.app, installed with the package. SpringBoard copies it into its
// own caches (where Nyxian can sign it) and starts it with posix_spawn for one extension, with
// a pipe on its stdin (requests) and one on its stdout (answers), one JSON object per line.
// When a host ends while it still had widgets to show, it is started again and every view is
// shown again; a host that keeps ending within seconds of its start is not started again in
// this SpringBoard session (its widgets say "Could not draw").

#import "WPRemote.h"
#import <dlfcn.h>
#import <fcntl.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;
BOOL WPDiagnosticLogEnabled(void); // WPSettings.m

static void (^gWPRemoteLogger)(NSString *line);
static void (^gWPOpenURLHandler)(NSURL *url, WPWidgetExtension *extension);

static void WPRLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void WPRLog(NSString *fmt, ...) {
    if (!gWPRemoteLogger || !WPDiagnosticLogEnabled()) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    gWPRemoteLogger(line);
}

#pragma mark - The host executable

// The installed host app is next to this dylib's folder tree (the root this process sees is
// not "/"); its copy in SpringBoard's caches is what runs.
static NSString *WPHostExecutable(void) {
    static NSString *executable;
    static BOOL tried;
    if (tried) return executable;
    tried = YES;
    NSFileManager *fm = [NSFileManager defaultManager];
    Dl_info info;
    NSString *dylib = dladdr((const void *)&WPHostExecutable, &info) && info.dli_fname ? @(info.dli_fname) : @"";
    NSString *source = nil;
    for (NSString *marker in @[ @"/Library/MobileSubstrate/DynamicLibraries/", @"/usr/lib/TweakInject/" ]) {
        NSRange r = [dylib rangeOfString:marker];
        if (r.location == NSNotFound) continue;
        NSString *c = [[dylib substringToIndex:r.location] stringByAppendingPathComponent:@"Library/SwitzachWidgetProbe/SwitzachWidgetHost.app"];
        if ([fm fileExistsAtPath:c]) source = c;
    }
    if (!source && [fm fileExistsAtPath:@"/Library/SwitzachWidgetProbe/SwitzachWidgetHost.app"]) source = @"/Library/SwitzachWidgetProbe/SwitzachWidgetHost.app";
    if (!source) {
        WPRLog(@"Widget host not found next to %@", dylib);
        return nil;
    }
    NSString *copy = [[WPProbe workDirectory] stringByAppendingPathComponent:@"SwitzachWidgetHost.app"];
    NSString *exe = [copy stringByAppendingPathComponent:@"SwitzachWidgetHost"];
    // Copied again only when the installed one changed (a signed copy is reused).
    NSDictionary *a = [fm attributesOfItemAtPath:[source stringByAppendingPathComponent:@"SwitzachWidgetHost"] error:nil];
    NSString *stamp = [NSString stringWithFormat:@"%@|%@", a[NSFileSize], @([a[NSFileModificationDate] timeIntervalSince1970])];
    NSString *stampPath = [[WPProbe workDirectory] stringByAppendingPathComponent:@"host-source"];
    NSString *old = [NSString stringWithContentsOfFile:stampPath encoding:NSUTF8StringEncoding error:nil];
    if (![old isEqualToString:stamp] || ![fm fileExistsAtPath:exe]) {
        [fm removeItemAtPath:copy error:nil];
        NSError *err = nil;
        if (![fm copyItemAtPath:source toPath:copy error:&err]) {
            WPRLog(@"Could not copy the widget host: %@", err.localizedDescription);
            return nil;
        }
        chmod(exe.fileSystemRepresentation, 0755);
        [stamp writeToFile:stampPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
    }
    executable = exe;
    return executable;
}

#pragma mark - One host

@interface WPRemoteHost : NSObject
@property (nonatomic, strong) WPWidgetExtension *extension;
@property (nonatomic) pid_t pid;
@property (nonatomic) int writeFD;
@property (nonatomic, strong) dispatch_source_t readSource;
@property (nonatomic, strong) NSMutableData *pending;
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *widgets;
@property (nonatomic, strong) NSMutableArray *listWaiters;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSDictionary *> *shows;   // the last show of each view
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id> *viewEvents;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id> *tapWaiters;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *quickEnds; // start times of runs that ended within 20 s
@property (nonatomic) CFAbsoluteTime startedAt;
@property (nonatomic) BOOL disabled;
@property (nonatomic) BOOL restartScheduled;
@end

@implementation WPRemoteHost

- (instancetype)init {
    if ((self = [super init])) {
        _writeFD = -1;
        _listWaiters = [NSMutableArray array];
        _shows = [NSMutableDictionary dictionary];
        _viewEvents = [NSMutableDictionary dictionary];
        _tapWaiters = [NSMutableDictionary dictionary];
        _quickEnds = [NSMutableArray array];
    }
    return self;
}

- (BOOL)running {
    return self.writeFD >= 0;
}

- (void)send:(NSDictionary *)message {
    if (![self start]) return;
    NSData *json = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    if (!json) return;
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    const uint8_t *p = line.bytes;
    size_t left = line.length;
    while (left > 0) {
        ssize_t n = write(self.writeFD, p, left);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            WPRLog(@"Widget host %@: could not write (%s)", self.extension.appName, strerror(errno));
            return;
        }
        p += n;
        left -= (size_t)n;
    }
}

// Starts the host if it is not running. NO when it cannot (or should not) run.
- (BOOL)start {
    if (self.running) return YES;
    if (self.disabled) return NO;
    NSString *exe = WPHostExecutable();
    if (!exe) return NO;
    WPWidgetExtension *e = self.extension;
    int out[2], in[2];
    if (pipe(out) != 0) return NO;
    if (pipe(in) != 0) {
        close(out[0]);
        close(out[1]);
        return NO;
    }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, in[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO);
    NSString *errPath = WPDiagnosticLogEnabled() ? [[WPProbe workDirectory] stringByAppendingPathComponent:@"hosts-stderr.txt"] : @"/dev/null";
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, errPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);

    NSArray *args = @[ exe, e.extensionBundleID ?: @"", e.appBundleID ?: @"", e.appName ?: @"", e.appPath ?: @"", e.extensionPath ?: @"",
                       e.executablePath ?: @"", e.dataContainerPath ?: @"" ];
    char **argv = calloc(args.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < args.count; i++) argv[i] = strdup([args[i] UTF8String]);
    NSMutableArray *env = [NSMutableArray array];
    for (char **v = environ; *v; v++) {
        if (strncmp(*v, "WP_DIAGNOSTIC_LOG=", 18) != 0) [env addObject:@(*v)];
    }
    [env addObject:[NSString stringWithFormat:@"WP_DIAGNOSTIC_LOG=%d", WPDiagnosticLogEnabled() ? 1 : 0]];
    char **envp = calloc(env.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < env.count; i++) envp[i] = strdup([env[i] UTF8String]);

    pid_t pid = 0;
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    int r = posix_spawn(&pid, exe.fileSystemRepresentation, &actions, &attr, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    for (NSUInteger i = 0; argv[i]; i++) free(argv[i]);
    for (NSUInteger i = 0; envp[i]; i++) free(envp[i]);
    free(argv);
    free(envp);
    close(in[0]);
    close(out[1]);
    if (r != 0) {
        close(in[1]);
        close(out[0]);
        WPRLog(@"Widget host for %@ did not start: %s", e.appName, strerror(r));
        return NO;
    }
    fcntl(in[1], F_SETFD, FD_CLOEXEC);
    fcntl(out[0], F_SETFD, FD_CLOEXEC);
    fcntl(out[0], F_SETFL, O_NONBLOCK);
    self.pid = pid;
    self.writeFD = in[1];
    self.startedAt = CFAbsoluteTimeGetCurrent();
    self.pending = [NSMutableData data];
    WPRLog(@"Widget host for %@ started: pid %d (%.0f ms)", e.appName, pid, (CFAbsoluteTimeGetCurrent() - t0) * 1000);

    int readFD = out[0];
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, readFD, 0, dispatch_get_main_queue());
    __weak WPRemoteHost *weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        WPRemoteHost *strong = weakSelf;
        uint8_t buf[8192];
        ssize_t n = read(readFD, buf, sizeof buf);
        if (n > 0) {
            [strong received:buf length:(NSUInteger)n];
        } else if (n == 0 || (errno != EAGAIN && errno != EINTR)) {
            dispatch_source_cancel(source);
            [strong ended:pid];
        }
    });
    dispatch_source_set_cancel_handler(source, ^{ close(readFD); });
    self.readSource = source;
    dispatch_resume(source);

    // How it ends, for the log.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = 0;
        if (waitpid(pid, &status, 0) != pid) return;
        NSString *how = WIFSIGNALED(status) ? [NSString stringWithFormat:@"signal %d", WTERMSIG(status)]
                                           : [NSString stringWithFormat:@"exit code %d", WEXITSTATUS(status)];
        dispatch_async(dispatch_get_main_queue(), ^{ WPRLog(@"Widget host for %@ (pid %d) ended: %@", e.appName, pid, how); });
    });
    return YES;
}

- (void)received:(const uint8_t *)bytes length:(NSUInteger)length {
    [self.pending appendBytes:bytes length:length];
    for (;;) {
        const uint8_t *p = self.pending.bytes;
        const uint8_t *nl = memchr(p, '\n', self.pending.length);
        if (!nl) break;
        NSUInteger len = (NSUInteger)(nl - p);
        NSData *line = [self.pending subdataWithRange:NSMakeRange(0, len)];
        [self.pending replaceBytesInRange:NSMakeRange(0, len + 1) withBytes:NULL length:0];
        id m = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
        if ([m isKindOfClass:[NSDictionary class]]) [self handle:m];
    }
}

- (void)handle:(NSDictionary *)m {
    NSString *op = m[@"op"];
    NSNumber *viewID = [m[@"view"] isKindOfClass:[NSNumber class]] ? m[@"view"] : nil;
    if ([op isEqualToString:@"widgets"]) {
        self.widgets = [m[@"list"] isKindOfClass:[NSArray class]] ? m[@"list"] : @[];
        WPRLog(@"Widget host for %@: %lu widget(s)", self.extension.appName, (unsigned long)self.widgets.count);
        NSArray *waiters = [self.listWaiters copy];
        [self.listWaiters removeAllObjects];
        for (void (^w)(void) in waiters) w();
    } else if ([op isEqualToString:@"tapped"] && viewID) {
        void (^waiter)(NSString *, NSDictionary *) = self.tapWaiters[viewID];
        [self.tapWaiters removeObjectForKey:viewID];
        if (waiter) waiter([m[@"result"] isKindOfClass:[NSString class]] ? m[@"result"] : @"none", m);
    } else if ([op isEqualToString:@"open"]) {
        NSURL *url = [m[@"url"] isKindOfClass:[NSString class]] ? [NSURL URLWithString:m[@"url"]] : nil;
        if (url && gWPOpenURLHandler) gWPOpenURLHandler(url, self.extension);
    } else if ([op isEqualToString:@"log"]) {
        WPRLog(@"[%@ host] %@", self.extension.appName, m[@"text"]);
    } else if (viewID) {
        void (^events)(NSDictionary *) = self.viewEvents[viewID];
        if (events) events(m);
    }
}

// The host's output ended: it exited or crashed.
- (void)ended:(pid_t)pid {
    if (pid != self.pid) return;
    if (self.writeFD >= 0) close(self.writeFD);
    self.writeFD = -1;
    self.readSource = nil;
    self.pid = 0;
    NSArray *tapWaiters = self.tapWaiters.allValues;
    [self.tapWaiters removeAllObjects];
    for (void (^w)(NSString *, NSDictionary *) in tapWaiters) w(@"failed", @{});
    if (self.shows.count == 0 && self.listWaiters.count == 0) return; // idle: it ended by itself

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - self.startedAt < 20) [self.quickEnds addObject:@(now)];
    [self.quickEnds filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSNumber *t, NSDictionary *b) { return now - t.doubleValue < 300; }]];
    if (self.quickEnds.count >= 3) {
        self.disabled = YES;
        WPRLog(@"Widget host for %@ ended 3 times right after starting: not started again", self.extension.appName);
        for (NSNumber *v in self.shows.allKeys) {
            void (^events)(NSDictionary *) = self.viewEvents[v];
            if (events) events(@{ @"op" : @"failed", @"reason" : @"the widget keeps crashing" });
        }
        NSArray *waiters = [self.listWaiters copy];
        [self.listWaiters removeAllObjects];
        for (void (^w)(void) in waiters) w();
        return;
    }
    for (NSNumber *v in self.shows.allKeys) {
        void (^events)(NSDictionary *) = self.viewEvents[v];
        if (events) events(@{ @"op" : @"lost" });
    }
    if (self.restartScheduled) return;
    self.restartScheduled = YES;
    __weak WPRemoteHost *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WPRemoteHost *strong = weakSelf;
        if (!strong) return;
        strong.restartScheduled = NO;
        if (strong.running || (strong.shows.count == 0 && strong.listWaiters.count == 0)) return;
        if (strong.listWaiters.count) [strong send:@{ @"op" : @"list" }];
        for (NSDictionary *show in strong.shows.allValues) [strong send:show];
    });
}

@end

#pragma mark - API

static NSMutableDictionary<NSString *, WPRemoteHost *> *WPHosts(void) {
    static NSMutableDictionary *hosts;
    if (!hosts) hosts = [NSMutableDictionary dictionary];
    return hosts;
}

static WPRemoteHost *WPHostFor(WPWidgetExtension *ext) {
    if (!ext.extensionBundleID) return nil;
    WPRemoteHost *h = WPHosts()[ext.extensionBundleID];
    if (!h) {
        h = [WPRemoteHost new];
        h.extension = ext;
        WPHosts()[ext.extensionBundleID] = h;
    }
    return h;
}

@implementation WPRemote

+ (void)prepareExtension:(WPWidgetExtension *)extension completion:(void (^)(void))completion {
    WPRemoteHost *h = WPHostFor(extension);
    if (!h || h.widgets || h.disabled) {
        if (h && !h.widgets && h.disabled) h.widgets = @[];
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }
    BOOL first = h.listWaiters.count == 0;
    [h.listWaiters addObject:completion ? [completion copy] : [^{} copy]];
    if (!first) return;
    if (![h start]) {
        h.widgets = @[];
        NSArray *waiters = [h.listWaiters copy];
        [h.listWaiters removeAllObjects];
        for (void (^w)(void) in waiters) w();
        return;
    }
    [h send:@{ @"op" : @"list" }];
}

+ (NSArray<NSDictionary *> *)loadedWidgetsForExtension:(WPWidgetExtension *)extension {
    return WPHosts()[extension.extensionBundleID ?: @""].widgets;
}

+ (NSArray<NSDictionary *> *)widgetsForExtension:(WPWidgetExtension *)extension {
    return [self loadedWidgetsForExtension:extension] ?: @[];
}

+ (NSInteger)newViewID {
    static NSInteger next;
    return ++next;
}

+ (void)showView:(NSInteger)viewID extension:(WPWidgetExtension *)extension kind:(NSString *)kind family:(int)family size:(CGSize)size
            dark:(BOOL)dark events:(void (^)(NSDictionary *))events {
    WPRemoteHost *h = WPHostFor(extension);
    if (!h) return;
    if (h.disabled) {
        events(@{ @"op" : @"failed", @"reason" : @"the widget keeps crashing" });
        return;
    }
    NSDictionary *show = @{ @"op" : @"show", @"view" : @(viewID), @"kind" : kind, @"family" : @(family), @"w" : @(size.width),
                            @"h" : @(size.height), @"style" : dark ? @"dark" : @"light" };
    h.shows[@(viewID)] = show;
    h.viewEvents[@(viewID)] = [events copy];
    BOOL wasRunning = h.running;
    [h send:show];
    if (!wasRunning && !h.running) events(@{ @"op" : @"failed", @"reason" : @"the widget host did not start" });
}

+ (void)hideView:(NSInteger)viewID extension:(WPWidgetExtension *)extension {
    WPRemoteHost *h = WPHosts()[extension.extensionBundleID ?: @""];
    if (!h.shows[@(viewID)]) return;
    [h.shows removeObjectForKey:@(viewID)];
    [h.viewEvents removeObjectForKey:@(viewID)];
    if (h.running) [h send:@{ @"op" : @"hide", @"view" : @(viewID) }];
}

+ (void)tapView:(NSInteger)viewID extension:(WPWidgetExtension *)extension point:(CGPoint)point
         result:(void (^)(NSString *, NSDictionary *))result {
    WPRemoteHost *h = WPHosts()[extension.extensionBundleID ?: @""];
    if (!h.running || !h.shows[@(viewID)]) {
        result(@"failed", @{});
        return;
    }
    void (^previous)(NSString *, NSDictionary *) = h.tapWaiters[@(viewID)];
    if (previous) previous(@"failed", @{});
    __block BOOL answered = NO;
    void (^once)(NSString *, NSDictionary *) = ^(NSString *r, NSDictionary *m) {
        if (answered) return;
        answered = YES;
        result(r, m);
    };
    h.tapWaiters[@(viewID)] = [once copy];
    [h send:@{ @"op" : @"tap", @"view" : @(viewID), @"x" : @(point.x), @"y" : @(point.y) }];
    // No answer (a busy or stuck host): treated as a tap outside any control.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (answered) return;
        if (h.tapWaiters[@(viewID)] == once) [h.tapWaiters removeObjectForKey:@(viewID)];
        once(@"failed", @{});
    });
}

+ (void)setOpenURLHandler:(void (^)(NSURL *, WPWidgetExtension *))handler {
    gWPOpenURLHandler = [handler copy];
}

+ (void)setLogger:(void (^)(NSString *))logger {
    gWPRemoteLogger = [logger copy];
}

+ (void)diagnosticLogChanged {
    BOOL on = WPDiagnosticLogEnabled();
    for (WPRemoteHost *h in WPHosts().allValues) {
        if (h.running) [h send:@{ @"op" : @"log", @"on" : @(on) }];
    }
}

@end
