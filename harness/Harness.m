// SlopLab: a stand-in Instagram for the simulator. It defines classes with the same names
// SGHooks.xm hooks (IGUnifiedVideoCollectionView, IGSundialFeedViewController,
// IGMainFeedListAdapterDataSource) so the real hooks + gate + engine + overlay run unchanged.
// Launch with -SGAutotest <scenario> to have it drive itself and log what happened.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import "SGEngine.h"
#import "SGGate.h"
#import "SGOverlayView.h"

// Stands in for Instagram's "update on TestFlight" screen
@interface SLTestFlightUpdateNudgeViewController : UIViewController
@end
@implementation SLTestFlightUpdateNudgeViewController
@end

extern int SGKeychainRewriteCount(void);

// MARK: Logging

static NSString *SLLogPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"sglog.txt"];
}

static CFTimeInterval SLStart;

static void SLLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void SLLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%7.2f %@\n", CACurrentMediaTime() - SLStart, message];
    NSLog(@"[SlopLab] %@", message);
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:SLLogPath()];
    if (!handle) {
        [line writeToFile:SLLogPath() atomically:NO encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [handle seekToEndOfFile];
    [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

static NSURL *SLVideoURL(void) {
    return [[NSBundle mainBundle] URLForResource:@"sample" withExtension:@"mp4"];
}

static UIColor *SLHue(NSInteger i, CGFloat s, CGFloat b) {
    return [UIColor colorWithHue:fmod(i * 0.137, 1.0) saturation:s brightness:b alpha:1];
}

// MARK: Stand-ins for Instagram's classes

@interface IGUnifiedVideoCollectionView : UICollectionView
@end
@implementation IGUnifiedVideoCollectionView
@end

@interface SLReelCell : UICollectionViewCell
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) AVSampleBufferAudioRenderer *audio;
@property (nonatomic, strong) UILabel *label;
@end

@implementation SLReelCell
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        // Reels have sound, and Instagram's own engine plays some of it through a renderer
        _player = [AVPlayer playerWithURL:SLVideoURL()];
        _player.muted = NO;
        _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        _audio = [AVSampleBufferAudioRenderer new];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(loop:) name:AVPlayerItemDidPlayToEndTimeNotification object:_player.currentItem];
        _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
        _playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        _playerLayer.opacity = 0.55;
        [self.contentView.layer addSublayer:_playerLayer];

        _label = [UILabel new];
        _label.font = [UIFont systemFontOfSize:44 weight:UIFontWeightHeavy];
        _label.textColor = UIColor.whiteColor;
        _label.textAlignment = NSTextAlignmentCenter;
        [self.contentView addSubview:_label];

        UIStackView *ufi = [[UIStackView alloc] init];
        ufi.axis = UILayoutConstraintAxisVertical;
        ufi.spacing = 22;
        for (NSString *name in @[@"heart", @"bubble.right", @"paperplane"]) {
            UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:name withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:26]]];
            icon.tintColor = UIColor.whiteColor;
            [ufi addArrangedSubview:icon];
        }
        ufi.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:ufi];
        [NSLayoutConstraint activateConstraints:@[
            [ufi.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [ufi.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-140],
        ]];
    }
    return self;
}
- (void)loop:(NSNotification *)note {
    [self.player seekToTime:kCMTimeZero];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.playerLayer.frame = self.contentView.bounds;
    self.label.frame = self.contentView.bounds;
}
@end

@interface IGSundialFeedViewController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegate>
@property (nonatomic, strong) IGUnifiedVideoCollectionView *pager;
@property (nonatomic, copy) NSString *headerTitle;
@property (nonatomic) NSInteger refreshes;
- (void)_refreshReelsWithParamsForNetworkRequest:(NSInteger)arg1 userDidPullToRefresh:(BOOL)arg2;
@end

@implementation IGSundialFeedViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.scrollDirection = UICollectionViewScrollDirectionVertical;
    layout.minimumLineSpacing = 0;
    _pager = [[IGUnifiedVideoCollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:layout];
    _pager.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _pager.pagingEnabled = YES;
    _pager.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _pager.dataSource = self;
    _pager.delegate = self;
    _pager.showsVerticalScrollIndicator = NO;
    [_pager registerClass:[SLReelCell class] forCellWithReuseIdentifier:@"reel"];
    UIRefreshControl *refresh = [UIRefreshControl new];
    refresh.tintColor = UIColor.whiteColor;
    [refresh addTarget:self action:@selector(pulled:) forControlEvents:UIControlEventValueChanged];
    _pager.refreshControl = refresh;

    // Like Instagram: the pager sits in a container, with an invisible full-screen layer on top
    UIView *stage = [[UIView alloc] initWithFrame:self.view.bounds];
    stage.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [stage addSubview:_pager];
    [self.view addSubview:stage];
    UIView *chrome = [[UIView alloc] initWithFrame:self.view.bounds];
    chrome.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    chrome.backgroundColor = [UIColor colorWithWhite:0 alpha:0.001];
    [self.view addSubview:chrome];

    // Header sits above the pager, like Instagram's
    UIView *header = [UIView new];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:header];
    UILabel *title = [UILabel new];
    title.text = self.headerTitle ?: @"Reels";
    title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    title.textColor = UIColor.whiteColor;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:title];
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:48],
        [title.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [title.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:56],
    ]];
    if (self.navigationController.viewControllers.firstObject != self) {
        UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
        [back setImage:[UIImage systemImageNamed:@"chevron.left" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold]] forState:UIControlStateNormal];
        back.tintColor = UIColor.whiteColor;
        back.translatesAutoresizingMaskIntoConstraints = NO;
        [back addTarget:self action:@selector(back) forControlEvents:UIControlEventTouchUpInside];
        [header addSubview:back];
        [NSLayoutConstraint activateConstraints:@[
            [back.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
            [back.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:12],
            [back.widthAnchor constraintEqualToConstant:40],
            [back.heightAnchor constraintEqualToConstant:40],
        ]];
    } else {
        title.text = @"Reels";
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:YES animated:NO];
}

- (void)back {
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)pulled:(UIRefreshControl *)control {
    [self _refreshReelsWithParamsForNetworkRequest:0 userDidPullToRefresh:YES];
    [control endRefreshing];
}

- (void)_refreshReelsWithParamsForNetworkRequest:(NSInteger)arg1 userDidPullToRefresh:(BOOL)arg2 {
    self.refreshes += 1;
    [self.pager reloadData];
    [self.pager setContentOffset:CGPointZero animated:NO];
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return 500;
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    return collectionView.bounds.size;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    SLReelCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"reel" forIndexPath:indexPath];
    NSInteger n = indexPath.item + self.refreshes * 1000;
    cell.contentView.backgroundColor = SLHue(n, 0.75, 0.55);
    cell.label.text = [NSString stringWithFormat:@"Reel %ld", (long)indexPath.item + 1];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView willDisplayCell:(SLReelCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {
    [cell.player play];
}

- (void)collectionView:(UICollectionView *)collectionView didEndDisplayingCell:(SLReelCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {
    [cell.player pause];
}

@end

// IGListKit-shaped adapter + Instagram's feed data source
@interface SLListAdapter : NSObject
@property (nonatomic, weak) UICollectionView *collectionView;
@end
@implementation SLListAdapter
@end

@interface IGMainFeedListAdapterDataSource : NSObject
- (NSArray *)objectsForListAdapter:(id)adapter;
@end
@implementation IGMainFeedListAdapterDataSource
- (NSArray *)objectsForListAdapter:(id)adapter {
    return @[@"tray", @"posts"];
}
@end

// MARK: Story viewer (must keep working while the feed is locked)

@interface SLStoryViewController : UIViewController
@property (nonatomic, strong) AVPlayer *player;
@end

@implementation SLStoryViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.35 green:0.12 blue:0.45 alpha:1];
    _player = [AVPlayer playerWithURL:SLVideoURL()];
    _player.muted = YES;
    AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:_player];
    layer.frame = self.view.bounds;
    layer.opacity = 0.6;
    [self.view.layer addSublayer:layer];
    UILabel *label = [UILabel new];
    label.text = @"Story";
    label.font = [UIFont systemFontOfSize:40 weight:UIFontWeightHeavy];
    label.textColor = UIColor.whiteColor;
    [label sizeToFit];
    label.center = CGPointMake(self.view.bounds.size.width / 2, 160);
    [self.view addSubview:label];
    [self.view addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)]];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.player play];
}
- (void)close {
    [self.player pause];
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

// MARK: Feed

@interface SLTrayCell : UICollectionViewCell <UICollectionViewDataSource, UICollectionViewDelegate>
@property (nonatomic, strong) UICollectionView *strip;
@property (nonatomic, copy) void (^onTap)(void);
@end

@implementation SLTrayCell
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
        layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
        layout.itemSize = CGSizeMake(76, 96);
        layout.minimumLineSpacing = 10;
        layout.sectionInset = UIEdgeInsetsMake(0, 12, 0, 12);
        _strip = [[UICollectionView alloc] initWithFrame:self.contentView.bounds collectionViewLayout:layout];
        _strip.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _strip.backgroundColor = UIColor.clearColor;
        _strip.showsHorizontalScrollIndicator = NO;
        _strip.dataSource = self;
        _strip.delegate = self;
        [_strip registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"s"];
        [self.contentView addSubview:_strip];
    }
    return self;
}
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section { return 12; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewCell *cell = [cv dequeueReusableCellWithReuseIdentifier:@"s" forIndexPath:indexPath];
    for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];
    UIView *ring = [[UIView alloc] initWithFrame:CGRectMake(5, 4, 66, 66)];
    ring.layer.cornerRadius = 33;
    ring.layer.borderWidth = 3;
    ring.layer.borderColor = [UIColor colorWithRed:0.95 green:0.3 blue:0.5 alpha:1].CGColor;
    UIView *dot = [[UIView alloc] initWithFrame:CGRectInset(ring.bounds, 5, 5)];
    dot.backgroundColor = SLHue(indexPath.item + 3, 0.5, 0.8);
    dot.layer.cornerRadius = dot.bounds.size.width / 2;
    [ring addSubview:dot];
    [cell.contentView addSubview:ring];
    UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(0, 76, 76, 16)];
    name.text = @[@"you", @"alex", @"mara", @"teo", @"ines", @"luca", @"ana", @"rob", @"iza", @"dan", @"eli", @"sam"][indexPath.item];
    name.font = [UIFont systemFontOfSize:12];
    name.textAlignment = NSTextAlignmentCenter;
    [cell.contentView addSubview:name];
    return cell;
}
- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    if (self.onTap) self.onTap();
}
@end

@interface SLPostCell : UICollectionViewCell
@property (nonatomic, strong) UILabel *name;
@property (nonatomic, strong) UIView *media;
@end

@implementation SLPostCell
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        UIView *avatar = [[UIView alloc] initWithFrame:CGRectMake(12, 10, 34, 34)];
        avatar.layer.cornerRadius = 17;
        avatar.backgroundColor = UIColor.systemGray4Color;
        [self.contentView addSubview:avatar];
        _name = [[UILabel alloc] initWithFrame:CGRectMake(56, 10, 240, 34)];
        _name.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        [self.contentView addSubview:_name];
        _media = [UIView new];
        [self.contentView addSubview:_media];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    self.media.frame = CGRectMake(0, 54, w, w * 1.1);
}
@end

@interface SLFeedViewController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) IGMainFeedListAdapterDataSource *dataSource;
@property (nonatomic, strong) SLListAdapter *adapter;
@end

@implementation SLFeedViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Instagram";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.minimumLineSpacing = 8;
    _collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:layout];
    _collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _collectionView.backgroundColor = UIColor.systemBackgroundColor;
    _collectionView.dataSource = self;
    _collectionView.delegate = self;
    [_collectionView registerClass:[SLTrayCell class] forCellWithReuseIdentifier:@"tray"];
    [_collectionView registerClass:[SLPostCell class] forCellWithReuseIdentifier:@"post"];
    [self.view addSubview:_collectionView];

    _dataSource = [IGMainFeedListAdapterDataSource new];
    _adapter = [SLListAdapter new];
    _adapter.collectionView = _collectionView;
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.dataSource objectsForListAdapter:self.adapter];
}
- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)cv { return 2; }
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section { return section == 0 ? 1 : 300; }
- (CGSize)collectionView:(UICollectionView *)cv layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat w = cv.bounds.size.width;
    return indexPath.section == 0 ? CGSizeMake(w, 104) : CGSizeMake(w, 54 + w * 1.1 + 60);
}
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        SLTrayCell *tray = [cv dequeueReusableCellWithReuseIdentifier:@"tray" forIndexPath:indexPath];
        __weak typeof(self) weakSelf = self;
        tray.onTap = ^{ [weakSelf openStory]; };
        return tray;
    }
    SLPostCell *post = [cv dequeueReusableCellWithReuseIdentifier:@"post" forIndexPath:indexPath];
    post.name.text = [NSString stringWithFormat:@"friend_%ld", (long)indexPath.item + 1];
    post.media.backgroundColor = SLHue(indexPath.item + 40, 0.45, 0.85);
    return post;
}
- (void)openStory {
    SLStoryViewController *story = [SLStoryViewController new];
    story.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:story animated:YES completion:nil];
}
@end

// MARK: DMs

@interface SLInboxViewController : UITableViewController
@end

@implementation SLInboxViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Messages";
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"c"];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return 6; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"c" forIndexPath:indexPath];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ sent a reel", @[@"alex", @"mara", @"teo", @"ines", @"luca", @"ana"][indexPath.row]];
    cell.imageView.image = [UIImage systemImageNamed:@"play.rectangle.fill"];
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tv deselectRowAtIndexPath:indexPath animated:YES];
    [self openReelFrom:[tv cellForRowAtIndexPath:indexPath].textLabel.text];
}
- (void)openReelFrom:(NSString *)who {
    IGSundialFeedViewController *viewer = [IGSundialFeedViewController new];
    viewer.headerTitle = who;
    viewer.hidesBottomBarWhenPushed = YES;
    [self.navigationController pushViewController:viewer animated:YES];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:NO];
}
@end

// MARK: Autotest driver

@interface SLDriver : NSObject
@property (nonatomic, weak) UITabBarController *tabs;
@property (nonatomic, strong) NSMutableArray<NSString *> *failures;
@property (nonatomic, strong) NSMutableArray<NSString *> *passes;
@property (nonatomic) NSInteger lastReelsMode;
@property (nonatomic) NSInteger lastFeedMode;
@property (nonatomic) NSInteger lastState;
@end

@implementation SLDriver

- (void)check:(BOOL)ok what:(NSString *)what {
    if (ok) [self.passes addObject:what];
    else [self.failures addObject:what];
    SLLog(@"%@ %@", ok ? @"PASS" : @"FAIL", what);
}

- (void)snap:(NSString *)name {
    // Render in-process too: simctl screenshots lag when the machine is busy
    UIWindow *window = self.tabs.view.window;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:window.bounds];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
    }];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    [UIImagePNGRepresentation(image) writeToFile:[docs stringByAppendingPathComponent:[NSString stringWithFormat:@"inapp-%@.png", name]] atomically:YES];
    SLLog(@"SNAP %@", name);
}

- (void)after:(NSTimeInterval)delay do:(void (^)(void))block {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

- (UINavigationController *)nav:(NSInteger)i {
    return self.tabs.viewControllers[i];
}

- (IGSundialFeedViewController *)frontReels {
    UIViewController *top = ((UINavigationController *)self.tabs.selectedViewController).topViewController;
    return [top isKindOfClass:[IGSundialFeedViewController class]] ? (IGSundialFeedViewController *)top : nil;
}

- (SLFeedViewController *)feed {
    return (SLFeedViewController *)[self nav:0].viewControllers.firstObject;
}

- (NSDictionary *)watcher:(NSString *)surface {
    for (NSDictionary *d in [SGGate debugSnapshot]) {
        if ([d[@"surface"] isEqual:surface] && [d[@"onScreen"] boolValue]) return d;
    }
    for (NSDictionary *d in [SGGate debugSnapshot]) {
        if ([d[@"surface"] isEqual:surface]) return d;
    }
    return nil;
}

- (NSDictionary *)media {
    return [SGGate debugSnapshot].lastObject;
}

- (SGOverlayView *)overlayIn:(UIView *)root {
    if ([root isKindOfClass:[SGOverlayView class]] && root.superview && root.alpha > 0.5) return (SGOverlayView *)root;
    for (UIView *sub in root.subviews.reverseObjectEnumerator) {
        SGOverlayView *found = [self overlayIn:sub];
        if (found) return found;
    }
    return nil;
}

- (NSString *)stateLine {
    SGEngine *e = [SGEngine shared];
    NSArray *states = @[@"free", @"spin", @"locked"];
    return [NSString stringWithFormat:@"state=%@ reason=%ld wins=%ld left=%ld seen=%ld cold=%@ chance=%.2f",
            states[e.state], (long)e.lockReason, (long)e.wins, (long)e.unitsLeft, (long)e.unitsSeen,
            e.coldStartServed ? @"served" : @"pending", [e currentWinChance]];
}

- (void)watchTransitions {
    NSDictionary *reels = [self watcher:@"reels"];
    NSDictionary *feed = [self watcher:@"feed"];
    NSInteger reelsMode = [reels[@"mode"] integerValue];
    NSInteger feedMode = [feed[@"mode"] integerValue];
    NSArray *names = @[@"none", @"coldstart", @"roulette", @"locked", @"frozen", @"feedlocked"];
    if (reelsMode != self.lastReelsMode) {
        SLLog(@"REELS overlay %@ -> %@  %@", names[self.lastReelsMode], names[reelsMode], [self stateLine]);
        self.lastReelsMode = reelsMode;
    }
    if (feedMode != self.lastFeedMode) {
        SLLog(@"FEED overlay %@ -> %@  %@", names[self.lastFeedMode], names[feedMode], [self stateLine]);
        self.lastFeedMode = feedMode;
    }
}

// Behave like a thumb: only scroll when the scroll view would accept a drag
- (BOOL)swipeReel {
    IGSundialFeedViewController *reels = [self frontReels];
    UIScrollView *pager = reels.pager;
    if (!pager) return NO;
    if (!pager.scrollEnabled) {
        SLLog(@"SWIPE blocked (reels)");
        return NO;
    }
    CGFloat h = pager.bounds.size.height;
    NSInteger page = (NSInteger)llround(pager.contentOffset.y / h);
    [pager setContentOffset:CGPointMake(0, (page + 1) * h) animated:YES];
    SLLog(@"SWIPE reels -> page %ld", (long)page + 2);
    return YES;
}

- (BOOL)swipeFeed {
    UIScrollView *cv = [self feed].collectionView;
    if (!cv.scrollEnabled) {
        SLLog(@"SWIPE blocked (feed)");
        return NO;
    }
    [cv setContentOffset:CGPointMake(0, cv.contentOffset.y + cv.bounds.size.height * 0.9) animated:YES];
    SLLog(@"SWIPE feed -> y=%.0f", cv.contentOffset.y);
    return YES;
}

- (void)finish {
    SLLog(@"RESULT %@ passes=%lu failures=%lu %@", self.failures.count ? @"FAIL" : @"PASS",
          (unsigned long)self.passes.count, (unsigned long)self.failures.count, [self.failures componentsJoinedByString:@" | "]);
    SLLog(@"DONE");
}

- (void)run:(NSString *)scenario {
    self.failures = [NSMutableArray array];
    self.passes = [NSMutableArray array];
    SLLog(@"SCENARIO %@ seed=%ld scale=%.2f", scenario, (long)[[NSUserDefaults standardUserDefaults] integerForKey:@"SGSeed"], [SGEngine timeScale]);
    SLLog(@"%@", [self stateLine]);

    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) { [self watchTransitions]; }];

    SEL selector = NSSelectorFromString([NSString stringWithFormat:@"scenario_%@", scenario]);
    if ([self respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(self, selector);
    } else {
        SLLog(@"unknown scenario");
        [self finish];
    }
}

// Waits until the condition holds (polling), then continues
- (void)waitFor:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout label:(NSString *)label then:(void (^)(BOOL ok))next {
    CFTimeInterval start = CACurrentMediaTime();
    __block NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        BOOL ok = condition();
        if (ok || CACurrentMediaTime() - start > timeout) {
            [t invalidate];
            if (!ok) SLLog(@"TIMEOUT waiting for %@", label);
            next(ok);
        }
    }];
    (void)timer;
}

// Keep swiping reels every `interval` until the engine stops being free; stops at the first gate
- (void)swipeReelsUntilGate:(NSTimeInterval)interval then:(void (^)(void))next {
    [NSTimer scheduledTimerWithTimeInterval:interval repeats:YES block:^(NSTimer *t) {
        // The engine decides the spin as the wheel starts turning, so watch for the wheel too
        BOOL wheel = [[self watcher:@"reels"][@"mode"] isEqual:@(SGOverlayModeRoulette)];
        if ([SGEngine shared].state != SGGameStateFree || wheel) {
            [t invalidate];
            next();
            return;
        }
        [self swipeReel];
    }];
}

// Swipes through every gate, letting the roulette play out, until locked
- (void)playReelsToLock:(void (^)(void))done {
    SGEngine *e = [SGEngine shared];
    [self swipeReelsUntilGate:1.0 then:^{
        if (![[self watcher:@"reels"][@"mode"] isEqual:@(SGOverlayModeRoulette)]) {
            done();
            return;
        }
        NSInteger round = e.wins;
        // The gate covers the reel synchronously, so these hold the instant the run ends
        [self check:[[self watcher:@"reels"][@"mode"] isEqual:@(SGOverlayModeRoulette)] what:@"wheel covers reels the instant the run ends"];
        [self check:[[self watcher:@"reels"][@"scrollEnabled"] boolValue] == NO what:@"reels scrolling blocked during roulette"];
        [self check:![self swipeReel] what:@"swipe refused during roulette"];
        [self check:[[self media][@"mediaBlocked"] boolValue] what:@"video paused during roulette"];
        [self check:[[self media][@"audible"] integerValue] == 0 what:@"sound muted during roulette"];
        [self snap:[NSString stringWithFormat:@"roulette-%ld", (long)round]];

        SGOverlayView *overlay = [self overlayIn:[self frontReels].view];
        [self waitFor:^BOOL{ return [@[@"spinning", @"result"] containsObject:overlay.accessibilityValue ?: @""]; } timeout:30 label:@"spin start" then:^(BOOL ok) {
            [self after:1.4 * [SGEngine timeScale] do:^{ [self snap:[NSString stringWithFormat:@"spinning-%ld", (long)round]]; }];
            [self waitFor:^BOOL{ return [overlay.accessibilityValue isEqual:@"result"]; } timeout:60 label:@"spin result" then:^(BOOL ok1) {
                [self snap:[NSString stringWithFormat:@"result-%ld", (long)round]];
                [self waitFor:^BOOL{ return ![[self watcher:@"reels"][@"mode"] isEqual:@(SGOverlayModeRoulette)]; } timeout:60 label:@"roulette to close" then:^(BOOL ok2) {
                    SLLog(@"after spin: %@", [self stateLine]);
                    if (e.state == SGGameStateFree) {
                        [self waitFor:^BOOL{ return [[self watcher:@"reels"][@"scrollEnabled"] boolValue]; } timeout:10 label:@"scroll back" then:^(BOOL ok3) {
                            [self check:ok3 what:@"scrolling back after a win"];
                            [self playReelsToLock:done];
                        }];
                    } else {
                        done();
                    }
                }];
            }];
        }];
    }];
}

// 1. The full reels loop: cold start, runs, roulette, lock, then the feed and stories while locked
- (void)scenario_reels {
    SGEngine *e = [SGEngine shared];
    self.tabs.selectedIndex = 1;
    [self after:1.2 do:^{
        NSDictionary *w = [self watcher:@"reels"];
        [self check:[w[@"mode"] isEqual:@(SGOverlayModeColdStart)] what:@"cold start screen on first Reels open"];
        [self check:![w[@"scrollEnabled"] boolValue] what:@"reels can't scroll during cold start"];
        [self check:[[self media][@"mediaBlocked"] boolValue] what:@"video paused during cold start"];
        [self check:[[self media][@"renderers"] integerValue] > 0 && [[self media][@"audible"] integerValue] == 0 what:@"sound muted during cold start"];
        [self check:[w[@"hasExit"] boolValue] == NO what:@"no exit button on the Reels tab itself"];
        [self check:![self swipeReel] what:@"swipe refused during cold start"];
        [self snap:@"coldstart"];

        CFTimeInterval coldStart = CACurrentMediaTime();
        NSTimeInterval expected = [e coldStartRemaining] * [SGEngine timeScale];
        [self waitFor:^BOOL{ return e.coldStartServed; } timeout:200 label:@"cold start" then:^(BOOL ok) {
            NSTimeInterval took = CACurrentMediaTime() - coldStart;
            SLLog(@"cold start finished %.1fs after the check (clock said %.1fs left)", took, expected);
            [self check:ok && took > expected - 0.5 && took < expected + 1.5 what:@"cold start lasts its full duration"];
            [self after:0.8 do:^{
                NSDictionary *w2 = [self watcher:@"reels"];
                [self check:[w2[@"mode"] isEqual:@(SGOverlayModeNone)] what:@"cold start screen gone"];
                [self check:[w2[@"scrollEnabled"] boolValue] what:@"reels scroll after cold start"];
                [self check:![[self media][@"mediaBlocked"] boolValue] what:@"video plays after cold start"];
                [self check:[[self media][@"audible"] integerValue] > 0 what:@"sound back after cold start"];
                [self check:e.unitsSeen == 1 what:@"first reel counted once"];
                [self snap:@"reels-free"];
                [self playReelsToLock:^{
                    [self afterLockChecks];
                }];
            }];
        }];
    }];
}

- (void)afterLockChecks {
    SGEngine *e = [SGEngine shared];
    // A lost spin shows its result first; wait for the lock screen itself
    [self waitFor:^BOOL{
        NSInteger mode = [[self watcher:@"reels"][@"mode"] integerValue];
        return mode == SGOverlayModeLocked || mode == SGOverlayModeFrozen;
    } timeout:30 label:@"lock screen" then:^(BOOL ok) { [self after:0.5 do:^{
        NSDictionary *w = [self watcher:@"reels"];
        SLLog(@"LOCKED %@", [self stateLine]);
        [self check:e.state == SGGameStateLocked what:@"ends locked"];
        BOOL frozen = e.lockReason == SGLockReasonFreeze;
        [self check:[w[@"mode"] isEqual:@(frozen ? SGOverlayModeFrozen : SGOverlayModeLocked)] what:@"lock screen matches lock reason"];
        [self check:![w[@"scrollEnabled"] boolValue] what:@"reels can't scroll when locked"];
        [self check:![self swipeReel] what:@"swipe refused when locked"];
        [self check:[[self media][@"mediaBlocked"] boolValue] what:@"video paused when locked"];
        BOOL anyPlaying = NO;
        for (NSNumber *rate in [self media][@"playerRates"]) if (rate.floatValue > 0) anyPlaying = YES;
        [self check:!anyPlaying what:@"no player running behind the lock"];
        [self check:[[self media][@"audible"] integerValue] == 0 what:@"sound muted behind the lock"];
        // Instagram trying to unmute while locked doesn't get through
        for (UICollectionViewCell *cell in [self frontReels].pager.visibleCells) {
            ((SLReelCell *)cell).player.muted = NO;
            ((SLReelCell *)cell).audio.muted = NO;
        }
        [self check:[[self media][@"audible"] integerValue] == 0 what:@"unmuting refused while locked"];
        [self snap:frozen ? @"frozen" : @"locked"];

        // Feed is locked too, story tray still reachable
        self.tabs.selectedIndex = 0;
        [self after:1.5 do:^{
            NSDictionary *f = [self watcher:@"feed"];
            [self check:[f[@"mode"] isEqual:@(SGOverlayModeFeedLocked)] what:@"feed locked too"];
            [self check:![f[@"scrollEnabled"] boolValue] what:@"feed can't scroll when locked"];
            CGRect frame = CGRectFromString(f[@"overlayFrame"]);
            UICollectionView *cv = [self feed].collectionView;
            CGFloat trayBottomOnScreen = cv.frame.origin.y + 104 + cv.adjustedContentInset.top;
            SLLog(@"feed overlay %@, tray bottom %.0f", f[@"overlayFrame"], trayBottomOnScreen);
            [self check:fabs(frame.origin.y - trayBottomOnScreen) < 30 what:@"feed lock starts right under the story tray"];
            [self snap:@"feed-locked"];

            // Tap the story tray: hit-test at the tray to be sure nothing covers it
            UIWindow *window = cv.window;
            CGPoint trayPoint = [cv convertPoint:CGPointMake(50, 52) toView:window];
            UIView *hit = [window hitTest:trayPoint withEvent:nil];
            SLTrayCell *tray = (SLTrayCell *)[cv cellForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
            [self check:[hit isDescendantOfView:tray] what:@"story tray is tappable under feed lock"];
            [[self feed] openStory];
            [self after:1.6 do:^{
                SLStoryViewController *story = (SLStoryViewController *)[self feed].presentedViewController;
                [self check:[story isKindOfClass:[SLStoryViewController class]] what:@"story opens"];
                [self check:story.player.rate > 0 what:@"story video plays while reels/feed are locked"];
                [self check:![[self media][@"mediaBlocked"] boolValue] what:@"media not blocked over a story"];
                [self snap:@"story-while-locked"];
                [story close];
                [self after:1.2 do:^{
                    self.tabs.selectedIndex = 2;
                    [self after:1.0 do:^{
                        [self check:[self nav:2].topViewController != nil what:@"messages tab works while locked"];
                        [self snap:@"messages-while-locked"];
                        self.tabs.selectedIndex = 1;
                        [self after:1.2 do:^{
                            NSDictionary *w3 = [self watcher:@"reels"];
                            [self check:[w3[@"mode"] integerValue] == SGOverlayModeLocked || [w3[@"mode"] integerValue] == SGOverlayModeFrozen what:@"still locked after wandering around"];
                            [self finish];
                        }];
                    }];
                }];
            }];
        }];
    }]; }];
}

// 2. Leaving during the cold start resets the clock
- (void)scenario_leave {
    SGEngine *e = [SGEngine shared];
    self.tabs.selectedIndex = 1;
    NSTimeInterval scale = [SGEngine timeScale];
    [self after:e.coldStartDuration * scale * 0.5 do:^{
        double before = [e coldStartRemaining];
        SLLog(@"halfway: %.1f s left", before);
        self.tabs.selectedIndex = 0;
        [self after:2.0 do:^{
            self.tabs.selectedIndex = 1;
            [self after:0.6 do:^{
                double after = [e coldStartRemaining];
                SLLog(@"came back: %.1f s left (duration %.0f)", after, e.coldStartDuration);
                [self check:after > e.coldStartDuration * 0.9 what:@"leaving restarts the cold start clock"];
                [self check:!e.coldStartServed what:@"still not served"];
                [self snap:@"coldstart-restarted"];
                [self finish];
            }];
        }];
    }];
}

// 3. Reels opened from DMs get the same rules, with a way out
- (void)scenario_dm {
    SGEngine *e = [SGEngine shared];
    self.tabs.selectedIndex = 2;
    [self after:1.0 do:^{
        SLInboxViewController *inbox = (SLInboxViewController *)[self nav:2].viewControllers.firstObject;
        [inbox openReelFrom:@"alex sent a reel"];
        [self after:1.2 do:^{
            NSDictionary *w = [self watcher:@"reels"];
            [self check:[w[@"mode"] isEqual:@(SGOverlayModeColdStart)] what:@"cold start on a DM reel too"];
            [self check:[w[@"hasExit"] boolValue] what:@"DM reel offers Not now"];
            [self snap:@"dm-coldstart"];

            SGOverlayView *overlay = [self overlayIn:[self frontReels].view];
            UIButton *exit = nil;
            for (UIView *v in overlay.subviews) if ([v isKindOfClass:[UIButton class]] && !v.hidden) exit = (UIButton *)v;
            [self check:exit != nil what:@"Not now button visible"];
            [exit sendActionsForControlEvents:UIControlEventTouchUpInside];
            [self after:1.0 do:^{
                [self check:[self nav:2].viewControllers.count == 1 what:@"Not now goes back to the chat"];
                [self check:![[self media][@"mediaBlocked"] boolValue] what:@"media unblocked after leaving"];
                [self snap:@"dm-back-in-chat"];

                // Open again and sit it out, then watch reels from the chat
                [inbox openReelFrom:@"mara sent a reel"];
                [self waitFor:^BOOL{ return e.coldStartServed; } timeout:200 label:@"cold start" then:^(BOOL ok) {
                    [self after:0.8 do:^{
                        SLLog(@"DM reel open: %@", [self stateLine]);
                        [self check:e.unitsSeen == 1 what:@"opening a DM reel counts as one reel"];
                        [self snap:@"dm-reel-playing"];
                        // Bounce in and out of shared reels: each opening costs a reel
                        [[self nav:2] popViewControllerAnimated:NO];
                        __block NSInteger opens = 0;
                        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
                            if (e.state != SGGameStateFree || opens >= 25) {
                                [t invalidate];
                                SLLog(@"after %ld re-opens: %@", (long)opens, [self stateLine]);
                                [self check:e.state != SGGameStateFree what:@"hopping between shared reels hits the wall too"];
                                [self after:1.0 do:^{
                                    [self snap:@"dm-gate"];
                                    [self finish];
                                }];
                                return;
                            }
                            if ([self nav:2].viewControllers.count > 1) [[self nav:2] popViewControllerAnimated:NO];
                            [inbox openReelFrom:@"teo sent a reel"];
                            opens += 1;
                        }];
                    }];
                }];
            }];
        }];
    }];
}

// 4. Home feed scrolling feeds the same machine
- (void)scenario_feed {
    SGEngine *e = [SGEngine shared];
    self.tabs.selectedIndex = 0;
    [self after:1.0 do:^{
        [self check:[[self watcher:@"feed"][@"mode"] isEqual:@(SGOverlayModeNone)] what:@"feed open with no cold start"];
        [self check:e.unitsSeen == 0 what:@"first feed screen is free"];
        [self snap:@"feed-free"];
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            if (e.state != SGGameStateFree) {
                [t invalidate];
                SLLog(@"feed gate after %ld screens: %@", (long)e.unitsSeen, [self stateLine]);
                [self after:0.8 do:^{
                    NSDictionary *f = [self watcher:@"feed"];
                    if (e.state == SGGameStateSpinPending) {
                        [self check:[f[@"mode"] isEqual:@(SGOverlayModeRoulette)] what:@"roulette on the feed"];
                        [self snap:@"feed-roulette"];
                        [self waitFor:^BOOL{ return ![[self watcher:@"feed"][@"mode"] isEqual:@(SGOverlayModeRoulette)]; } timeout:30 label:@"feed spin" then:^(BOOL ok) {
                            SLLog(@"after feed spin: %@", [self stateLine]);
                            [self after:1.0 do:^{
                                [self snap:@"feed-after-spin"];
                                [self finish];
                            }];
                        }];
                    } else {
                        // A lost spin still shows its result first, then the lock
                        [self waitFor:^BOOL{ return [[self watcher:@"feed"][@"mode"] isEqual:@(SGOverlayModeFeedLocked)]; } timeout:30 label:@"feed lock" then:^(BOOL ok) {
                            [self check:ok what:@"feed lock covers the feed"];
                            [self check:![[self watcher:@"feed"][@"scrollEnabled"] boolValue] what:@"locked feed can't scroll"];
                            [self check:![self swipeFeed] what:@"feed swipe refused when locked"];
                            [self after:0.6 do:^{
                                [self snap:@"feed-locked"];
                                [self finish];
                            }];
                        }];
                    }
                }];
                return;
            }
            [self swipeFeed];
        }];
    }];
}

// 5. Just show the cold start (for restart escalation checks)
- (void)scenario_cold {
    SGEngine *e = [SGEngine shared];
    self.tabs.selectedIndex = 1;
    [self after:1.5 do:^{
        NSInteger expected = [[NSUserDefaults standardUserDefaults] integerForKey:@"SGExpectCold"];
        SLLog(@"cold start duration %.0f (expected %ld)", e.coldStartDuration, (long)expected);
        if (expected) [self check:llround(e.coldStartDuration) == expected what:[NSString stringWithFormat:@"cold start is %lds", (long)expected]];
        [self snap:[NSString stringWithFormat:@"cold-%ld", (long)llround(e.coldStartDuration)]];
        [self finish];
    }];
}

// 7. Re-signing fixes: login keychain, app group folder, TestFlight nag
- (void)scenario_sideload {
    // Instagram saves its session into Meta's keychain group, which a re-signed app can't use
    NSString *group = @"MH9GU9K5PX.shared";
    NSDictionary *query = @{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                             (__bridge id)kSecAttrService: @"com.slopgram.test",
                             (__bridge id)kSecAttrAccount: @"session",
                             (__bridge id)kSecAttrAccessGroup: group };
    // Control: without the fix, Meta's group really is refused
    OSStatus (*rawAdd)(CFDictionaryRef, CFTypeRef *) = dlsym(RTLD_DEFAULT, "SecItemAdd");
    NSMutableDictionary *raw = [query mutableCopy];
    raw[(__bridge id)kSecValueData] = [@"x" dataUsingEncoding:NSUTF8StringEncoding];
    OSStatus refused = rawAdd((__bridge CFDictionaryRef)raw, NULL);
    SLLog(@"keychain add without the fix: %d", (int)refused);
    [self check:refused == errSecMissingEntitlement what:@"control: Meta's keychain group is refused without the fix"];

    int before = SGKeychainRewriteCount();
    SecItemDelete((__bridge CFDictionaryRef)query);
    NSMutableDictionary *add = [query mutableCopy];
    add[(__bridge id)kSecValueData] = [@"token-123" dataUsingEncoding:NSUTF8StringEncoding];
    OSStatus added = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    SLLog(@"keychain add status %d", (int)added);
    [self check:added == errSecSuccess what:@"login saved despite Meta's keychain group"];

    NSMutableDictionary *read = [query mutableCopy];
    read[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef result = NULL;
    OSStatus found = SecItemCopyMatching((__bridge CFDictionaryRef)read, &result);
    NSString *token = result ? [[NSString alloc] initWithData:(__bridge_transfer NSData *)result encoding:NSUTF8StringEncoding] : nil;
    [self check:found == errSecSuccess && [token isEqual:@"token-123"] what:@"login read back on next launch"];

    OSStatus updated = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)@{ (__bridge id)kSecValueData: [@"token-456" dataUsingEncoding:NSUTF8StringEncoding] });
    [self check:updated == errSecSuccess what:@"login updated"];
    [self check:SecItemDelete((__bridge CFDictionaryRef)query) == errSecSuccess what:@"login deleted on logout"];
    SLLog(@"keychain rewrites %d", SGKeychainRewriteCount() - before);
    [self check:SGKeychainRewriteCount() - before >= 5 what:@"every keychain call went through SlopGram's fix"];

    NSURL *container = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:@"group.com.burbn.instagram"];
    NSURL *probe = [container URLByAppendingPathComponent:@"probe.txt"];
    BOOL wrote = container && [@"ok" writeToURL:probe atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self check:wrote what:@"shared app group folder is writable"];

    NSURL *receipt = [[NSBundle mainBundle] appStoreReceiptURL];
    SLLog(@"receipt %@", receipt.lastPathComponent);
    [self check:![receipt.lastPathComponent isEqual:@"sandboxReceipt"] what:@"app doesn't look like a TestFlight build"];

    UIViewController *top = self.tabs;
    [top presentViewController:[SLTestFlightUpdateNudgeViewController new] animated:NO completion:nil];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"TestFlight Update Available"
                                                                   message:@"Thank you for testing Instagram Beta. Please update the app using TestFlight to access new features and improvements."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [top presentViewController:alert animated:NO completion:nil];
    [self after:0.8 do:^{
        [self check:top.presentedViewController == nil what:@"TestFlight update nag never shows"];
        UIAlertController *normal = [UIAlertController alertControllerWithTitle:@"Delete post?" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [top presentViewController:normal animated:NO completion:nil];
        [self after:0.8 do:^{
            [self check:top.presentedViewController == normal what:@"other pop-ups still show"];
            [self snap:@"sideload"];
            [top dismissViewControllerAnimated:NO completion:^{ [self finish]; }];
        }];
    }];
}

// 6. Pull to refresh costs a reel
- (void)scenario_refresh {
    SGEngine *e = [SGEngine shared];
    self.tabs.selectedIndex = 1;
    [self waitFor:^BOOL{ return e.coldStartServed; } timeout:200 label:@"cold start" then:^(BOOL ok) {
        [self after:0.8 do:^{
            NSInteger before = e.unitsSeen;
            [[self frontReels] _refreshReelsWithParamsForNetworkRequest:0 userDidPullToRefresh:YES];
            [self after:0.8 do:^{
                SLLog(@"refresh: seen %ld -> %ld", (long)before, (long)e.unitsSeen);
                [self check:e.unitsSeen == before + 1 || e.state != SGGameStateFree what:@"refresh costs a unit"];
                [self finish];
            }];
        }];
    }];
}

@end

// MARK: App

@interface SLSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) SLDriver *driver;
@end

@implementation SLSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    UITabBarController *tabs = [UITabBarController new];
    UINavigationController *home = [[UINavigationController alloc] initWithRootViewController:[SLFeedViewController new]];
    home.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Home" image:[UIImage systemImageNamed:@"house"] tag:0];
    UINavigationController *reels = [[UINavigationController alloc] initWithRootViewController:[IGSundialFeedViewController new]];
    reels.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Reels" image:[UIImage systemImageNamed:@"play.rectangle"] tag:1];
    UINavigationController *dms = [[UINavigationController alloc] initWithRootViewController:[SLInboxViewController new]];
    dms.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Messages" image:[UIImage systemImageNamed:@"paperplane"] tag:2];
    tabs.viewControllers = @[home, reels, dms];

    window.rootViewController = tabs;
    [window makeKeyAndVisible];
    self.window = window;

    NSString *scenario = [[NSUserDefaults standardUserDefaults] stringForKey:@"SGAutotest"];
    if (scenario.length) {
        self.driver = [SLDriver new];
        self.driver.tabs = tabs;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.driver run:scenario];
        });
    }
}
@end

@interface SLAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation SLAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    SLStart = CACurrentMediaTime();
    [[NSFileManager defaultManager] removeItemAtPath:SLLogPath() error:nil];
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"SGResetColdStarts"]) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"slopgram.coldStarts"];
    }
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:nil];
    return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    config.delegateClass = [SLSceneDelegate class];
    return config;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([SLAppDelegate class]));
    }
}
