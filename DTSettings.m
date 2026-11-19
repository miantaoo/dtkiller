//
//  DTSettings.m —— 设置界面
//
//  入口两处：
//    1) 「我」页面右上角齿轮（浮动按钮，随页面出现/消失）
//    2) 微信「设置」页顶部插一行（尽力而为，失败不影响 1）
//  页面本身是标准 UITableViewController，所有开关即时写 NSUserDefaults。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "DTHook.h"
#import "DTConfig.h"
#import "DTClassFinder.h"
#import "DTLog.h"
#import "DTModules.h"
#import "DTUtil.h"
#import "DTDiag.h"

#pragma mark - 设置项模型

typedef NS_ENUM(NSInteger, DTItemKind) {
    DTItemKindSwitch = 0,
    DTItemKindText,
    DTItemKindNumber,
    DTItemKindAction,
    DTItemKindInfo,
    DTItemKindList,   // 逗号分隔的数组（群列表 / 白名单）
    DTItemKindPick,   // 枚举选择，值存 NSInteger，选项在 options
};

@interface DTItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, assign) DTItemKind kind;
@property (nonatomic, copy) NSString *placeholder;
@property (nonatomic, strong) NSArray<NSString *> *options;
@property (nonatomic, assign) BOOL defaultValue;      // 开关的缺省值
@property (nonatomic, assign) BOOL dirty;             // 需要重启微信才生效
@property (nonatomic, copy) void (^action)(UIViewController *host);
@end

@implementation DTItem
@end

#pragma mark - 设置页

static void DTAlert(UIViewController *host, NSString *msg) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"DTKiller"
                                                              message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *top = host;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:a animated:YES completion:nil];
}

static void DTReload(UIViewController *host) {
    if ([host isKindOfClass:[UITableViewController class]])
        [[(UITableViewController *)host tableView] reloadData];
}

@interface DTSettingsVC : UITableViewController
@property (nonatomic, strong) NSArray<NSArray<DTItem *> *> *sections;
@property (nonatomic, strong) NSArray<NSString *> *headers;
- (void)showLog;
@end

@implementation DTSettingsVC
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    // 所有开关都是启动时读一次，这里统一说明，省得用户以为改完立刻生效。
    if (s != (NSInteger)self.sections.count - 1) return nil;
    return @"以上开关都在微信启动时读取一次：改完请上滑关掉微信再从桌面打开，"
            "只退到后台不会生效。诊断包在「调试」组最上面。";
}


- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"DTKiller";
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"日志" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(showLog)];
    [self buildItems];
}

- (void)buildItems {
    DTItem *(^sw)(NSString *, NSString *, NSString *, BOOL) = ^DTItem *(NSString *t, NSString *sub, NSString *k, BOOL defOn) {
        DTItem *i = [DTItem new];
        i.title = t; i.subtitle = sub; i.key = k; i.kind = DTItemKindSwitch; i.defaultValue = defOn;
        return i;
    };
    DTItem *(^num)(NSString *, NSString *, NSString *) = ^DTItem *(NSString *t, NSString *sub, NSString *k) {
        DTItem *i = [DTItem new];
        i.title = t; i.subtitle = sub; i.key = k; i.kind = DTItemKindNumber;
        return i;
    };
    DTItem *(^txt)(NSString *, NSString *, NSString *) = ^DTItem *(NSString *t, NSString *sub, NSString *k) {
        DTItem *i = [DTItem new];
        i.title = t; i.subtitle = sub; i.key = k; i.kind = DTItemKindText;
        return i;
    };
    DTItem *(^lst)(NSString *, NSString *, NSString *) = ^DTItem *(NSString *t, NSString *sub, NSString *k) {
        DTItem *i = [DTItem new];
        i.title = t; i.subtitle = sub; i.key = k; i.kind = DTItemKindList;
        return i;
    };
    DTItem *(^pick)(NSString *, NSString *, NSString *, NSArray<NSString *> *) =
        ^DTItem *(NSString *t, NSString *sub, NSString *k, NSArray<NSString *> *opts) {
        DTItem *i = [DTItem new];
        i.title = t; i.subtitle = sub; i.key = k; i.kind = DTItemKindPick; i.options = opts;
        return i;
    };
    DTItem *(^act)(NSString *, NSString *, void (^)(UIViewController *)) = ^DTItem *(NSString *t, NSString *sub, void (^h)(UIViewController *)) {
        DTItem *i = [DTItem new];
        i.title = t; i.subtitle = sub; i.kind = DTItemKindAction; i.action = h;
        return i;
    };

    // ---------------- 净化 ----------------
    NSArray<NSString *> *pureKeys = @[
        @"DTPureHideMiniProgram", @"DTPureHideChannels", @"DTPureHideLive",
        @"DTPureHideShopping", @"DTPureHideGames", @"DTPureHideMeMoments",
        @"DTPureHideMeEmoji", @"DTPureHideMeFavorites", @"DTPureHideMeWallet",
        @"DTPureHideMeSticker", @"DTPureHideEmojiCamera", @"DTPureHideEmojiRecent",
        @"DTPureHideEmojiSearch"
    ];
    DTItem *cleanAll = act(@"一键全净", @"把下面 13 个入口开关全部打开", ^(UIViewController *host) {
        for (NSString *k in pureKeys) DTSetBool(k, YES);
        DTSetBool(@"DTPureEnable", YES);
        DTSetBool(@"DTPureCleanAll", YES);
        DTFlush();
        DTAlert(host, @"已全部打开，重启微信生效。");
        DTReload(host);
    });

    // ---------------- 语音 ----------------
    DTItem *silk = act(@"音频转语音", @"从「文件」App 选音频，截前 N 秒", ^(UIViewController *host) {
        DTSilkPickFile(host);
    });
    DTItem *groupAvatar = act(@"群头像刷缓存", @"把 avatars 目录里的图刷进缓存", ^(UIViewController *host) {
        int n = DTGroupAvatarFlushToCache();
        if (n > 0) {
            DTAlert(host, [NSString stringWithFormat:@"已写入 %d 张，重启微信生效。", n]);
        } else if (n == 0) {
            DTAlert(host, @"没有可写入的缓存：微信还没为这些群生成过头像缓存。\n先打开对应群聊看一次头像，再回来重试。");
        } else if (n == -1) {
            DTAlert(host, @"请先打开「群头像」开关。");
        } else {
            DTAlert(host, @"没找到微信头像缓存目录，本功能需要微信先正常加载过头像。");
        }
    });
    DTItem *ledger = act(@"记账本汇总", @"按月统计已记录的交易", ^(UIViewController *host) {
        NSDictionary *m = DTLedgerMonthlySummary();
        NSArray *keys = [m.allKeys sortedArrayUsingSelector:@selector(compare:)];
        NSMutableString *buf = [NSMutableString string];
        for (NSString *k in keys) [buf appendFormat:@"%@  %@\n", k, m[k]];
        DTAlert(host, buf.length ? buf : @"还没有记录。打开上面的开关后，收款/转账会记下来。");
    });

    // ---------------- 调试 ----------------
    DTItem *diag = act(@"★ 导出诊断包", @"日志+配置+设备信息，直接发给我", ^(UIViewController *host) {
        DTDiagShare(host);
    });
    DTItem *copyTail = act(@"复制最近 200 行日志", @"复制后粘贴发给我，最省事", ^(UIViewController *host) {
        DTDiagCopyTail(200);
        DTAlert(host, @"已复制到剪贴板，去聊天窗口粘贴即可。");
    });
    DTItem *logTail = act(@"查看日志", @"最近 200 行", ^(UIViewController *host) {
        if ([host isKindOfClass:[DTSettingsVC class]]) [(DTSettingsVC *)host showLog];
    });
    DTItem *exportLog = act(@"导出日志", @"通过分享面板导出 app.log", ^(UIViewController *host) {
        NSString *p = [DTLogDirectory() stringByAppendingPathComponent:@"app.log"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:p]) { DTAlert(host, @"日志还没生成"); return; }
        UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:p]]
                                                                        applicationActivities:nil];
        if (av.popoverPresentationController) {
            av.popoverPresentationController.sourceView = host.view;
            av.popoverPresentationController.sourceRect =
                CGRectMake(host.view.bounds.size.width / 2, host.view.bounds.size.height / 2, 1, 1);
        }
        [host presentViewController:av animated:YES completion:nil];
    });
    DTItem *exportCfg = act(@"导出配置", @"生成 config.json", ^(UIViewController *host) {
        NSString *json = DTExportJSON();
        NSString *p = [DTLogDirectory() stringByAppendingPathComponent:@"config.json"];
        [json writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:p]]
                                                                        applicationActivities:nil];
        if (av.popoverPresentationController) {
            av.popoverPresentationController.sourceView = host.view;
            av.popoverPresentationController.sourceRect =
                CGRectMake(host.view.bounds.size.width / 2, host.view.bounds.size.height / 2, 1, 1);
        }
        [host presentViewController:av animated:YES completion:nil];
    });
    DTItem *importCfg = act(@"从粘贴板导入配置", @"把 config.json 内容复制后点这里", ^(UIViewController *host) {
        NSString *json = [UIPasteboard generalPasteboard].string;
        if (!json.length) { DTAlert(host, @"粘贴板是空的"); return; }
        BOOL ok = DTImportJSON(json);
        DTReload(host);
        DTAlert(host, ok ? @"导入完成，重启微信生效。" : @"导入失败，内容不是合法 JSON。");
    });

    self.headers = @[@"净化（改完重启微信）", @"语音", @"钱包", @"增强", @"调试"];

    self.sections = @[
        // 1. 净化
        @[ cleanAll,
           sw(@"界面净化", @"总开关（关掉不会自动恢复已隐藏的项）", @"DTPureEnable", NO),
           sw(@"小程序入口", @"发现页", @"DTPureHideMiniProgram", YES),
           sw(@"视频号入口", @"发现页", @"DTPureHideChannels", YES),
           sw(@"直播", @"发现页", @"DTPureHideLive", YES),
           sw(@"购物", @"发现页", @"DTPureHideShopping", YES),
           sw(@"游戏", @"发现页", @"DTPureHideGames", YES),
           sw(@"我·朋友圈", @"「我」页入口", @"DTPureHideMeMoments", YES),
           sw(@"我·表情", @"「我」页入口", @"DTPureHideMeEmoji", YES),
           sw(@"我·收藏", @"「我」页入口", @"DTPureHideMeFavorites", YES),
           sw(@"我·卡包", @"「我」页入口", @"DTPureHideMeWallet", YES),
           sw(@"我·表情商店", @"「我」页入口", @"DTPureHideMeSticker", YES),
           sw(@"表情面板·拍照", @"聊天表情面板", @"DTPureHideEmojiCamera", YES),
           sw(@"表情面板·最近", @"聊天表情面板", @"DTPureHideEmojiRecent", YES),
           sw(@"表情面板·搜索", @"聊天表情面板", @"DTPureHideEmojiSearch", YES),
           sw(@"广告净化", @"总开关", @"DTAdBlockEnable", NO),
           sw(@"朋友圈广告", @"", @"DTAdBlockMoments", YES),
           sw(@"品牌广告", @"", @"DTAdBlockBrand", YES),
           sw(@"小程序广告", @"", @"DTAdBlockMiniProgram", YES),
           sw(@"搜索广告", @"", @"DTAdBlockSearch", YES),
           sw(@"发现页净化", @"总开关", @"DTFinderBlockEnable", NO),
           sw(@"发现页", @"", @"DTFinderBlockDiscover", YES),
           sw(@"「我」页", @"", @"DTFinderBlockMe", YES),
           sw(@"朋友圈入口", @"", @"DTFinderBlockMoments", YES),
           sw(@"链接用 Safari 打开", @"公众号文章不转", @"DTSafariEnable", NO),
           sw(@"自动下载", @"总开关", @"DTAutoDownloadEnable", NO),
           sw(@"  图片", @"", @"DTAutoDownloadImage", YES),
           sw(@"  视频", @"", @"DTAutoDownloadVideo", YES),
           sw(@"  文件", @"", @"DTAutoDownloadFile", YES),
           sw(@"  语音", @"", @"DTAutoDownloadVoice", YES),
           pick(@"  网络", @"选「关闭」等于不自动下载", @"DTAutoDownloadNet", @[@"仅 WiFi", @"含蜂窝", @"关闭"]),
           num(@"  单文件上限 MB", @"超过就不下", @"DTAutoDownloadMaxMB"),
           sw(@"  群聊也下载", @"", @"DTAutoDownloadGroup", YES),
           sw(@"  单聊也下载", @"", @"DTAutoDownloadPrivate", NO) ],

        // 2. 语音
        @[ sw(@"语音进度条", @"QQ 风格，气泡底部 3pt 进度线", @"DTVoiceBarEnable", NO),
           sw(@"  显示时间", @"进度条两端显示 0:03 / 0:12", @"DTVoiceBarShowTime", NO),
           sw(@"  暂停按钮", @"进度条右侧", @"DTVoiceBarPauseBtn", NO),
           num(@"  默认倍速", @"1.0 / 1.5 / 2.0 / 2.5 / 3.0", @"DTVoiceBarRate"),
           sw(@"语音转发", @"长按语音多一项「转发」", @"DTVoiceFwdEnable", NO),
           sw(@"左滑引用", @"消息左滑即引用回复", @"DTSwipeQuoteEnable", NO),
           sw(@"音频转语音", @"需要先集成 SILK SDK", @"DTSilkEnable", NO),
           num(@"  最长秒数", @"微信上限 60", @"DTSilkMaxSeconds"),
           num(@"  码率", @"默认 25000", @"DTSilkBitrate"),
           silk,
           sw(@"CallKit 来电", @"锁屏像电话一样接", @"DTCallKitEnable", NO),
           sw(@"  带视频", @"", @"DTCallKitVideo", NO),
           sw(@"  仅后台时接管", @"前台交给微信自己", @"DTCallKitBackgroundOnly", NO) ],

        // 3. 钱包
        @[ sw(@"零钱加成", @"只改显示，不动真实数据", @"DTBalanceEnable", NO),
           num(@"  偏移金额", @"真实余额 + 这个数", @"DTBalanceOffset"),
           sw(@"抢红包", @"只抢列表里的群", @"DTRedPacketEnable", NO),
           num(@"  最短延迟秒", @"默认 3", @"DTRedPacketMinSec"),
           num(@"  最长延迟秒", @"默认 8", @"DTRedPacketMaxSec"),
           lst(@"  只抢这些群", @"群 id，逗号分隔；留空=全部", @"DTRedPacketGroups"),
           sw(@"收款自动回复", @"", @"DTPayReplyEnable", NO),
           lst(@"  白名单", @"wxid，逗号分隔；空=不生效", @"DTPayReplyList"),
           txt(@"  回复文案", @"[金额] 会替换成金额", @"DTPayReplyText"),
           sw(@"记账本", @"收款/转账记到 ledger.json", @"DTLedgerEnable", NO),
           ledger ],

        // 4. 增强
        @[ sw(@"头像圆角", @"所有头像变圆角", @"DTIconRadiusEnable", NO),
           num(@"  圆角比例", @"0.22 = 22%，0.5 = 正圆", @"DTIconRadiusRatio"),
           sw(@"  用 layer 模式", @"关掉则重绘图片（省内存更稳）", @"DTIconRadiusLayerMode", NO),
           sw(@"  所有图片都圆角", @"不只头像", @"DTIconRadiusAll", NO),
           sw(@"气泡美化", @"", @"DTBubbleEnable", NO),
           pick(@"  样式", @"", @"DTBubbleStyle", @[@"纯净白", @"浅绿", @"深色", @"从文件夹读"]),
           txt(@"  文件夹名", @"样式选「文件夹」时生效", @"DTBubbleFolder"),
           sw(@"朋友圈尾巴", @"只改手机端来源", @"DTMomentsTailEnable", NO),
           txt(@"  尾巴文案", @"默认 iPhone 15 Pro Max", @"DTMomentsTailPhone"),
           sw(@"群头像", @"按群设置", @"DTGroupAvatarEnable", NO),
           groupAvatar,
           sw(@"突破 9 图上限", @"", @"DTImageLimitEnable", NO),
           num(@"  上限张数", @"9–99，默认 20", @"DTImageLimitMax"),
           sw(@"红点消除", @"只去发现页/我页红点，保留未读数", @"DTBadgeEnable", NO),
           sw(@"群折叠", @"免打扰的群压成一行", @"DTGroupFoldEnable", NO),
           sw(@"  只折叠免打扰群", @"", @"DTGroupFoldMuteOnly", NO),
           sw(@"退群通知", @"群成员变动时提示", @"DTGroupLeaveEnable", NO),
           sw(@"拍一拍后缀", @"", @"DTPatEnable", NO),
           txt(@"  后缀文案", @"", @"DTPatSuffix"),
           sw(@"虚拟步数", @"只改微信内显示", @"DTStepEnable", NO),
           pick(@"  模式", @"", @"DTStepMode", @[@"区间随机", @"固定值"]),
           num(@"  最小值", @"默认 15000", @"DTStepMin"),
           num(@"  最大值", @"默认 35000", @"DTStepMax"),
           num(@"  固定值", @"模式选「固定值」时用", @"DTStepFixed"),
           num(@"  每天几点重置", @"0–23，默认 0", @"DTStepResetHour"),
           num(@"  自然抖动", @"0.08 = ±8%", @"DTStepJitter") ],

        // 5. 调试
        @[ sw(@"反检测", @"checkHook / 越狱检测返回 NO", @"DTGuardEnable", YES),
           sw(@"  屏蔽 hook 校验", @"checkHook:/checkConsistency:", @"DTBlockHookCheck", YES),
           sw(@"  屏蔽文件校验上报", @"reportFileConsistency:", @"DTBlockFileConsistency", YES),
           sw(@"  屏蔽上报（旧键）", @"等同上一项，老配置仍生效", @"DTGuardBlockReport", NO),
           sw(@"  伪造 bundleId", @"Auth/WWK 类返回 com.tencent.xin", @"DTSpoofBundleID", NO),
           sw(@"防撤回", @"对方撤回后消息还在", @"DTRevokeEnable", NO),
           sw(@"  也拦自己撤回", @"关掉则自己撤回能正常撤", @"DTRevokeAllowSelf", NO),
           sw(@"自动确认登录", @"异常登录页不点", @"DTAutoLoginEnable", NO),
           num(@"  延迟秒", @"", @"DTAutoLoginDelay"),
           sw(@"@全体", @"非管理员只能发普通文本", @"DTAtAllEnable", NO),
           txt(@"  触发词", @"逗号分隔", @"DTAtAllWords"),
           sw(@"详细日志", @"写更多行到 app.log", @"DTLogVerbose", NO),
           diag,
           copyTail,
           logTail,
           exportLog,
           exportCfg,
           importCfg ]
    ];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return self.sections.count; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return s < self.headers.count ? self.headers[s] : nil;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.sections[s].count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"dtcell";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];

    DTItem *it = self.sections[ip.section][ip.row];
    c.textLabel.text = it.title;
    c.detailTextLabel.text = it.subtitle;
    c.accessoryView = nil;
    c.accessoryType = UITableViewCellAccessoryNone;
    c.selectionStyle = UITableViewCellSelectionStyleNone;

    if (it.kind == DTItemKindSwitch) {
        UISwitch *sw = [UISwitch new];
        sw.on = DTBool(it.key, it.defaultValue);
        sw.tag = ip.section * 1000 + ip.row;
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
    } else if (it.kind == DTItemKindAction) {
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (it.kind == DTItemKindNumber || it.kind == DTItemKindText || it.kind == DTItemKindList) {
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        if (it.kind == DTItemKindNumber) {
            // 未设置就不要显示成「当前 0」：用户点进去看到 0 再保存，就把 0 真写进配置了
            // （比如 DTKillerBitrate 变 0 会让 SILK 编码直接失败）。
            if (DTObj(it.key)) {
                c.detailTextLabel.text = [NSString stringWithFormat:@"%@  (当前 %g)", it.subtitle ?: @"", DTDouble(it.key, 0)];
            } else {
                c.detailTextLabel.text = [NSString stringWithFormat:@"%@  (未设置，用内置默认)", it.subtitle ?: @""];
            }
        } else if (it.kind == DTItemKindList) {
            id v = DTObj(it.key);
            NSString *cur = [v isKindOfClass:[NSArray class]] ? [(NSArray *)v componentsJoinedByString:@","]
                          : ([v isKindOfClass:[NSString class]] ? v : @"");
            c.detailTextLabel.text = cur.length ? [NSString stringWithFormat:@"%@  (当前 %@)", it.subtitle ?: @"", cur]
                                                : [NSString stringWithFormat:@"%@  (当前 空)", it.subtitle ?: @""];
        } else {
            NSString *cur = DTStr(it.key, @"");
            c.detailTextLabel.text = [NSString stringWithFormat:@"%@  (当前 %@)", it.subtitle ?: @"", cur.length ? cur : @"空"];
        }
    } else if (it.kind == DTItemKindPick) {
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        NSInteger idx = DTInt(it.key, 0);
        NSString *cur = (idx >= 0 && idx < (NSInteger)it.options.count) ? it.options[(NSUInteger)idx] : @"?";
        c.detailTextLabel.text = cur;
    }
    return c;
}

- (void)switchChanged:(UISwitch *)sw {
    NSInteger s = sw.tag / 1000, r = sw.tag % 1000;
    if (s >= self.sections.count || r >= self.sections[s].count) return;
    DTItem *it = self.sections[s][r];
    DTSetBool(it.key, sw.on);
    DTFlush();
    DTLog(@"settings: %@ = %d", it.key, sw.on);
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    DTItem *it = self.sections[ip.section][ip.row];

    if (it.kind == DTItemKindAction && it.action) {
        it.action(self);
        return;
    }
    if (it.kind == DTItemKindPick) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:it.title
                                                                  message:it.subtitle
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
        NSInteger cur = DTInt(it.key, 0);
        [it.options enumerateObjectsUsingBlock:^(NSString *opt, NSUInteger idx, BOOL *stop) {
            NSString *t = (idx == (NSUInteger)cur) ? [NSString stringWithFormat:@"✓ %@", opt] : opt;
            [a addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
                DTSetInt(it.key, (NSInteger)idx);
                DTFlush();
                DTLog(@"settings: %@ = %lu (%@)", it.key, (unsigned long)idx, opt);
                [self.tableView reloadData];
            }]];
        }];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        a.popoverPresentationController.sourceView = self.view;
        a.popoverPresentationController.sourceRect =
            CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    if (it.kind == DTItemKindNumber || it.kind == DTItemKindText || it.kind == DTItemKindList) {
        BOOL isNum  = (it.kind == DTItemKindNumber);
        BOOL isList = (it.kind == DTItemKindList);

        UIAlertController *a = [UIAlertController alertControllerWithTitle:it.title
                                                                  message:it.subtitle
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            if (isNum) {
                // DecimalPad 打不出负号（余额偏移设不了 -50），改用带标点的数字键盘
                tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
                tf.text = DTObj(it.key) ? [NSString stringWithFormat:@"%g", DTDouble(it.key, 0)] : @"";
                tf.placeholder = @"留空 = 恢复内置默认";
            } else if (isList) {
                id v = DTObj(it.key);
                tf.text = [v isKindOfClass:[NSArray class]] ? [(NSArray *)v componentsJoinedByString:@","]
                        : ([v isKindOfClass:[NSString class]] ? v : @"");
                tf.placeholder = @"多个用英文逗号分隔";
                tf.keyboardType = UIKeyboardTypeDefault;
                tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
                tf.autocorrectionType = UITextAutocorrectionTypeNo;
            } else {
                tf.text = DTStr(it.key, @"");
            }
        }];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            NSString *v = a.textFields.firstObject.text ?: @"";
            if (isNum) {
                if (v.length == 0) DTSetObj(it.key, nil);   // 删除键 = 回到模块内置默认
                else               DTSetDouble(it.key, v.doubleValue);
            } else if (isList) {
                NSMutableArray *arr = [NSMutableArray array];
                NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
                for (NSString *s in [v componentsSeparatedByString:@","]) {
                    NSString *t = [s stringByTrimmingCharactersInSet:ws];
                    if (t.length) [arr addObject:t];
                }
                DTSetObj(it.key, arr);
            } else {
                DTSetStr(it.key, v);
            }
            DTFlush();
            [self.tableView reloadData];
        }]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

- (void)showLog {
    NSString *tail = DTLogTail(200);
    UITextView *tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    tv.text = tail.length ? tail : @"（空）";
    tv.editable = NO;
    tv.font = [UIFont fontWithName:@"Menlo" size:11];
    UIViewController *vc = [UIViewController new];
    vc.title = @"日志";
    vc.view.backgroundColor = [UIColor systemBackgroundColor];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [vc.view addSubview:tv];
    [self.navigationController pushViewController:vc animated:YES];
}

@end

#pragma mark - 入口：悬浮齿轮

@interface DTGearButton : UIButton
@end

@implementation DTGearButton
@end

static DTGearButton *gGear = nil;
static UIWindow *gGearWindow = nil;

static void DTShowSettings(UIViewController *from) {
    DTSettingsVC *vc = [DTSettingsVC new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    UIViewController *top = from;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:nav animated:YES completion:nil];
}

@interface DTGearTarget : NSObject
@end

@implementation DTGearTarget
- (void)tap:(id)sender {
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    UIViewController *top = w.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    DTShowSettings(top);
}
@end

static DTGearTarget *gGearTarget = nil;

static void DTInstallGear(void) {
    if (gGear) return;
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) win = [UIApplication sharedApplication].windows.firstObject;
    if (!win) {
        // 原来这里直接 return，keyWindow 还没就绪就永久没有设置入口。
        static int tries = 0;
        if (tries++ < 25) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ DTInstallGear(); });
        } else {
            DTLog(@"settings: gear gave up, no keyWindow");
        }
        return;
    }
    gGearTarget = [DTGearTarget new];

    CGFloat s = 34;
    gGear = [[DTGearButton alloc] initWithFrame:CGRectMake(win.bounds.size.width - s - 12, 100, s, s)];
    gGear.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.35];
    gGear.layer.cornerRadius = s / 2;
    gGear.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    [gGear setTitle:@"⚙" forState:UIControlStateNormal];
    gGear.titleLabel.font = [UIFont systemFontOfSize:18];
    [gGear addTarget:gGearTarget action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
    [win addSubview:gGear];

    DTLog(@"settings: gear installed at %@", NSStringFromCGRect(gGear.frame));
}

void DTModuleSettingsInstall(void) {
    // 延迟到窗口就绪
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ DTInstallGear(); });
    DTLog(@"settings: install scheduled");
}
