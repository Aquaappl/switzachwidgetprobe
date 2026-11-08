// SpringBoard's side of the widget hosts (see WGHostMain.m for the host and its messages).
//
// A host is SwitzachWidgetHost.app, installed with the package. SpringBoard copies it into its
// caches (where Nyxian can sign it; again only when the installed one changed) and starts it
// with posix_spawn for one extension, with a pipe on its stdin and one on its stdout.
//
// SpringBoard's main thread never waits for a host: Nyxian's posix_spawn waits until the new
// process is up, so starting runs on a queue of its own, as do the writes (a host that stops
// reading cannot block SpringBoard), and reading runs on another. Writing to a host that has
// just ended is not a signal for SpringBoard (F_SETNOSIGPIPE).
//
// When a host ends while it had widgets to show, it is started again and every view shown again;
// one that keeps ending right after starting is not started again in this SpringBoard session.

#import "WGSpringBoard.h"
#import <dlfcn.h>
#import <fcntl.h>
#import <spawn.h>
#import <sys/stat.h>
#import <unistd.h>

extern char **environ;

#pragma mark - The host executable

// The installed host app, found next to this dylib's folder tree (the root this process sees is
// not "/"); its copy in the work folder is what runs. Any thread.
static NSString *WGHostExecutable(void) {
    static NSString *executable;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        Dl_info info;
        NSString *dylib = dladdr((const void *)&WGHostExecutable, &info) && info.dli_fname ? @(info.dli_fname) : @"";
        NSString *source = nil;
        for (NSString *marker in @[ @"/Library/MobileSubstrate/DynamicLibraries/", @"/usr/lib/TweakInject/" ]) {
            NSRange r = [dylib rangeOfString:marker];
            if (r.location == NSNotFound) continue;
            NSString *c = [[dylib substringToIndex:r.location] stringByAppendingPathComponent:@"Library/SwitzachWidgetProbe/SwitzachWidgetHost.app"];
            if ([fm fileExistsAtPath:c]) source = c;
        }
        if (!source && [fm fileExistsAtPath:@"/Library/SwitzachWidgetProbe/SwitzachWidgetHost.app"]) source = @"/Library/SwitzachWidgetProbe/SwitzachWidgetHost.app";
        if (!source) {
            WGLogImportant(@"The widget host app was not found (next to %@)", dylib);
            return;
        }
        NSString *copy = WGWorkPath(@"SwitzachWidgetHost.app");
        NSString *exe = [copy stringByAppendingPathComponent:@"SwitzachWidgetHost"];
        struct stat st;
        NSString *stamp = stat([source stringByAppendingPathComponent:@"SwitzachWidgetHost"].fileSystemRepresentation, &st) == 0
                              ? [NSString stringWithFormat:@"%lld|%ld", (long long)st.st_size, (long)st.st_mtimespec.tv_sec] : @"?";
        NSString *stampPath = WGWorkPath(@"host-source");
        if (![[NSString stringWithContentsOfFile:stampPath encoding:NSUTF8StringEncoding error:nil] isEqualToString:stamp] ||
            access(exe.fileSystemRepresentation, X_OK) != 0) {
            [fm removeItemAtPath:copy error:nil];
            NSError *err = nil;
            if (![fm copyItemAtPath:source toPath:copy error:&err]) {
                WGLogImportant(@"Could not copy the widget host: %@", err.localizedDescription);
                return;
            }
            chmod(exe.fileSystemRepresentation, 0755);
            [stamp writeToFile:stampPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
        }
        executable = exe;
    });
    return executable;
}

#pragma mark - One host

@interface WGHost ()
@property (nonatomic, readwrite) WGExtension *extension;
@property (nonatomic, readwrite, nullable) NSArray<NSDictionary *> *widgets;
@property (nonatomic, readwrite) BOOL blocked;
@property (nonatomic, readwrite) BOOL disabled;
@end

@implementation WGHost {
    dispatch_queue_t _queue;     // starting and writing
    int _writeFD;                // on _queue
    NSUInteger _queueRun;        // on _queue: the run _writeFD belongs to
    NSUInteger _run;             // main: the current run (0 = never started)
    BOOL _running;
    pid_t _pid;
    CFAbsoluteTime _startedAt;
    NSMutableArray *_listWaiters;
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *_shows; // each view's last show (replayed after a restart)
    NSMutableDictionary<NSNumber *, void (^)(NSDictionary *)> *_events;
    NSMutableDictionary<NSNumber *, void (^)(NSString *, NSDictionary *)> *_tapWaiters;
    NSMutableDictionary<NSNumber *, void (^)(NSDictionary *)> *_replyWaiters; // request → its answer
    NSInteger _lastRequest;
    NSMutableArray<NSNumber *> *_quickEnds;
    BOOL _restartScheduled;
    NSMutableDictionary<NSNumber *, NSNumber *> *_contextIDs; // each view's context, as the host last said
    NSMutableSet<NSNumber *> *_drawnViews;
    NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *_parked;
}

static NSMutableDictionary<NSString *, WGHost *> *gHosts;
static int gSandboxState = -1; // Nyxian's filesystem sandbox, as the last host to start found it

int WGFilesystemSandboxState(void) {
    return gSandboxState;
}

+ (instancetype)hostForExtension:(WGExtension *)extension {
    if (!gHosts) gHosts = [NSMutableDictionary dictionary];
    WGHost *h = gHosts[extension.extensionID];
    if (!h) {
        h = [WGHost new];
        h->_queue = dispatch_queue_create([@"com.rinapple.switzachwidgetprobe.host." stringByAppendingString:extension.extensionID].UTF8String,
                                          DISPATCH_QUEUE_SERIAL);
        h->_writeFD = -1;
        h->_listWaiters = [NSMutableArray array];
        h->_shows = [NSMutableDictionary dictionary];
        h->_events = [NSMutableDictionary dictionary];
        h->_tapWaiters = [NSMutableDictionary dictionary];
        h->_replyWaiters = [NSMutableDictionary dictionary];
        h->_quickEnds = [NSMutableArray array];
        h->_contextIDs = [NSMutableDictionary dictionary];
        h->_drawnViews = [NSMutableSet set];
        h->_parked = [NSMutableDictionary dictionary];
        gHosts[extension.extensionID] = h;
    }
    h.extension = extension; // the newest paths, for the next start
    return h;
}

+ (NSInteger)newViewID {
    static NSInteger next;
    return ++next;
}

#pragma mark Starting

- (BOOL)start {
    if (_running) return YES;
    if (self.disabled) return NO;
    int toHost[2], fromHost[2];
    if (pipe(toHost) != 0) return NO;
    if (pipe(fromHost) != 0) {
        close(toHost[0]);
        close(toHost[1]);
        return NO;
    }
    // Close-on-exec for all four ends: no other process SpringBoard starts may hold them (a host
    // that ended would not be noticed). The host's own ends become its stdin / stdout by dup2,
    // which clears the flag there.
    for (int i = 0; i < 2; i++) {
        fcntl(toHost[i], F_SETFD, FD_CLOEXEC);
        fcntl(fromHost[i], F_SETFD, FD_CLOEXEC);
    }
    fcntl(toHost[1], F_SETNOSIGPIPE, 1);
    fcntl(fromHost[0], F_SETFL, fcntl(fromHost[0], F_GETFL) | O_NONBLOCK);
    _running = YES;
    NSUInteger run = ++_run;
    _startedAt = CFAbsoluteTimeGetCurrent();
    [self readFrom:fromHost[0] run:run];

    int hostIn = toHost[0], hostOut = fromHost[1], ourOut = toHost[1];
    WGExtension *e = self.extension;
    NSArray *args = e.arguments;
    BOOL log = WGLogEnabled();
    dispatch_async(_queue, ^{
        NSString *exe = WGHostExecutable();
        pid_t pid = 0;
        int r = ENOENT;
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        if (exe) {
            posix_spawn_file_actions_t actions;
            posix_spawn_file_actions_init(&actions);
            posix_spawn_file_actions_adddup2(&actions, hostIn, STDIN_FILENO);
            posix_spawn_file_actions_adddup2(&actions, hostOut, STDOUT_FILENO);
            NSString *errPath = log ? WGWorkPath(@"hosts-stderr.txt") : @"/dev/null";
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, errPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
            posix_spawnattr_t attr;
            posix_spawnattr_init(&attr);
            posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);
            NSMutableArray *argList = [NSMutableArray arrayWithObject:exe];
            [argList addObjectsFromArray:args];
            NSMutableArray *envList = [NSMutableArray array];
            for (char **v = environ; v && *v; v++) {
                if (strncmp(*v, "WG_DIAGNOSTIC_LOG=", 18) != 0) [envList addObject:@(*v)];
            }
            [envList addObject:[NSString stringWithFormat:@"WG_DIAGNOSTIC_LOG=%d", log]];
            char **argv = calloc(argList.count + 1, sizeof(char *)), **envp = calloc(envList.count + 1, sizeof(char *));
            for (NSUInteger i = 0; i < argList.count; i++) argv[i] = strdup([argList[i] UTF8String]);
            for (NSUInteger i = 0; i < envList.count; i++) envp[i] = strdup([envList[i] UTF8String] ?: "");
            r = posix_spawn(&pid, exe.fileSystemRepresentation, &actions, &attr, argv, envp);
            posix_spawn_file_actions_destroy(&actions);
            posix_spawnattr_destroy(&attr);
            for (NSUInteger i = 0; argv[i]; i++) free(argv[i]);
            for (NSUInteger i = 0; envp[i]; i++) free(envp[i]);
            free(argv);
            free(envp);
        }
        close(hostIn);
        close(hostOut); // a host that did not start: the reader sees the end at once
        if (r != 0) {
            close(ourOut);
            dispatch_async(dispatch_get_main_queue(), ^{ WGLogImportant(@"Widget host for %@ did not start: %s", e.appName, strerror(r)); });
            return;
        }
        if (self->_writeFD >= 0) close(self->_writeFD);
        self->_writeFD = ourOut;
        self->_queueRun = run;
        double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (run == self->_run) self->_pid = pid;
            WGLog(@"Widget host for %@ started: pid %d (%.0f ms)", e.appName, pid, ms);
        });
    });
    return YES;
}

- (void)readFrom:(int)fd run:(NSUInteger)run {
    static dispatch_queue_t readQueue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ readQueue = dispatch_queue_create("com.rinapple.switzachwidgetprobe.read", DISPATCH_QUEUE_SERIAL); });
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, readQueue);
    WGLineReader *reader = [WGLineReader new];
    __weak WGHost *weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        uint8_t buf[16384];
        for (;;) {
            ssize_t n = read(fd, buf, sizeof buf);
            if (n > 0) {
                [reader appendBytes:buf length:(size_t)n handler:^(NSDictionary *m) {
                    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf received:m run:run]; });
                }];
                continue;
            }
            if (n < 0 && errno == EINTR) continue;
            if (n < 0 && errno == EAGAIN) return;
            dispatch_source_cancel(source);
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf endedRun:run]; });
            return;
        }
    });
    dispatch_source_set_cancel_handler(source, ^{ close(fd); });
    dispatch_resume(source);
}

- (void)send:(NSDictionary *)message {
    if (![self start]) return;
    NSData *data = WGEncodeMessage(message);
    if (!data) return;
    NSUInteger run = _run;
    dispatch_async(_queue, ^{
        if (self->_queueRun != run || self->_writeFD < 0) return; // that run ended
        const uint8_t *p = data.bytes;
        size_t left = data.length;
        while (left > 0) {
            ssize_t n = write(self->_writeFD, p, left);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) return; // the host is gone: its reader reports the end
            p += n;
            left -= (size_t)n;
        }
    });
}

#pragma mark Messages

- (void)received:(NSDictionary *)m run:(NSUInteger)run {
    if (run != _run) return;
    NSString *op = m[WGOp];
    NSNumber *viewID = [m[WGView] isKindOfClass:[NSNumber class]] ? m[WGView] : nil;
    if ([op isEqual:@"ready"]) {
        self.blocked = [m[@"blocked"] boolValue];
        if (gSandboxState != self.blocked) {
            gSandboxState = self.blocked;
            [[NSNotificationCenter defaultCenter] postNotificationName:WGFilesystemSandboxChangedNotification object:nil];
        }
        if (self.blocked) WGLogImportant(@"Widget host for %@ cannot reach its files: Nyxian's filesystem sandbox is on", self.extension.appName);
    } else if ([op isEqual:@"widgets"]) {
        self.widgets = [m[@"list"] isKindOfClass:[NSArray class]] ? m[@"list"] : @[];
        if ([m[@"problem"] isEqual:@"filesystem-sandbox"] && !self.blocked) {
            self.blocked = YES;
            gSandboxState = 1;
            [[NSNotificationCenter defaultCenter] postNotificationName:WGFilesystemSandboxChangedNotification object:nil];
        }
        WGLog(@"Widget host for %@: %lu widget(s)%@", self.extension.appName, (unsigned long)self.widgets.count,
              m[@"problem"] ? [@", " stringByAppendingString:m[@"problem"]] : @"");
        [self finishListWaiters];
    } else if ([op isEqual:@"tapped"] && viewID) {
        void (^waiter)(NSString *, NSDictionary *) = _tapWaiters[viewID];
        [_tapWaiters removeObjectForKey:viewID];
        if (waiter) waiter([m[@"result"] isKindOfClass:[NSString class]] ? m[@"result"] : @"none", m);
    } else if ([op isEqual:@"reply"] && [m[@"req"] isKindOfClass:[NSNumber class]]) {
        void (^waiter)(NSDictionary *) = _replyWaiters[m[@"req"]];
        [_replyWaiters removeObjectForKey:m[@"req"]];
        if (waiter) waiter(m);
    } else if ([op isEqual:@"open"]) {
        NSURL *url = [m[@"url"] isKindOfClass:[NSString class]] ? [NSURL URLWithString:m[@"url"]] : nil;
        if (url) WGOpenWidgetURL(url, self.extension);
    } else if (viewID) {
        if ([op isEqual:@"context"] && [m[@"id"] isKindOfClass:[NSNumber class]]) _contextIDs[viewID] = m[@"id"];
        else if ([op isEqual:@"drawn"]) [_drawnViews addObject:viewID];
        void (^events)(NSDictionary *) = _events[viewID];
        if (events) events(m);
    }
}

- (void)finishListWaiters {
    NSArray *waiters = [_listWaiters copy];
    [_listWaiters removeAllObjects];
    for (void (^w)(void) in waiters) w();
}

// The host's output ended: it exited or crashed.
- (void)endedRun:(NSUInteger)run {
    if (run != _run || !_running) return;
    _running = NO;
    pid_t pid = _pid;
    _pid = 0;
    dispatch_async(_queue, ^{
        if (self->_queueRun == run && self->_writeFD >= 0) {
            close(self->_writeFD);
            self->_writeFD = -1;
        }
    });
    NSArray *taps = _tapWaiters.allValues;
    [_tapWaiters removeAllObjects];
    for (void (^w)(NSString *, NSDictionary *) in taps) w(@"failed", @{});
    NSArray *replies = _replyWaiters.allValues;
    [_replyWaiters removeAllObjects];
    for (void (^w)(NSDictionary *) in replies) w(nil);
    if (_shows.count == 0 && _listWaiters.count == 0) {
        WGLog(@"Widget host for %@ (pid %d) ended", self.extension.appName, pid);
        return; // idle: it ended by itself
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _startedAt < 20) [_quickEnds addObject:@(now)];
    [_quickEnds filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSNumber *t, NSDictionary *b) { return now - t.doubleValue < 300; }]];
    WGLogImportant(@"Widget host for %@ (pid %d) ended while showing widgets", self.extension.appName, pid);
    if (_quickEnds.count >= 3) {
        self.disabled = YES;
        WGLogImportant(@"Widget host for %@ ended 3 times right after starting: not started again until the next respring", self.extension.appName);
        for (NSNumber *v in _shows.allKeys) {
            void (^events)(NSDictionary *) = _events[v];
            if (events) events(@{ WGOp : @"failed", @"reason" : @"crashing" });
        }
        if (!self.widgets) self.widgets = @[];
        [self finishListWaiters];
        return;
    }
    [_contextIDs removeAllObjects];
    [_drawnViews removeAllObjects];
    for (NSNumber *v in _shows.allKeys) {
        void (^events)(NSDictionary *) = _events[v];
        if (events) events(@{ WGOp : @"lost" });
    }
    if (_restartScheduled) return;
    _restartScheduled = YES;
    __weak WGHost *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WGHost *h = weakSelf;
        if (!h) return;
        h->_restartScheduled = NO;
        if (h->_running || (h->_shows.count == 0 && h->_listWaiters.count == 0)) return;
        if (h->_listWaiters.count) [h send:@{ WGOp : @"list" }];
        for (NSDictionary *show in h->_shows.allValues) [h send:show];
    });
}

#pragma mark API

- (void)loadWidgets:(void (^)(void))completion {
    if (self.widgets || self.disabled) {
        if (!self.widgets) self.widgets = @[];
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }
    BOOL first = _listWaiters.count == 0;
    [_listWaiters addObject:completion ? [completion copy] : [^{} copy]];
    if (!first) return;
    if (![self start]) {
        self.widgets = @[];
        [self finishListWaiters];
        return;
    }
    [self send:@{ WGOp : @"list" }];
}

- (void)showView:(NSInteger)viewID request:(NSDictionary *)request events:(void (^)(NSDictionary *))events {
    if (self.disabled) {
        events(@{ WGOp : @"failed", @"reason" : @"crashing" });
        return;
    }
    NSMutableDictionary *show = [request mutableCopy];
    show[WGOp] = @"show";
    show[WGView] = @(viewID);
    _shows[@(viewID)] = show;
    _events[@(viewID)] = [events copy];
    [self send:show];
    if (!_running) events(@{ WGOp : @"failed", @"reason" : @"the widget host did not start" });
}

- (void)setView:(NSInteger)viewID visible:(BOOL)visible {
    NSMutableDictionary *show = _shows[@(viewID)];
    if (!show || [show[@"visible"] boolValue] == visible) return;
    show[@"visible"] = @(visible);
    if (_running) [self send:@{ WGOp : @"visible", WGView : @(viewID), @"on" : @(visible) }];
}

- (void)hideView:(NSInteger)viewID {
    if (!_shows[@(viewID)]) return;
    [_shows removeObjectForKey:@(viewID)];
    [_events removeObjectForKey:@(viewID)];
    [_contextIDs removeObjectForKey:@(viewID)];
    [_drawnViews removeObject:@(viewID)];
    if (_running) [self send:@{ WGOp : @"hide", WGView : @(viewID) }];
}

- (void)parkView:(NSInteger)viewID key:(NSString *)key {
    if (!_shows[@(viewID)]) return;
    [_events removeObjectForKey:@(viewID)];
    NSMutableArray *list = _parked[key] ?: (_parked[key] = [NSMutableArray array]);
    [list addObject:@(viewID)];
    __weak WGHost *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WGHost *h = weakSelf;
        if (!h || ![h->_parked[key] containsObject:@(viewID)]) return; // taken over
        [h->_parked[key] removeObject:@(viewID)];
        [h hideView:viewID];
    });
}

- (NSDictionary *)adoptViewWithKey:(NSString *)key events:(void (^)(NSDictionary *))events {
    NSNumber *viewID = _parked[key].lastObject;
    if (!viewID) return nil;
    [_parked[key] removeLastObject];
    _events[viewID] = [events copy];
    NSMutableDictionary *taken = [@{ WGView : viewID, @"request" : _shows[viewID] ?: @{}, @"drawn" : @([_drawnViews containsObject:viewID]) } mutableCopy];
    if (_contextIDs[viewID]) taken[@"context"] = _contextIDs[viewID];
    return taken;
}

- (void)tapView:(NSInteger)viewID point:(CGPoint)point result:(void (^)(NSString *, NSDictionary *))result {
    if (!_running || !_shows[@(viewID)]) {
        result(@"failed", @{});
        return;
    }
    void (^previous)(NSString *, NSDictionary *) = _tapWaiters[@(viewID)];
    if (previous) previous(@"failed", @{});
    __block BOOL answered = NO;
    void (^once)(NSString *, NSDictionary *) = [^(NSString *r, NSDictionary *m) {
        if (answered) return;
        answered = YES;
        result(r, m);
    } copy];
    _tapWaiters[@(viewID)] = once;
    [self send:@{ WGOp : @"tap", WGView : @(viewID), @"x" : @(point.x), @"y" : @(point.y) }];
    // No answer (a busy or stuck host): as a tap outside any control.
    __weak WGHost *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WGHost *h = weakSelf;
        if (answered) return;
        if (h && h->_tapWaiters[@(viewID)] == once) [h->_tapWaiters removeObjectForKey:@(viewID)];
        once(@"failed", @{});
    });
}

- (void)request:(NSDictionary *)message timeout:(NSTimeInterval)timeout reply:(void (^)(NSDictionary *))reply {
    if (![self start]) {
        reply(nil);
        return;
    }
    NSNumber *req = @(++_lastRequest);
    __block BOOL answered = NO;
    void (^once)(NSDictionary *) = [^(NSDictionary *m) {
        if (answered) return;
        answered = YES;
        reply(m);
    } copy];
    _replyWaiters[req] = once;
    NSMutableDictionary *m = [message mutableCopy];
    m[@"req"] = req;
    [self send:m];
    __weak WGHost *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WGHost *h = weakSelf;
        if (answered) return;
        if (h) [h->_replyWaiters removeObjectForKey:req];
        once(nil);
    });
}

+ (void)restartAll {
    for (WGHost *h in gHosts.allValues) {
        h.disabled = NO;
        [h->_quickEnds removeAllObjects];
        if (h->_running) {
            [h send:@{ WGOp : @"quit" }]; // its end restarts it and shows its widgets again
        } else if (h->_shows.count) {
            for (NSDictionary *show in h->_shows.allValues) [h send:show];
        }
    }
}

+ (void)diagnosticLogChanged {
    BOOL on = WGLogEnabled();
    for (WGHost *h in gHosts.allValues) {
        if (h->_running) [h send:@{ WGOp : @"log", @"on" : @(on) }];
    }
}

@end
