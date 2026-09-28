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

static GetInfoFn getInfo;
static GetIsPlayingFn getIsPlaying;
static GetClientFn getClient;
static ClientBundleFn clientBundle, clientParentBundle;
static SendCommandFn sendCommand;
static SetElapsedFn setElapsed;
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
            void (^finish)(NSString *) = ^(NSString *bundle) {
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
            if (!getClient) { finish(nil); return; }
            getClient(dispatch_get_main_queue(), ^(id client) {
                NSString *b = nil;
                if (client && clientParentBundle) b = (__bridge NSString *)clientParentBundle(client);
                if (!b.length && client && clientBundle) b = (__bridge NSString *)clientBundle(client);
                finish(b);
            });
        });
    });
}

static void readCommands(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char buf[256];
        while (fgets(buf, sizeof buf, stdin)) {
            NSString *cmd = [[NSString stringWithUTF8String:buf]
                             stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([cmd isEqualToString:@"toggle"]) sendCommand(2, NULL);
                else if ([cmd isEqualToString:@"next"]) sendCommand(4, NULL);
                else if ([cmd isEqualToString:@"previous"]) sendCommand(5, NULL);
                else if ([cmd hasPrefix:@"seek "] && setElapsed) setElapsed([[cmd substringFromIndex:5] doubleValue]);
                poll();
            });
        }
        exit(0); // parent closed the pipe: NotchApp quit
    });
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
    if (!getInfo || !getIsPlaying || !sendCommand) { fprintf(stderr, "MediaRemote symbols missing\n"); exit(2); }

    readCommands();
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{ poll(); });
    dispatch_resume(timer);
    CFRunLoopRun();
}
