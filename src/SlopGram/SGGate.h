#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

typedef NS_ENUM(NSInteger, SGSurface) {
    SGSurfaceReels,   // any full-screen reels pager: Reels tab, reels opened from DMs, profiles, explore
    SGSurfaceFeed     // home feed
};

// Glue between Instagram's scroll views and SlopGram. Hooks call in here; nothing here knows
// about Instagram's classes beyond UIKit, so the same code runs in the simulator harness.
@interface SGGate : NSObject

+ (void)attachScrollView:(UIScrollView *)scrollView surface:(SGSurface)surface;

// Instagram asks to change scrollEnabled; returns what it should actually be set to
+ (BOOL)scrollView:(UIScrollView *)scrollView wantsScrollEnabled:(BOOL)enabled;

// Pull-to-refresh on reels hands you a fresh pile: that costs a unit
+ (void)noteReelsRefreshed;

// Video gate: players stay paused while a SlopGram screen covers reels
+ (BOOL)player:(AVPlayer *)player mayPlayAtRate:(float)rate;
+ (void)playerPaused:(AVPlayer *)player;

// Sound gate: AVPlayers and audio renderers stay muted while blocked. Returns the value
// setMuted: should actually get.
+ (BOOL)media:(id)media wantsMuted:(BOOL)muted;
+ (void)audioRendererCreated:(AVSampleBufferAudioRenderer *)renderer;

// Testing
+ (NSArray<NSDictionary *> *)debugSnapshot;

@end
