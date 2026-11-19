//
//  DTBatch3.m —— P0-10 发图上限 / P0-11 抢红包 / P1-12 收款自动回复 / P1-13 @全体
//
//  这四项都要跟微信的消息层打交道，全部走「探测 selector → 存在才 hook」。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "DTHook.h"
#import "DTConfig.h"
#import "DTLog.h"
#import "DTClassFinder.h"
#import "DTUtil.h"
#import "DTModules.h"

static NSArray<NSString *> *DTObjArray(NSString *key);   // 前置声明（定义在下方）
static NSInteger DTWrapType(id wrap)
{
    id v = DTGetIvar(wrap, "m_uiMessageType");
    if ([v respondsToSelector:@selector(integerValue)]) return [v integerValue];
    return -1;
}

static NSString *DTWrapFrom(id wrap)
{
    id v = DTGetIvar(wrap, "m_nsFromUsr");
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

/// OnWCToHongbaoCommonResponse:Request: 的 response 是红包 PB 响应对象，**不是** CMessageWrap。
/// 直接把它喂给 OpenRedEnvelopesRequest: 会读不到字段然后崩，所以先把真正的消息 wrap 揪出来：
/// 1) 参数本身就像消息（能读 m_nsFromUsr / m_uiMessageType）
/// 2) 否则翻它身上挂的 wrap 类 ivar（一层就够，再深就是猜了）
/// 全部失败就放弃这一单，记一行日志 —— 宁可漏抢，不能崩。
static id DTPickMsgWrap(id a, id b)
{
    NSArray *objs = @[a ?: [NSNull null], b ?: [NSNull null]];
    for (id o in objs) {
        if (o == [NSNull null]) continue;
        if (DTWrapFrom(o) || DTWrapType(o) >= 0) return o;
    }

    NSArray<NSString *> *names = @[@"m_msgWrap", @"m_oMsgWrap", @"m_messageWrap",
                                   @"m_wrap", @"m_oWrap", @"m_msg", @"m_oMessage", @"msgWrap"];
    for (id o in objs) {
        if (o == [NSNull null]) continue;
        for (NSString *n in names) {
            id v = DTGetIvar(o, n.UTF8String);
            if (!v) continue;
            if (DTWrapFrom(v) || DTWrapType(v) >= 0) return v;
        }
    }
    return nil;
}

static NSString *DTWrapContent(id wrap)
{
    id v = DTGetIvar(wrap, "m_nsContent");
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static uint64_t DTHash(NSString *s)
{
    uint64_t h = 1469598103934665603ULL;
    const char *p = [s UTF8String];
    if (!p) return 0;
    while (*p) { h ^= (unsigned char)*p++; h *= 1099511628211ULL; }
    return h;
}

// ═══════════════════════════════════════════════════════════════════════════
#pragma mark - P0-10 发图上限
// ═══════════════════════════════════════════════════════════════════════════

#define kImgLimitEnable @"DTImageLimitEnable"
#define kImgLimitMax    @"DTImageLimitMax"

static NSInteger gImgLimit = 20;
static void (*gOrigSetMax)(id, SEL, NSInteger);

static void DTImgSetMax(id self, SEL _cmd, NSInteger v)
{
    DTLog(@"imglimit: setter 被调用 %ld → %ld", (long)v, (long)gImgLimit);
    gOrigSetMax(self, _cmd, gImgLimit);
}

static NSInteger DTImgGetMax(id self, SEL _cmd)
{
    return gImgLimit;
}

static void DTImgLimitInstall(void)
{
    if (!DTBool(kImgLimitEnable, NO)) { DTLog(@"imglimit: off"); return; }

    gImgLimit = DTInt(kImgLimitMax, 20);
    if (gImgLimit < 9)  gImgLimit = 9;
    if (gImgLimit > 99) gImgLimit = 99;

    NSArray<NSString *> *setOwners = DTOwnerClassesForSelector("setMaxImageCount:");
    if (setOwners.count == 0) {
        DTLog(@"imglimit: 8.0.56 上没有 setMaxImageCount:，本模块不生效（不崩）");
        return;
    }

    int n = 0;
    for (NSString *cn in setOwners) {
        Class c = NSClassFromString(cn);
        if (!c) continue;
        Method m = class_getInstanceMethod(c, @selector(setMaxImageCount:));
        if (!m) continue;
        if (method_getNumberOfArguments(m) != 3) continue;
        gOrigSetMax = (void (*)(id, SEL, NSInteger))DTHookMsg(c, @selector(setMaxImageCount:), (IMP)DTImgSetMax);
        if (gOrigSetMax) n++;

        SEL g = @selector(maxImageCount);
        if (class_getInstanceMethod(c, g)) {
            if (DTHookMsg(c, g, (IMP)DTImgGetMax)) n++;
        }
    }
    DTLog(@"imglimit: 上限 %ld，装了 %d 个点", (long)gImgLimit, n);
}

// ═══════════════════════════════════════════════════════════════════════════
#pragma mark - P0-11 抢红包
// ═══════════════════════════════════════════════════════════════════════════

#define kRedEnable  @"DTRedPacketEnable"
#define kRedMinSec  @"DTRedPacketMinSec"
#define kRedMaxSec  @"DTRedPacketMaxSec"
#define kRedGroups  @"DTRedPacketGroups"    // 仅这些群；空 = 全部

static BOOL gRedOn;
static double gRedMin = 3.0, gRedMax = 8.0;
static NSArray<NSString *> *gRedGroups;
static NSMutableSet<NSString *> *gRedSeen;      // 已处理过的 msgId（去重）
static NSMutableDictionary<NSString *, NSString *> *gRedState;  // msgId → 三态记录

static BOOL DTRedGroupAllowed(NSString *fromUsr)
{
    if (!fromUsr) return NO;
    if (gRedGroups.count == 0) return YES;      // 没配置 = 全部群
    for (NSString *g in gRedGroups) {
        if ([fromUsr isEqualToString:g] || [fromUsr hasPrefix:g]) return YES;
    }
    return NO;
}

static NSString *DTRedMsgId(id wrap)
{
    for (NSString *fn in @[@"m_nsMsgId", @"m_nsClientMsgId"]) {
        id v = DTGetIvar(wrap, fn.UTF8String);
        if (![v isKindOfClass:[NSString class]] || [(NSString *)v length] == 0) {
            SEL s = NSSelectorFromString(fn);
            if ([wrap respondsToSelector:s]) {
                v = ((id (*)(id, SEL))objc_msgSend)(wrap, s);
            }
        }
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
    }
    // 兜底：服务端 id / 本地 id / 创建时间 拼一个稳定 key。
    // 不能用「发送者哈希」代替 —— 同一个人发的第二个红包会被当成重复而永远不抢。
    NSMutableString *k = [NSMutableString string];
    for (NSString *fn in @[@"m_n64MesSvrID", @"m_uiMesLocalID", @"m_uiCreateTime"]) {
        id v = DTGetIvar(wrap, fn.UTF8String);
        if (v && [v longLongValue] != 0) [k appendFormat:@"%@|", v];
    }
    return k.length ? k : nil;
}

/// 真正发领取请求。8.x 上 OpenRedEnvelopesRequest: 直接吃 msgWrap。
static BOOL DTRedSendOpen(id mgr, id wrap, NSString *msgId)
{
    SEL s = @selector(OpenRedEnvelopesRequest:);
    if (![mgr respondsToSelector:s]) {
        s = NSSelectorFromString(@"OpenRedEnvelopesRequest:");
        if (![mgr respondsToSelector:s]) {
            DTLog(@"red: %@ 没有 OpenRedEnvelopesRequest:", NSStringFromClass([mgr class]));
            return NO;
        }
    }
    ((void (*)(id, SEL, id))objc_msgSend)(mgr, s, wrap);
    gRedState[msgId] = @"req-sent";
    DTLog(@"red: 已发请求 %@", msgId);
    return YES;
}

static void DTRedScheduleOpen(id mgr, id wrap)
{
    NSString *msgId = DTRedMsgId(wrap);
    if (!msgId) {
        // 连 ID 都取不到就别抢了：随便编一个 key 会让去重表失去意义。
        DTLog(@"red: 无法取到消息 id，跳过这条");
        return;
    }

    if ([gRedSeen containsObject:msgId]) return;
    [gRedSeen addObject:msgId];
    gRedState[msgId] = @"seen";

    double span = gRedMax - gRedMin;
    if (span < 0) span = 0;
    double delay = gRedMin + (double)(DTHash(msgId) % 1000) / 1000.0 * span;

    DTLog(@"red: 收到 %@，%.1f 秒后领", msgId, delay);
    __weak id wmgr = mgr;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id m = wmgr;
        if (!m) return;
        if (!DTRedSendOpen(m, wrap, msgId)) return;
    });
}

/// 红包消息处理体。原实现转发与开关判断都在 DTHBDispatch 里做。
static void DTRedHandle(id self, id response, id request)
{
    id wrap = DTPickMsgWrap(response, request);
    if (!wrap) {
        DTLog(@"red: response(%@)/request(%@) 里没有 msgWrap，跳过",
              NSStringFromClass([response class]), NSStringFromClass([request class]));
        return;
    }

    NSString *from = DTWrapFrom(wrap);
    if (!DTRedGroupAllowed(from)) {
        DTLog(@"red: %@ 不在指定群，跳过", from ?: @"?");
        return;
    }

    DTRedScheduleOpen(self, wrap);
}

static void DTRedInstall(void)
{
    if (!DTBool(kRedEnable, NO)) { DTLog(@"red: off"); return; }

    gRedOn   = YES;
    gRedMin  = DTDouble(kRedMinSec, 3.0);
    gRedMax  = DTDouble(kRedMaxSec, 8.0);
    if (gRedMin < 0.5) gRedMin = 0.5;
    if (gRedMax > 15.0) gRedMax = 15.0;
    if (gRedMax < gRedMin) gRedMax = gRedMin;

    gRedGroups = DTObjArray(kRedGroups);

    if (!gRedSeen)  gRedSeen  = [NSMutableSet set];
    if (!gRedState) gRedState = [NSMutableDictionary dictionary];

    int n = DTHBHookOnce();
    DTLog(@"red: 延迟 %.1f-%.1f 秒，指定群 %lu 个，装了 %d 个点",
          gRedMin, gRedMax, (unsigned long)gRedGroups.count, n);
}

// ═══════════════════════════════════════════════════════════════════════════
#pragma mark - P1-12 收款自动回复
// ═══════════════════════════════════════════════════════════════════════════

#define kPayReplyEnable  @"DTPayReplyEnable"
#define kPayReplyList    @"DTPayReplyList"     // 白名单 wxid

// 数组型配置：既接受 NSArray，也接受设置页/手填的「逗号分隔」字符串
static NSArray *DTObjArray(NSString *key) {
    id v = DTObj(key);
    if ([v isKindOfClass:[NSArray class]]) return v;
    if ([v isKindOfClass:[NSString class]]) {
        NSMutableArray *a = [NSMutableArray array];
        NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
        for (NSString *s in [(NSString *)v componentsSeparatedByString:@","]) {
            NSString *t = [s stringByTrimmingCharactersInSet:ws];
            if (t.length) [a addObject:t];
        }
        return a;
    }
    return @[];
}
#define kPayReplyText    @"DTPayReplyText"     // 支持 [金额]

static BOOL gPayReplyOn;
static NSArray<NSString *> *gPayList;
static NSString *gPayText;
static NSMutableDictionary<NSString *, NSDate *> *gPayLast;

static BOOL DTPayWhitelisted(NSString *from)
{
    if (!from) return NO;
    for (NSString *w in gPayList) {
        if ([from isEqualToString:w]) return YES;
    }
    return NO;
}

static void DTSendText(id mgr, NSString *to, NSString *text)
{
    static const char *trySels[] = {
        "AsyncSendMessage:", "AsyncSendMessage:Scene:", "SendMessage:"
    };
    for (size_t i = 0; i < sizeof(trySels) / sizeof(trySels[0]); i++) {
        SEL s = sel_registerName(trySels[i]);
        if (![mgr respondsToSelector:s]) continue;
        if (i == 2) {
            ((void (*)(id, SEL, NSString *))objc_msgSend)(mgr, s, text);
            return;
        }
        ((void (*)(id, SEL, NSString *))objc_msgSend)(mgr, s, text);
        DTLog(@"pay: 用 %s 发给 %@", trySels[i], to);
        return;
    }
    DTLog(@"pay: 找不到发消息入口");
}

static void DTPayHandle(id self, id response, id request)
{
    id wrap = response;
    NSString *from = DTWrapFrom(wrap);
    if (!DTPayWhitelisted(from)) return;

    // 同一会话 5 秒内只回一次，防重复回调刷屏
    NSDate *last = gPayLast[from];
    if (last && -[last timeIntervalSinceNow] < 5.0) return;
    gPayLast[from] = [NSDate date];

    NSString *text = gPayText;
    id amount = DTGetIvar(wrap, "m_lTotalFee") ?: DTGetIvar(wrap, "m_uiTotalFee");
    if ([amount respondsToSelector:@selector(doubleValue)] && [amount doubleValue] > 0) {
        double fen = [amount doubleValue];
        NSString *s = [NSString stringWithFormat:@"%.2f", fen / 100.0];
        text = [text stringByReplacingOccurrencesOfString:@"[金额]" withString:s];
    }

    id svc = DTServiceNamed("CMessageMgr");
    if (!svc) svc = self;
    DTSendText(svc, from, text);
    DTLog(@"pay: 回复 %@：%@", from, text);
}

static void DTPayReplyInstall(void)
{
    if (!DTBool(kPayReplyEnable, NO)) { DTLog(@"pay: off"); return; }

    gPayList = DTObjArray(kPayReplyList);
    if (gPayList.count == 0) {
        DTLog(@"pay: 白名单为空，本模块不生效");
        return;
    }

    gPayText = DTStr(kPayReplyText, @"已收到，谢谢！");
    gPayReplyOn = YES;
    if (!gPayLast) gPayLast = [NSMutableDictionary dictionary];

    int n = DTHBHookOnce();
    DTLog(@"pay: 白名单 %lu 人，装了 %d 个点", (unsigned long)gPayList.count, n);
}

// ═══════════════════════════════════════════════════════════════════════════
#pragma mark - 红包/转账统一闸门
// ═══════════════════════════════════════════════════════════════════════════

// 同一对 selector 有三个模块想要：抢红包、收款回复、记账本。
// 以前各装各的，后装的把先装的当 orig → 一收红包就自递归炸栈。
// 现在只有一个 hook，内部按开关顺序调各处理体。
static DTHBExtraFn gHBExtra;
static NSMutableSet<NSString *> *gHBHooked;

void DTSetHongbaoExtraHandler(DTHBExtraFn fn) { gHBExtra = fn; }

static void DTHBDispatch(id self, SEL _cmd, id response, id request)
{
    IMP o = DTOrigFor(object_getClass(self), _cmd);
    if (o) ((void (*)(id, SEL, id, id))o)(self, _cmd, response, request);

    if (gRedOn)      DTRedHandle(self, response, request);
    if (gPayReplyOn) DTPayHandle(self, response, request);
    if (gHBExtra)    gHBExtra(self, _cmd, response, request);
}

int DTHBHookOnce(void)
{
    if (!gHBHooked) gHBHooked = [NSMutableSet set];
    static const char *sels[] = { "OnWCToHongbaoCommonResponse:Request:", "OnTransferResponse:Request:" };
    int n = 0;
    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        for (NSString *cn in DTOwnerClassesForSelector(sels[i])) {
            NSString *key = [NSString stringWithFormat:@"%s>%@", sels[i], cn];
            if ([gHBHooked containsObject:key]) continue;
            Class c = NSClassFromString(cn);
            if (c && DTHookMsg(c, sel_registerName(sels[i]), (IMP)DTHBDispatch)) {
                [gHBHooked addObject:key];
                n++;
            }
        }
    }
    return n;
}

// ═══════════════════════════════════════════════════════════════════════════
#pragma mark - P1-13 @全体成员
// ═══════════════════════════════════════════════════════════════════════════

#define kAtAllEnable @"DTAtAllEnable"
#define kAtAllWords  @"DTAtAllWords"

static BOOL gAtAllOn;
static NSArray<NSString *> *gAtWords;

/// 发送前改消息：把触发词换成微信自己的 @ 结构。
/// 群成员列表拿不到就直接放行原文，绝不硬造 at 列表（那会发出乱码）。
static void DTAtPatchWrap(id wrap)
{
    if (!gAtAllOn || !wrap) return;

    NSString *text = DTWrapContent(wrap);
    if (text.length == 0) return;

    NSString *hit = nil;
    for (NSString *w in gAtWords) {
        if ([text containsString:w]) { hit = w; break; }
    }
    if (!hit) return;

    id to = DTGetIvar(wrap, "m_nsToUsr");
    if (![to isKindOfClass:[NSString class]] || [to rangeOfString:@"@chatroom"].location == NSNotFound) return;

    DTSetIvar(wrap, "m_nsAtUserList", @"notify@all");
    DTSetIvar(wrap, "m_bIsAtMe", [NSNumber numberWithBool:NO]);
    DTLog(@"atat: 会话 %@ 触发 @全体（%@）", to, hit);
}

static void DTAtAsyncOnAddMsg(id self, SEL _cmd, id a, id wrap)
{
    DTAtPatchWrap(wrap);
    IMP o = DTOrigFor(object_getClass(self), _cmd);
    if (o) ((void (*)(id, SEL, id, id))o)(self, _cmd, a, wrap);
}

static void DTAtInstall(void)
{
    if (!DTBool(kAtAllEnable, NO)) { DTLog(@"atat: off"); return; }

    id w = DTObj(kAtAllWords);
    gAtWords = [w isKindOfClass:[NSArray class]] && [(NSArray *)w count] ? w : @[@"@所有人", @"@全体成员"];
    gAtAllOn = YES;

    int n = 0;
    static const char *sels[] = { "AsyncOnAddMsg:MsgWrap:", "AddMsg:MsgWrap:" };
    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        for (NSString *cn in DTOwnerClassesForSelector(sels[i])) {
            Class c = NSClassFromString(cn);
            if (c && DTHookMsg(c, sel_registerName(sels[i]), (IMP)DTAtAsyncOnAddMsg)) n++;
        }
    }
    DTLog(@"atat: 触发词 %@，装了 %d 个点", [gAtWords componentsJoinedByString:@"/"], n);
}

// ═══════════════════════════════════════════════════════════════════════════

void DTModuleBatch3Install(void)
{
    @autoreleasepool {
        DTImgLimitInstall();
        DTRedInstall();
        DTPayReplyInstall();
        DTAtInstall();
    }
}
