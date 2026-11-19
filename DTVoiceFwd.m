//
//  DTVoiceFwd.m —— 语音转发
//
//  目标：长按语音 → 菜单多一项「转发」→ 选人 → 对方点开就能播。
//  做法：优先走微信原生转发通道（ForwardMsg:ToContact:Scene:），
//        原生拒绝语音时退回「读出 silk 数据 → 重新发一条语音」。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "DTHook.h"
#import "DTConfig.h"
#import "DTClassFinder.h"
#import "DTLog.h"
#import "DTModules.h"
#import "DTUtil.h"
#import "DTSilkCodec.h"

static NSString *const kEn = @"DTVoiceFwdEnable";

#pragma mark - 前置声明

static NSArray<NSString *> *DTRecentContacts(int limit);
static BOOL DTSendVoiceToContact(NSData *silk, NSUInteger sec, NSString *userName);
static BOOL DTNativeForward(id wrap, NSString *userName);

#pragma mark - 取语音数据

/// 在 Documents 下找 .aud。wantId 非空时优先匹配路径里含 msgId 的那个；
/// 找不到就退回「最近修改的那个 .aud」（用户刚听完必有）。
static NSData *DTFindAud(NSString *doc, NSString *wantId, BOOL newestIfNoMatch) {
    if (!doc.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:doc];
    NSString *hit = nil;
    NSString *newest = nil;
    NSDate *newestDate = nil;
    int scanned = 0;
    for (NSString *rel in en) {
        if (++scanned > 5000) break;
        if (![[rel pathExtension].lowercaseString isEqualToString:@"aud"]) continue;
        NSString *full = [doc stringByAppendingPathComponent:rel];
        if (wantId.length && [rel rangeOfString:wantId].location != NSNotFound) {
            hit = full;
            break;
        }
        NSDictionary *at = [fm attributesOfItemAtPath:full error:NULL];
        NSDate *mt = at[NSFileModificationDate];
        if (mt && (!newestDate || [mt compare:newestDate] == NSOrderedDescending)) {
            newestDate = mt;
            newest = full;
        }
    }
    if (!hit && newestIfNoMatch) hit = newest;
    if (!hit && !wantId.length) hit = newest;   // 没有 msgId 可对时，取最新
    if (!hit) return nil;
    NSData *d = [NSData dataWithContentsOfFile:hit];
    DTLog(@"voicefwd: aud = %@ (%lu bytes)", [hit lastPathComponent], (unsigned long)d.length);
    return d;
}

static NSData *DTVoiceDataOfWrap(id wrap) {
    if (!wrap) return nil;

    // 1) 直接有 NSData 字段
    //    8.0.54 class-dump 实证：CMessageWrap 上语音数据本体就是 m_dtVoice
    NSArray *dataIvars = @[@"m_dtVoice", @"m_dtVoiceData", @"m_nsVoiceData", @"m_voiceData", @"voiceData"];
    for (NSString *iv in dataIvars) {
        id v = DTGetIvar(wrap, iv.UTF8String);
        if ([v isKindOfClass:[NSData class]] && [v length]) return v;
    }

    // 2) 有路径字段 → 读文件
    NSArray *pathGetters = @[@"m_nsVoicePath", @"voicePath", @"getVoicePath", @"m_nsPath"];
    id p = DTCallGetter(wrap, pathGetters);
    if (![p isKindOfClass:[NSString class]]) {
        p = DTGetIvar(wrap, "m_nsVoicePath");
    }
    if ([p isKindOfClass:[NSString class]] && [p length]) {
        NSString *path = p;
        if (![path isAbsolutePath]) {
            NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            path = [doc stringByAppendingPathComponent:p];
        }
        NSData *d = [NSData dataWithContentsOfFile:path];
        if (d.length) return d;
    }

    // 3) 微信把语音存在 voice2 目录，文件名是 msgId
    id msgId = DTCallGetter(wrap, @[@"m_nsMsgId", @"msgId", @"getMsgId"]);
    if ([msgId isKindOfClass:[NSString class]]) {
        NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSArray *cands = @[
            [doc stringByAppendingPathComponent:[NSString stringWithFormat:@"voice2/%@.silk", msgId]],
            [doc stringByAppendingPathComponent:[NSString stringWithFormat:@"voice/%@.silk", msgId]],
        ];
        for (NSString *c in cands) {
            NSData *d = [NSData dataWithContentsOfFile:c];
            if (d.length) return d;
        }
    }

    // 4) 8.x 真实落盘：Documents/<hash>/Audio/<hash>/<random>.aud
    //    文件名是随机的，只能靠 msgId 出现在路径里来认；认不出就取最新的一个 .aud
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSData *byId = DTFindAud(doc, [msgId isKindOfClass:[NSString class]] ? msgId : nil, NO);
    if (byId.length) return byId;

    return nil;
}

static NSUInteger DTVoiceSeconds(id wrap) {
    NSInteger raw = 0;
    if (DTIntValue(wrap, @[@"m_uiVoiceTime", @"voiceTime", @"getVoiceTime"], &raw) && raw > 0) {
        NSUInteger v = (NSUInteger)raw;
        // 微信的 m_uiVoiceTime 是毫秒；大于 600 的一律按毫秒处理
        return v > 600 ? (v / 1000) : v;
    }
    // 退路：按 SILK 帧数算（每帧 480 样本 @24kHz = 20ms）
    NSData *d = DTVoiceDataOfWrap(wrap);
    NSUInteger frames = 0;
    if (d.length && DTSilkInspect(d, &frames, NULL)) {
        NSUInteger sec = (frames * 480) / 24000;
        return sec ?: 1;
    }
    return 1;
}

#pragma mark - 转发动作

static BOOL DTSendVoiceToContact(NSData *silk, NSUInteger sec, NSString *userName) {
    id mgr = DTServiceNamed("CMessageMgr");
    if (!mgr || !silk.length) return NO;

    // 先切到目标会话，让「发送到当前会话」的接口可用
    SEL enter = NSSelectorFromString(@"EnterSessionWithUser:Scene:");
    if ([mgr respondsToSelector:enter]) {
        IMP imp = [mgr methodForSelector:enter];
        ((void (*)(id, SEL, id, unsigned int))imp)(mgr, enter, userName, 0);
    }

    // 单位是**毫秒**（微信内部 m_uiVoiceTime 就是毫秒，直接透传）。
    // 传秒会让对方看到 0 秒的语音；传超过 60 秒会被微信自己拒掉，所以两头都夹一下。
    unsigned int ms = (unsigned int)(sec * 1000.0);
    if (ms < 1000)  ms = 1000;
    if (ms > 60000) ms = 60000;

    SEL s1 = NSSelectorFromString(@"PutsendVoice:tovoicedata:");
    if ([mgr respondsToSelector:s1]) {
        IMP imp = [mgr methodForSelector:s1];
        ((void (*)(id, SEL, unsigned int, id))imp)(mgr, s1, ms, silk);
        DTLog(@"voicefwd: PutsendVoice ms=%u", ms);
        return YES;
    }
    SEL s2 = NSSelectorFromString(@"SendVoice:VoiceData:");
    if ([mgr respondsToSelector:s2]) {
        IMP imp = [mgr methodForSelector:s2];
        ((void (*)(id, SEL, unsigned int, id))imp)(mgr, s2, ms, silk);
        DTLog(@"voicefwd: SendVoice ms=%u", ms);
        return YES;
    }
    return NO;
}

/// 原生通道：ForwardMsg:ToContact:Scene:
static BOOL DTNativeForward(id wrap, NSString *userName) {
    id mgr = DTServiceNamed("CMessageMgr");
    if (!mgr) return NO;
    SEL sel = NSSelectorFromString(@"ForwardMsg:ToContact:Scene:");
    if (![mgr respondsToSelector:sel]) return NO;
    IMP imp = [mgr methodForSelector:sel];
    ((void (*)(id, SEL, id, id, unsigned int))imp)(mgr, sel, wrap, userName, 0);
    return YES;
}

#pragma mark - 选联系人（用系统通讯录式列表，避免依赖微信内部选择器）

@interface DTVoiceFwdPicker : UITableViewController
@property (nonatomic, strong) NSArray<NSString *> *contacts;
@property (nonatomic, copy) void (^onPick)(NSString *userName);
@end

@implementation DTVoiceFwdPicker

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"转发给";
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(close)];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.contacts.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"c";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    c.textLabel.text = self.contacts[ip.row];
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *u = self.contacts[ip.row];
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.onPick) self.onPick(u);
    }];
}

@end

#pragma mark - 取最近联系人

static NSArray<NSString *> *DTRecentContacts(int limit) {
    NSMutableArray *out = [NSMutableArray array];
    id svc = DTServiceNamed("MMNewSessionMgr") ?: DTServiceNamed("CMessageMgr");
    if (!svc) return out;

    // 常见 getter：GetAllSession / getSessionList / m_arrSession
    id list = DTCallGetter(svc, @[@"GetAllSessions", @"getAllSessions", @"m_arrSession", @"sessionList"]);
    if (![list isKindOfClass:[NSArray class]]) {
        list = DTGetIvar(svc, "m_arrSession");
    }
    if (![list isKindOfClass:[NSArray class]]) return out;

    for (id s in (NSArray *)list) {
        NSString *u = DTCallGetter(s, @[@"m_nsUserName", @"userName", @"getUserName"]);
        if ([u isKindOfClass:[NSString class]] && u.length) {
            [out addObject:u];
            if ((int)out.count >= limit) break;
        }
    }
    return out;
}

#pragma mark - 菜单注入

static void DTHandleVoiceForward(id wrap, UIViewController *host) {
    if (!wrap) return;
    NSData *silk = DTVoiceDataOfWrap(wrap);
    NSUInteger sec = DTVoiceSeconds(wrap);
    DTLog(@"voicefwd: wrap=%@ data=%lu sec=%lu",
          NSStringFromClass([wrap class]), (unsigned long)silk.length, (unsigned long)sec);

    if (!silk.length) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"转发语音"
                                                                  message:@"读不到这条语音的原始数据"
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [host presentViewController:a animated:YES completion:nil];
        return;
    }

    DTVoiceFwdPicker *pk = [DTVoiceFwdPicker new];
    NSArray *recent = DTRecentContacts(30);
    pk.contacts = recent.count ? recent : @[];
    pk.onPick = ^(NSString *userName) {
        BOOL ok = DTNativeForward(wrap, userName);
        if (!ok) ok = DTSendVoiceToContact(silk, sec, userName);
        DTLog(@"voicefwd: -> %@ ok=%d", userName, ok);
        if (!ok) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"转发失败"
                                                                      message:@"两条发送通道都不可用，见日志"
                                                               preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [UIApplication.sharedApplication.keyWindow.rootViewController presentViewController:a animated:YES completion:nil];
        }
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:pk];
    [host presentViewController:nav animated:YES completion:nil];
}

/// 给消息 cell 的长按菜单加一项。菜单项不同版本类名不同，这里用 KVC 兜底。
static NSArray *DTAppendForwardItem(NSArray *items, id wrap, UIViewController *host) {
    if (![items isKindOfClass:[NSArray class]]) return items;
    for (id it in items) {
        id t = DTCallGetter(it, @[@"title", @"m_nsTitle"]);
        if ([t isKindOfClass:[NSString class]] && [t containsString:@"转发语音"]) return items;
    }

    // 构造菜单项：优先微信自己的 WCMenuItem
    Class menuCls = NSClassFromString(@"WCMenuItem") ?: NSClassFromString(@"MMMenuItem");
    if (!menuCls) { DTLog(@"voicefwd: no menu item class"); return items; }

    id item = [menuCls new];
    @try {
        [item setValue:@"转发语音" forKey:@"title"];
        [item setValue:@(0) forKey:@"type"];
    } @catch (__unused NSException *e) {
        // 字段名不对就算了，下面用 ivar 写
        DTSetIvar(item, "m_nsTitle", @"转发语音");
    }

    __block id bWrap = wrap;
    __weak UIViewController *weakHost = host;
    // 用 block 版 action（微信菜单项一般支持 target/action，也支持 block 的变体）
    SEL blockSel = NSSelectorFromString(@"initWithTitle:handler:");
    if ([menuCls instancesRespondToSelector:blockSel]) {
        IMP imp = [menuCls instanceMethodForSelector:blockSel];
        id (*fn)(id, SEL, NSString *, void (^)(void)) = (void *)imp;
        item = fn([menuCls alloc], blockSel, @"转发语音", ^{
            DTHandleVoiceForward(bWrap, weakHost);
        });
    }

    NSMutableArray *m = [items mutableCopy];
    [m addObject:item];
    return m;
}

void DTModuleVoiceFwdInstall(void) {
    if (!DTBool(kEn, NO)) { DTLog(@"voicefwd: disabled"); return; }

    __block int n = 0;
    for (NSString *cn in DTWeChatClassNames()) {
        if (![cn containsString:@"Menu"] && ![cn containsString:@"Msg"]) continue;
        Class c = objc_getClass(cn.UTF8String);
        if (!c) continue;

        SEL sel = NSSelectorFromString(@"operationMenuItems");
        if (class_getInstanceMethod(c, sel)) {
            __block Class wc = c;
            DTHookMsg(c, sel, imp_implementationWithBlock(^id(id self) {
                IMP o = DTOrigFor(wc, sel);
                id items = o ? ((id (*)(id, SEL))o)(self, sel) : nil;
                if (!DTBool(kEn, NO)) return items;
                id wrap = DTCallGetter(self, @[@"m_msgWrap", @"msgWrap"]) ?: DTGetIvar(self, "m_msgWrap");
                if (!wrap) return items;
                // 只处理语音（type 34）。取不到类型就当作「不是语音」，
                // 否则会给文本/图片消息也挂上「转发语音」，点下去必然报读不到数据。
                NSInteger mt = -1;
                if (!DTIntValue(wrap, @[@"m_uiMessageType", @"messageType"], &mt) || mt != 34) return items;
                UIViewController *host = DTViewControllerOf((UIView *)self);
                return DTAppendForwardItem(items, wrap, host);
            }));
            n++;
        }
    }
    DTLog(@"voicefwd: hooked %d menu providers", n);
}
