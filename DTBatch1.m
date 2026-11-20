//
//  DTBatch1.m —— P0-4 广告净化 / P0-5 视频号净化 / P0-6 链接转 Safari / P0-7 自动下载
//
//  这四项的共同点：都要先判断「这条消息 / 这个数据项是什么类型」，再决定放行还是拦。
//  微信里消息类型走 CMessageWrap 的 m_uiMessageType，朋友圈 / 视频号走 WCDataItem 的标记位。
//  类名大多被抹了，所以全部用 selector 反查 + 运行时探测，找不到就只关这一项。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "DTHook.h"
#import "DTConfig.h"
#import "DTLog.h"
#import "DTClassFinder.h"
#import "DTUtil.h"
#import "DTModules.h"

#pragma mark - 公用：读消息类型

static NSInteger DTMsgType(id wrap)
{
    if (!wrap) return -1;
    id v = DTGetIvar(wrap, "m_uiMessageType");
    if ([v respondsToSelector:@selector(integerValue)]) return [v integerValue];
    if ([wrap respondsToSelector:@selector(m_uiMessageType)]) {
        NSInteger t = ((NSInteger (*)(id, SEL))objc_msgSend)(wrap, @selector(m_uiMessageType));
        return t;
    }
    return -1;
}

static NSString *DTMsgContent(id wrap)
{
    id v = DTGetIvar(wrap, "m_nsContent");
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([wrap respondsToSelector:@selector(m_nsContent)]) {
        NSString *s = ((NSString *(*)(id, SEL))objc_msgSend)(wrap, @selector(m_nsContent));
        if ([s isKindOfClass:[NSString class]]) return s;
    }
    return nil;
}

// ═══════════════════════════════════════════════════════════════════════════
#pragma mark - P0-4 广告净化
// ═══════════════════════════════════════════════════════════════════════════

#define kAdEnable      @"DTAdBlockEnable"
#define kAdMoments     @"DTAdBlockMoments"      // 朋友圈
#define kAdBrand       @"DTAdBlockBrand"        // 公众号文章底部
#define kAdMiniApp     @"DTAdBlockMiniProgram"  // 小程序
#define kAdSearch      @"DTAdBlockSearch"       // 搜一搜

static BOOL gAdMoments, gAdBrand, gAdMiniApp, gAdSearch;
static BOOL gFinderMoments;   // 合并闸门（下面 DTBeforeReturnDataItem）也要用，提前声明

/// 判断一个数据项是不是广告。字段名在 8.x 里有 isAd / isAdvertisement / m_isAd 几种写法，
/// 能读到一个为真就算广告。
static BOOL DTItemIsAd(id item)
{
    if (!item) return NO;

    id v = DTGetIvar(item, "m_isAd");
    if ([v respondsToSelector:@selector(boolValue)] && [v boolValue]) return YES;
    v = DTGetIvar(item, "m_uiAdFlag");
    if ([v respondsToSelector:@selector(integerValue)] && [v integerValue] != 0) return YES;

    static const char *sels[] = { "isAd", "isAdvertisement", "isAdItem", "isBrandAd" };
    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        SEL s = sel_registerName(sels[i]);
        if ([item respondsToSelector:s]) {
            BOOL r = ((BOOL (*)(id, SEL))objc_msgSend)(item, s);
            if (r) return YES;
        }
    }
    return NO;
}

static BOOL DTFinderIsCard(id item);          // 定义在后面，先声明

/// 朋友圈数据项进列表前的唯一闸门：广告 + 视频号卡片都从这里过。
/// 以前「广告净化」和「视频号净化」各 hook 了一次 LL_onBeforeReturnDataItem:，
/// 第二个 wrapper 会把第一个当成自己的 orig → 遇到普通动态就自递归，滑一次闪退。
static NSMutableSet<NSString *> *gBeforeReturnDone;

static id DTBeforeReturnDataItem(id self, SEL _cmd, id item)
{
    IMP o = DTOrigFor(object_getClass(self), _cmd);

    if (gAdMoments && DTItemIsAd(item)) {
        DTLog(@"ad: 丢掉一条朋友圈广告 %@", NSStringFromClass([item class]));
        return nil;
    }
    if (gFinderMoments && DTFinderIsCard(item)) {
        return nil;
    }
    if (!o) return item;
    return ((id (*)(id, SEL, id))o)(self, _cmd, item);
}

/// 幂等安装：两个模块都调它，只有第一次真的挂 hook。
static int DTHookBeforeReturnOnce(void)
{
    if (!gBeforeReturnDone) gBeforeReturnDone = [NSMutableSet set];
    int n = 0;
    for (NSString *cn in DTOwnerClassesForSelector("LL_onBeforeReturnDataItem:")) {
        if ([gBeforeReturnDone containsObject:cn]) continue;
        Class c = NSClassFromString(cn);
        if (!c) continue;
        if (DTHookMsg(c, sel_registerName("LL_onBeforeReturnDataItem:"),
                      (IMP)DTBeforeReturnDataItem)) {
            [gBeforeReturnDone addObject:cn];
            n++;
        }
    }
    return n;
}

/// 兜底：isAd 一律报 NO。移除失败时至少让广告按普通样式渲染，不至于整块白。
static BOOL DTAdIsAdNo(id self, SEL _cmd)
{
    return NO;
}

static void DTAdInstallMoments(void)
{
    int n = 0;
    // 主闸：列表构建（与视频号净化共用一个 hook）
    n += DTHookBeforeReturnOnce();
    // 次闸：标记位
    for (NSString *cn in DTClassesMatching("TimeLine")) {
        Class c = NSClassFromString(cn);
        if (!c) continue;
        SEL s = sel_registerName("isAd");
        if (class_getInstanceMethod(c, s) && DTHookMsg(c, s, (IMP)DTAdIsAdNo)) n++;
    }
    DTLog(@"ad: 朋友圈装了 %d 个点", n);
}

static void DTAdInstallBrand(void)
{
    // 公众号正文底部的广告卡片：类名里带 Brand / Article 的容器，把它的广告子项裁掉。
    int n = 0;
    for (NSString *cn in DTClassesMatching("Brand")) {
        Class c = NSClassFromString(cn);
        if (!c) continue;
        SEL s = sel_registerName("isAd");
        if (class_getMethodImplementation(c, s) && DTHookMsg(c, s, (IMP)DTAdIsAdNo)) n++;
    }
    DTLog(@"ad: 公众号装了 %d 个点", n);
}

static void DTAdInstallMiniProgram(void)
{
    int n = 0;
    for (NSString *cn in DTClassesMatching("MiniProgram")) {
        Class c = NSClassFromString(cn);
        if (!c) continue;
        SEL s = sel_registerName("isAd");
        if (class_getMethodImplementation(c, s) && DTHookMsg(c, s, (IMP)DTAdIsAdNo)) n++;
    }
    DTLog(@"ad: 小程序装了 %d 个点", n);
}

static void DTAdInstallSearch(void)
{
    int n = 0;
    for (NSString *cn in DTClassesMatching("Search")) {
        Class c = NSClassFromString(cn);
        if (!c) continue;
        SEL s = sel_registerName("isAd");
        if (class_getMethodImplementation(c, s) && DTHookMsg(c, s, (IMP)DTAdIsAdNo)) n++;
    }
    DTLog(@"ad: 搜一搜装了 %d 个点", n);
}

static void DTAdInstall(void)
{
    if (!DTBool(kAdEnable, NO)) { DTLog(@"ad: off"); return; }

    gAdMoments = DTBool(kAdMoments, YES);
    gAdBrand   = DTBool(kAdBrand, YES);
    gAdMiniApp = DTBool(kAdMiniApp, YES);
    gAdSearch  = DTBool(kAdSearch, YES);

    if (gAdMoments) DTAdInstallMoments();
    if (gAdBrand)   DTAdInstallBrand();
    if (gAdMiniApp) DTAdInstallMiniProgram();
    if (gAdSearch)  DTAdInstallSearch();
}

// ═══════════════════════════════════════════════════════════════════════════
#pragma mark - P0-5 视频号净化
// ═══════════════════════════════════════════════════════════════════════════

#define kFinderEnable   @"DTFinderBlockEnable"
#define kFinderDiscover @"DTFinderBlockDiscover"   // 发现页入口
#define kFinderMe       @"DTFinderBlockMe"         // 我页入口
#define kFinderMoments  @"DTFinderBlockMoments"    // 朋友圈卡片
// 聊天里的分享卡片永远不拦

static BOOL gFinderDiscover, gFinderMe;

/// 发现页 / 我页的入口项：返回 NO 让这一行不显示。
static BOOL DTFinderShouldShow(id self, SEL _cmd)
{
    NSString *cn = NSStringFromClass([self class]);
    if (gFinderDiscover && [cn rangeOfString:@"Discover"].location != NSNotFound) return NO;
    if (gFinderMe && [cn rangeOfString:@"Me"].location != NSNotFound) return NO;
    // 子开关都关时必须回到微信原逻辑：原来这里直接 return NO，
    // 于是「发现页」「我页」两个子开关关着也照样隐藏视频号入口，等于装饰。
    IMP o = DTOrigFor(object_getClass(self), _cmd);
    return o ? ((BOOL (*)(id, SEL))o)(self, _cmd) : NO;
}

/// 朋友圈里的视频号卡片：在数据项层面判类型，返回 YES 表示要拦。
static BOOL DTFinderIsCard(id item)
{
    if (!item) return NO;
    static const char *sels[] = { "isFinderItem", "isFinderCard", "isChannelsItem", "isFinderVideo" };
    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        SEL s = sel_registerName(sels[i]);
        if ([item respondsToSelector:s]) {
            if (((BOOL (*)(id, SEL))objc_msgSend)(item, s)) return YES;
        }
    }
    return NO;
}

static id DTFinderBeforeReturn(id self, SEL _cmd, id item)
{
    IMP o = DTOrigFor(object_getClass(self), _cmd);
    if (gFinderMoments && DTFinderIsCard(item)) return nil;
    if (!o) return item;
    return ((id (*)(id, SEL, id))o)(self, _cmd, item);
}

static void DTFinderInstall(void)
{
    if (!DTBool(kFinderEnable, NO)) { DTLog(@"finder: off"); return; }

    gFinderDiscover = DTBool(kFinderDiscover, YES);
    gFinderMe       = DTBool(kFinderMe, YES);
    gFinderMoments  = DTBool(kFinderMoments, YES);

    int n = 0;
    static const char *sels[] = { "shouldShowFinderEntry", "isFinderEntry", "showFinderEntry", "isShowFinder" };
    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        for (NSString *cn in DTOwnerClassesForSelector(sels[i])) {
            Class c = NSClassFromString(cn);
            if (c && DTHookMsg(c, sel_registerName(sels[i]), (IMP)DTFinderShouldShow)) n++;
        }
    }

    if (gFinderMoments) {
        n += DTHookBeforeReturnOnce();      // 幂等，广告那边装过就复用
    }
    DTLog(@"finder: 装了 %d 个点", n);
}

// ═══════════════════════════════════════════════════════════════════════════
#pragma mark - P0-6 链接转 Safari
// ═══════════════════════════════════════════════════════════════════════════

#define kSafariEnable @"DTSafariEnable"

static BOOL gSafariOn;

/// 只转「纯网页链接」。公众号文章（消息类型 49 / appmsg type 5）、支付、小程序一律放过。
static BOOL DTSafariShouldOpen(NSString *url, id msgWrap)
{
    if (url.length < 8) return NO;
    if (![url hasPrefix:@"http://"] && ![url hasPrefix:@"https://"]) return NO;

    // 域名级排除
    static NSString *deny[] = {
        @"mp.weixin.qq.com", @"weixin.qq.com", @"pay.weixin", @"wx.tenpay",
        @"servicewechat.com", @"qpic.cn", @"gtimg.cn"
    };
    for (size_t i = 0; i < sizeof(deny) / sizeof(deny[0]); i++) {
        if ([url rangeOfString:deny[i]].location != NSNotFound) return NO;
    }

    if (msgWrap) {
        NSInteger t = DTMsgType(msgWrap);
        if (t == 49) return NO;          // appmsg：公众号文章 / 小程序 / 卡片
        if (t == 49 || t == 2000 || t == 2001) return NO;
    }
    return YES;
}

static void DTSafariOpen(NSString *url)
{
    NSURL *u = [NSURL URLWithString:url];
    if (!u) return;
    DTLog(@"safari: 转出 %@", url);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
    });
}

/// 聊天里点链接的总入口。不同版本参数个数不同，probe 后按 4 参处理（self + _cmd + url + rect）。
/// 从点击发生的对象身上找那条消息，用来排除 type 49（公众号文章/卡片）。
/// 不找的话「公众号文章不转 Safari」这条需求就是空的。
static id DTSafariMsgWrapOf(id self)
{
    static const char *names[] = { "m_msgWrap", "m_msg", "m_oMsgWrap", "msgWrap" };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        id v = DTGetIvar(self, names[i]);
        if (v) return v;
    }
    return nil;
}

static id DTSafariOnLinkClicked(id self, SEL _cmd, id url, CGRect rect)
{
    IMP o = DTOrigFor(object_getClass(self), _cmd);
    NSString *s = nil;
    if ([url isKindOfClass:[NSString class]]) s = url;
    else if ([url isKindOfClass:[NSURL class]]) s = [(NSURL *)url absoluteString];

    if (gSafariOn && DTSafariShouldOpen(s, DTSafariMsgWrapOf(self))) {
        DTSafariOpen(s);
        return nil;
    }
    if (!o) return nil;
    return ((id (*)(id, SEL, id, CGRect))o)(self, _cmd, url, rect);
}

static void DTSafariInstall(void)
{
    if (!DTBool(kSafariEnable, NO)) { DTLog(@"safari: off"); return; }
    gSafariOn = YES;

    int n = 0;
    static const char *sels[] = { "onLinkClicked:withRect:", "onLinkClicked:backupUrl:withRect:extraInfo:" };
    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        for (NSString *cn in DTOwnerClassesForSelector(sels[i])) {
            Class c = NSClassFromString(cn);
            if (!c) continue;
            // 只处理 4 参的那个；5 参的签名不同，先不碰，避免栈错位
            if (i != 0) continue;
            if (DTHookMsg(c, sel_registerName(sels[i]), (IMP)DTSafariOnLinkClicked)) n++;
        }
    }
    DTLog(@"safari: 装了 %d 个点", n);
}

// ═══════════════════════════════════════════════════════════════════════════
#pragma mark - P0-7 自动下载
// ═══════════════════════════════════════════════════════════════════════════

#define kDlEnable   @"DTAutoDownloadEnable"
#define kDlImage    @"DTAutoDownloadImage"
#define kDlVideo    @"DTAutoDownloadVideo"
#define kDlFile     @"DTAutoDownloadFile"
#define kDlVoice    @"DTAutoDownloadVoice"
#define kDlNet      @"DTAutoDownloadNet"      // 0=仅WiFi 1=含蜂窝 2=关
#define kDlMaxMB    @"DTAutoDownloadMaxMB"
#define kDlGroup    @"DTAutoDownloadGroup"
#define kDlPrivate  @"DTAutoDownloadPrivate"

static BOOL gDlImage, gDlVideo, gDlFile, gDlVoice, gDlGroup, gDlPrivate;
static NSInteger gDlNet, gDlMaxMB;
static NSMutableSet<NSString *> *gDlDone;

static BOOL DTNetAllows(void)
{
    if (gDlNet == 2) return NO;
    if (gDlNet == 1) return YES;

    // 仅 WiFi：用 ReachableViaWiFi 判断
    Class rc = NSClassFromString(@"Reachability");
    if (rc && [rc respondsToSelector:@selector(reachabilityForInternetConnection)]) {
        id r = ((id (*)(id, SEL))objc_msgSend)(rc, @selector(reachabilityForInternetConnection));
        if (r && [r respondsToSelector:@selector(currentReachabilityStatus)]) {
            NSInteger st = ((NSInteger (*)(id, SEL))objc_msgSend)(r, @selector(currentReachabilityStatus));
            return st == 2;   // 2 = WiFi
        }
    }
    return YES;   // 拿不到网络状态就放行，避免全都不下载
}

static BOOL DTDlWanted(id msgWrap)
{
    NSInteger t = DTMsgType(msgWrap);
    if (t == 3  && !gDlImage) return NO;   // 图片
    if (t == 43 && !gDlVideo) return NO;   // 视频
    if (t == 49 && !gDlFile)  return NO;   // 文件 / appmsg
    if (t == 34 && !gDlVoice) return NO;   // 语音

    NSString *to = DTGetIvar(msgWrap, "m_nsToUsr");
    if ([to isKindOfClass:[NSString class]]) {
        BOOL isGroup = [to rangeOfString:@"@chatroom"].location != NSNotFound;
        if (isGroup && !gDlGroup) return NO;
        if (!isGroup && !gDlPrivate) return NO;
    }

    // 体积上限：能拿到大小才判；拿不到（多数视频/文件在下载前是 0）就放行。
    if (gDlMaxMB > 0) {
        static const char *sizeKeys[] = { "m_uiFileSize", "m_uFileSize", "m_nFileSize", "fileSize" };
        for (int i = 0; i < 4; i++) {
            id v = DTGetIvar(msgWrap, sizeKeys[i]);
            if ([v isKindOfClass:[NSNumber class]]) {
                long long sz = [v longLongValue];
                if (sz > 0 && sz > (long long)gDlMaxMB * 1024 * 1024) {
                    DTLog(@"dl: 跳过 %s，%lld 字节 > 上限 %ldMB", sizeKeys[i], sz, (long)gDlMaxMB);
                    return NO;
                }
                break;
            }
        }
    }
    return YES;
}

/// 「现在能不能下载这个媒体」—— 微信自己就在这里判网络和限额，把它改成 YES 最省事。
/// 但子开关必须真的生效：参数确实是消息对象时按 DTDlWanted 过滤。
static BOOL DTDlCanDownload(id self, SEL _cmd, id arg)
{
    IMP o = DTOrigFor(object_getClass(self), _cmd);
    if (!DTNetAllows()) return o ? ((BOOL (*)(id, SEL, id))o)(self, _cmd, arg) : NO;
    if (arg && DTGetIvar(arg, "m_uiMessageType")) {
        return DTDlWanted(arg);
    }
    return YES;
}

/// 两参版本（-allowSilentDownload 之类）：不能当成有第三参调用，否则读寄存器垃圾。
static BOOL DTDlSilent(id self, SEL _cmd)
{
    IMP o = DTOrigFor(object_getClass(self), _cmd);
    if (!DTNetAllows()) return o ? ((BOOL (*)(id, SEL))o)(self, _cmd) : NO;
    return YES;
}

static void DTDlInstall(void)
{
    if (!DTBool(kDlEnable, NO)) { DTLog(@"dl: off"); return; }

    gDlImage   = DTBool(kDlImage, YES);
    gDlVideo   = DTBool(kDlVideo, YES);
    gDlFile    = DTBool(kDlFile, NO);
    gDlVoice   = DTBool(kDlVoice, NO);
    gDlGroup   = DTBool(kDlGroup, YES);
    gDlPrivate = DTBool(kDlPrivate, YES);
    gDlNet     = DTInt(kDlNet, 0);
    gDlMaxMB   = DTInt(kDlMaxMB, 10);

    if (!gDlDone) gDlDone = [NSMutableSet set];

    int n = 0;
    static const char *sels[] = { "canMediaDownloadedNow:", "allowSilentDownload", "canAutoDownloadMedia:" };
    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        SEL s = sel_registerName(sels[i]);
        for (NSString *cn in DTOwnerClassesForSelector(sels[i])) {
            Class c = NSClassFromString(cn);
            if (!c) continue;
            Method m = class_getInstanceMethod(c, s);
            if (!m) continue;
            char rtb[16] = {0}; method_getReturnType(m, rtb, sizeof(rtb)); const char *rt = rtb;
            if (!rt || rt[0] != 'B') continue;     // 只碰返回 BOOL 的
            NSUInteger ac = method_getNumberOfArguments(m);
            if (ac == 3) {
                if (DTHookMsg(c, s, (IMP)DTDlCanDownload)) n++;
            } else if (ac == 2) {
                if (DTHookMsg(c, s, (IMP)DTDlSilent)) n++;
            }
        }
    }
    DTLog(@"dl: 装了 %d 个点，网络模式 %ld，上限 %ldMB（拿不到体积时该上限不生效）",
          n, (long)gDlNet, (long)gDlMaxMB);
}

// ═══════════════════════════════════════════════════════════════════════════
#pragma mark - 统一入口
// ═══════════════════════════════════════════════════════════════════════════

void DTModuleAdBlockInstall(void)
{
    @autoreleasepool {
        DTAdInstall();
        DTFinderInstall();
        DTSafariInstall();
        DTDlInstall();
    }
}
