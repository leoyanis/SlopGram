#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, SGOverlayMode) {
    SGOverlayModeNone,
    SGOverlayModeColdStart,   // countdown ring
    SGOverlayModeRoulette,    // the wheel
    SGOverlayModeLocked,      // reels locked until restart
    SGOverlayModeFrozen,      // reels "broke": frozen frame + small pill
    SGOverlayModeFeedLocked   // feed locked, stories tray left reachable
};

@interface SGOverlayView : UIView

@property (nonatomic, readonly) SGOverlayMode mode;

// True while the wheel spins or shows its result; the gate leaves it alone then
@property (nonatomic, readonly, getter=isBusy) BOOL busy;

// Set by the gate every tick; the cold start clock and the wheel only run while visible
@property (nonatomic) BOOL onScreen;

// Shown as "Not now" when set (leave a reels viewer opened from DMs)
@property (nonatomic, copy) void (^exitHandler)(void);

// Called when a spin's result has been shown and the gate should re-evaluate
@property (nonatomic, copy) void (^spinFinished)(void);

- (void)setMode:(SGOverlayMode)mode animated:(BOOL)animated;

// Frame-driven refresh (countdown text, etc.)
- (void)tick;

@end
