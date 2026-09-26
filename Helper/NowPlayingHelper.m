//
//  NowPlayingHelper.m
//  JustHide
//
//  Reads the system-wide Now Playing -- whatever macOS's own player shows,
//  from any app: Music, Spotify, Safari, Chrome, Dia -- and passes it on.
//
//  Why a separate library run inside /usr/bin/perl: since macOS 15.4
//  MediaRemote answers only Apple-signed processes, so JustHide asking
//  directly gets nothing (measured on 27.2: no PID, empty info). /usr/bin/perl
//  is Apple's, and a library it loads asks with perl's identity, which is
//  answered. The same trick as ungive/mediaremote-adapter, written small.
//
//  Protocol, one JSON object per line:
//    out  {"type":"state", "bundle":..., "title":..., "playing":..., ...}
//         {"type":"none"}                     nothing is playing anywhere
//         {"type":"artwork", "id":..., "data":<base64>}
//    in   play | pause | toggle | next | previous
//  End of input means JustHide has gone, and so does this.
//
//  Built by build.sh into Contents/Frameworks/NowPlayingHelper.dylib.
//

#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*MRGetInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetIsPlaying)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetClient)(dispatch_queue_t, void (^)(id));
typedef NSString *(*MRClientString)(id);
typedef void (*MRRegister)(dispatch_queue_t);
typedef Boolean (*MRSend)(int, NSDictionary *);

static MRGetInfo getInfo;
static MRGetIsPlaying getIsPlaying;
static MRGetClient getClient;
static MRClientString clientBundle, clientParentBundle;
static MRSend sendCommand;

static dispatch_queue_t queue;
static NSString *lastArtworkID;
static BOOL refreshPending;

static void emit(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

/// JSON has no infinity: a live stream reports an infinite duration.
static NSNumber *finite(id value) {
    if (![value isKindOfClass:[NSNumber class]]) return nil;
    double d = [value doubleValue];
    return isfinite(d) ? value : nil;
}

static NSString *string(id value) {
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

/// Reads the three things MediaRemote keeps apart and sends them as one.
static void refresh(void) {
    getClient(queue, ^(id client) {
        NSString *bundle = nil;
        if (client) {
            // A web page playing in a browser helper names the browser here.
            if (clientParentBundle) bundle = clientParentBundle(client);
            if (!bundle.length && clientBundle) bundle = clientBundle(client);
        }
        getIsPlaying(queue, ^(Boolean playing) {
            getInfo(queue, ^(NSDictionary *info) {
                NSString *title = string(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
                if (!info || !title.length) {
                    lastArtworkID = nil;
                    emit(@{@"type": @"none"});
                    return;
                }
                NSMutableDictionary *out = [@{
                    @"type": @"state",
                    @"bundle": bundle ?: @"",
                    @"title": title,
                    @"artist": string(info[@"kMRMediaRemoteNowPlayingInfoArtist"]),
                    @"album": string(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]),
                    @"playing": @(playing),
                } mutableCopy];
                NSNumber *duration = finite(info[@"kMRMediaRemoteNowPlayingInfoDuration"]);
                NSNumber *elapsed = finite(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
                NSNumber *rate = finite(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
                NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                if (duration.doubleValue > 0) out[@"duration"] = duration;
                if (elapsed) out[@"elapsed"] = elapsed;
                if (rate) out[@"rate"] = rate;
                if ([stamp isKindOfClass:[NSDate class]]) out[@"timestamp"] = @(stamp.timeIntervalSince1970);

                // Artwork once per picture, not with every play and pause.
                NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                NSString *artworkID = string(info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"]);
                if (!artworkID.length && [artwork isKindOfClass:[NSData class]])
                    artworkID = [NSString stringWithFormat:@"%lu", (unsigned long)artwork.hash];
                out[@"artworkID"] = artworkID;
                emit(out);
                if ([artwork isKindOfClass:[NSData class]] && artwork.length
                    && ![artworkID isEqualToString:lastArtworkID]) {
                    lastArtworkID = artworkID;
                    emit(@{@"type": @"artwork", @"id": artworkID,
                           @"data": [artwork base64EncodedStringWithOptions:0]});
                }
            });
        });
    });
}

/// MediaRemote posts several notifications for one change; one read covers them.
static void scheduleRefresh(void) {
    dispatch_async(queue, ^{
        if (refreshPending) return;
        refreshPending = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), queue, ^{
            refreshPending = NO;
            refresh();
        });
    });
}

static NSString *notificationName(void *handle, const char *symbol) {
    CFStringRef *name = dlsym(handle, symbol);
    return name ? (__bridge NSString *)*name : [NSString stringWithUTF8String:symbol];
}

static void readCommands(void) {
    // MediaRemote's command numbers.
    NSDictionary *commands = @{@"play": @0, @"pause": @1, @"toggle": @2,
                               @"next": @4, @"previous": @5};
    char line[64];
    while (fgets(line, sizeof line, stdin)) {
        NSString *word = [[NSString stringWithUTF8String:line]
                          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSNumber *command = commands[word];
        if (command) sendCommand(command.intValue, nil);
        else if ([word isEqualToString:@"refresh"]) scheduleRefresh();
    }
    exit(0);
}

/// Entry point, called from perl. Never returns.
void justhide_now_playing(void) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) { fprintf(stderr, "MediaRemote not found\n"); exit(2); }
    getInfo = dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getIsPlaying = dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getClient = dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
    clientBundle = dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
    clientParentBundle = dlsym(mr, "MRNowPlayingClientGetParentAppBundleIdentifier");
    sendCommand = dlsym(mr, "MRMediaRemoteSendCommand");
    MRRegister registerForNotifications = dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getIsPlaying || !getClient || !sendCommand || !registerForNotifications) {
        fprintf(stderr, "MediaRemote is missing functions\n");
        exit(3);
    }

    queue = dispatch_queue_create("dev.justhide.nowplaying", DISPATCH_QUEUE_SERIAL);
    registerForNotifications(queue);
    for (NSString *name in @[notificationName(mr, "kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
                             notificationName(mr, "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"),
                             notificationName(mr, "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification")]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) { scheduleRefresh(); }];
    }
    scheduleRefresh();
    [NSThread detachNewThreadWithBlock:^{ readCommands(); }];
    CFRunLoopRun();
}
