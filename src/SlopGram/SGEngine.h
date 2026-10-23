#import <Foundation/Foundation.h>

// SlopGram's friction engine: one per app launch, no settings.
//
// A launch starts "cold": the first time Reels are opened you sit through a
// wait. After that every reel (and every screen of home feed) costs one unit
// from a short free run. When the run is empty a roulette decides whether you
// get another run. Lose, or hit a random freeze, and Reels + feed stay locked
// until Instagram is restarted, which costs another (longer) cold wait.
//
// The schedule is front-loaded: the first gate comes fast, a win buys a longer
// stretch, then gates come fast again and the odds keep shrinking.

typedef NS_ENUM(NSInteger, SGGameState) {
    SGGameStateFree,         // scrolling allowed, units counting down
    SGGameStateSpinPending,  // run is empty, roulette must be spun
    SGGameStateLocked        // locked until the process dies
};

typedef NS_ENUM(NSInteger, SGLockReason) {
    SGLockReasonNone,
    SGLockReasonRoulette,
    SGLockReasonFreeze
};

typedef NS_ENUM(NSInteger, SGUnitResult) {
    SGUnitResultIgnored,     // not counting right now
    SGUnitResultCounted,     // still free
    SGUnitResultSpin,        // run just ran out
    SGUnitResultFreeze       // random freeze, now locked
};

extern NSNotificationName const SGEngineDidChangeNotification;

@interface SGEngine : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) SGGameState state;
@property (nonatomic, readonly) SGLockReason lockReason;
@property (nonatomic, readonly) NSInteger wins;          // spins won this launch
@property (nonatomic, readonly) NSInteger unitsLeft;     // left in the current free run
@property (nonatomic, readonly) NSInteger unitsSeen;     // reels + feed screens this launch
@property (nonatomic, readonly) BOOL coldStartServed;

// Cold start
- (NSTimeInterval)coldStartDuration;          // fixed for this launch once first asked
- (NSTimeInterval)coldStartRemaining;         // starts the clock if it isn't running
- (void)coldStartAbandoned;                   // left the screen: clock resets
- (NSInteger)coldStartsInLastHour;            // including this launch's, once begun

// Scrolling
- (SGUnitResult)registerUnit;

// Roulette
- (double)currentWinChance;
- (BOOL)isNight;                              // midnight to 6 am: roulette pays half as often
- (BOOL)spin;                                 // only valid in SpinPending
- (double)survivalChanceOfCurrentStreak;      // product of the odds already beaten

// Wait the next cold start will cost if Instagram is restarted now
- (NSTimeInterval)nextColdStartDuration;

// Testing: deterministic randomness and faster clocks (never set in Instagram)
+ (double)timeScale;
- (void)resetForTesting;

@end
