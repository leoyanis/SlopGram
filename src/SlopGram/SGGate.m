#import "SGGate.h"
#import "SGEngine.h"
#import "SGOverlayView.h"
#import <objc/runtime.h>

static const void *kWatcherKey = &kWatcherKey;
static const void *kWantsPlayKey = &kWantsPlayKey;
static const void *kWantsMuteKey = &kWantsMuteKey;

// MARK: Watcher

@interface SGWatcher : NSObject
@property (nonatomic, weak) UIScrollView *scrollView;
@property (nonatomic) SGSurface surface;
@property (nonatomic) NSInteger maxIndex;
@property (nonatomic, strong) SGOverlayView *overlay;
@property (nonatomic) BOOL igWantsScroll;
@property (nonatomic) BOOL blocking;
@property (nonatomic) BOOL onScreen;
@property (nonatomic) BOOL hasExit;
@end

@implementation SGWatcher
- (void)dealloc {
    [_overlay removeFromSuperview];
}
@end

static NSHashTable<SGWatcher *> *SGWatchers(void) {
    static NSHashTable *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

// Players and audio renderers get touched from Instagram's media threads, so these two
// tables are only used under @synchronized(table)
static NSHashTable<AVPlayer *> *SGPlayers(void) {
    static NSHashTable *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

static NSHashTable<AVSampleBufferAudioRenderer *> *SGRenderers(void) {
    static NSHashTable *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

static NSArray *SGAll(NSHashTable *table) {
    @synchronized (table) {
        return table.allObjects;
    }
}

static void SGTrack(NSHashTable *table, id object) {
    @synchronized (table) {
        [table addObject:object];
    }
}

static BOOL SGMediaBlocked = NO;
static BOOL SGPausingInternally = NO;
static BOOL SGSettingScroll = NO;
static BOOL SGTicking = NO;
static CFTimeInterval SGColdHiddenSince = 0;

// MARK: Geometry helpers

static BOOL SGIsEligible(UIScrollView *sv, SGSurface surface) {
    UIWindow *window = sv.window;
    if (!window) return NO;
    if (surface == SGSurfaceFeed) return YES;
    // Only full-screen pagers count as reels, not little previews
    return sv.bounds.size.height >= window.bounds.size.height * 0.6 && sv.bounds.size.width >= window.bounds.size.width * 0.8;
}

static UIViewController *SGViewControllerFor(UIView *view);

static BOOL SGIsOnScreen(UIScrollView *sv) {
    UIWindow *window = sv.window;
    if (!window || window.hidden || !sv.superview) return NO;
    for (UIView *view = sv; view; view = view.superview) {
        if (view.hidden || view.alpha < 0.01) return NO;
    }

    CGRect rect = [sv convertRect:sv.bounds toView:window];
    CGRect visible = CGRectIntersection(rect, window.bounds);
    if (CGRectIsNull(visible) || visible.size.width * visible.size.height < rect.size.width * rect.size.height * 0.5) return NO;

    // Something presented on top (stories, comments sheet...) means we're not what the user sees.
    // Chrome Instagram layers over the pager is fine: anything inside our own controller tree counts.
    UIView *hit = [window hitTest:CGPointMake(CGRectGetMidX(visible), CGRectGetMidY(visible)) withEvent:nil];
    if (!hit || [hit isDescendantOfView:sv.superview]) return YES;
    UIViewController *root = SGViewControllerFor(sv);
    while (root.parentViewController) root = root.parentViewController;
    return root.isViewLoaded && [hit isDescendantOfView:root.view];
}

static NSInteger SGPageIndex(UIScrollView *sv, SGSurface surface) {
    CGFloat height = sv.bounds.size.height;
    if (height < 1) return 0;
    CGFloat y = sv.contentOffset.y + sv.adjustedContentInset.top;
    return surface == SGSurfaceReels ? (NSInteger)llround(y / height) : (NSInteger)floor(y / height);
}

// Bottom edge of the story tray (first horizontally scrolling strip near the top of the feed)
static CGFloat SGTrayClearance(UIScrollView *sv) {
    if (![sv isKindOfClass:[UICollectionView class]]) return 0;
    UICollectionView *cv = (UICollectionView *)sv;
    CGFloat best = 0;

    for (UICollectionViewCell *cell in cv.visibleCells) {
        CGRect frame = [cv convertRect:cell.bounds fromView:cell];
        CGFloat top = frame.origin.y - cv.contentOffset.y;
        if (top > cv.bounds.size.height * 0.35 || CGRectGetMaxY(frame) - cv.contentOffset.y <= 0) continue;

        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:cell];
        while (queue.count) {
            UIView *view = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if ([view isKindOfClass:[UIScrollView class]] && view != cv) {
                UIScrollView *inner = (UIScrollView *)view;
                if (inner.contentSize.width > inner.bounds.size.width + 1 && inner.bounds.size.height > 40) {
                    CGRect innerFrame = [cv convertRect:inner.bounds fromView:inner];
                    best = MAX(best, CGRectGetMaxY(innerFrame) - cv.contentOffset.y);
                }
            }
            if (queue.count < 400) [queue addObjectsFromArray:view.subviews];
        }
    }
    return MIN(best, cv.bounds.size.height * 0.45);
}

// MARK: Leaving a reels viewer

static UIViewController *SGViewControllerFor(UIView *view) {
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:[UIViewController class]]) return (UIViewController *)responder;
    }
    return nil;
}

// Returns a block that closes the viewer this scroll view lives in, or nil for tab roots
static void (^SGExitAction(UIScrollView *sv))(void) {
    UIViewController *vc = SGViewControllerFor(sv);
    if (!vc) return nil;

    UIViewController *child = vc;
    while (child.parentViewController && ![child.parentViewController isKindOfClass:[UINavigationController class]]) {
        child = child.parentViewController;
    }
    UINavigationController *nav = (UINavigationController *)child.parentViewController;
    if ([nav isKindOfClass:[UINavigationController class]] && nav.topViewController == child && nav.viewControllers.count > 1) {
        __weak UINavigationController *weakNav = nav;
        return ^{ [weakNav popViewControllerAnimated:YES]; };
    }

    if (vc.tabBarController) return nil;
    for (UIViewController *p = vc; p; p = p.parentViewController) {
        if (p.presentingViewController && p.presentingViewController.presentedViewController == p) {
            __weak UIViewController *weakP = p;
            return ^{ [weakP dismissViewControllerAnimated:YES completion:nil]; };
        }
    }
    return nil;
}

// MARK: Gate

@implementation SGGate

+ (void)startTimerIfNeeded {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSTimer *timer = [NSTimer timerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *t) {
            [SGGate tickAll];
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];

        [[NSNotificationCenter defaultCenter] addObserverForName:SGEngineDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            if ([NSThread isMainThread] && !SGTicking) [SGGate tickAll];
            else dispatch_async(dispatch_get_main_queue(), ^{ [SGGate tickAll]; });
        }];
    });
}

+ (void)attachScrollView:(UIScrollView *)scrollView surface:(SGSurface)surface {
    if (!scrollView) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [SGGate attachScrollView:scrollView surface:surface]; });
        return;
    }
    if (objc_getAssociatedObject(scrollView, kWatcherKey)) return;

    SGWatcher *watcher = [SGWatcher new];
    watcher.scrollView = scrollView;
    watcher.surface = surface;
    watcher.igWantsScroll = scrollView.scrollEnabled;
    // Opening a reel counts as watching it; the feed's first screen is free
    watcher.maxIndex = surface == SGSurfaceReels ? -1 : SGPageIndex(scrollView, surface);
    objc_setAssociatedObject(scrollView, kWatcherKey, watcher, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [SGWatchers() addObject:watcher];

    [self startTimerIfNeeded];
    [self tick:watcher];
}

+ (BOOL)scrollView:(UIScrollView *)scrollView wantsScrollEnabled:(BOOL)enabled {
    SGWatcher *watcher = objc_getAssociatedObject(scrollView, kWatcherKey);
    if (!watcher || SGSettingScroll) return enabled;
    watcher.igWantsScroll = enabled;
    return watcher.blocking ? NO : enabled;
}

+ (void)noteReelsRefreshed {
    [[SGEngine shared] registerUnit];
    for (SGWatcher *watcher in SGWatchers().allObjects) {
        if (watcher.surface == SGSurfaceReels) watcher.maxIndex = 0;
    }
}

// MARK: Ticking

+ (SGOverlayMode)desiredModeFor:(SGSurface)surface {
    SGEngine *engine = [SGEngine shared];
    if (surface == SGSurfaceReels && !engine.coldStartServed) return SGOverlayModeColdStart;

    switch (engine.state) {
        case SGGameStateFree:
            return SGOverlayModeNone;
        case SGGameStateSpinPending:
            return SGOverlayModeRoulette;
        case SGGameStateLocked:
            if (surface == SGSurfaceFeed) return SGOverlayModeFeedLocked;
            return engine.lockReason == SGLockReasonFreeze ? SGOverlayModeFrozen : SGOverlayModeLocked;
    }
    return SGOverlayModeNone;
}

+ (void)tickAll {
    if (SGTicking) return;
    SGTicking = YES;
    BOOL block = NO;
    BOOL coldVisible = NO;
    for (SGWatcher *watcher in SGWatchers().allObjects) {
        [self tick:watcher];
        if (watcher.overlay && watcher.onScreen) block = YES;
        if (watcher.onScreen && watcher.overlay.mode == SGOverlayModeColdStart) coldVisible = YES;
    }
    SGTicking = NO;
    [self setMediaBlocked:block];

    // The cold start clock only runs while you sit and look at it. Switch tabs, back out of
    // a shared reel, whatever: a second away and it starts over.
    SGEngine *engine = [SGEngine shared];
    if (coldVisible || engine.coldStartServed) {
        SGColdHiddenSince = 0;
    } else if (SGColdHiddenSince == 0) {
        SGColdHiddenSince = CACurrentMediaTime();
    } else if (CACurrentMediaTime() - SGColdHiddenSince > 1.0) {
        [engine coldStartAbandoned];
    }
}

+ (void)setBlocking:(BOOL)blocking watcher:(SGWatcher *)watcher {
    UIScrollView *sv = watcher.scrollView;
    if (watcher.blocking == blocking) {
        if (blocking && sv.scrollEnabled) {
            SGSettingScroll = YES;
            sv.scrollEnabled = NO;
            SGSettingScroll = NO;
        }
        return;
    }
    watcher.blocking = blocking;
    SGSettingScroll = YES;
    sv.scrollEnabled = blocking ? NO : watcher.igWantsScroll;
    SGSettingScroll = NO;
}

+ (void)removeOverlay:(SGWatcher *)watcher {
    SGOverlayView *overlay = watcher.overlay;
    if (!overlay) return;
    watcher.overlay = nil;
    [UIView animateWithDuration:0.3 animations:^{
        overlay.alpha = 0;
    } completion:^(BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

+ (void)tick:(SGWatcher *)watcher {
    UIScrollView *sv = watcher.scrollView;
    if (!sv) return;
    SGEngine *engine = [SGEngine shared];

    if (!SGIsEligible(sv, watcher.surface)) {
        watcher.onScreen = NO;
        return;
    }

    BOOL onScreen = SGIsOnScreen(sv);
    watcher.onScreen = onScreen;
    SGOverlayMode want = [self desiredModeFor:watcher.surface];

    if (watcher.overlay.busy) {
        watcher.overlay.onScreen = onScreen;
        return;
    }

    if (want == SGOverlayModeNone) {
        [self removeOverlay:watcher];
        [self setBlocking:NO watcher:watcher];

        if (onScreen && engine.state == SGGameStateFree) {
            NSInteger index = SGPageIndex(sv, watcher.surface);
            while (index > watcher.maxIndex && engine.state == SGGameStateFree) {
                watcher.maxIndex += 1;
                [engine registerUnit];
            }
            watcher.maxIndex = MAX(watcher.maxIndex, index);
            // That reel ended the run: cover it now, not on the next tick
            if (engine.state != SGGameStateFree) {
                [self tick:watcher];
                [self setMediaBlocked:watcher.overlay != nil];
            }
        }
        return;
    }

    UIView *container = sv.superview;
    if (!container) return;

    SGOverlayView *overlay = watcher.overlay;
    if (!overlay || overlay.superview != container) {
        [overlay removeFromSuperview];
        overlay = [[SGOverlayView alloc] initWithFrame:sv.frame];
        __weak SGWatcher *weakWatcher = watcher;
        overlay.spinFinished = ^{
            SGWatcher *strongWatcher = weakWatcher;
            if (strongWatcher) [SGGate tick:strongWatcher];
        };
        [container insertSubview:overlay aboveSubview:sv];
        watcher.overlay = overlay;
        watcher.hasExit = NO;
    }

    if (want == SGOverlayModeFeedLocked && overlay.mode != SGOverlayModeFeedLocked) {
        // Back to the top so the story tray stays in reach
        [sv setContentOffset:CGPointMake(sv.contentOffset.x, -sv.adjustedContentInset.top) animated:YES];
    }
    [overlay setMode:want animated:YES];
    [self setBlocking:YES watcher:watcher];

    CGRect frame = sv.frame;
    if (want == SGOverlayModeFeedLocked) {
        CGFloat clearance = SGTrayClearance(sv);
        frame.origin.y += clearance;
        frame.size.height -= clearance;
    }
    if (!CGRectEqualToRect(overlay.frame, frame)) overlay.frame = frame;

    if (watcher.surface == SGSurfaceReels) {
        void (^exit)(void) = SGExitAction(sv);
        if ((exit != nil) != watcher.hasExit) {
            watcher.hasExit = exit != nil;
            overlay.exitHandler = exit ? ^{
                void (^fresh)(void) = SGExitAction(sv);
                if (fresh) fresh();
            } : nil;
        }
    }

    overlay.onScreen = onScreen;
    // Pause video the moment a screen goes up, not on the next pass
    if (onScreen && !SGMediaBlocked) [self setMediaBlocked:YES];
}

// MARK: Video

static BOOL SGWantsPlay(AVPlayer *player) {
    return [objc_getAssociatedObject(player, kWantsPlayKey) boolValue];
}

static void SGSetWantsPlay(AVPlayer *player, BOOL wants) {
    objc_setAssociatedObject(player, kWantsPlayKey, @(wants), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (BOOL)player:(AVPlayer *)player mayPlayAtRate:(float)rate {
    if (rate <= 0) {
        if (!SGPausingInternally) SGSetWantsPlay(player, NO);
        return YES;
    }
    SGTrack(SGPlayers(), player);
    SGSetWantsPlay(player, YES);
    if (SGMediaBlocked && !player.muted) [self muteMedia:player];
    return !SGMediaBlocked;
}

+ (void)playerPaused:(AVPlayer *)player {
    if (!SGPausingInternally) SGSetWantsPlay(player, NO);
}

// Sound: anything that plays audio gets muted while blocked, and Instagram's own attempts to
// unmute are remembered and applied once the screen goes away.
static BOOL SGMutingInternally = NO;

+ (BOOL)media:(id)media wantsMuted:(BOOL)muted {
    if (SGMutingInternally) return muted;
    objc_setAssociatedObject(media, kWantsMuteKey, @(muted), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([media isKindOfClass:[AVSampleBufferAudioRenderer class]]) SGTrack(SGRenderers(), media);
    return muted || SGMediaBlocked;
}

+ (void)audioRendererCreated:(AVSampleBufferAudioRenderer *)renderer {
    SGTrack(SGRenderers(), renderer);
    if (SGMediaBlocked) [self muteMedia:renderer];
}

+ (void)muteMedia:(id)media {
    // Remember what Instagram had, the first time only
    if (!objc_getAssociatedObject(media, kWantsMuteKey)) {
        objc_setAssociatedObject(media, kWantsMuteKey, @([media isMuted]), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    SGMutingInternally = YES;
    [media setMuted:YES];
    SGMutingInternally = NO;
}

+ (void)unmuteMedia:(id)media {
    NSNumber *wanted = objc_getAssociatedObject(media, kWantsMuteKey);
    if (!wanted) return;
    SGMutingInternally = YES;
    [media setMuted:wanted.boolValue];
    SGMutingInternally = NO;
}

+ (void)setMediaBlocked:(BOOL)blocked {
    if (blocked == SGMediaBlocked) {
        if (blocked) [self pauseAll];
        return;
    }
    SGMediaBlocked = blocked;

    if (blocked) {
        [self pauseAll];
    } else {
        for (AVPlayer *player in SGAll(SGPlayers())) [self unmuteMedia:player];
        for (AVSampleBufferAudioRenderer *renderer in SGAll(SGRenderers())) [self unmuteMedia:renderer];
        for (AVPlayer *player in SGAll(SGPlayers())) {
            if (SGWantsPlay(player) && player.rate == 0) [player play];
        }
    }
}

+ (void)pauseAll {
    SGPausingInternally = YES;
    for (AVPlayer *player in SGAll(SGPlayers())) {
        if (!player.muted) [self muteMedia:player];
        if (player.rate != 0) [player pause];
    }
    SGPausingInternally = NO;
    for (AVSampleBufferAudioRenderer *renderer in SGAll(SGRenderers())) {
        if (!renderer.muted) [self muteMedia:renderer];
    }
}

// MARK: Testing

+ (NSArray<NSDictionary *> *)debugSnapshot {
    NSMutableArray *out = [NSMutableArray array];
    for (SGWatcher *watcher in SGWatchers().allObjects) {
        UIScrollView *sv = watcher.scrollView;
        if (!sv) continue;
        [out addObject:@{
            @"surface": watcher.surface == SGSurfaceReels ? @"reels" : @"feed",
            @"mode": @(watcher.overlay ? watcher.overlay.mode : SGOverlayModeNone),
            @"onScreen": @(watcher.onScreen),
            @"scrollEnabled": @(sv.scrollEnabled),
            @"maxIndex": @(watcher.maxIndex),
            @"index": @(SGPageIndex(sv, watcher.surface)),
            @"hasExit": @(watcher.hasExit),
            @"overlayFrame": watcher.overlay ? NSStringFromCGRect(watcher.overlay.frame) : @"-",
        }];
    }
    NSMutableArray *rates = [NSMutableArray array];
    NSInteger audible = 0;
    for (AVPlayer *player in SGAll(SGPlayers())) {
        [rates addObject:@(player.rate)];
        if (!player.muted) audible++;
    }
    for (AVSampleBufferAudioRenderer *renderer in SGAll(SGRenderers())) {
        if (!renderer.muted) audible++;
    }
    [out addObject:@{ @"mediaBlocked": @(SGMediaBlocked), @"playerRates": rates, @"audible": @(audible),
                      @"renderers": @(SGAll(SGRenderers()).count) }];
    return out;
}

@end
