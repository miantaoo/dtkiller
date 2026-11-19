//
//  DTCallKit.m —— 微信语音/视频来电转系统来电
//
//  原插件证据（WeCallKit.dylib，8 个 hook，imp 地址全部还原）：
//    isDeviceCallkitAvailable                     0x5194  = mov w0,#1; ret（无条件 YES）
//    isCallkitAvailable                           0x519c
//    getIfCanUseCX:                               0x5478
//    onServiceEnterBackground                     0x5480
//    onServiceEnterForeground                     0x5774
//    reportIncomingCallFromUser:ofType:withMsg:isPushKit:                         0x5780
//    reportIncomingCallFromUser:ofType:withMsg:isPushKit:displayName:completion:  0x5e2c
//    handleVoIPPushInfoContent:VoIPPushInfo:type:completion:                      0x5ae0
//  导入符号只有 _MSHookMessageEx / _objc_getClass / _object_getClass
//  → 纯 hook 型 dylib，自己不做网络，全部靠微信的来电对象。
//
//  同时 WCPureExtension.dylib 也挂了 isCallkitAvailable / isDeviceCallkitAvailable
//  （hookscan 7d2ae4 / 7d3188 / 7d2b04 / 7d31a8），MiYou 有 MIsCallkitKey 开关。
//  三家叠加时 MSHookMessageEx 会链式串起来：后加载的把前者当 orig。
//  所以**如果原插件还在，别同时装这个模块**，会互相盖掉。
//
//  设计取舍：
//    · 只在「微信在后台 / 锁屏 / 被 PushKit 唤醒」时上报系统来电
//      前台时仍走微信自己的来电页，避免重复响铃
//    · 接听/挂断通过 delegate 转回微信；转不回去时至少把微信拉到前台
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CallKit/CallKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>
#import "DTHook.h"
#import "DTConfig.h"
#import "DTClassFinder.h"
#import "DTLog.h"
#import "DTModules.h"

static NSString *const kEn       = @"DTCallKitEnable";
static NSString *const kVideoHint= @"DTCallKitVideo";     // 是否把视频通话标成 video
static NSString *const kBackgroundOnly = @"DTCallKitBackgroundOnly";

static BOOL gInBackground = NO;
static BOOL gDidInstall   = NO;

#pragma mark - provider

@interface DTCallKitCenter : NSObject <CXProviderDelegate>
@property (nonatomic, strong) CXProvider *provider;
@property (nonatomic, strong) NSMutableDictionary<NSUUID *, id> *uuidToMsg;
+ (instancetype)shared;
- (void)reportIncoming:(id)user type:(long)type msg:(id)msg display:(NSString *)name;
- (void)endAllCalls;
@end

@implementation DTCallKitCenter

+ (instancetype)shared {
    static DTCallKitCenter *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [DTCallKitCenter new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _uuidToMsg = [NSMutableDictionary dictionary];
        CXProviderConfiguration *cfg =
            [[CXProviderConfiguration alloc] initWithLocalizedName:@"微信"];
        cfg.supportsVideo = DTBool(kVideoHint, YES);
        cfg.maximumCallGroups = 1;
        cfg.maximumCallsPerCallGroup = 1;
        cfg.supportedHandleTypes = [NSSet setWithObject:@(CXHandleTypeGeneric)];
        _provider = [[CXProvider alloc] initWithConfiguration:cfg];
        [_provider setDelegate:self queue:dispatch_get_main_queue()];
    }
    return self;
}

- (void)reportIncoming:(id)user type:(long)type msg:(id)msg display:(NSString *)name {
    NSString *who = name;
    if (!who.length && user) {
        for (NSString *k in @[@"m_nsNickName", @"m_nsRemark", @"m_nsUsrName", @"nickname"]) {
            @try {
                id v = [user valueForKey:k];
                if ([v isKindOfClass:[NSString class]] && [v length]) { who = v; break; }
            } @catch (__unused NSException *e) {}
        }
    }
    if (!who.length) who = @"微信通话";

    NSUUID *uuid = [NSUUID UUID];
    CXCallUpdate *u = [[CXCallUpdate alloc] init];
    u.remoteHandle = [[CXHandle alloc] initWithType:CXHandleTypeGeneric value:who];
    u.localizedCallerName = who;
    u.hasVideo = DTBool(kVideoHint, YES);
    u.supportsHolding = NO;
    u.supportsGrouping = NO;
    u.supportsUngrouping = NO;

    __weak typeof(self) ws = self;
    [self.provider reportNewIncomingCallWithUUID:uuid update:u completion:^(NSError *e) {
        __strong typeof(ws) ss = ws;
        if (e) {
            DTLog(@"callkit: report FAILED %@ (%ld)", e.localizedDescription, (long)e.code);
            // 微信没有 voip 后台模式时 iOS 会拒绝，退化成「本地通知 + 震动」，
            // 至少锁屏能看到是谁打来的。
            [ss fallbackNotify:who];
            return;
        }
        DTLog(@"callkit: reported incoming from %@", who);
        if (ss && msg) ss.uuidToMsg[uuid] = msg;
    }];
}

/// CallKit 被系统拒绝时的降级：本地通知 + 震动
- (void)fallbackNotify:(NSString *)who {
    UNMutableNotificationContent *c = [UNMutableNotificationContent new];
    c.title = @"微信来电";
    c.body = who.length ? [NSString stringWithFormat:@"%@ 正在呼叫你", who] : @"有人正在呼叫你";
    c.sound = [UNNotificationSound defaultSound];
    UNNotificationRequest *r = [UNNotificationRequest requestWithIdentifier:[[NSUUID UUID] UUIDString]
                                                                  content:c trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:r withCompletionHandler:^(NSError *e) {
        DTLog(@"callkit: fallback notify err=%@", e);
    }];
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
}

- (void)endAllCalls {
    for (NSUUID *u in self.uuidToMsg.allKeys) {
        [self.provider reportCallWithUUID:u endedAtDate:[NSDate date] reason:CXCallEndedReasonRemoteEnded];
    }
    [self.uuidToMsg removeAllObjects];
}

#pragma mark CXProviderDelegate

- (void)providerDidReset:(CXProvider *)provider {
    DTLog(@"callkit: providerDidReset");
    [self.uuidToMsg removeAllObjects];
}

- (void)provider:(CXProvider *)provider performAnswerCallAction:(CXAnswerCallAction *)action {
    DTLog(@"callkit: user answered %@", action.callUUID);
    [self forwardToWeChat:@"answer"];
    [action fulfill];
}

- (void)provider:(CXProvider *)provider performEndCallAction:(CXEndCallAction *)action {
    DTLog(@"callkit: user ended %@", action.callUUID);
    [self forwardToWeChat:@"end"];
    [action fulfill];
    [self.uuidToMsg removeObjectForKey:action.callUUID];
}

/// 把「接听/挂断」转回微信。微信的接听入口名字每个版本都在变，
/// 这里按候选 selector 逐个试，全失败就只记日志（用户点系统来电后微信会被拉起来，
/// 手动在自己的来电页点接听也能通）。
- (void)forwardToWeChat:(NSString *)what {
    NSArray<NSString *> *answerSels = @[@"AcceptCall:", @"acceptCall:", @"answerCall:",
                                        @"AnswerCall:", @"onAcceptCall:", @"accept"];
    NSArray<NSString *> *endSels    = @[@"EndCall:", @"endCall:", @"HangUp:", @"hangUp:",
                                        @"onEndCall:", @"rejectCall:", @"RejectCall:"];
    NSArray<NSString *> *sels = [what isEqualToString:@"answer"] ? answerSels : endSels;

    id target = nil;
    Class vc = NSClassFromString(@"MMVoIPService");
    if (!vc) vc = NSClassFromString(@"VoIPService");
    if (!vc) vc = NSClassFromString(@"MMVoIPMgr");
    if (vc) target = DTService(vc);

    if (!target) {
        for (NSString *cn in DTWeChatClassNames()) {
            if ([cn rangeOfString:@"VoIP" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
            Class c = objc_getClass(cn.UTF8String);
            if (!c) continue;
            for (NSString *s in sels) {
                if (class_getInstanceMethod(c, NSSelectorFromString(s))) { target = c; break; }
            }
            if (target) break;
        }
    }

    for (NSString *s in sels) {
        SEL sel = NSSelectorFromString(s);
        if (!target || ![target respondsToSelector:sel]) continue;
        Method m = class_getInstanceMethod(object_getClass(target), sel);
        NSUInteger ac = m ? method_getNumberOfArguments(m) : 0;
        DTLog(@"callkit: forwarding %@ via %@ (argc=%lu)", what, s, (unsigned long)ac);
        @try {
            if (ac >= 3) {
                ((void (*)(id, SEL, id))[target methodForSelector:sel])(target, sel, nil);
            } else {
                ((void (*)(id, SEL))[target methodForSelector:sel])(target, sel);
            }
        } @catch (__unused NSException *e) {
            DTLog(@"callkit: forward threw on %@", s);
        }
        return;
    }
    DTLog(@"callkit: no forward target for %@（手动在微信里操作）", what);
}

@end

#pragma mark - hooks

static void n_serviceBackground(id self, SEL _cmd) {
    gInBackground = YES;
    IMP o = DTOrigFor(object_getClass(self), _cmd);
    if (o) ((void (*)(id, SEL))o)(self, _cmd);
}

static void n_serviceForeground(id self, SEL _cmd) {
    gInBackground = NO;
    IMP o = DTOrigFor(object_getClass(self), _cmd);
    if (o) ((void (*)(id, SEL))o)(self, _cmd);
    // 回到前台说明用户已经在微信里处理了，把系统来电收掉，避免残留
    [[DTCallKitCenter shared] endAllCalls];
}

static BOOL n_alwaysYes(id self, SEL _cmd) { return YES; }
static BOOL n_alwaysYes1(id self, SEL _cmd, id a) { return YES; }

static void n_report4(id self, SEL _cmd, id user, long type, id msg, BOOL isPushKit) {
    BOOL bgOnly = DTBool(kBackgroundOnly, YES);
    if ((bgOnly && gInBackground) || isPushKit) {
        [[DTCallKitCenter shared] reportIncoming:user type:type msg:msg display:nil];
        return;                     // 不再走微信自己的来电页
    }
    IMP o = DTOrigFor(object_getClass(self), _cmd);
    if (o) ((void (*)(id, SEL, id, long, id, BOOL))o)(self, _cmd, user, type, msg, isPushKit);
}

static void n_report5(id self, SEL _cmd, id user, long type, id msg,
                      BOOL isPushKit, id displayName, id completion) {
    BOOL bgOnly = DTBool(kBackgroundOnly, YES);
    if ((bgOnly && gInBackground) || isPushKit) {
        [[DTCallKitCenter shared] reportIncoming:user
                                            type:type
                                             msg:msg
                                         display:[displayName isKindOfClass:[NSString class]] ? displayName : nil];
        if (completion) {
            @try { ((void (^)(BOOL))completion)(YES); } @catch (__unused NSException *e) {}
        }
        return;
    }
    IMP o = DTOrigFor(object_getClass(self), _cmd);
    if (o) ((void (*)(id, SEL, id, long, id, BOOL, id, id))o)(self, _cmd, user, type, msg, isPushKit, displayName, completion);
}

/// PushKit 通道：微信被系统唤醒（甚至没完全启动）时由这里进来
static void n_handlePush(id self, SEL _cmd, id content, id voipInfo, long type, id completion) {
    id payload = voipInfo;
    @try {
        if ([voipInfo respondsToSelector:sel_registerName("payload")]) {
            payload = ((id (*)(id, SEL))[voipInfo methodForSelector:sel_registerName("payload")])(voipInfo, sel_registerName("payload"));
        }
    } @catch (__unused NSException *e) {}

    NSString *name = nil;
    if ([payload isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = payload;
        id n = d[@"nickname"] ?: d[@"from"];
        if ([n isKindOfClass:[NSString class]]) name = n;
    }
    if (payload) {
        [[DTCallKitCenter shared] reportIncoming:nil type:type msg:payload display:name];
    }
    IMP o = DTOrigFor(object_getClass(self), _cmd);
    if (o) ((void (*)(id, SEL, id, id, long, id))o)(self, _cmd, content, voipInfo, type, completion);
}

#pragma mark - 安装

void DTModuleCallKitInstall(void) {
    if (gDidInstall) return;
    gDidInstall = YES;
    if (!DTBool(kEn, YES)) { DTLog(@"callkit: disabled"); return; }

    int n = 0;
    n += DTHookSelectorInImage("WeChat", "isDeviceCallkitAvailable", (IMP)n_alwaysYes);
    n += DTHookSelectorInImage("WeChat", "isCallkitAvailable", (IMP)n_alwaysYes);
    n += DTHookSelectorInImage("WeChat", "getIfCanUseCX:", (IMP)n_alwaysYes1);
    n += DTHookSelectorInImage("WeChat", "onServiceEnterBackground", (IMP)n_serviceBackground);
    n += DTHookSelectorInImage("WeChat", "onServiceEnterForeground", (IMP)n_serviceForeground);

    SEL r4 = sel_registerName("reportIncomingCallFromUser:ofType:withMsg:isPushKit:");
    if (DTFirstClassForSelector("reportIncomingCallFromUser:ofType:withMsg:isPushKit:")) {
        n += DTHookSelectorInImage("WeChat", "reportIncomingCallFromUser:ofType:withMsg:isPushKit:",
                                   (IMP)n_report4);
    }
    (void)r4;

    if (DTFirstClassForSelector("reportIncomingCallFromUser:ofType:withMsg:isPushKit:displayName:completion:")) {
        n += DTHookSelectorInImage("WeChat",
                                   "reportIncomingCallFromUser:ofType:withMsg:isPushKit:displayName:completion:",
                                   (IMP)n_report5);
    }

    if (DTFirstClassForSelector("handleVoIPPushInfoContent:VoIPPushInfo:type:completion:")) {
        n += DTHookSelectorInImage("WeChat", "handleVoIPPushInfoContent:VoIPPushInfo:type:completion:",
                                   (IMP)n_handlePush);
    }

    Class dev = NSClassFromString(@"UIDevice");
    if (dev) {
        // 微信有时用 UIDevice 判断是否支持 CallKit，兜一层
        SEL s = sel_registerName("supportsCallKit");
        if (class_getInstanceMethod(dev, s)) DTHookMsg(dev, s, (IMP)n_alwaysYes);
    }

    // 预热 provider：第一次 report 之前必须实例化，否则 iOS 会丢掉首个来电
    (void)[DTCallKitCenter shared];

    DTLog(@"callkit: armed %d selectors", n);
}
