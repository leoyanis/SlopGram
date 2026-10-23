// Engine tests + Monte Carlo of the odds. Runs on macOS:
//   clang -fobjc-arc -framework Foundation -I../src/SlopGram ../src/SlopGram/SGEngine.m EngineTests.m -o /tmp/engine_tests && /tmp/engine_tests
#import <Foundation/Foundation.h>
#import "SGEngine.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL %s:%d  ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void clearColdStarts(void) {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"slopgram.coldStarts"];
}

static void testColdStart(void) {
    clearColdStarts();
    SGEngine *e = [SGEngine shared];
    [e resetForTesting];

    CHECK(e.coldStartDuration == 30, "first cold start should be 30s, got %.0f", e.coldStartDuration);
    CHECK(e.nextColdStartDuration == 45, "next restart before waiting should cost 45s, got %.0f", e.nextColdStartDuration);
    NSTimeInterval remaining = [e coldStartRemaining];
    CHECK(remaining > 29 && remaining <= 30, "remaining %.2f", remaining);
    CHECK(!e.coldStartServed, "not served yet");
    CHECK(e.coldStartsInLastHour == 1, "recorded once, got %ld", (long)e.coldStartsInLastHour);
    CHECK(e.nextColdStartDuration == 45, "next cold start 45s, got %.0f", e.nextColdStartDuration);

    // Abandoning resets the clock
    [e coldStartAbandoned];
    remaining = [e coldStartRemaining];
    CHECK(remaining > 29, "clock restarted, got %.2f", remaining);
    CHECK(e.coldStartsInLastHour == 1, "abandoning must not record a second cold start");

    // Simulated relaunches escalate: 30, 45, 60, ... capped at 120
    NSArray *expected = @[@45, @60, @75, @90, @105, @120, @120];
    for (NSNumber *want in expected) {
        [e resetForTesting];
        CHECK(e.coldStartDuration == want.doubleValue, "escalation want %.0f got %.0f", want.doubleValue, e.coldStartDuration);
        [e coldStartRemaining];
    }
    clearColdStarts();
}

static void testStateMachine(void) {
    SGEngine *e = [SGEngine shared];
    [e resetForTesting];

    CHECK(e.state == SGGameStateFree, "starts free");
    CHECK(e.unitsLeft >= 1 && e.unitsLeft <= 5, "first run is 1-5, got %ld", (long)e.unitsLeft);
    CHECK(![e spin], "can't spin while free");

    // Run until something stops us
    SGUnitResult r = SGUnitResultCounted;
    int guard = 0;
    while (r == SGUnitResultCounted && guard++ < 100) r = [e registerUnit];
    CHECK(r == SGUnitResultSpin || r == SGUnitResultFreeze, "run must end in spin or freeze");
    CHECK([e registerUnit] == SGUnitResultIgnored, "units ignored while gated");

    if (r == SGUnitResultFreeze) {
        CHECK(e.state == SGGameStateLocked && e.lockReason == SGLockReasonFreeze, "freeze locks");
    } else {
        CHECK(e.state == SGGameStateSpinPending, "spin pending");
        BOOL won = [e spin];
        if (won) {
            CHECK(e.state == SGGameStateFree && e.wins == 1, "win frees");
            CHECK(e.unitsLeft >= 10 && e.unitsLeft <= 20, "second run is 10-20, got %ld", (long)e.unitsLeft);
            CHECK(fabs(e.survivalChanceOfCurrentStreak - 0.40) < 1e-9, "one win at 40%% leaves 40%% survival, got %.3f", e.survivalChanceOfCurrentStreak);
        } else {
            CHECK(e.state == SGGameStateLocked && e.lockReason == SGLockReasonRoulette, "loss locks");
        }
    }

    // Once locked, nothing gets you out
    if (e.state == SGGameStateLocked) {
        CHECK(![e spin], "no spinning out of a lock");
        CHECK([e registerUnit] == SGUnitResultIgnored, "locked ignores units");
    }
}

// Plays one launch the way an addict would: always keeps scrolling, always spins.
static NSInteger simulateLaunch(SGEngine *e, NSInteger *spinsOut) {
    [e resetForTesting];
    NSInteger spins = 0;
    while (e.state != SGGameStateLocked) {
        SGUnitResult r = [e registerUnit];
        if (r == SGUnitResultSpin) { spins++; [e spin]; }
    }
    if (spinsOut) *spinsOut = spins;
    return e.unitsSeen;
}

static void monteCarlo(BOOL night) {
    [[NSUserDefaults standardUserDefaults] setBool:night forKey:@"SGForceNight"];
    SGEngine *e = [SGEngine shared];
    const int N = 200000;
    NSInteger total = 0, atLeast10 = 0, atLeast20 = 0, atLeast30 = 0, atLeast50 = 0, atLeast100 = 0, maxSeen = 0;
    NSInteger zeroSpinLocks = 0, firstSpinLosses = 0;
    NSMutableArray *samples = [NSMutableArray arrayWithCapacity:N];

    for (int i = 0; i < N; i++) {
        NSInteger spins = 0;
        NSInteger seen = simulateLaunch(e, &spins);
        total += seen;
        if (seen >= 10) atLeast10++;
        if (seen >= 20) atLeast20++;
        if (seen >= 30) atLeast30++;
        if (seen >= 50) atLeast50++;
        if (seen >= 100) atLeast100++;
        if (seen > maxSeen) maxSeen = seen;
        if (spins == 0) zeroSpinLocks++;
        if (spins == 1 && e.wins == 0) firstSpinLosses++;
        [samples addObject:@(seen)];
    }
    [samples sortUsingSelector:@selector(compare:)];

    printf("\n%s, %d simulated launches, always scrolling, always spinning:\n", night ? "NIGHT (00-06)" : "DAY", N);
    printf("  reels before lock: mean %.1f, median %ld, 90th pct %ld, max %ld\n",
           (double)total / N, (long)[samples[N / 2] integerValue], (long)[samples[N * 9 / 10] integerValue], (long)maxSeen);
    printf("  frozen before first spin: %.1f%%   lost first spin: %.1f%%\n", 100.0 * zeroSpinLocks / N, 100.0 * firstSpinLosses / N);
    printf("  >=10 reels %.1f%%   >=20 %.1f%%   >=30 %.2f%%   >=50 %.3f%%   >=100 %.4f%%\n",
           100.0 * atLeast10 / N, 100.0 * atLeast20 / N, 100.0 * atLeast30 / N, 100.0 * atLeast50 / N, 100.0 * atLeast100 / N);

    if (!night) {
        CHECK((double)atLeast30 / N < 0.06, "doom session (30+) should be rare, got %.2f%%", 100.0 * atLeast30 / N);
        CHECK((double)total / N < 12, "mean should be short, got %.1f", (double)total / N);
    }
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"SGForceNight"];
}

int main(void) {
    @autoreleasepool {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"SGForceNight"];
        testColdStart();
        for (int i = 0; i < 2000; i++) testStateMachine();
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"SGForceNight"];
        monteCarlo(NO);
        monteCarlo(YES);
        printf("\n%s (%d failures)\n", failures ? "FAILED" : "ALL PASSED", failures);
        return failures ? 1 : 0;
    }
}
