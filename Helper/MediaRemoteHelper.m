// Streams the system Now Playing state as JSON lines on stdout and accepts commands on stdin.
// macOS only serves MediaRemote to Apple-entitled processes, so this dylib is hosted inside
// /usr/bin/perl (see media-remote.pl) and NotchApp talks to that process over pipes.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*ClientBundleFn)(id);
typedef Boolean (*SendCommandFn)(int, CFDictionaryRef);
typedef void (*SetElapsedFn)(double);
typedef id (*GetOriginFn)(void);
typedef void (*GetSupportedFn)(id, dispatch_queue_t, void (^)(NSArray *));
typedef int (*CommandInfoCmdFn)(id);
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*CommandInfoEnabledFn)(id);

// MRMediaRemoteCommand ids (checked with MRMediaRemoteCopyCommandDescription on macOS 27).
enum {
    kCmdTogglePlayPause = 2, kCmdNext = 4, kCmdPrevious = 5,
    kCmdAdvanceShuffle = 6, kCmdAdvanceRepeat = 7, kCmdLike = 21,
    kCmdSetRepeatMode = 25, kCmdSetShuffleMode = 26,
};

static GetInfoFn getInfo;
static GetIsPlayingFn getIsPlaying;
static GetClientFn getClient;
static ClientBundleFn clientBundle, clientParentBundle;
static SendCommandFn sendCommand;
static SetElapsedFn setElapsed;
static GetOriginFn getLocalOrigin;
static GetSupportedFn getSupported;
static CommandInfoCmdFn commandInfoCommand;
static CommandInfoEnabledFn commandInfoEnabled;
static RegisterFn registerForNotifications;
static NSString *lastLine;
static NSString *lastArtworkKey;

static void emit(NSDictionary *obj) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!d) return;
    fwrite(d.bytes, 1, d.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void poll(void) {
    getInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
        getIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
            void (^finish)(NSString *, NSArray *) = ^(NSString *bundle, NSArray *commandInfos) {
                NSMutableDictionary *o = [NSMutableDictionary dictionary];
                NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"] ?: @"";
                NSString *artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
                NSString *album = info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @"";
                o[@"title"] = title; o[@"artist"] = artist; o[@"album"] = album;
                o[@"playing"] = @(playing);
                o[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
                o[@"elapsed"] = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] ?: @0;
                o[@"rate"] = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] ?: @0;
                NSDate *ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                o[@"timestamp"] = @(ts ? ts.timeIntervalSince1970 : NSDate.date.timeIntervalSince1970);
                o[@"bundle"] = bundle ?: @"";

                // Shuffle / repeat / like state when the source exposes it (MRMediaRemoteShuffleMode:
                // 1 off, 2 albums, 3 songs; MRMediaRemoteRepeatMode: 1 off, 2 one, 3 all).
                id shuffle = info[@"kMRMediaRemoteNowPlayingInfoShuffleMode"];
                id repeat = info[@"kMRMediaRemoteNowPlayingInfoRepeatMode"];
                id liked = info[@"kMRMediaRemoteNowPlayingInfoIsLiked"];
                NSMutableArray *enabled = [NSMutableArray array];
                for (id ci in commandInfos) {
                    if (commandInfoEnabled && !commandInfoEnabled(ci)) continue;
                    int c = commandInfoCommand(ci);
                    [enabled addObject:@(c)];
                    // Some sources report the current mode only in the Set*Mode command's options.
                    if ((c == kCmdSetShuffleMode && !shuffle) || (c == kCmdSetRepeatMode && !repeat)) {
                        NSDictionary *opts = [ci respondsToSelector:@selector(options)] ? [ci valueForKey:@"options"] : nil;
                        NSString *needle = c == kCmdSetShuffleMode ? @"ShuffleMode" : @"RepeatMode";
                        if ([opts isKindOfClass:NSDictionary.class]) for (NSString *k in opts) {
                            if ([k isKindOfClass:NSString.class] && [k containsString:needle]
                                && [opts[k] isKindOfClass:NSNumber.class]) {
                                if (c == kCmdSetShuffleMode) shuffle = opts[k]; else repeat = opts[k];
                                break;
                            }
                        }
                    }
                }
                if ([shuffle isKindOfClass:NSNumber.class]) o[@"shuffle"] = shuffle;
                if ([repeat isKindOfClass:NSNumber.class]) o[@"repeat"] = repeat;
                if ([liked isKindOfClass:NSNumber.class]) o[@"liked"] = liked;
                if (commandInfos) o[@"commands"] = [enabled sortedArrayUsingSelector:@selector(compare:)];

                NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                NSString *artKey = [NSString stringWithFormat:@"%@|%@|%@|%lu", title, artist, album, (unsigned long)art.length];
                BOOL artChanged = ![artKey isEqualToString:lastArtworkKey ?: @""];

                NSData *base = [NSJSONSerialization dataWithJSONObject:o options:NSJSONWritingSortedKeys error:nil];
                NSString *line = [[NSString alloc] initWithData:base encoding:NSUTF8StringEncoding];
                if (!artChanged && [line isEqualToString:lastLine ?: @""]) return;
                lastLine = line;
                if (artChanged) {
                    lastArtworkKey = artKey;
                    o[@"artwork"] = art.length ? [art base64EncodedStringWithOptions:0] : @"";
                }
                emit(o);
            };
            void (^withCommands)(NSString *) = ^(NSString *bundle) {
                if (!getSupported || !getLocalOrigin || !commandInfoCommand) { finish(bundle, nil); return; }
                getSupported(getLocalOrigin(), dispatch_get_main_queue(), ^(NSArray *infos) {
                    finish(bundle, infos ?: @[]);
                });
            };
            if (!getClient) { withCommands(nil); return; }
            getClient(dispatch_get_main_queue(), ^(id client) {
                NSString *b = nil;
                if (client && clientParentBundle) b = (__bridge NSString *)clientParentBundle(client);
                if (!b.length && client && clientBundle) b = (__bridge NSString *)clientBundle(client);
                withCommands(b);
            });
        });
    });
}

/// Coalesces a burst of MediaRemote notifications (info + isPlaying + app change usually arrive
/// together) into one query. Main queue only.
static BOOL pollScheduled;
static void schedulePoll(void) {
    if (pollScheduled) return;
    pollScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        pollScheduled = NO;
        poll();
    });
}

static void readCommands(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char buf[256];
        while (fgets(buf, sizeof buf, stdin)) {
            NSString *cmd = [[NSString stringWithUTF8String:buf]
                             stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([cmd isEqualToString:@"toggle"]) sendCommand(kCmdTogglePlayPause, NULL);
                else if ([cmd isEqualToString:@"next"]) sendCommand(kCmdNext, NULL);
                else if ([cmd isEqualToString:@"previous"]) sendCommand(kCmdPrevious, NULL);
                else if ([cmd isEqualToString:@"shuffle"]) sendCommand(kCmdAdvanceShuffle, NULL);
                else if ([cmd isEqualToString:@"repeat"]) sendCommand(kCmdAdvanceRepeat, NULL);
                else if ([cmd isEqualToString:@"like"]) sendCommand(kCmdLike, NULL);
                else if ([cmd hasPrefix:@"setshuffle "] || [cmd hasPrefix:@"setrepeat "]) {
                    BOOL sh = [cmd hasPrefix:@"setshuffle "];
                    int mode = [[cmd substringFromIndex:sh ? 11 : 10] intValue];
                    NSDictionary *opt = @{(sh ? @"kMRMediaRemoteOptionShuffleMode" : @"kMRMediaRemoteOptionRepeatMode"): @(mode)};
                    sendCommand(sh ? kCmdSetShuffleMode : kCmdSetRepeatMode, (__bridge CFDictionaryRef)opt);
                }
                else if ([cmd hasPrefix:@"seek "] && setElapsed) setElapsed([[cmd substringFromIndex:5] doubleValue]);
                // Shuffle/repeat/like and command availability don't always post a notification.
                schedulePoll();
            });
        }
        exit(0); // parent closed the pipe: NotchApp quit
    });
}

/// Reads an exported `CFStringRef` constant, falling back to its (identical) literal value.
static NSString *notificationName(void *h, const char *sym) {
    CFStringRef *p = (CFStringRef *)dlsym(h, sym);
    return p && *p ? (__bridge NSString *)*p : [NSString stringWithUTF8String:sym];
}

// Installed as a perl XSUB; the arguments perl passes are ignored. Never returns.
void notchapp_media_stream(void *a, void *b) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!h) { fprintf(stderr, "MediaRemote unavailable\n"); exit(2); }
    getInfo = (GetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    getIsPlaying = (GetIsPlayingFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getClient = (GetClientFn)dlsym(h, "MRMediaRemoteGetNowPlayingClient");
    clientBundle = (ClientBundleFn)dlsym(h, "MRNowPlayingClientGetBundleIdentifier");
    clientParentBundle = (ClientBundleFn)dlsym(h, "MRNowPlayingClientGetParentAppBundleIdentifier");
    sendCommand = (SendCommandFn)dlsym(h, "MRMediaRemoteSendCommand");
    setElapsed = (SetElapsedFn)dlsym(h, "MRMediaRemoteSetElapsedTime");
    getLocalOrigin = (GetOriginFn)dlsym(h, "MRMediaRemoteGetLocalOrigin");
    getSupported = (GetSupportedFn)dlsym(h, "MRMediaRemoteGetSupportedCommandsForOrigin");
    commandInfoCommand = (CommandInfoCmdFn)dlsym(h, "MRMediaRemoteCommandInfoGetCommand");
    commandInfoEnabled = (CommandInfoEnabledFn)dlsym(h, "MRMediaRemoteCommandInfoGetEnabled");
    registerForNotifications = (RegisterFn)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getIsPlaying || !sendCommand) { fprintf(stderr, "MediaRemote symbols missing\n"); exit(2); }

    readCommands();

    // Push: MediaRemote posts these on the default center once registered. Elapsed time isn't
    // streamed (NotchApp extrapolates from elapsed+timestamp+rate); seeks post InfoDidChange.
    BOOL pushed = NO;
    if (registerForNotifications) {
        registerForNotifications(dispatch_get_main_queue());
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        const char *names[] = {
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        };
        for (size_t i = 0; i < sizeof names / sizeof *names; i++) {
            [nc addObserverForName:notificationName(h, names[i]) object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *n) { schedulePoll(); }];
        }
        pushed = YES;
    }
    poll();

    // Safety net for sources/state that change without a notification (e.g. supported commands).
    // Without push support, fall back to the old fast poll.
    uint64_t interval = pushed ? 5 * NSEC_PER_SEC : 500 * NSEC_PER_MSEC;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, interval), interval, interval / 5);
    dispatch_source_set_event_handler(timer, ^{ poll(); });
    dispatch_resume(timer);
    CFRunLoopRun();
}
