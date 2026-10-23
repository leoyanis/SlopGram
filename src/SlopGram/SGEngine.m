#import "SGEngine.h"

NSNotificationName const SGEngineDidChangeNotification = @"SGEngineDidChangeNotification";

static NSString *const kColdStartsKey = @"slopgram.coldStarts";

// Cold start: 30 s, +15 s for every other cold start in the past hour, max 2 min
static const NSTimeInterval kColdStartBase = 30;
static const NSTimeInterval kColdStartStep = 15;
static const NSTimeInterval kColdStartMax = 120;

// The schedule. Stage = spins won so far this launch.
//   0: stop me quick       1-5 units, 6% freeze per unit, 40% to win the spin
//   1: let me for a while  10-20 units, 1.5% freeze,      30%
//   2: stop me quick again 2-5 units,  5% freeze,         20%
//   3+: really hard        1-3 units,  10% freeze,        10%
typedef struct { NSInteger minRun, maxRun; double freeze, win; } SGStage;
static const SGStage kStages[] = {
    { 1, 5,  0.06,  0.40 },
    { 10, 20, 0.015, 0.30 },
    { 2, 5,  0.05,  0.20 },
    { 1, 3,  0.10,  0.10 },
};
static const NSInteger kStageCount = sizeof(kStages) / sizeof(kStages[0]);

// Between midnight and 6 am the roulette pays half as often
static const double kNightWinFactor = 0.5;

@interface SGEngine ()
@property (nonatomic, readwrite) SGGameState state;
@property (nonatomic, readwrite) SGLockReason lockReason;
@property (nonatomic, readwrite) NSInteger wins;
@property (nonatomic, readwrite) NSInteger unitsLeft;
@property (nonatomic, readwrite) NSInteger unitsSeen;
@property (nonatomic, readwrite) BOOL coldStartServed;
@property (nonatomic) NSTimeInterval coldDuration;     // 0 = not decided yet
@property (nonatomic, strong) NSDate *coldDeadline;
@property (nonatomic) BOOL coldStartRecorded;
@property (nonatomic) double streakSurvival;
@end

@implementation SGEngine

+ (instancetype)shared {
    static SGEngine *engine;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        engine = [SGEngine new];
    });
    return engine;
}

+ (double)timeScale {
    double scale = [[NSUserDefaults standardUserDefaults] doubleForKey:@"SGTimeScale"];
    return scale > 0 ? scale : 1.0;
}

static BOOL seededRandom(void) {
    static BOOL seeded;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSInteger seed = [[NSUserDefaults standardUserDefaults] integerForKey:@"SGSeed"];
        if (seed != 0) {
            srand48(seed);
            seeded = YES;
        }
    });
    return seeded;
}

// Uniform in [0, 1)
static double SGRandom(void) {
    if (seededRandom()) return drand48();
    return (double)arc4random_uniform(UINT32_MAX) / (double)UINT32_MAX;
}

static NSInteger SGRandomBetween(NSInteger lo, NSInteger hi) {
    return lo + (NSInteger)floor(SGRandom() * (double)(hi - lo + 1));
}

- (instancetype)init {
    if ((self = [super init])) {
        [self resetForTesting];
    }
    return self;
}

- (void)resetForTesting {
    self.state = SGGameStateFree;
    self.lockReason = SGLockReasonNone;
    self.wins = 0;
    self.unitsSeen = 0;
    self.coldStartServed = NO;
    self.coldDuration = 0;
    self.coldDeadline = nil;
    self.coldStartRecorded = NO;
    self.streakSurvival = 1.0;
    self.unitsLeft = [self freshRun];
}

- (SGStage)stage {
    return kStages[MIN(self.wins, kStageCount - 1)];
}

- (NSInteger)freshRun {
    SGStage stage = [self stage];
    return SGRandomBetween(stage.minRun, stage.maxRun);
}

- (void)changed {
    [[NSNotificationCenter defaultCenter] postNotificationName:SGEngineDidChangeNotification object:self];
}

// MARK: Cold start

- (NSArray<NSDate *> *)recentColdStarts {
    NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:kColdStartsKey];
    NSDate *hourAgo = [NSDate dateWithTimeIntervalSinceNow:-3600];
    NSMutableArray *recent = [NSMutableArray array];
    for (id date in stored) {
        if ([date isKindOfClass:[NSDate class]] && [date compare:hourAgo] == NSOrderedDescending) {
            [recent addObject:date];
        }
    }
    return recent;
}

- (NSInteger)coldStartsInLastHour {
    return [self recentColdStarts].count;
}

- (NSTimeInterval)durationForPriorColdStarts:(NSInteger)prior {
    return MIN(kColdStartBase + kColdStartStep * prior, kColdStartMax);
}

- (NSTimeInterval)coldStartDuration {
    if (self.coldDuration == 0) {
        self.coldDuration = [self durationForPriorColdStarts:[self coldStartsInLastHour]];
    }
    return self.coldDuration;
}

- (NSTimeInterval)nextColdStartDuration {
    NSInteger prior = [self coldStartsInLastHour];
    if (!self.coldStartRecorded) prior += 1;
    return [self durationForPriorColdStarts:prior];
}

- (void)recordColdStart {
    if (self.coldStartRecorded) return;
    self.coldStartRecorded = YES;

    NSMutableArray *recent = [[self recentColdStarts] mutableCopy];
    [recent addObject:[NSDate date]];
    [[NSUserDefaults standardUserDefaults] setObject:recent forKey:kColdStartsKey];
}

- (NSTimeInterval)coldStartRemaining {
    if (self.coldStartServed) return 0;

    NSTimeInterval duration = [self coldStartDuration];
    if (!self.coldDeadline) {
        self.coldDeadline = [NSDate dateWithTimeIntervalSinceNow:duration * [SGEngine timeScale]];
        [self recordColdStart];
    }

    NSTimeInterval remaining = [self.coldDeadline timeIntervalSinceNow] / [SGEngine timeScale];
    if (remaining <= 0) {
        self.coldStartServed = YES;
        self.coldDeadline = nil;
        [self changed];
        return 0;
    }
    return remaining;
}

- (void)coldStartAbandoned {
    if (self.coldStartServed) return;
    self.coldDeadline = nil;
}

// MARK: Scrolling

- (SGUnitResult)registerUnit {
    if (self.state != SGGameStateFree) return SGUnitResultIgnored;

    self.unitsSeen += 1;

    if (SGRandom() < [self stage].freeze) {
        self.state = SGGameStateLocked;
        self.lockReason = SGLockReasonFreeze;
        [self changed];
        return SGUnitResultFreeze;
    }

    self.unitsLeft -= 1;
    if (self.unitsLeft <= 0) {
        self.unitsLeft = 0;
        self.state = SGGameStateSpinPending;
        [self changed];
        return SGUnitResultSpin;
    }

    return SGUnitResultCounted;
}

// MARK: Roulette

- (BOOL)isNight {
    NSInteger hour = [[NSCalendar currentCalendar] component:NSCalendarUnitHour fromDate:[NSDate date]];
    NSNumber *forced = [[NSUserDefaults standardUserDefaults] objectForKey:@"SGForceNight"];
    if (forced) return forced.boolValue;
    return hour < 6;
}

- (double)currentWinChance {
    double chance = [self stage].win;
    if ([self isNight]) chance *= kNightWinFactor;
    return chance;
}

- (BOOL)spin {
    if (self.state != SGGameStateSpinPending) return NO;

    double chance = [self currentWinChance];
    BOOL won = SGRandom() < chance;

    if (won) {
        self.streakSurvival *= chance;
        self.wins += 1;
        self.unitsLeft = [self freshRun];
        self.state = SGGameStateFree;
    } else {
        self.state = SGGameStateLocked;
        self.lockReason = SGLockReasonRoulette;
    }

    [self changed];
    return won;
}

- (double)survivalChanceOfCurrentStreak {
    return self.streakSurvival;
}

@end
