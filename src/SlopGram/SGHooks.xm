// SlopGram's hooks into Instagram. Kept tiny on purpose: everything else lives in SGGate,
// SGEngine and SGOverlayView, which the simulator harness runs as-is.
//
// The internal generator only needs the Objective-C runtime, so this exact file is also
// compiled into the harness, where stand-in classes carry the same names.
%config(generator=internal)

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "SGGate.h"

@interface IGUnifiedVideoCollectionView : UIScrollView
@end

@interface IGSundialFeedViewController : UIViewController
@end

@interface IGMainFeedListAdapterDataSource : NSObject
@end

// Every full-screen reels pager: the Reels tab, reels opened from DMs, profiles and explore
%hook IGUnifiedVideoCollectionView
- (void)didMoveToWindow {
    %orig;
    if (self.window) [SGGate attachScrollView:self surface:SGSurfaceReels];
}

- (void)setScrollEnabled:(BOOL)enabled {
    %orig([SGGate scrollView:self wantsScrollEnabled:enabled]);
}
%end

// Pull to refresh on Reels
%hook IGSundialFeedViewController
- (void)_refreshReelsWithParamsForNetworkRequest:(NSInteger)arg1 userDidPullToRefresh:(BOOL)arg2 {
    [SGGate noteReelsRefreshed];
    %orig(arg1, arg2);
}
%end

// The home feed's list adapter hands us its collection view
%hook IGMainFeedListAdapterDataSource
- (NSArray *)objectsForListAdapter:(id)adapter {
    NSArray *objects = %orig(adapter);
    if ([adapter respondsToSelector:@selector(collectionView)]) {
        id collectionView = [adapter valueForKey:@"collectionView"];
        if ([collectionView isKindOfClass:[UIScrollView class]]) {
            [SGGate attachScrollView:collectionView surface:SGSurfaceFeed];
        }
    }
    return objects;
}
%end

// Keep video paused behind SlopGram's screens
%hook AVPlayer
- (void)play {
    if ([SGGate player:self mayPlayAtRate:1]) %orig;
}

- (void)setRate:(float)rate {
    if ([SGGate player:self mayPlayAtRate:rate]) %orig(rate);
}

- (void)playImmediatelyAtRate:(float)rate {
    if ([SGGate player:self mayPlayAtRate:rate]) %orig(rate);
}

- (void)pause {
    [SGGate playerPaused:self];
    %orig;
}

- (void)setMuted:(BOOL)muted {
    %orig([SGGate media:self wantsMuted:muted]);
}
%end

// Reels sound mostly goes through Meta's own engine, not AVPlayer: mute that too
%hook AVSampleBufferAudioRenderer
- (instancetype)init {
    self = %orig;
    if (self) [SGGate audioRendererCreated:self];
    return self;
}

- (void)setMuted:(BOOL)muted {
    %orig([SGGate media:self wantsMuted:muted]);
}
%end
