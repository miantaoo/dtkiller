//
//  DTBatch4.m —— P1-14 记账本 / P1-15 群折叠 / P1-16 红点 / P1-17 拍一拍 / P1-18 退群通知
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#import "DTHook.h"
#import "DTConfig.h"
#import "DTLog.h"
#import "DTClassFinder.h"
#import "DTUtil.h"
#import "DTModules.h"

static NSString *DTIvarStr(id o, const char *k)
{
    id v = DTGetIvar(o, k);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static NSInteger DTIvarInt(id o, const char *k)
{
    id v = DTGetIvar(o, k);
    return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : 0;
}

// ═══════════════════════════════════════════════════════════════════════════
#pragma mark - P1-14 记账本
// ═══════════════════════════════════════════════════════════════════════════

#define kLedgerEnable @"DTLedgerEnable"

static BOOL gLedgerOn;
static NSMutableArray<NSDictionary *> *gLedger;
static NSString *gLedgerPath;
static NSMutableSet<NSString *> *gLedgerSeen;

static void DTLedgerLoad(void)
{
    if (gLedger) return;
    gLedger = [NSMutableArray array];
    gLedgerSeen = [NSMutableSet set];

    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/DTKiller"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    gLedgerPath = [dir stringByAppendingPathComponent:@"ledger.json"];

    NSData *d = [NSData dataWithContentsOfFile:gLedgerPath];
    if (d) {
        id arr = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
        if ([arr isKindOfClass:[NSArray class]]) [gLedger addObjectsFromArray:arr];
    }
    for (NSDictionary *e in gLedger) {
        NSString *k = e[@"id"];
        if (k) [gLedgerSeen addObject:k];
    }
    DTLog(@"ledger: 载入 %lu 条", (unsigned long)gLedger.count);
}

static void DTLedgerSave(void)
{
    if (!gLedgerPath) return;
    NSData *d = [NSJSONSerialization dataWithJSONObject:gLedger options:NSJSONWritingPrettyPrinted error:NULL];
    if (d) [d writeToFile:gLedgerPath atomically:YES];
}

static void DTLedgerRecord(NSString *ident, NSString *kind, double yuan, NSString *peer, NSString *memo)
{
    if (!gLedgerOn || ident.length == 0) return;
    DTLedgerLoad();
    if ([gLedgerSeen containsObject:ident]) return;
    [gLedgerSeen addObject:ident];

    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *ts = [f stringFromDate:[NSDate date]];

    [gLedger addObject:@{
        @"id"   : ident,
        @"time" : ts,
        @"kind" : kind ?: @"?",
        @"yuan" : @(yuan),
        @"peer" : peer ?: @"",
        @"memo" : memo ?: @"",
    }];
    DTLedgerSave();
    DTLog(@"ledger: 记 +%.2f 元（%@ / %@）", yuan, kind, peer ?: @"");
}

/// 记账本处理体。转发原实现由 DTHBDispatch 统一负责，这里只管记账。
static void DTLedgerHandle(id self, SEL _cmd, id response, id request)
{
    if (!gLedgerOn || !response) return;

    NSString *from = DTIvarStr(response, "m_nsFromUsr");
    NSInteger type = DTIvarInt(response, "m_uiMessageType");
    id fee = DTGetIvar(response, "m_lTotalFee") ?: DTGetIvar(response, "m_uiTotalFee");
    double fen = [fee respondsToSelector:@selector(doubleValue)] ? [fee doubleValue] : 0;
    if (fen <= 0) return;

    // 用入口 selector 区分红包/转账。m_uiMessageType 的 34 是语音消息，
    // 拿它判红包会让所有红包都记成「转账」。
    BOOL isTransfer = (strcmp(sel_getName(_cmd), "OnTransferResponse:Request:") == 0);

    NSString *ident = DTIvarStr(response, "m_nsMsgId");
    if (!ident) ident = [NSString stringWithFormat:@"%@-%ld-%.0f", from ?: @"", (long)type, fen];

    DTLedgerRecord(ident, isTransfer ? @"转账" : @"红包", fen / 100.0, from, nil);
}

static void DTLedgerInstall(void)
{
    if (!DTBool(kLedgerEnable, NO)) { DTLog(@"ledger: off"); return; }
    DTLedgerLoad();
    gLedgerOn = YES;

    // 挂到统一闸门上，不自己再 hook 一次（否则会和红包/收款互相递归）
    DTSetHongbaoExtraHandler(DTLedgerHandle);
    int n = DTHBHookOnce();
    DTLog(@"ledger: 挂在统一闸门上（%d 个点）", n);
}

/// 给设置页用：按月汇总
NSDictionary<NSString *, NSNumber *> *DTLedgerMonthlySummary(void)
{
    DTLedgerLoad();
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (NSDictionary *e in gLedger) {
        NSString *t = e[@"time"] ?: @"";
        if (t.length < 7) continue;
        NSString *month = [t substringToIndex:7];
        double v = [e[@"yuan"] doubleValue];
        m[month] = @([m[month] doubleValue] + v);
    }
    return m;
}

// ═══════════════════════════════════════════════════════════════════════════
#pragma mark - P1-15 群折叠
// ═══════════════════════════════════════════════════════════════════════════

#define kFoldEnable @"DTGroupFoldEnable"
#define kFoldMuteOnly @"DTGroupFoldMuteOnly"

static BOOL gFoldOn, gFoldMuteOnly;

/// 会话 cell 的「来消息」数据项，判断是不是免打扰群。
static BOOL DTIsMutedGroup(id info)
{
    if (!info) return NO;
    NSString *usr = DTIvarStr(info, "m_nsUserName");
    if (!usr) usr = DTIvarStr(info, "m_nsUsrName");
    if (!usr || [usr rangeOfString:@"@chatroom"].location == NSNotFound) return NO;

    if (!gFoldMuteOnly) return YES;
    id mute = DTGetIvar(info, "m_uiMuteFlag");
    if ([mute respondsToSelector:@selector(integerValue)] && [mute integerValue] != 0) return YES;
    id quiet = DTGetIvar(info, "m_bSilent");
    if ([quiet respondsToSelector:@selector(boolValue)] && [quiet boolValue]) return YES;
    return NO;
}

/// 折叠 = 把免打扰群的行高压成 0（视觉上收进「群聊」那一行下面）。
/// 不动数据源，所以排序、未读数、点击路由都不受影响；代价是「展开」也只能靠原列表滚动。
static CGFloat DTHeightForRow(id self, SEL _cmd, id tv, id indexPath)
{
    IMP o = DTOrigFor(object_getClass(self), _cmd);
    CGFloat h = o ? ((CGFloat (*)(id, SEL, id, id))o)(self, _cmd, tv, indexPath) : 44.0;

    if (!gFoldOn) return h;
    id info = nil;
    for (NSString *fn in @[@"getSessionInfoAtIndexPath:", @"sessionInfoAtIndexPath:"]) {
        SEL s = NSSelectorFromString(fn);
        if ([self respondsToSelector:s]) {
            info = ((id (*)(id, SEL, id))objc_msgSend)(self, s, indexPath);
            break;
        }
    }
    if (DTIsMutedGroup(info)) return 0.01;
    return h;
}

static void DTFoldInstall(void)
{
    if (!DTBool(kFoldEnable, NO)) { DTLog(@"fold: off"); return; }
    gFoldOn = YES;
    gFoldMuteOnly = DTBool(kFoldMuteOnly, YES);

    int n = 0;
    for (NSString *cn in DTOwnerClassesForSelector("tableView:heightForRowAtIndexPath:")) {
        if ([cn rangeOfString:@"Session"].location == NSNotFound) continue;
        Class c = NSClassFromString(cn);
        if (c && DTHookMsg(c, @selector(tableView:heightForRowAtIndexPath:), (IMP)DTHeightForRow)) n++;
    }
    DTLog(@"fold: 装了 %d 个点（只压免打扰群=%d）", n, (int)gFoldMuteOnly);
}

// ═══════════════════════════════════════════════════════════════════════════
#pragma mark - P1-16 红点消除
// ═══════════════════════════════════════════════════════════════════════════

#define kBadgeEnable @"DTBadgeEnable"

static BOOL gBadgeOn;

/// 只隐藏红点控件，不清业务状态。底部「微信」的未读数字不受影响。
static void DTBadgeSetHidden(id self, SEL _cmd, BOOL hidden)
{
    IMP o = DTOrigFor(object_getClass(self), _cmd);
    NSString *cn = NSStringFromClass([self class]);
    BOOL isDot = [cn rangeOfString:@"Dot"].location != NSNotFound ||
                 [cn rangeOfString:@"Badge"].location != NSNotFound;
    if (gBadgeOn && isDot && !hidden) {
        if (o) ((void (*)(id, SEL, BOOL))o)(self, _cmd, YES);
        return;
    }
    if (o) ((void (*)(id, SEL, BOOL))o)(self, _cmd, hidden);
}

static void DTBadgeSetText(id self, SEL _cmd, id text)
{
    IMP o = DTOrigFor(object_getClass(self), _cmd);
    if (gBadgeOn) {
        NSString *cn = NSStringFromClass([self class]);
        if ([cn rangeOfString:@"RedDot"].location != NSNotFound) {
            if (o) ((void (*)(id, SEL, id))o)(self, _cmd, nil);
            return;
        }
    }
    if (o) ((void (*)(id, SEL, id))o)(self, _cmd, text);
}

static void DTBadgeInstall(void)
{
    if (!DTBool(kBadgeEnable, NO)) { DTLog(@"badge: off"); return; }
    gBadgeOn = YES;

    NSUInteger n = 0;
    for (NSString *cn in DTWeChatClassNames()) {
        if ([cn rangeOfString:@"Dot"].location == NSNotFound &&
            [cn rangeOfString:@"Badge"].location == NSNotFound) continue;
        Class c = NSClassFromString(cn);
        if (!c) continue;
        if (![c isSubclassOfClass:[UIView class]]) continue;

        if (class_getInstanceMethod(c, @selector(setHidden:))) {
            if (DTHookMsg(c, @selector(setHidden:), (IMP)DTBadgeSetHidden)) n++;
        }
        if (class_getInstanceMethod(c, @selector(setText:))) {
            if (DTHookMsg(c, @selector(setText:), (IMP)DTBadgeSetText)) n++;
        }
    }
    DTLog(@"badge: 装了 %lu 个点", (unsigned long)n);
}

// ═══════════════════════════════════════════════════════════════════════════
#pragma mark - P1-17 拍一拍后缀
// ═══════════════════════════════════════════════════════════════════════════

#define kPatEnable @"DTPatEnable"
#define kPatSuffix @"DTPatSuffix"

static BOOL gPatOn;
static NSString *gPatSuffix;

/// 拍一拍走系统消息，改的是生成文案那一步。
/// 只改自己发起的那条，别人拍的保持原样。
static id DTPatMakeText(id self, SEL _cmd, id wrap)
{
    IMP o = DTOrigFor(object_getClass(self), _cmd);
    id r = o ? ((id (*)(id, SEL, id))o)(self, _cmd, wrap) : nil;
    if (!gPatOn || !gPatSuffix.length) return r;
    if (![r isKindOfClass:[NSString class]]) return r;

    NSString *s = (NSString *)r;
    if ([s rangeOfString:@"拍了拍"].location == NSNotFound) return r;
    if ([s rangeOfString:gPatSuffix].location != NSNotFound) return r;
    return [s stringByAppendingString:gPatSuffix];
}

static void DTPatInstall(void)
{
    if (!DTBool(kPatEnable, NO)) { DTLog(@"pat: off"); return; }
    gPatSuffix = DTStr(kPatSuffix, @" 并摸了摸头");
    if (!gPatSuffix.length) { DTLog(@"pat: 后缀为空"); return; }
    gPatOn = YES;

    int n = 0;
    static const char *sels[] = { "genPatMessageContent:", "makePatText:", "patTextForWrap:" };
    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        for (NSString *cn in DTOwnerClassesForSelector(sels[i])) {
            Class c = NSClassFromString(cn);
            if (c && DTHookMsg(c, sel_registerName(sels[i]), (IMP)DTPatMakeText)) n++;
        }
    }
    DTLog(@"pat: 后缀「%@」，装了 %d 个点", gPatSuffix, n);
}

// ═══════════════════════════════════════════════════════════════════════════
#pragma mark - P1-18 退群通知
// ═══════════════════════════════════════════════════════════════════════════

#define kLeaveEnable @"DTGroupLeaveEnable"

static BOOL gLeaveOn;

static void DTNotify(NSString *title, NSString *body)
{
    if (!title.length) return;
    UNMutableNotificationContent *c = [[UNMutableNotificationContent alloc] init];
    c.title = title;
    c.body  = body ?: @"";
    c.sound = nil;

    UNNotificationRequest *r = [UNNotificationRequest requestWithIdentifier:[[NSUUID UUID] UUIDString]
                                                                  content:c trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:r withCompletionHandler:nil];
    DTLog(@"leave: 通知 %@ / %@", title, body);
}

/// 群成员变更：有成员身份就精确显示，没有就只说「有变动」。
static void DTLeaveOnMemberChange(id self, SEL _cmd, id a, id b)
{
    IMP o = DTOrigFor(object_getClass(self), _cmd);
    if (o) ((void (*)(id, SEL, id, id))o)(self, _cmd, a, b);
    if (!gLeaveOn) return;

    NSString *who = nil;
    NSString *room = nil;
    for (id x in @[a ?: [NSNull null], b ?: [NSNull null]]) {
        if (x == [NSNull null]) continue;
        if (!who)  who  = DTIvarStr(x, "m_nsNickName") ?: DTIvarStr(x, "m_nsUsrName");
        if (!room) room = DTIvarStr(x, "m_nsChatRoomName") ?: DTIvarStr(x, "m_nsUsrName");
    }

    if (who && room) {
        DTNotify([NSString stringWithFormat:@"%@ 退出了群聊", who], room);
    } else {
        DTNotify(@"群成员有变动", room ?: @"");
    }
}

static void DTLeaveInstall(void)
{
    if (!DTBool(kLeaveEnable, NO)) { DTLog(@"leave: off"); return; }
    gLeaveOn = YES;

    int n = 0;
    static const char *sels[] = {
        "OnModChatRoomMember:", "onModChatRoomMember:",
        "OnQuitChatRoom:", "onQuitChatRoom:",
    };
    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        for (NSString *cn in DTOwnerClassesForSelector(sels[i])) {
            Class c = NSClassFromString(cn);
            if (!c) continue;
            Method m = class_getInstanceMethod(c, sel_registerName(sels[i]));
            if (!m || method_getNumberOfArguments(m) != 3) continue;
            if (DTHookMsg(c, sel_registerName(sels[i]), (IMP)DTLeaveOnMemberChange)) n++;
        }
    }
    DTLog(@"leave: 装了 %d 个点（事件不存在时不会触发，属于预期）", n);
}

// ═══════════════════════════════════════════════════════════════════════════

void DTModuleBatch4Install(void)
{
    @autoreleasepool {
        DTLedgerInstall();
        DTFoldInstall();
        DTBadgeInstall();
        DTPatInstall();
        DTLeaveInstall();
    }
}
