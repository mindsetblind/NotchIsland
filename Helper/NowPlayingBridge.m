// Reads the system "Now Playing" (what a browser tab with YouTube is playing) and sends
// play/pause/next/previous and seeks to it.
//
// Since macOS 15.4 MediaRemote answers only Apple-signed processes, so NotchIsland can't ask
// directly. This library is loaded into /usr/bin/perl (Apple-signed) by BrowserMedia.swift:
//   perl -e '<load + call>' NowPlayingBridge.dylib np_stream   → one JSON line per change, forever
//   NP_COMMAND=2 perl -e '…' NowPlayingBridge.dylib np_send    → sends one command and exits
// The functions are installed as Perl XSUBs; they never return to Perl (they exit instead).

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <libproc.h>
#import <stdio.h>
#import <unistd.h>

typedef void (*MRGetInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetPID)(dispatch_queue_t, void (^)(int));
typedef void (*MRRegister)(dispatch_queue_t);
typedef Boolean (*MRSend)(int, NSDictionary *);
typedef void (*MRSendToApp)(int, NSDictionary *, id origin, NSString *bundleID, int appOptions,
                            dispatch_queue_t, void (^)(id error, id statuses));
typedef void (*MRGetClients)(dispatch_queue_t, void (^)(NSArray *));

@interface NSObject (MediaRemote)
+ (id)localOrigin;                 // MROrigin
- (NSString *)bundleIdentifier;    // MRClient
@end

static void *mr(const char *name) {
    static void *handle;
    if (!handle) handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    return handle ? dlsym(handle, name) : NULL;
}

static NSString *bundleIDForPID(int pid) {
    if (pid <= 0) return nil;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof path) <= 0) return nil;
    // …/Foo.app/Contents/MacOS/Foo (or a helper inside it): the outermost .app is the browser.
    NSString *p = [NSString stringWithUTF8String:path];
    NSRange r = [p rangeOfString:@".app/"];
    if (r.location == NSNotFound) return nil;
    return [NSBundle bundleWithPath:[p substringToIndex:r.location + 4]].bundleIdentifier;
}

static void writeLine(NSDictionary *d) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    if (fflush(stdout) != 0) exit(0);   // NotchIsland is gone
}

static NSString *lastArtworkID;

static void emit(void) {
    MRGetInfo getInfo = (MRGetInfo)mr("MRMediaRemoteGetNowPlayingInfo");
    MRGetPID getPID = (MRGetPID)mr("MRMediaRemoteGetNowPlayingApplicationPID");
    MRGetClients getClients = (MRGetClients)mr("MRMediaRemoteGetNowPlayingClients");
    if (!getInfo || !getPID || !getClients) return;
    // Every app that has media right now (e.g. Spotify *and* a browser), not only the shown one:
    // NotchIsland keeps a paused video around while Spotify is the system's "now playing".
    getClients(dispatch_get_main_queue(), ^(NSArray *list) {
    NSMutableArray *clients = [NSMutableArray array];
    for (id c in list) {
        NSString *b = [c respondsToSelector:@selector(bundleIdentifier)] ? [c bundleIdentifier] : nil;
        if ([b isKindOfClass:NSString.class]) [clients addObject:b];
    }
    getPID(dispatch_get_main_queue(), ^(int pid) {
        getInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
            NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
            if (![title isKindOfClass:NSString.class] || title.length == 0) {
                lastArtworkID = nil;
                writeLine(@{ @"none": @YES, @"clients": clients });
                return;
            }
            NSMutableDictionary *o = [NSMutableDictionary dictionary];
            o[@"title"] = title;
            o[@"artist"] = [info[@"kMRMediaRemoteNowPlayingInfoArtist"] isKindOfClass:NSString.class] ? info[@"kMRMediaRemoteNowPlayingInfoArtist"] : @"";
            o[@"album"] = [info[@"kMRMediaRemoteNowPlayingInfoAlbum"] isKindOfClass:NSString.class] ? info[@"kMRMediaRemoteNowPlayingInfoAlbum"] : @"";
            double duration = [info[@"kMRMediaRemoteNowPlayingInfoDuration"] doubleValue];
            double elapsed = [info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] doubleValue];
            double rate = [info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] doubleValue];
            // Elapsed time is as of the info's timestamp: bring it up to now.
            NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            if (rate > 0 && [stamp isKindOfClass:NSDate.class]) elapsed += -stamp.timeIntervalSinceNow * rate;
            o[@"duration"] = @(duration);
            o[@"elapsed"] = @(duration > 0 ? MIN(elapsed, duration) : elapsed);
            o[@"rate"] = @(rate);
            o[@"pid"] = @(pid);
            o[@"clients"] = clients;
            NSString *bundleID = bundleIDForPID(pid);
            if (bundleID) o[@"bundleID"] = bundleID;
            NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            if ([art isKindOfClass:NSData.class] && art.length > 0) {
                NSString *artID = info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"];
                if (![artID isKindOfClass:NSString.class]) artID = [NSString stringWithFormat:@"%@|%lu", title, (unsigned long)art.length];
                o[@"artworkID"] = artID;
                // The picture itself only when it changed: it's ~100 KB per line.
                if (![artID isEqualToString:lastArtworkID]) {
                    o[@"artwork"] = [art base64EncodedStringWithOptions:0];
                    lastArtworkID = artID;
                }
            }
            writeLine(o);
        });
    });
    });
}

void np_stream(void *perl, void *cv) {
    (void)perl; (void)cv;
    MRRegister reg = (MRRegister)mr("MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!reg) exit(2);
    reg(dispatch_get_main_queue());
    __block dispatch_block_t pending;
    void (^changed)(NSNotification *) = ^(NSNotification *n) {
        (void)n;
        // Several notifications arrive per change: coalesce them.
        if (pending) dispatch_block_cancel(pending);
        pending = dispatch_block_create(0, ^{ emit(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), pending);
    };
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    for (NSString *name in @[ @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                              @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                              @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                              @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange" ]) {
        [nc addObserverForName:name object:nil queue:nil usingBlock:changed];
    }
    // A safety net for missed notifications, and quit when NotchIsland is gone.
    pid_t parent = getppid();
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), 15 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        if (getppid() != parent) exit(0);
        emit();
    });
    dispatch_resume(timer);
    emit();
    CFRunLoopRun();
    exit(0);
}

void np_send(void *perl, void *cv) {
    (void)perl; (void)cv;
    const char *cmd = getenv("NP_COMMAND");
    const char *app = getenv("NP_APP");
    if (!cmd) exit(2);
    // NP_POSITION (seconds) goes with command 24, SeekToPlaybackPosition.
    NSDictionary *options = nil;
    const char *pos = getenv("NP_POSITION");
    if (pos) {
        NSString *const *key = (NSString *const *)mr("kMRMediaRemoteOptionPlaybackPosition");
        options = @{ key ? *key : @"kMRMediaRemoteOptionPlaybackPosition": @(atof(pos)) };
    }
    // To one app by bundle ID: pausing the video must not pause Spotify, whichever the system shows.
    MRSendToApp sendToApp = (MRSendToApp)mr("MRMediaRemoteSendCommandToApp");
    Class origin = NSClassFromString(@"MROrigin");
    if (app && sendToApp && origin) {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        sendToApp(atoi(cmd), options, [origin localOrigin], [NSString stringWithUTF8String:app], 0,
                  dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(id error, id statuses) {
            (void)error; (void)statuses;
            dispatch_semaphore_signal(done);
        });
        exit(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0 ? 0 : 1);
    }
    MRSend send = (MRSend)mr("MRMediaRemoteSendCommand");
    if (!send) exit(2);
    Boolean ok = send(atoi(cmd), options);
    // The command goes out asynchronously: give it a moment before the process ends.
    usleep(150 * 1000);
    exit(ok ? 0 : 1);
}
