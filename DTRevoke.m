//
//  DTRevoke.m —— 防撤回
//
//  原插件证据：
//    MiYou.dylib  selector：onRevokeMsg:（唯一实现者）
//                 配置键：WBRevokeEnable = true（用户实际开着）
//                         mIsRevokeMsg / mIsNoRevokeContent
//    WCPureExtension.dylib 也 hook 了 onRevokeMsg:（hookscan 848894 / 8488d4，
//                 两个类各挂一次，同一 imp 849120），但没有开关键 —— 常开。
//    HB / Misaka / PKC 里 revoke 相关条目为 0（PKC 的 21 条是「撤回后自动回复」）。
//
//  原理：微信收到 <sysmsg type="revokemsg"> 后走
//        -[CMessageMgr onRevokeMsg:]（参数是那条 sysmsg 的 CMessageWrap），
//        原实现做三件事：①按 newmsgid 找到被撤回的消息 ②删掉它
//        ③插一条「xx 撤回了一条消息」。直接 return 不调原实现 → 消息还在，提示也不出现。
//
//  代价（必须知道）：
//    1. 这是**单边**的。对方手机上那条已经删了，他看不到；你这边还在。
//       换设备、重装、清缓存后原消息不会回来（服务端已记撤回）。
//    2. 你自己撤回时，你这边也不会变「已撤回」——因为拦的是同一个入口。
//       要区分的话见文件末尾注释。
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "DTHook.h"
#import "DTConfig.h"
#import "DTClassFinder.h"
#import "DTLog.h"
#import "DTModules.h"

static NSString *const kEn = @"DTRevokeEnable";
static NSString *const kAllowSelf = @"DTRevokeAllowSelf";

static BOOL gDidInstall = NO;

/// 本机发起撤回的时刻。用于在 onRevokeMsg: 里区分「自己撤回」与「别人撤回」。
static NSTimeInterval gSelfRevokeAt = 0;

/// 时间窗：自己点完撤回后 3 秒内到达的 onRevokeMsg: 视为自己撤回。
/// 不用解析 sysmsg 的 replacemsg 昵称来比对 —— 昵称会改、可能是备注名，
/// 比对不可靠；而「自己刚点完撤回」这个时间相关性在实测里足够稳。
static const NSTimeInterval kSelfWindow = 3.0;

#pragma mark - hooks

static void n_onRevokeMsg(id self, SEL _cmd, id arg) {
    IMP o = DTOrigFor(object_getClass(self), _cmd);

    if (!DTBool(kEn, YES)) {
        if (o) ((void (*)(id, SEL, id))o)(self, _cmd, arg);
        return;
    }

    if (DTBool(kAllowSelf, YES) && gSelfRevokeAt > 0) {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - gSelfRevokeAt < kSelfWindow) {
            NSTimeInterval dt = now - gSelfRevokeAt;
            gSelfRevokeAt = 0;
            DTLog(@"revoke: self-revoke within %.1fs, pass through", dt);
            if (o) ((void (*)(id, SEL, id))o)(self, _cmd, arg);
            return;
        }
    }

    DTLog(@"revoke: blocked (%@)", NSStringFromClass([arg class]));
}

/// 本机发起撤回的入口：只负责记时间，然后照常转发。
static void n_selfRevoke(id self, SEL _cmd, id arg) {
    gSelfRevokeAt = [NSDate timeIntervalSinceReferenceDate];
    IMP o = DTOrigFor(object_getClass(self), _cmd);
    if (o) ((void (*)(id, SEL, id))o)(self, _cmd, arg);
}

/// 只拦「名字里带 Revoke」的 void(id) 变体，不动普通的 DelMsg:
/// （DelMsg: 是用户主动删消息也走的公共路径，拦了会出别的问题）
static void n_revokeNoop(id self, SEL _cmd, id arg) {
    DTLog(@"revoke: blocked %@", NSStringFromSelector(_cmd));
}

#pragma mark - 安装

/// 只 hook 签名恰好是 `- (void)xxx:(id)` 的实例方法，避免装到返回 BOOL 的方法上。
static int dtHookVoidID(const char *selName, IMP newImp) {
    int n = 0;
    unsigned int total = 0;
    Class *all = objc_copyClassList(&total);
    if (!all) return 0;
    SEL s = sel_registerName(selName);
    for (unsigned int i = 0; i < total; i++) {
        Class c = all[i];
        Method m = class_getInstanceMethod(c, s);
        if (!m) continue;
        if (method_getNumberOfArguments(m) != 3) continue;
        char *rt = method_copyReturnType(m);
        char r = rt ? rt[0] : 'v';
        free(rt);
        if (r != 'v') continue;
        if (DTHookMsg(c, s, newImp)) n++;
    }
    free(all);
    return n;
}

void DTModuleRevokeInstall(void) {
    if (gDidInstall) return;
    gDidInstall = YES;
    if (!DTBool(kEn, YES)) { DTLog(@"revoke: disabled"); return; }

    int n = 0;
    n += DTHookSelectorInImage("WeChat", "onRevokeMsg:", (IMP)n_onRevokeMsg);
    n += DTHookSelectorInImage("WeChat", "OnRevokeMsg:", (IMP)n_onRevokeMsg);

    // 本机发起撤回的入口。名字在各版本不统一，逐个试，只认 void(id) 签名。
    int selfn = 0;
    if (DTBool(kAllowSelf, YES)) {
        static const char *selfSels[] = {
            "RevokeMsg:", "revokeMsg:", "RevokeMessage:", "revokeMessage:",
            "onRevoke:", "RevokeMsgWithWrap:"
        };
        for (size_t i = 0; i < sizeof(selfSels) / sizeof(selfSels[0]); i++) {
            if (!strcmp(selfSels[i], "onRevokeMsg:") ||
                !strcmp(selfSels[i], "OnRevokeMsg:")) continue;
            selfn += dtHookVoidID(selfSels[i], (IMP)n_selfRevoke);
        }
    }

    // 变体兜底：扫所有类，找名字含 Revoke、签名是 void(id) 的实例方法
    int variants = 0;
    unsigned int total = 0;
    Class *all = objc_copyClassList(&total);
    if (all) {
        for (unsigned int i = 0; i < total; i++) {
            Class c = all[i];
            NSString *cn = NSStringFromClass(c);
            if (!cn.length) continue;
            unichar c0 = [cn characterAtIndex:0];
            if (c0 != 'C' && c0 != 'M' && c0 != 'W') continue;

            unsigned int mc = 0;
            Method *ml = class_copyMethodList(c, &mc);
            for (unsigned int k = 0; k < mc; k++) {
                SEL s = method_getName(ml[k]);
                NSString *sn = NSStringFromSelector(s);
                if ([sn rangeOfString:@"Revoke" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
                if ([sn isEqualToString:@"onRevokeMsg:"] || [sn isEqualToString:@"OnRevokeMsg:"]) continue;
                if (method_getNumberOfArguments(ml[k]) != 3) continue;
                char *rt = method_copyReturnType(ml[k]);
                char r = rt ? rt[0] : 'v';
                free(rt);
                if (r != 'v') continue;
                if (DTHookMsg(c, s, (IMP)n_revokeNoop)) variants++;
            }
            if (ml) free(ml);
        }
        free(all);
    }

    DTLog(@"revoke: armed onRevokeMsg=%d, variants=%d, selfEntry=%d (allowSelf=%d)",
          n, variants, selfn, (int)DTBool(kAllowSelf, YES));
}

// ─────────────────────────────────────────────────────────────────────────────
// 关于「自己撤回」
//
//   已实现：`DTRevokeAllowSelf`（默认 YES）。做法是 hook 本机发起撤回的入口
//   （RevokeMsg: / revokeMsg: / RevokeMessage: / revokeMessage: / onRevoke: 逐个试），
//   在 n_selfRevoke 里记下时刻，随后 3 秒内到达的 onRevokeMsg: 视为自己撤回、放行原实现。
//
//   为什么不用「解析 sysmsg 里的昵称再和 GetSelfUserName 比」：
//     1. `<revokemsg>` 里只有 `<session>`（会话 id）和 `<newmsgid>`，**没有撤回者的 wxid**
//     2. replacemsg 里是昵称，可能是备注名、群昵称，随群变化，比对不可靠
//     3. GetSelfUserName 在 8.0.5x 上名字不固定，取错会把所有撤回都放过
//
//   时间窗的副作用：自己点完撤回后 3 秒内如果别人正好也撤回，那条会漏拦。
//   概率低，且可以用 `DTRevokeAllowSelf=NO` 关掉。
// ─────────────────────────────────────────────────────────────────────────────
