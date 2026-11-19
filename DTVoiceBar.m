//
//  DTVoiceBar.m —— QQ 式语音进度条
//
//  能力：气泡内进度线 / 已播+总时长 / 拖动 seek 实时预览 / 暂停继续 /
//        长按切倍速（1.0 1.5 2.0 2.5 3.0）
//  不做：连播（跟随微信原生）、听筒扬声器切换（不侵入）
//
//  定位策略（不写死类名，换微信版本仍可用）：
//    语音气泡 = 类名含 Voice 的 UITableViewCell 子类
//    播放器   = 同时实现 play/pause/currentTime/duration 的微信类
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import "DTHook.h"
#import "DTConfig.h"
#import "DTClassFinder.h"
#import "DTLog.h"
#import "DTModules.h"

static NSString *const kEn      = @"DTVoiceBarEnable";
static NSString *const kShowTime= @"DTVoiceBarShowTime";
static NSString *const kPauseBtn= @"DTVoiceBarPauseBtn";
static NSString *const kRateKey = @"DTVoiceBarRate";
static const NSInteger kBarTag  = 0x44544231;   // 'DTB1'

#pragma mark - 前置声明（定义在后面，先声明避免 implicit declaration）

UIViewController *DTKeyWindowVC(void);
void DTVoiceSeekRatio(CGFloat r);
void DTVoiceTogglePause(void);
void DTVoiceApplyRate(void);

#pragma mark - 运行时工具

/// 递归查 ivar（含父类）
static Ivar DTIvar(Class cls, const char *name) {
    for (Class c = cls; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        Ivar iv = class_getInstanceVariable(c, name);
        if (iv) return iv;
    }
    return NULL;
}

/// 从对象里读一个 int 型 ivar
static int DTIntIvar(id obj, const char *name) {
    if (!obj) return 0;
    Ivar iv = DTIvar([obj class], name);
    if (!iv) return 0;
    ptrdiff_t off = ivar_getOffset(iv);
    const char *t = ivar_getTypeEncoding(iv);
    if (!t) return 0;
    char *p = (char *)(__bridge void *)obj + off;
    switch (t[0]) {
        case 'i': return *(int *)p;
        case 'I': return (int)*(unsigned int *)p;
        case 'q': return (int)*(long long *)p;
        case 'Q': return (int)*(unsigned long long *)p;
        case 's': return *(short *)p;
        case 'c': return *(char *)p;
        case 'B': return *(unsigned char *)p ? 1 : 0;
        default:  return 0;
    }
}

static id DTObjIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar iv = DTIvar([obj class], name);
    if (!iv) return nil;
    return object_getIvar(obj, iv);
}

#pragma mark - 进度条视图

@interface DTVoiceBarView : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, weak)   UIView *bubble;
@property (nonatomic, strong) UIView *track;
@property (nonatomic, strong) UIView *fill;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UIButton *pauseBtn;
@property (nonatomic, assign) BOOL dragging;
@property (nonatomic, assign) BOOL pausedUI;
@property (nonatomic, assign) NSTimeInterval total;
- (instancetype)initWithBubble:(UIView *)bubble;
- (void)updateRatio:(CGFloat)r current:(NSTimeInterval)c total:(NSTimeInterval)t;
- (void)setPausedUI:(BOOL)p;
@end

@implementation DTVoiceBarView

- (instancetype)initWithBubble:(UIView *)bubble {
    CGRect b = bubble.bounds;
    CGFloat h = 13;
    CGRect f = CGRectMake(4, CGRectGetMaxY(b) - h - 2, MAX(40, CGRectGetWidth(b) - 8), h);
    if ((self = [super initWithFrame:f])) {
        self.bubble = bubble;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        self.backgroundColor = [UIColor clearColor];
        self.tag = kBarTag;
        self.clipsToBounds = NO;

        _track = [[UIView alloc] initWithFrame:CGRectZero];
        _track.backgroundColor = [UIColor colorWithWhite:0 alpha:0.10];
        _track.layer.cornerRadius = 1.5;
        _track.clipsToBounds = YES;
        _track.userInteractionEnabled = YES;
        [self addSubview:_track];

        _fill = [[UIView alloc] initWithFrame:CGRectZero];
        _fill.backgroundColor = [UIColor colorWithRed:0.10 green:0.78 blue:0.38 alpha:1.0];
        _fill.layer.cornerRadius = 1.5;
        _fill.userInteractionEnabled = NO;
        [_track addSubview:_fill];

        _timeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _timeLabel.font = [UIFont monospacedDigitSystemFontOfSize:8.5 weight:UIFontWeightRegular];
        _timeLabel.textColor = [UIColor colorWithWhite:0.45 alpha:0.95];
        _timeLabel.text = @"0:00 / 0:00";
        _timeLabel.userInteractionEnabled = NO;
        [self addSubview:_timeLabel];

        _pauseBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        [_pauseBtn setTitle:@"⏸" forState:UIControlStateNormal];
        [_pauseBtn setTitleColor:[UIColor colorWithWhite:0.35 alpha:1] forState:UIControlStateNormal];
        _pauseBtn.titleLabel.font = [UIFont systemFontOfSize:10];
        _pauseBtn.userInteractionEnabled = YES;
        [_pauseBtn addTarget:self action:@selector(onPauseTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_pauseBtn];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
        pan.delegate = self;
        [_track addGestureRecognizer:pan];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTapTrack:)];
        [_track addGestureRecognizer:tap];

        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
        lp.minimumPressDuration = 0.45;
        [_track addGestureRecognizer:lp];

        [bubble addSubview:self];
        [bubble bringSubviewToFront:self];
        [self setNeedsLayout];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = 3.0;
    CGFloat labelW = DTBool(kShowTime, YES) ? 58 : 0;
    CGFloat btnW   = DTBool(kPauseBtn, YES) ? 15 : 0;
    CGFloat gap    = 3;
    CGFloat trackW = self.bounds.size.width - labelW - btnW - gap * 2;
    if (trackW < 24) { trackW = self.bounds.size.width; labelW = 0; btnW = 0; }

    _track.frame = CGRectMake(0, (self.bounds.size.height - h) / 2.0, trackW, h);
    _fill.frame  = CGRectMake(0, 0, _fill.frame.size.width > trackW ? trackW : _fill.frame.size.width, h);
    _timeLabel.frame = CGRectMake(CGRectGetMaxX(_track.frame) + gap, 0, labelW, self.bounds.size.height);
    _pauseBtn.frame  = CGRectMake(CGRectGetMaxX(_timeLabel.frame) + gap, 0, btnW, self.bounds.size.height);
}

- (void)updateRatio:(CGFloat)r current:(NSTimeInterval)c total:(NSTimeInterval)t {
    _total = t;
    if (!_dragging) {
        CGFloat w = _track.frame.size.width;
        CGRect f = _fill.frame;
        f.size.width = w * MAX(0, MIN(1, r));
        _fill.frame = f;
    }
    if (DTBool(kShowTime, YES)) {
        int cc = (int)MAX(0, c), tt = (int)MAX(0, t);
        _timeLabel.text = [NSString stringWithFormat:@"%d:%02d/%d:%02d", cc/60, cc%60, tt/60, tt%60];
    }
}

- (void)setPausedUI:(BOOL)p {
    _pausedUI = p;
    [_pauseBtn setTitle:p ? @"▶" : @"⏸" forState:UIControlStateNormal];
}

#pragma mark 手势

- (CGFloat)ratioAtPoint:(CGPoint)pt {
    CGFloat w = _track.frame.size.width;
    if (w <= 0) return 0;
    return MAX(0, MIN(1, pt.x / w));
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint pt = [g locationInView:_track];
    CGFloat r = [self ratioAtPoint:pt];
    if (g.state == UIGestureRecognizerStateBegan) {
        _dragging = YES;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGRect f = _fill.frame;
        f.size.width = _track.frame.size.width * r;
        _fill.frame = f;
        if (DTBool(kShowTime, YES) && _total > 0) {
            int cc = (int)(_total * r), tt = (int)_total;
            _timeLabel.text = [NSString stringWithFormat:@"%d:%02d/%d:%02d", cc/60, cc%60, tt/60, tt%60];
        }
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled) {
        _dragging = NO;
        extern void DTVoiceSeekRatio(CGFloat);
        DTVoiceSeekRatio(r);
    }
}

- (void)onTapTrack:(UITapGestureRecognizer *)g {
    CGFloat r = [self ratioAtPoint:[g locationInView:_track]];
    extern void DTVoiceSeekRatio(CGFloat);
    DTVoiceSeekRatio(r);
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIViewController *vc = DTKeyWindowVC();
    if (!vc) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"播放倍速"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *rates = @[@1.0, @1.5, @2.0, @2.5, @3.0];
    double cur = DTDouble(kRateKey, 1.0);
    for (NSNumber *n in rates) {
        NSString *title = [NSString stringWithFormat:@"%.1fx%@", n.doubleValue,
                           fabs(n.doubleValue - cur) < 0.01 ? @"  ✓" : @""];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            DTSetDouble(kRateKey, n.doubleValue);
            extern void DTVoiceApplyRate(void);
            DTVoiceApplyRate();
            DTLog(@"rate -> %.1f", n.doubleValue);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // iPad 需要 popover 锚点
    sheet.popoverPresentationController.sourceView = self;
    sheet.popoverPresentationController.sourceRect = self.bounds;
    [vc presentViewController:sheet animated:YES completion:nil];
}

- (void)onPauseTapped {
    extern void DTVoiceTogglePause(void);
    DTVoiceTogglePause();
}

#pragma mark 只让按钮和轨道接管点击，其余透明

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self) return nil;   // 空白处穿透给气泡
    return v;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;   // 不和微信自己的长按/滑动打架
}

@end

#pragma mark - 播放器绑定

static __weak id       gPlayer   = nil;
static Class           gPlayerCls= Nil;
static IMP             gPlayOrig = NULL;
static IMP             gPauseOrig= NULL;
static IMP             gAvPlayOrig = NULL;
static CADisplayLink  *gLink     = nil;
static __weak DTVoiceBarView *gBar = nil;

/// 把 CADisplayLink 的强引用断掉，避免和 block 形成环
@interface DTLinkProxy : NSObject
@property (nonatomic, copy) void (^blk)(void);
@end
@implementation DTLinkProxy
- (void)fire { if (self.blk) self.blk(); }
@end
static DTLinkProxy *gProxy = nil;

UIViewController *DTKeyWindowVC(void) {
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.isKeyWindow) return w.rootViewController;
        }
    }
    return [UIApplication sharedApplication].keyWindow.rootViewController;
}

static __weak id gPlayingMsg = nil;      // 当前在播的 CMessageWrap

// 8.0.54 class-dump 实证：语音播放器不是 AVAudioPlayer 体系。
//   SilkAudioPlayer   : getCurrentTimeMs / playAtTime: / setCurrentPacketWithTime: / preparePlayWithFile:sync:
//   SilkAudioPlayerV2 : duration / isPlaying / start / resume / pause / stop
//   AudioReceiver     : 中枢，-StartPlay:Path:Resume:、-getCurrentTimeMs、-setProgress:
static Class DTFindPlayerClass(void) {
    if (gPlayerCls) return gPlayerCls;

    NSArray<NSString *> *pref = @[
        @"SilkAudioPlayerV2", @"SilkAudioPlayer",
        @"MsgAudioUnitPlayer", @"SimpleAudioPlayer",
        @"AMRAudioPlayerV2", @"AMRAudioPlayer",
        @"SPXAudioPlayer", @"FavAudioPlayer",
        @"AQAudioPlayer", @"MMAudioPlayerQueue",
    ];
    for (NSString *cn in pref) {
        Class c = NSClassFromString(cn);
        if (!c) continue;
        if (class_getInstanceMethod(c, sel_registerName("getCurrentTimeMs")) ||
            class_getInstanceMethod(c, sel_registerName("playAtTime:")) ||
            class_getInstanceMethod(c, sel_registerName("preparePlayWithFile:sync:")) ||
            (class_getInstanceMethod(c, sel_registerName("duration")) &&
             class_getInstanceMethod(c, sel_registerName("isPlaying")))) {
            gPlayerCls = c;
            DTLog(@"voicebar: player class = %@ (by name)", cn);
            return c;
        }
    }

    // 名字变了就按能力找
    for (NSString *cn in DTWeChatClassNames()) {
        Class c = objc_getClass(cn.UTF8String);
        if (!c) continue;
        if ([c isSubclassOfClass:[UIView class]] ||
            [c isSubclassOfClass:[UIViewController class]]) continue;
        if (class_getInstanceMethod(c, sel_registerName("getCurrentTimeMs")) ||
            (class_getInstanceMethod(c, sel_registerName("playAtTime:")) &&
             class_getInstanceMethod(c, sel_registerName("stop")))) {
            gPlayerCls = c;
            DTLog(@"voicebar: player class = %@ (by feature)", cn);
            return c;
        }
    }
    return Nil;
}

static NSTimeInterval DTCurrentTime(id p) {
    if (!p) return 0;
    SEL s = sel_registerName("currentTime");
    if (![p respondsToSelector:s]) return 0;
    double (*fn)(id, SEL) = (void *)[p methodForSelector:s];
    return fn ? fn(p, s) : 0;
}

/// 毫秒进度：优先 getCurrentTimeMs（SilkAudioPlayer 的原生接口），退回 currentTime*1000
static NSTimeInterval DTCurrentMs(id p) {
    if (!p) return 0;
    SEL s = sel_registerName("getCurrentTimeMs");
    if ([p respondsToSelector:s]) {
        int (*fn)(id, SEL) = (void *)[p methodForSelector:s];
        if (fn) return (NSTimeInterval)fn(p, s);
    }
    return DTCurrentTime(p) * 1000.0;
}

static NSTimeInterval DTDuration(id p) {
    if (!p) return 0;
    SEL s = sel_registerName("duration");
    if (![p respondsToSelector:s]) return 0;
    double (*fn)(id, SEL) = (void *)[p methodForSelector:s];
    return fn ? fn(p, s) : 0;
}

/// 消息自带的语音时长。CMessageWrap.m_uiVoiceTime 在 8.x 是秒，
/// 老版本/服务端 XML 里是毫秒 —— 用 >600 当界区分。
static NSTimeInterval DTMsgVoiceMs(id msg) {
    if (!msg) return 0;
    NSNumber *n = nil;
    @try {
        id v = [msg valueForKey:@"m_uiVoiceTime"];
        if ([v isKindOfClass:[NSNumber class]]) n = v;
    } @catch (__unused NSException *e) { n = nil; }
    double v = n ? n.doubleValue : 0;
    if (v <= 0) return 0;
    return v > 600 ? v : v * 1000.0;
}

/// 总时长：消息 > duration > 0
static NSTimeInterval DTTotalMs(id p) {
    NSTimeInterval ms = DTMsgVoiceMs(gPlayingMsg);
    if (ms > 0) return ms;
    NSTimeInterval d = DTDuration(p);
    return d > 0 ? d * 1000.0 : 0;
}

static BOOL DTIsPlaying(id p) {
    if (!p) return NO;
    SEL s = sel_registerName("isPlaying");
    if ([p respondsToSelector:s]) {
        BOOL (*fn)(id, SEL) = (void *)[p methodForSelector:s];
        if (fn) return fn(p, s);
    }
    // SilkAudioPlayer 没有 isPlaying，用「进度在走」判断
    return DTCurrentMs(p) > 0;
}

static void DTTick(void) {
    id p = gPlayer;
    NSTimeInterval d = DTTotalMs(p);
    if (d <= 0) return;
    NSTimeInterval c = DTCurrentMs(p);
    if (c < 0) c = 0;
    if (c > d) c = d;
    [gBar updateRatio:(CGFloat)(c / d) current:c / 1000.0 total:d / 1000.0];
}

static void DTStartLink(void) {
    if (gLink) {
        gLink.paused = NO;
        return;
    }
    gProxy = [DTLinkProxy new];
    __weak typeof(gProxy) wp = gProxy;
    gProxy.blk = ^{
        __strong typeof(wp) sp = wp;
        if (sp) DTTick();
    };
    gLink = [CADisplayLink displayLinkWithTarget:gProxy selector:@selector(fire)];
    gLink.preferredFramesPerSecond = 12;   // 足够，省电
    [gLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

void DTVoiceApplyRate(void) {
    id p = gPlayer;
    if (!p) return;
    double rate = DTDouble(kRateKey, 1.0);
    SEL en = sel_registerName("enableRate");
    if ([p respondsToSelector:en]) {
        void (*f1)(id, SEL) = (void *)[p methodForSelector:en];
        if (f1) f1(p, en);
    }
    SEL rs = sel_registerName("rate");
    if ([p respondsToSelector:rs]) {
        void (*f2)(id, SEL, float) = (void *)[p methodForSelector:rs];
        if (f2) f2(p, rs, (float)rate);
    }
    // AVAudioPlayer 系走 setRate:
    SEL sr = sel_registerName("setRate:");
    if ([p respondsToSelector:sr]) {
        void (*f3)(id, SEL, float) = (void *)[p methodForSelector:sr];
        if (f3) f3(p, sr, (float)rate);
    }
}

void DTVoiceSeekRatio(CGFloat r) {
    id p = gPlayer;
    if (!p) return;
    NSTimeInterval d = DTTotalMs(p);
    if (d <= 0) return;
    r = MAX(0, MIN(1, r));
    unsigned ms = (unsigned)(d * r);

    // 1) SilkAudioPlayer 的原生定位：playAtTime:（单位毫秒）
    SEL pa = sel_registerName("playAtTime:");
    if ([p respondsToSelector:pa]) {
        void (*f)(id, SEL, unsigned) = (void *)[p methodForSelector:pa];
        if (f) f(p, pa, ms);
    } else {
        // 2) AudioReceiver / 旧播放器：setProgress:
        SEL sp = sel_registerName("setProgress:");
        if ([p respondsToSelector:sp]) {
            void (*f)(id, SEL, unsigned) = (void *)[p methodForSelector:sp];
            if (f) f(p, sp, ms);
        } else {
            // 3) 最后的兜底
            SEL sc = sel_registerName("setCurrentTime:");
            if ([p respondsToSelector:sc]) {
                void (*f)(id, SEL, double) = (void *)[p methodForSelector:sc];
                if (f) f(p, sc, ms / 1000.0);
            }
        }
    }

    [gBar updateRatio:r current:ms / 1000.0 total:d / 1000.0];
    // seek 之后倍速会掉回 1.0，重新设一次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ DTVoiceApplyRate(); });
}

void DTVoiceTogglePause(void) {
    id p = gPlayer;
    if (!p) return;
    if (DTIsPlaying(p)) {
        if (gPauseOrig) ((void (*)(id, SEL))gPauseOrig)(p, sel_registerName("pause"));
        [gBar setPausedUI:YES];
        gLink.paused = YES;
    } else {
        if (gPlayOrig) ((BOOL (*)(id, SEL))gPlayOrig)(p, sel_registerName("play"));
        [gBar setPausedUI:NO];
        gLink.paused = NO;
        DTVoiceApplyRate();
    }
}

#pragma mark - 语音气泡识别

static BOOL DTCellIsVoice(id cell) {
    if (!cell) return NO;
    id wrap = DTObjIvar(cell, "m_msgWrap");
    if (!wrap) wrap = DTObjIvar(cell, "m_msg");
    if (!wrap) return NO;
    // 8.0.54: CMessageWrap -IsVoiceMsg 是唯一的语音谓词，优先用它
    SEL sv = sel_registerName("IsVoiceMsg");
    if ([wrap respondsToSelector:sv]) {
        BOOL (*f)(id, SEL) = (void *)[wrap methodForSelector:sv];
        if (f) return f(wrap, sv);
    }
    return DTIntIvar(wrap, "m_uiMessageType") == 34;
}

static void DTMountBar(UIView *cell) {
    if (!DTBool(kEn, YES)) return;
    if (!DTCellIsVoice(cell)) return;

    // 已有就不重复加
    for (UIView *v in cell.subviews) {
        if (v.tag == kBarTag) return;
    }

    // 找气泡：优先高度 25~70 的矩形子视图
    __block UIView *bubble = nil;
    __block CGFloat bestArea = 0;
    for (UIView *v in cell.contentView.subviews) {
        CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
        if (h < 20 || h > 90) continue;
        if ([v isKindOfClass:[UIImageView class]]) continue;
        CGFloat area = w * h;
        if (area > bestArea) { bestArea = area; bubble = v; }
    }
    if (!bubble) {
        for (UIView *v in cell.subviews) {
            if ([v isKindOfClass:[DTVoiceBarView class]]) continue;
            CGFloat area = v.bounds.size.width * v.bounds.size.height;
            if (area > bestArea) { bestArea = area; bubble = v; }
        }
    }
    if (!bubble) bubble = cell;

    if (!gPlayingMsg) {
        id w = DTObjIvar(cell, "m_msgWrap");
        if (!w) w = DTObjIvar(cell, "m_msg");
        if (w) gPlayingMsg = w;          // 兜底：没抓到播放事件时用最近一条语音消息
    }

    DTVoiceBarView *bar = [[DTVoiceBarView alloc] initWithBubble:bubble];
    gBar = bar;
}

#pragma mark - 安装

void DTModuleVoiceBarInstall(void) {
    if (!DTBool(kEn, YES)) { DTLog(@"voicebar: disabled"); return; }

    // 1) 播放器
    Class pc = DTFindPlayerClass();
    if (pc) {
        SEL playSel = sel_registerName("play");
        Method pm = class_getInstanceMethod(pc, playSel);
        // 只 hook 无显式参数、返回 BOOL/void 的 play，参数个数不符就别碰（block 签名会错）
        if (pm && method_getNumberOfArguments(pm) == 2) {
            gPlayOrig = DTHookMsg(pc, playSel, imp_implementationWithBlock(^BOOL(id self) {
                if (self != (id)gPlayer) {
                    gPlayer = self;
                    gPlayerCls = pc;
                }
                BOOL r = YES;
                if (gPlayOrig) r = ((BOOL (*)(id, SEL))gPlayOrig)(self, playSel);
                [gBar setPausedUI:NO];
                DTStartLink();
                DTVoiceApplyRate();
                return r;
            }));
            DTLog(@"voicebar: hooked -play on %@ (orig=%p)", NSStringFromClass(pc), gPlayOrig);
        } else {
            DTLog(@"voicebar: -play missing or has args, skip (%@)", NSStringFromClass(pc));
        }

        SEL pauseSel = sel_registerName("pause");
        Method qm = class_getInstanceMethod(pc, pauseSel);
        if (qm && method_getNumberOfArguments(qm) == 2) {
            gPauseOrig = DTHookMsg(pc, pauseSel, imp_implementationWithBlock(^(id self) {
                if (gPauseOrig) ((void (*)(id, SEL))gPauseOrig)(self, pauseSel);
                [gBar setPausedUI:YES];
            }));
        }

        // 停止时把进度条清空
        SEL stopSel = sel_registerName("stop");
        Method sm = class_getInstanceMethod(pc, stopSel);
        if (sm && method_getNumberOfArguments(sm) == 2) {
            IMP o = DTHookMsg(pc, stopSel, imp_implementationWithBlock(^(id self) {
                IMP prev = DTOrigFor(pc, stopSel);
                if (prev) ((void (*)(id, SEL))prev)(self, stopSel);
                [gBar updateRatio:0 current:0 total:0];
                [gBar setPausedUI:NO];
            }));
            (void)o;
        }
    } else {
        DTLog(@"voicebar: player class NOT found");
    }

    // 1a) 抓住「现在播的是哪条消息」——进度条的总时长只能从 CMessageWrap 拿
    //     （SilkAudioPlayer 没有 duration，只有 SilkAudioPlayerV2 有）
    Class plc = NSClassFromString(@"PlayingController");
    if (plc) {
        int hn = 0;
        SEL spm = sel_registerName("StartPlayMessage:Resume:");
        Method m1 = class_getInstanceMethod(plc, spm);
        if (m1 && method_getNumberOfArguments(m1) == 4) {
            DTHookMsg(plc, spm, imp_implementationWithBlock(^(id self, id msg, BOOL resume) {
                gPlayingMsg = msg;
                IMP pv = DTOrigFor(plc, spm);
                if (pv) ((void (*)(id, SEL, id, BOOL))pv)(self, spm, msg, resume);
                [gBar setPausedUI:NO];
                DTStartLink();
            }));
            hn++;
        }
        DTLog(@"voicebar: PlayingController armed %d", hn);
    }

    Class ar = NSClassFromString(@"AudioReceiver");
    if (ar) {
        int hn = 0;
        SEL sp1 = sel_registerName("StartPlay:");
        Method m2 = class_getInstanceMethod(ar, sp1);
        char rt = 'v';
        if (m2) {
            char *t = method_copyReturnType(m2);
            if (t) { rt = t[0]; free(t); }
        }
        if (m2 && method_getNumberOfArguments(m2) == 3 && rt != 'v') {
            DTHookMsg(ar, sp1, imp_implementationWithBlock(^BOOL(id self, id msg) {
                gPlayingMsg = msg;
                static BOOL told = NO;
                if (!told) {
                    told = YES;
                    id ap = DTObjIvar(self, "m_audioPlayer");
                    if (!ap) ap = DTObjIvar(self, "_audioPlayer");
                    DTLog(@"voicebar: AudioReceiver.m_audioPlayer = %@",
                          ap ? NSStringFromClass([ap class]) : @"(nil)");
                }
                IMP pv = DTOrigFor(ar, sp1);
                BOOL r = pv ? ((BOOL (*)(id, SEL, id))pv)(self, sp1, msg) : NO;
                [gBar setPausedUI:NO];
                DTStartLink();
                return r;
            }));
            hn++;
        }
        DTLog(@"voicebar: AudioReceiver armed %d", hn);
    }

    // 1b) 兜底：直接盯 AVAudioPlayer。微信最终一定用它放语音，
    //     即使没识别出它自己的播放器类，也能靠这个拿到 currentTime/duration。
    Class avp = NSClassFromString(@"AVAudioPlayer");
    if (avp && avp != pc) {
        SEL ps = sel_registerName("play");
        Method am = class_getInstanceMethod(avp, ps);
        if (am && method_getNumberOfArguments(am) == 2) {
            gAvPlayOrig = DTHookMsg(avp, ps, imp_implementationWithBlock(^BOOL(id self) {
                BOOL r = YES;
                if (gAvPlayOrig) r = ((BOOL (*)(id, SEL))gAvPlayOrig)(self, ps);
                if (r && !gPlayer) {
                    gPlayer = self;
                    gPlayerCls = avp;
                    [gBar setPausedUI:NO];
                    DTStartLink();
                }
                return r;
            }));
            DTLog(@"voicebar: AVAudioPlayer fallback hooked (orig=%p)", gAvPlayOrig);
        }
    }

    // 2) 所有含 Voice 的 cell
    int n = 0;
    for (NSString *cn in DTWeChatClassNames()) {
        if ([cn rangeOfString:@"Voice" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        Class c = objc_getClass(cn.UTF8String);
        if (!c || ![c isSubclassOfClass:[UITableViewCell class]]) continue;

        SEL ls = sel_registerName("layoutSubviews");
        __block Class wc = c;
        // 注意：每个类的 layoutSubviews 原实现不同，必须从全局表按类取，不能共用一个 static
        DTHookMsg(c, ls, imp_implementationWithBlock(^(id self) {
            IMP o = DTOrigFor(wc, ls);
            if (o) ((void (*)(id, SEL))o)(self, ls);
            DTMountBar(self);
        }));
        n++;
    }
    DTLog(@"voicebar: mounted hint on %d cell classes", n);
}
