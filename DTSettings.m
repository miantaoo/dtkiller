//
//  DTSettings.m —— 设置界面
//
//  入口：微信「我 → 设置」列表中的 DTKiller 设置项。
//  页面首页提供五类导航；开关写入 com.dt.killer 配置域。
//

// 设置入口只在微信「我 → 设置」列表中注入；不显示全局悬浮按钮。
// 设置首页展示五类入口，每类再按功能分组。
#import <UIKit/UIKit.h>
#import <string.h>
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
@property (nonatomic, assign) NSInteger selectedCategory; // -1 首页；0..4 分类页
- (instancetype)initHome;
- (instancetype)initWithCategory:(NSInteger)category;
- (void)showLog;
@end

static NSArray<NSString *> *DTCategories(void) {
    return @[@"净化", @"语音", @"钱包", @"增强", @"调试"];
}
static NSArray<NSString *> *DTCategoriesDetail(void) {
    return @[
        @"隐藏入口、净化广告、管理自动下载",
        @"语音播放、转发、引用、音频转换与来电",
        @"零钱显示、红包、收款回复与本地记账",
        @"头像、气泡、朋友圈、群列表与步数显示",
        @"启动诊断、日志导出及可选兼容开关"
    ];
}

@implementation DTSettingsVC
- (instancetype)initHome {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) self.selectedCategory = -1;
    return self;
}

- (instancetype)initWithCategory:(NSInteger)category {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) self.selectedCategory = category;
    return self;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (self.selectedCategory < 0) return @"选择一个分类查看功能。多数开关需完全退出微信后重新打开才生效；诊断与日志导出在「调试」分类。";
    if (self.selectedCategory != 4 && !DTBool(@"DTModulesEnabled", NO))
        return @"当前「功能模块总开关」关闭：这里的选项可以保存，但功能不会加载。请到「调试」打开总开关，再从应用切换器上滑关闭微信并重新打开。";
    return @"部分功能只在微信启动时读取：修改后请从应用切换器上滑关闭微信，再从桌面重新打开。每项说明会标出作用范围与已知限制。";
}


- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64.0;
    if (self.selectedCategory < 0) {
        self.title = @"DTKiller 设置";
    } else {
        self.title = (self.selectedCategory >= 0 && self.selectedCategory < (NSInteger)DTCategories().count)
            ? DTCategories()[(NSUInteger)self.selectedCategory] : @"设置";
    }
    if (self.selectedCategory == 4) {
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"日志" style:UIBarButtonItemStylePlain
                                            target:self action:@selector(showLog)];
    }
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
    DTItem *(^info)(NSString *, NSString *) = ^DTItem *(NSString *t, NSString *sub) {
        DTItem *i = [DTItem new];
        i.title = t; i.subtitle = sub; i.kind = DTItemKindInfo;
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
    DTItem *restoreSafeMode = act(@"下次启动退出安全模式", @"仅在上次启动崩溃后需要；恢复后仍由功能总开关决定是否加载模块", ^(UIViewController *host) {
        DTSetBool(@"DTSafeModeNextBoot", YES);
        DTFlush();
        DTAlert(host, @"已记录。完全关闭微信后重新打开，将退出安全模式；如需加载功能模块，还要打开「功能模块总开关」。");
    });

    DTItem *diag = act(@"导出诊断包", @"包含启动阶段、版本、配置和最近日志，可直接分享", ^(UIViewController *host) {
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
        @[ info(@"入口净化", @"隐藏指定位置的入口，不会删除账户数据"),
           cleanAll,
           sw(@"界面净化", @"总开关；关闭后不再拦截入口，下面的单项选择会保留", @"DTPureEnable", NO),
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
           info(@"广告过滤", @"仅过滤微信返回的广告内容；个别广告样式可能无法识别"),
           sw(@"广告净化", @"总开关", @"DTAdBlockEnable", NO),
           sw(@"朋友圈广告", @"", @"DTAdBlockMoments", YES),
           sw(@"品牌广告", @"", @"DTAdBlockBrand", YES),
           sw(@"小程序广告", @"", @"DTAdBlockMiniProgram", YES),
           sw(@"搜索广告", @"", @"DTAdBlockSearch", YES),
           info(@"发现页与「我」页", @"子项关闭时保留微信原行为"),
           sw(@"发现页净化", @"总开关", @"DTFinderBlockEnable", NO),
           sw(@"发现页", @"", @"DTFinderBlockDiscover", YES),
           sw(@"「我」页", @"", @"DTFinderBlockMe", YES),
           sw(@"朋友圈入口", @"", @"DTFinderBlockMoments", YES),
           info(@"外部链接", @"公众号文章、支付、微信内部链接仍由微信打开"),
           sw(@"链接用 Safari 打开", @"仅处理识别到的普通网页链接", @"DTSafariEnable", NO),
           info(@"自动下载", @"按媒体类型与网络条件决定是否下载"),
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
        @[ info(@"播放体验", @"仅改变本机界面与播放控制"),
           sw(@"语音进度条", @"QQ 风格，显示在语音气泡底部", @"DTVoiceBarEnable", NO),
           sw(@"  显示时间", @"进度条两端显示 0:03 / 0:12", @"DTVoiceBarShowTime", NO),
           sw(@"  暂停按钮", @"进度条右侧", @"DTVoiceBarPauseBtn", NO),
           num(@"  默认倍速", @"1.0 / 1.5 / 2.0 / 2.5 / 3.0", @"DTVoiceBarRate"),
           sw(@"语音转发", @"长按语音添加转发项；发送端需微信支持上传", @"DTVoiceFwdEnable", NO),
           sw(@"左滑引用", @"消息左滑后引用到输入框", @"DTSwipeQuoteEnable", NO),
           info(@"音频文件转换", @"需要 SILK 编码器；尚未集成时转换按钮会提示不可用"),
           sw(@"音频转语音", @"从「文件」App 选择音频", @"DTSilkEnable", NO),
           num(@"  最长秒数", @"微信上限 60", @"DTSilkMaxSeconds"),
           num(@"  码率", @"默认 25000", @"DTSilkBitrate"),
           silk,
           info(@"系统来电界面", @"iOS 可能拒绝报告来电；失败时回退为通知提醒"),
           sw(@"CallKit 来电", @"后台来电尝试显示为系统电话界面", @"DTCallKitEnable", NO),
           sw(@"  带视频", @"", @"DTCallKitVideo", NO),
           sw(@"  仅后台时接管", @"前台交给微信自己", @"DTCallKitBackgroundOnly", NO) ],

        // 3. 钱包
        @[ info(@"零钱显示", @"只改本机页面上的数字，不改变微信服务器余额"),
           sw(@"零钱加成", @"本机显示值 = 页面读取值 + 偏移金额", @"DTBalanceEnable", NO),
           num(@"  偏移金额", @"真实余额 + 这个数", @"DTBalanceOffset"),
           info(@"红包处理", @"仅处理配置范围内且成功识别的红包消息"),
           sw(@"抢红包", @"只抢列表里的群；群列表留空表示不限制群", @"DTRedPacketEnable", NO),
           num(@"  最短延迟秒", @"默认 3", @"DTRedPacketMinSec"),
           num(@"  最长延迟秒", @"默认 8", @"DTRedPacketMaxSec"),
           lst(@"  只抢这些群", @"群 id，逗号分隔；留空=全部", @"DTRedPacketGroups"),
           info(@"收款回复", @"按白名单匹配；文案中的 [金额] 会替换为本次金额"),
           sw(@"收款自动回复", @"仅对列表中的联系人回复", @"DTPayReplyEnable", NO),
           lst(@"  白名单", @"wxid，逗号分隔；空=不生效", @"DTPayReplyList"),
           txt(@"  回复文案", @"[金额] 会替换成金额", @"DTPayReplyText"),
           info(@"本地记账", @"记录本地可识别的收款/转账回调，不等同微信账单"),
           sw(@"记账本", @"按可识别的消息回调记到本地文件", @"DTLedgerEnable", NO),
           ledger ],

        // 4. 增强
        @[ info(@"头像外观", @"仅处理本机显示的联系人/群头像"),
           sw(@"头像圆角", @"重绘头像图片；默认跳过小尺寸图标", @"DTIconRadiusEnable", NO),
           num(@"  圆角比例", @"0.22 = 22%，0.5 = 正圆", @"DTIconRadiusRatio"),
           sw(@"  用 layer 模式", @"关掉则重绘图片（省内存更稳）", @"DTIconRadiusLayerMode", NO),
           sw(@"  所有图片都圆角", @"不只头像", @"DTIconRadiusAll", NO),
           info(@"聊天外观", @"仅影响本机渲染，不改变对方看到的内容"),
           sw(@"气泡美化", @"本机替换消息气泡背景", @"DTBubbleEnable", NO),
           pick(@"  样式", @"", @"DTBubbleStyle", @[@"纯净白", @"浅绿", @"深色", @"从文件夹读"]),
           txt(@"  文件夹名", @"样式选「文件夹」时生效", @"DTBubbleFolder"),
           info(@"朋友圈显示", @"手机端来源尾巴仅本机可见；不同客户端显示规则可能不同"),
           sw(@"朋友圈尾巴", @"只改手机端来源", @"DTMomentsTailEnable", NO),
           txt(@"  尾巴文案", @"默认 iPhone 15 Pro Max", @"DTMomentsTailPhone"),
           sw(@"群头像", @"按群设置", @"DTGroupAvatarEnable", NO),
           groupAvatar,
           info(@"列表与发送", @"本机显示辅助；服务端限制仍由微信决定"),
           sw(@"突破 9 图上限", @"只调整本地选择器上限，不承诺突破服务器限制", @"DTImageLimitEnable", NO),
           num(@"  上限张数", @"9–99；实际发送仍受微信限制", @"DTImageLimitMax"),
           info(@"界面提示与群聊", @"不清除消息未读状态；退群信息可能只能显示通用提示"),
           sw(@"红点消除", @"只隐藏发现页/我页红点，保留底部未读数", @"DTBadgeEnable", NO),
           sw(@"群折叠", @"免打扰的群压成一行", @"DTGroupFoldEnable", NO),
           sw(@"  只折叠免打扰群", @"", @"DTGroupFoldMuteOnly", NO),
           sw(@"退群通知", @"群成员变动时提示", @"DTGroupLeaveEnable", NO),
           sw(@"拍一拍后缀", @"", @"DTPatEnable", NO),
           txt(@"  后缀文案", @"", @"DTPatSuffix"),
           info(@"微信运动显示", @"仅替换微信界面返回的步数；不写入 Apple 健康数据"),
           sw(@"虚拟步数", @"只改微信内显示", @"DTStepEnable", NO),
           pick(@"  模式", @"", @"DTStepMode", @[@"区间随机", @"固定值"]),
           num(@"  最小值", @"默认 15000", @"DTStepMin"),
           num(@"  最大值", @"默认 35000", @"DTStepMax"),
           num(@"  固定值", @"模式选「固定值」时用", @"DTStepFixed"),
           num(@"  每天几点重置", @"0–23，默认 0", @"DTStepResetHour"),
           num(@"  自然抖动", @"0.08 = ±8%", @"DTStepJitter") ],

        // 5. 调试
        @[ sw(@"功能模块总开关", @"默认关闭：首次确认微信稳定后再打开；打开后需重启才加载功能 hook", @"DTModulesEnabled", NO),
           restoreSafeMode,
           sw(@"反检测兼容项", @"默认关闭；改动可能影响微信完整性检查", @"DTGuardEnable", NO),
           sw(@"  屏蔽 hook 校验", @"checkHook:/checkConsistency:", @"DTBlockHookCheck", NO),
           sw(@"  屏蔽文件校验上报", @"reportFileConsistency:", @"DTBlockFileConsistency", NO),
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (self.selectedCategory < 0) return nil;
    return self.selectedCategory < (NSInteger)self.headers.count
        ? self.headers[(NSUInteger)self.selectedCategory] : nil;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (self.selectedCategory < 0) return (NSInteger)DTCategories().count;
    if (self.selectedCategory >= (NSInteger)self.sections.count) return 0;
    return (NSInteger)self.sections[(NSUInteger)self.selectedCategory].count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"dtcell";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    if (self.selectedCategory < 0) {
        NSArray<NSString *> *names = DTCategories();
        NSArray<NSString *> *details = DTCategoriesDetail();
        c.textLabel.text = names[(NSUInteger)ip.row];
        c.detailTextLabel.text = details[(NSUInteger)ip.row];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        c.accessoryView = nil;
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        return c;
    }

    DTItem *it = self.sections[(NSUInteger)self.selectedCategory][(NSUInteger)ip.row];
    c.textLabel.text = it.title;
    c.textLabel.numberOfLines = 0;
    c.detailTextLabel.text = it.subtitle;
    c.detailTextLabel.numberOfLines = 0;
    c.accessoryView = nil;
    c.accessoryType = UITableViewCellAccessoryNone;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    c.userInteractionEnabled = YES;

    if (it.kind == DTItemKindInfo) {
        c.textLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        c.textLabel.textColor = [UIColor secondaryLabelColor];
        c.detailTextLabel.font = [UIFont systemFontOfSize:11];
        c.detailTextLabel.textColor = [UIColor tertiaryLabelColor];
        c.backgroundColor = [UIColor clearColor];
        c.userInteractionEnabled = NO;
        return c;
    }
    c.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    c.textLabel.textColor = [UIColor labelColor];
    c.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    c.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];

    if (it.kind == DTItemKindSwitch) {
        UISwitch *sw = [UISwitch new];
        sw.on = DTBool(it.key, it.defaultValue);
        sw.tag = self.selectedCategory * 1000 + ip.row;
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
                c.detailTextLabel.text = [NSString stringWithFormat:@"%@  (当前 %.15g)", it.subtitle ?: @"", DTDouble(it.key, 0)];
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
    if (self.selectedCategory < 0) {
        DTSettingsVC *detail = [[DTSettingsVC alloc] initWithCategory:ip.row];
        [self.navigationController pushViewController:detail animated:YES];
        return;
    }
    if (self.selectedCategory >= (NSInteger)self.sections.count ||
        ip.row >= (NSInteger)self.sections[(NSUInteger)self.selectedCategory].count) return;
    DTItem *it = self.sections[(NSUInteger)self.selectedCategory][(NSUInteger)ip.row];

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
                tf.text = DTObj(it.key) ? [NSString stringWithFormat:@"%.15g", DTDouble(it.key, 0)] : @"";
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

#pragma mark - 微信「我 → 设置」页专属入口

@interface DTSettingsEntryTarget : NSObject
@property (nonatomic, weak) UIViewController *host;
- (void)openDTSettings:(id)sender;
@end

@implementation DTSettingsEntryTarget
- (void)openDTSettings:(id)sender {
    UIViewController *host = self.host;
    if (!host) {
        DTLog(@"settings-entry: tapped after host released");
        return;
    }
    DTSettingsVC *home = [[DTSettingsVC alloc] initHome];
    UINavigationController *nav = host.navigationController;
    if (nav) {
        [nav pushViewController:home animated:YES];
    } else if (host.view.window) {
        UINavigationController *modal = [[UINavigationController alloc] initWithRootViewController:home];
        modal.modalPresentationStyle = UIModalPresentationPageSheet;
        [host presentViewController:modal animated:YES completion:nil];
    } else {
        DTLog(@"settings-entry: host is not visible; cannot present");
    }
}
@end

static BOOL gSettingsEntryHooked = NO;
static BOOL gSettingsEntryInsertInProgress = NO;
static const void *kDTEntrySectionAssoc = &kDTEntrySectionAssoc;
static const void *kDTEntryTargetAssoc = &kDTEntryTargetAssoc;
static NSUInteger gSettingsEntryAttempts = 0;
static BOOL gSettingsEntrySlowRetryLogged = NO;
static NSMutableSet<NSString *> *gSettingsEntryHookedClasses = nil;
static NSArray<NSString *> *DTSettingsEntryClassNames(void) {
    return @[@"NewSettingViewController", @"SettingViewController"];
}

static DTSettingsEntryTarget *DTSettingsTargetForHost(UIViewController *host) {
    if (!host) return nil;
    DTSettingsEntryTarget *target = objc_getAssociatedObject(host, kDTEntryTargetAssoc);
    if (!target) {
        target = [DTSettingsEntryTarget new];
        target.host = host;
        objc_setAssociatedObject(host, kDTEntryTargetAssoc, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        target.host = host;
    }
    return target;
}

static BOOL DTSettingsMethodMatches(id receiver, SEL sel, unsigned int explicitArgs, const char *returnTypes) {
    if (!receiver || !sel || ![receiver respondsToSelector:sel]) return NO;
    BOOL classReceiver = object_isClass(receiver);
    Method m = classReceiver ? class_getClassMethod((Class)receiver, sel)
                             : class_getInstanceMethod([receiver class], sel);
    if (!m || method_getNumberOfArguments(m) != explicitArgs + 2) return NO;
    char *rt = method_copyReturnType(m);
    BOOL ok = rt && (!returnTypes || strchr(returnTypes, rt[0]) != NULL);
    free(rt);
    return ok;
}

static void DTSettingsInstallNavFallback(id rawHost, NSString *reason) {
    if (![rawHost isKindOfClass:[UIViewController class]]) return;
    UIViewController *host = (UIViewController *)rawHost;
    DTSettingsEntryTarget *target = DTSettingsTargetForHost(host);
    UINavigationItem *item = host.navigationItem;
    NSMutableArray<UIBarButtonItem *> *items = [item.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    for (UIBarButtonItem *button in items) {
        if (button.target == target && button.action == @selector(openDTSettings:)) return;
    }
    UIBarButtonItem *button = [[UIBarButtonItem alloc] initWithTitle:@"DTKiller"
        style:UIBarButtonItemStylePlain target:target action:@selector(openDTSettings:)];
    [items addObject:button];
    item.rightBarButtonItems = items;
    DTLog(@"settings-entry: installed navigation fallback on %@ (%@)",
          NSStringFromClass([host class]), reason ?: @"table entry unavailable");
}

static void DTSettingsInsertEntryImpl(id host) {
    if (![host isKindOfClass:[UIViewController class]]) {
        DTLog(@"settings-entry: unexpected host class %@", host ? NSStringFromClass([host class]) : @"nil");
        return;
    }
    UIViewController *hostVC = (UIViewController *)host;
    DTSettingsEntryTarget *target = DTSettingsTargetForHost(hostVC);
    id tableInfo = DTGetIvar(host, "m_tableViewInfo");
    if (!tableInfo) {
        DTSettingsInstallNavFallback(host, @"m_tableViewInfo unavailable");
        return;
    }

    SEL countSel = sel_registerName("getSectionCount");
    SEL sectionSel = sel_registerName("getSectionAt:");
    SEL addSectionSel = sel_registerName("addSection:");
    SEL insertSectionSel = sel_registerName("insertSection:At:");
    SEL tableSel = sel_registerName("getTableView");
    if (!DTSettingsMethodMatches(tableInfo, countSel, 0, "IQiq") ||
        !DTSettingsMethodMatches(tableInfo, sectionSel, 1, "@")) {
        DTLog(@"settings-entry: section API signature unavailable (%@)", NSStringFromClass([tableInfo class]));
        DTSettingsInstallNavFallback(host, @"section API signature unavailable");
        return;
    }

    unsigned int count = ((unsigned int (*)(id, SEL))objc_msgSend)(tableInfo, countSel);
    id prior = objc_getAssociatedObject(hostVC, kDTEntrySectionAssoc);
    SEL markerGetSel = sel_registerName("getUserInfoValueForKey:");
    for (unsigned int i = 0; i < count; i++) {
        id existing = ((id (*)(id, SEL, unsigned int))objc_msgSend)(tableInfo, sectionSel, i);
        BOOL isOurs = (prior && existing == prior);
        if (!isOurs && DTSettingsMethodMatches(existing, markerGetSel, 1, "@")) {
            id marker = ((id (*)(id, SEL, id))objc_msgSend)(existing, markerGetSel, @"DTKiller.Settings.Entry.v1");
            isOurs = [marker isEqual:@"DTKiller.Settings.Entry.v1"];
        }
        if (isOurs) {
            if (hostVC) objc_setAssociatedObject(hostVC, kDTEntrySectionAssoc, existing, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
    }

    Class sectionClass = objc_getClass("MMTableViewSectionInfo");
    Class cellClass = objc_getClass("MMTableViewCellInfo");
    SEL factorySel = sel_registerName("sectionInfoDefaut");
    SEL cellFactorySel = sel_registerName("normalCellForSel:target:title:accessoryType:");
    SEL addCellSel = sel_registerName("addCell:");
    if (!sectionClass || !cellClass ||
        !DTSettingsMethodMatches(sectionClass, factorySel, 0, "@") ||
        !DTSettingsMethodMatches(cellClass, cellFactorySel, 4, "@")) {
        DTLog(@"settings-entry: WeChat table classes unavailable");
        DTSettingsInstallNavFallback(host, @"cell factory unavailable");
        return;
    }

    id section = ((id (*)(id, SEL))objc_msgSend)(sectionClass, factorySel);
    if (!section) {
        DTSettingsInstallNavFallback(host, @"section factory returned nil");
        return;
    }
    SEL markerSetSel = sel_registerName("addUserInfoValue:forKey:");
    if (DTSettingsMethodMatches(section, markerSetSel, 2, "v")) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(section, markerSetSel,
            @"DTKiller.Settings.Entry.v1", @"DTKiller.Settings.Entry.v1");
    }
    SEL setHeaderSel = sel_registerName("setHeaderTitle:");
    if (DTSettingsMethodMatches(section, setHeaderSel, 1, "v"))
        ((void (*)(id, SEL, id))objc_msgSend)(section, setHeaderSel, @"DTKiller");

    id cell = ((id (*)(id, SEL, SEL, id, id, NSInteger))objc_msgSend)(
        cellClass, cellFactorySel, @selector(openDTSettings:), target, @"DTKiller 设置", (NSInteger)1);
    if (!cell || !DTSettingsMethodMatches(section, addCellSel, 1, "v")) {
        DTSettingsInstallNavFallback(host, @"cell creation failed");
        return;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(section, addCellSel, cell);

    if (DTSettingsMethodMatches(tableInfo, insertSectionSel, 2, "v")) {
        ((void (*)(id, SEL, id, unsigned int))objc_msgSend)(tableInfo, insertSectionSel, section, 0);
    } else if (DTSettingsMethodMatches(tableInfo, addSectionSel, 1, "v")) {
        ((void (*)(id, SEL, id))objc_msgSend)(tableInfo, addSectionSel, section);
    } else {
        DTLog(@"settings-entry: no addSection API");
        DTSettingsInstallNavFallback(host, @"addSection API unavailable");
        return;
    }
    if (hostVC) objc_setAssociatedObject(hostVC, kDTEntrySectionAssoc, section, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (DTSettingsMethodMatches(tableInfo, tableSel, 0, "@")) {
        id table = ((id (*)(id, SEL))objc_msgSend)(tableInfo, tableSel);
        if ([table respondsToSelector:@selector(reloadData)]) [table reloadData];
    }
    DTLog(@"settings-entry: inserted into %@ (sections=%u)", NSStringFromClass([host class]), count + 1);
}

static void DTSettingsInsertEntry(id host) {
    if (!host || gSettingsEntryInsertInProgress) return;
    gSettingsEntryInsertInProgress = YES;
    @try {
        DTSettingsInsertEntryImpl(host);
    } @catch (NSException *e) {
        DTLog(@"settings-entry: insertion exception %@: %@", e.name, e.reason);
        DTSettingsInstallNavFallback(host, e.name);
    } @finally {
        gSettingsEntryInsertInProgress = NO;
    }
}

static void DTSettingsReloadTable(id self, SEL _cmd) {
    DTCoreRecordUIStage(@"enter:settings-page-reload");
    @try {
        IMP orig = DTOrigFor(object_getClass(self), _cmd);
        if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
        DTSettingsInsertEntry(self);
    } @catch (NSException *e) {
        DTLog(@"settings-entry: reload exception %@: %@", e.name, e.reason);
        DTSettingsInstallNavFallback(self, e.name);
    } @finally {
        DTCoreRecordUIStage(@"done:settings-page-reload");
    }
}

static BOOL DTSettingsTryInstallEntry(void) {
    if (!gSettingsEntryHookedClasses) gSettingsEntryHookedClasses = [NSMutableSet set];
    for (NSString *name in DTSettingsEntryClassNames()) {
        if ([gSettingsEntryHookedClasses containsObject:name]) continue;
        Class cls = objc_getClass(name.UTF8String);
        SEL sel = sel_registerName("reloadTableData");
        Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
        if (!m || method_getNumberOfArguments(m) != 2) continue;
        char *rt = method_copyReturnType(m);
        BOOL returnsVoid = (rt && rt[0] == 'v');
        free(rt);
        if (!returnsVoid) continue;
        IMP old = DTHookMsg(cls, sel, (IMP)DTSettingsReloadTable);
        if (old) {
            [gSettingsEntryHookedClasses addObject:name];
            gSettingsEntryHooked = YES;
            DTLog(@"settings-entry: hooked %@ -reloadTableData", name);
        }
    }
    return gSettingsEntryHooked;
}

static void DTSettingsRetryEntryInstall(void) {
    DTSettingsTryInstallEntry();
    if (gSettingsEntryHookedClasses.count >= DTSettingsEntryClassNames().count) return;
    gSettingsEntryAttempts++;
    if (gSettingsEntryAttempts == 40 && !gSettingsEntrySlowRetryLogged) {
        gSettingsEntrySlowRetryLogged = YES;
        DTLog(@"settings-entry: switching to low-frequency probes; entry remains recoverable");
    }
    // 前 20 秒每 0.5 秒探测；之后每 5 秒持续探测，不让入口永久消失。
    NSTimeInterval delay = (gSettingsEntryAttempts < 40) ? 0.5 : 5.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ DTSettingsRetryEntryInstall(); });
}

void DTModuleSettingsInstall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        DTSettingsRetryEntryInstall();
        DTLog(@"settings: injected entry installer scheduled");
    });
}
