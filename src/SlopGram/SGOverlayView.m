#import "SGOverlayView.h"
#import "SGEngine.h"

// MARK: Style

static UIColor *SGInk(void)    { return [UIColor colorWithWhite:0.97 alpha:1]; }
static UIColor *SGMuted(void)  { return [UIColor colorWithWhite:1 alpha:0.58]; }
static UIColor *SGFaint(void)  { return [UIColor colorWithWhite:1 alpha:0.34]; }
static UIColor *SGAccent(void) { return [UIColor colorWithRed:1.00 green:0.38 blue:0.27 alpha:1]; }
static UIColor *SGDisc(void)   { return [UIColor colorWithWhite:1 alpha:0.10]; }
static UIColor *SGHub(void)    { return [UIColor colorWithRed:0.07 green:0.07 blue:0.08 alpha:1]; }

static UIFont *SGRounded(CGFloat size, UIFontWeight weight) {
    UIFont *font = [UIFont systemFontOfSize:size weight:weight];
    UIFontDescriptor *descriptor = [font.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    return descriptor ? [UIFont fontWithDescriptor:descriptor size:size] : font;
}

static UILabel *SGLabel(NSString *text, UIFont *font, UIColor *color) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    return label;
}

static UILabel *SGEyebrow(NSString *text) {
    UILabel *label = SGLabel(nil, [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold], SGFaint());
    label.attributedText = [[NSAttributedString alloc] initWithString:text.uppercaseString attributes:@{
        NSKernAttributeName: @(2.4),
        NSFontAttributeName: label.font,
        NSForegroundColorAttributeName: SGFaint()
    }];
    return label;
}

// MARK: Ring

@interface SGRingView : UIView
@property (nonatomic) CGFloat progress;
@property (nonatomic, strong) UILabel *numberLabel;
@property (nonatomic, strong) UILabel *unitLabel;
@end

@implementation SGRingView {
    CAShapeLayer *_track;
    CAShapeLayer *_fill;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _track = [CAShapeLayer layer];
        _track.fillColor = UIColor.clearColor.CGColor;
        _track.strokeColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;
        _track.lineWidth = 7;
        [self.layer addSublayer:_track];

        _fill = [CAShapeLayer layer];
        _fill.fillColor = UIColor.clearColor.CGColor;
        _fill.strokeColor = SGAccent().CGColor;
        _fill.lineWidth = 7;
        _fill.lineCap = kCALineCapRound;
        [self.layer addSublayer:_fill];

        _numberLabel = SGLabel(@"", [UIFont monospacedDigitSystemFontOfSize:64 weight:UIFontWeightSemibold], SGInk());
        UIFontDescriptor *rounded = [_numberLabel.font.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
        if (rounded) _numberLabel.font = [UIFont fontWithDescriptor:rounded size:64];
        _unitLabel = SGLabel(@"seconds", [UIFont systemFontOfSize:13 weight:UIFontWeightMedium], SGMuted());
        [self addSubview:_numberLabel];
        [self addSubview:_unitLabel];
        _progress = 1;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat radius = MIN(b.size.width, b.size.height) / 2 - 6;
    CGPoint c = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    UIBezierPath *path = [UIBezierPath bezierPathWithArcCenter:c radius:radius startAngle:-M_PI_2 endAngle:3 * M_PI_2 clockwise:YES];
    _track.frame = b;
    _fill.frame = b;
    _track.path = path.CGPath;
    _fill.path = path.CGPath;

    [_numberLabel sizeToFit];
    [_unitLabel sizeToFit];
    _numberLabel.center = CGPointMake(c.x, c.y - 6);
    _unitLabel.center = CGPointMake(c.x, CGRectGetMaxY(_numberLabel.frame) + 6);
}

- (void)setProgress:(CGFloat)progress {
    _progress = MAX(0, MIN(1, progress));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fill.strokeEnd = _progress;
    [CATransaction commit];
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(200, 200);
}

@end

// MARK: Wheel

@interface SGWheelView : UIView
@property (nonatomic, readonly) double chance;
- (instancetype)initWithChance:(double)chance;
- (void)spinToWin:(BOOL)win duration:(NSTimeInterval)duration completion:(void (^)(void))completion;
@end

@implementation SGWheelView {
    CALayer *_rotor;
    CAShapeLayer *_disc;
    CAShapeLayer *_wedge;
    CAShapeLayer *_ticks;
    CAShapeLayer *_hub;
    CAShapeLayer *_pointer;
    UILabel *_hubLabel;
    double _keepStart;   // radians, clockwise from 12 o'clock
}

- (instancetype)initWithChance:(double)chance {
    if ((self = [super initWithFrame:CGRectZero])) {
        _chance = chance;
        _keepStart = ((double)arc4random_uniform(10000) / 10000.0) * 2 * M_PI;

        _rotor = [CALayer layer];
        [self.layer addSublayer:_rotor];

        _disc = [CAShapeLayer layer];
        _disc.fillColor = SGDisc().CGColor;
        [_rotor addSublayer:_disc];

        _wedge = [CAShapeLayer layer];
        _wedge.fillColor = SGAccent().CGColor;
        [_rotor addSublayer:_wedge];

        _ticks = [CAShapeLayer layer];
        _ticks.strokeColor = [UIColor colorWithWhite:0 alpha:0.35].CGColor;
        _ticks.lineWidth = 1;
        [_rotor addSublayer:_ticks];

        _hub = [CAShapeLayer layer];
        _hub.fillColor = SGHub().CGColor;
        [self.layer addSublayer:_hub];

        _pointer = [CAShapeLayer layer];
        _pointer.fillColor = SGInk().CGColor;
        _pointer.shadowColor = UIColor.blackColor.CGColor;
        _pointer.shadowOpacity = 0.5;
        _pointer.shadowRadius = 4;
        _pointer.shadowOffset = CGSizeMake(0, 2);
        [self.layer addSublayer:_pointer];

        _hubLabel = SGLabel([NSString stringWithFormat:@"%.0f%%", round(chance * 100)], SGRounded(30, UIFontWeightBold), SGInk());
        [self addSubview:_hubLabel];
    }
    return self;
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(250, 250);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat r = MIN(b.size.width, b.size.height) / 2 - 10;
    CGPoint c = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    _rotor.bounds = b;
    _rotor.position = c;
    for (CAShapeLayer *layer in @[_disc, _wedge, _ticks]) layer.frame = b;

    _disc.path = [UIBezierPath bezierPathWithArcCenter:c radius:r startAngle:0 endAngle:2 * M_PI clockwise:YES].CGPath;

    double width = MAX(0.02, _chance * 2 * M_PI);
    UIBezierPath *wedge = [UIBezierPath bezierPath];
    [wedge moveToPoint:c];
    [wedge addArcWithCenter:c radius:r startAngle:-M_PI_2 + _keepStart endAngle:-M_PI_2 + _keepStart + width clockwise:YES];
    [wedge closePath];
    _wedge.path = wedge.CGPath;

    // Fine ticks around the rim, every 18 degrees
    UIBezierPath *ticks = [UIBezierPath bezierPath];
    for (int i = 0; i < 20; i++) {
        double a = -M_PI_2 + i * (M_PI / 10);
        [ticks moveToPoint:CGPointMake(c.x + cos(a) * (r * 0.62), c.y + sin(a) * (r * 0.62))];
        [ticks addLineToPoint:CGPointMake(c.x + cos(a) * r, c.y + sin(a) * r)];
    }
    _ticks.path = ticks.CGPath;

    _hub.frame = b;
    _hub.path = [UIBezierPath bezierPathWithArcCenter:c radius:r * 0.58 startAngle:0 endAngle:2 * M_PI clockwise:YES].CGPath;

    UIBezierPath *pointer = [UIBezierPath bezierPath];
    CGFloat top = c.y - r - 8;
    [pointer moveToPoint:CGPointMake(c.x - 11, top)];
    [pointer addLineToPoint:CGPointMake(c.x + 11, top)];
    [pointer addLineToPoint:CGPointMake(c.x, top + 24)];
    [pointer closePath];
    _pointer.frame = b;
    _pointer.path = pointer.CGPath;

    [CATransaction commit];

    [_hubLabel sizeToFit];
    _hubLabel.center = c;
}

- (void)spinToWin:(BOOL)win duration:(NSTimeInterval)duration completion:(void (^)(void))completion {
    double width = _chance * 2 * M_PI;
    double rest = 2 * M_PI - width;
    double u = (double)arc4random_uniform(10000) / 10000.0;

    // Land honestly inside the region the engine picked, away from its edges
    double target;
    if (win) {
        double margin = MIN(0.08, width * 0.2);
        target = _keepStart + margin + u * (width - 2 * margin);
    } else {
        double margin = MIN(0.08, rest * 0.2);
        target = _keepStart + width + margin + u * (rest - 2 * margin);
    }

    double settle = fmod(-target, 2 * M_PI);
    if (settle < 0) settle += 2 * M_PI;
    double total = 6 * 2 * M_PI + settle;

    [CATransaction begin];
    [CATransaction setCompletionBlock:completion];
    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue = @0;
    spin.toValue = @(total);
    spin.duration = duration;
    spin.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.12 :0.62 :0.08 :1.0];
    _rotor.transform = CATransform3DMakeRotation(total, 0, 0, 1);
    [_rotor addAnimation:spin forKey:@"spin"];
    [CATransaction commit];
}

@end

// MARK: Overlay

@implementation SGOverlayView {
    UIVisualEffectView *_blur;
    UIView *_dim;
    UIView *_content;
    UIButton *_exitButton;

    SGRingView *_ring;
    SGWheelView *_wheel;
    UILabel *_title;
    UILabel *_body;
    UILabel *_footnote;
    UIView *_pill;

    CADisplayLink *_link;
    BOOL _spinStarted;
    NSTimeInterval _modeStarted;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.clipsToBounds = YES;

        _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
        _blur.frame = self.bounds;
        _blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_blur];

        _dim = [[UIView alloc] initWithFrame:self.bounds];
        _dim.backgroundColor = [UIColor colorWithRed:0.03 green:0.03 blue:0.04 alpha:0.62];
        _dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_dim];

        _exitButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _exitButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        [_exitButton setTitleColor:SGMuted() forState:UIControlStateNormal];
        _exitButton.translatesAutoresizingMaskIntoConstraints = NO;
        _exitButton.hidden = YES;
        [_exitButton addTarget:self action:@selector(exitTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_exitButton];
        [NSLayoutConstraint activateConstraints:@[
            [_exitButton.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_exitButton.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor constant:-40],
            [_exitButton.heightAnchor constraintGreaterThanOrEqualToConstant:44]
        ]];

        self.accessibilityViewIsModal = YES;
    }
    return self;
}

- (void)dealloc {
    [_link invalidate];
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    [super willMoveToWindow:newWindow];
    if (!newWindow) {
        [_link invalidate];
        _link = nil;
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window && _mode == SGOverlayModeColdStart) [self startLink];
}

- (void)exitTapped {
    if (self.exitHandler) self.exitHandler();
}

- (void)setExitHandler:(void (^)(void))exitHandler {
    _exitHandler = [exitHandler copy];
    [self updateExitButton];
}

- (void)updateExitButton {
    BOOL show = self.exitHandler != nil && (_mode == SGOverlayModeColdStart || _mode == SGOverlayModeLocked || _mode == SGOverlayModeFrozen);
    _exitButton.hidden = !show;
    [_exitButton setTitle:(_mode == SGOverlayModeColdStart ? @"Not now" : @"Close") forState:UIControlStateNormal];
    [self bringSubviewToFront:_exitButton];
}

// MARK: Modes

- (void)setMode:(SGOverlayMode)mode animated:(BOOL)animated {
    if (mode == _mode) return;
    _mode = mode;
    _spinStarted = NO;
    _busy = NO;
    _modeStarted = CACurrentMediaTime();
    [_link invalidate];
    _link = nil;

    UIView *old = _content;
    _content = [[UIView alloc] initWithFrame:self.bounds];
    _content.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self insertSubview:_content belowSubview:_exitButton];
    _ring = nil;
    _wheel = nil;
    _pill = nil;

    BOOL frozen = mode == SGOverlayModeFrozen;
    switch (mode) {
        case SGOverlayModeColdStart:  [self buildColdStart]; break;
        case SGOverlayModeRoulette:   [self buildRoulette]; break;
        case SGOverlayModeLocked:     [self buildLocked]; break;
        case SGOverlayModeFeedLocked: [self buildFeedLocked]; break;
        case SGOverlayModeFrozen:     [self buildFrozen]; break;
        case SGOverlayModeNone: break;
    }
    [self updateExitButton];

    void (^apply)(void) = ^{
        self->_blur.alpha = frozen ? 0 : 1;
        self->_dim.alpha = frozen ? 0 : 1;
        old.alpha = 0;
        self->_content.alpha = 1;
    };

    if (animated) {
        _content.alpha = 0;
        [UIView animateWithDuration:0.35 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:apply completion:^(BOOL finished) {
            [old removeFromSuperview];
        }];
    } else {
        apply();
        [old removeFromSuperview];
    }

    if (mode == SGOverlayModeColdStart && self.window) [self startLink];
    [self tick];
}

- (UIStackView *)stackWith:(NSArray<UIView *> *)views {
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_content addSubview:stack];

    UILabel *wordmark = SGEyebrow(@"slopgram");
    wordmark.translatesAutoresizingMaskIntoConstraints = NO;
    [_content addSubview:wordmark];

    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:_content.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:_content.centerYAnchor constant:-8],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:320],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:_content.leadingAnchor constant:28],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:_content.trailingAnchor constant:-28],
        [wordmark.centerXAnchor constraintEqualToAnchor:_content.centerXAnchor],
        [wordmark.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor constant:-14],
    ]];
    for (UIView *view in views) {
        if ([view isKindOfClass:[UILabel class]]) {
            [view.widthAnchor constraintLessThanOrEqualToAnchor:stack.widthAnchor].active = YES;
        }
    }
    return stack;
}

- (void)buildColdStart {
    SGEngine *engine = [SGEngine shared];
    NSInteger seconds = (NSInteger)llround(engine.coldStartDuration);
    NSInteger restarts = (seconds - 30) / 15;

    _title = SGLabel(@"Reels are cold.", SGRounded(30, UIFontWeightBold), SGInk());
    _ring = [SGRingView new];
    _ring.translatesAutoresizingMaskIntoConstraints = NO;
    [_ring.widthAnchor constraintEqualToConstant:200].active = YES;
    [_ring.heightAnchor constraintEqualToConstant:200].active = YES;

    NSString *body = restarts <= 0
        ? @"Every fresh start of Instagram costs 30 seconds before Reels."
        : [NSString stringWithFormat:@"%ld restart%@ in the last hour, so this one costs %ld seconds.", (long)restarts, restarts == 1 ? @"" : @"s", (long)seconds];
    _body = SGLabel(body, [UIFont systemFontOfSize:16 weight:UIFontWeightRegular], SGMuted());
    _footnote = SGLabel(@"Leave and the clock starts over.", [UIFont systemFontOfSize:13 weight:UIFontWeightRegular], SGFaint());

    UIStackView *stack = [self stackWith:@[SGEyebrow(@"Cold start"), _title, _ring, _body, _footnote]];
    [stack setCustomSpacing:28 afterView:_title];
    [stack setCustomSpacing:28 afterView:_ring];
    [stack setCustomSpacing:8 afterView:_body];
}

- (void)buildRoulette {
    SGEngine *engine = [SGEngine shared];
    double chance = [engine currentWinChance];

    _title = SGLabel(@"Run's over.", SGRounded(30, UIFontWeightBold), SGInk());
    _wheel = [[SGWheelView alloc] initWithChance:chance];
    _wheel.translatesAutoresizingMaskIntoConstraints = NO;
    [_wheel.widthAnchor constraintEqualToConstant:250].active = YES;
    [_wheel.heightAnchor constraintEqualToConstant:250].active = YES;

    NSMutableString *body = [NSMutableString stringWithFormat:@"The coral slice keeps you scrolling. %.0f%% chance.", round(chance * 100)];
    if (engine.wins > 0) [body appendString:@"\nEvery win makes the next spin harder."];
    if ([engine isNight]) [body appendString:@"\nAfter midnight the odds are halved."];
    _body = SGLabel(body, [UIFont systemFontOfSize:16 weight:UIFontWeightRegular], SGMuted());

    UIStackView *stack = [self stackWith:@[SGEyebrow(@"Roulette"), _title, _wheel, _body]];
    [stack setCustomSpacing:24 afterView:_title];
    [stack setCustomSpacing:24 afterView:_wheel];
}

- (NSString *)nextStartText {
    return [NSString stringWithFormat:@"The next start costs %ld seconds.", (long)llround([[SGEngine shared] nextColdStartDuration])];
}

- (UIImageView *)symbol:(NSString *)name {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:44 weight:UIImageSymbolWeightSemibold];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:name withConfiguration:config]];
    icon.tintColor = SGAccent();
    return icon;
}

- (void)buildLocked {
    SGEngine *engine = [SGEngine shared];
    _title = SGLabel(@"That's it for Reels.", SGRounded(30, UIFontWeightBold), SGInk());
    _body = SGLabel([NSString stringWithFormat:@"Locked until you restart Instagram.\n%@", [self nextStartText]],
                    [UIFont systemFontOfSize:16 weight:UIFontWeightRegular], SGMuted());
    _footnote = SGLabel([NSString stringWithFormat:@"%ld reels · %ld spin%@ won this launch", (long)engine.unitsSeen, (long)engine.wins, engine.wins == 1 ? @"" : @"s"],
                        [UIFont systemFontOfSize:13 weight:UIFontWeightRegular], SGFaint());

    UIImageView *icon = [self symbol:@"moon.zzz.fill"];
    UIStackView *stack = [self stackWith:@[icon, SGEyebrow(@"Locked"), _title, _body, _footnote]];
    [stack setCustomSpacing:22 afterView:icon];
    [stack setCustomSpacing:20 afterView:_body];
}

- (void)buildFeedLocked {
    SGEngine *engine = [SGEngine shared];
    BOOL froze = engine.lockReason == SGLockReasonFreeze;
    _title = SGLabel(froze ? @"The feed froze." : @"That's it for the feed.", SGRounded(28, UIFontWeightBold), SGInk());
    _body = SGLabel(@"Stories and messages still work.\nRestart Instagram to scroll again.",
                    [UIFont systemFontOfSize:16 weight:UIFontWeightRegular], SGMuted());

    UIImageView *icon = [self symbol:froze ? @"snowflake" : @"moon.zzz.fill"];
    UIStackView *stack = [self stackWith:@[icon, _title, _body]];
    [stack setCustomSpacing:20 afterView:icon];
}

- (void)buildFrozen {
    // No blur: the last frame just sits there. A quiet note shows up a moment later.
    UIView *pill = [UIView new];
    pill.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.09 alpha:0.92];
    pill.layer.cornerRadius = 22;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    pill.alpha = 0;

    UILabel *label = SGLabel(@"Reels froze. Restart Instagram to unfreeze.", [UIFont systemFontOfSize:14 weight:UIFontWeightMedium], SGInk());
    label.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"snowflake" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold]]];
    icon.tintColor = SGAccent();
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [pill addSubview:icon];
    [pill addSubview:label];
    [_content addSubview:pill];

    [NSLayoutConstraint activateConstraints:@[
        [pill.centerXAnchor constraintEqualToAnchor:_content.centerXAnchor],
        [pill.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor constant:-84],
        [pill.leadingAnchor constraintGreaterThanOrEqualToAnchor:_content.leadingAnchor constant:20],
        [icon.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:16],
        [icon.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor],
        [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:8],
        [label.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-18],
        [label.topAnchor constraintEqualToAnchor:pill.topAnchor constant:13],
        [label.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-13],
    ]];
    _pill = pill;

    [UIView animateWithDuration:0.5 delay:1.6 * [SGEngine timeScale] options:0 animations:^{
        pill.alpha = 1;
    } completion:nil];
}

// MARK: Ticking

- (void)startLink {
    if (_link) return;
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)setOnScreen:(BOOL)onScreen {
    BOOL changed = onScreen != _onScreen;
    _onScreen = onScreen;
    if (changed) [self tick];
}

- (void)tick {
    switch (_mode) {
        case SGOverlayModeColdStart: [self tickColdStart]; break;
        case SGOverlayModeRoulette:  [self tickRoulette]; break;
        default: break;
    }
}

- (void)tickColdStart {
    SGEngine *engine = [SGEngine shared];
    NSTimeInterval duration = engine.coldStartDuration;
    NSTimeInterval remaining = self.onScreen ? [engine coldStartRemaining] : duration;

    NSString *text = [NSString stringWithFormat:@"%ld", (long)ceil(MAX(0, remaining))];
    if (![_ring.numberLabel.text isEqualToString:text]) {
        _ring.numberLabel.text = text;
        [_ring setNeedsLayout];
    }
    _ring.progress = duration > 0 ? remaining / duration : 0;
}

- (void)tickRoulette {
    if (_spinStarted || !self.onScreen) return;
    if (CACurrentMediaTime() - _modeStarted < 0.9 * [SGEngine timeScale]) {
        // Let the wheel be seen before it moves
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self tick];
        });
        return;
    }

    _spinStarted = YES;
    _busy = YES;
    self.accessibilityValue = @"spinning";

    BOOL won = [[SGEngine shared] spin];
    SGWheelView *wheel = _wheel;
    __weak typeof(self) weakSelf = self;
    [wheel spinToWin:won duration:4.2 * [SGEngine timeScale] completion:^{
        [weakSelf showSpinResult:won];
    }];
}

- (void)showSpinResult:(BOOL)won {
    if (_mode != SGOverlayModeRoulette) return;
    SGEngine *engine = [SGEngine shared];

    self.accessibilityValue = @"result";
    if (won) {
        double survival = [engine survivalChanceOfCurrentStreak] * 100;
        NSString *odds = survival < 1 ? @"under 1%" : [NSString stringWithFormat:@"%.0f%%", survival];
        _title.text = @"Lucky.";
        _title.textColor = SGAccent();
        _body.text = [NSString stringWithFormat:@"Keep going, for now.\nA run this long happens %@ of the time.", odds];
    } else {
        _title.text = @"Not this time.";
        _body.text = @"Reels and feed are done until you restart Instagram.";
    }

    NSTimeInterval hold = (won ? 2.0 : 1.6) * [SGEngine timeScale];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(hold * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_busy = NO;
        if (strongSelf.spinFinished) strongSelf.spinFinished();
    });
}

@end
