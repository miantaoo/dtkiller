//
//  DTBatch2.m —— P0-8 气泡美化 / P0-9 界面净化
//
//  界面净化只做「隐藏入口」这一类，不动数据源、不清状态。
//  每项独立开关；总开关只负责一次性把所有子项设成同一值（不覆盖之后的手动改动）。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "DTHook.h"
#import "DTConfig.h"
#import "DTLog.h"
#import "DTClassFinder.h"
#import "DTUtil.h"
#import "DTModules.h"

// ═══════════════════════════════════════════════════════════════════════════
#pragma mark - P0-8 气泡美化
// ═══════════════════════════════════════════════════════════════════════════

#define kBubbleEnable @"DTBubbleEnable"
#define kBubbleStyle  @"DTBubbleStyle"       // 0=纯净白 1=浅绿 2=深色 3=文件夹
#define kBubbleFolder @"DTBubbleFolder"      // 文件夹路径（可选）

static BOOL gBubbleOn;
static NSInteger gBubbleStyle;
static NSString *gBubbleFolder;
static NSMutableDictionary<NSString *, UIImage *> *gBubbleCache;

/// 用代码画一套气泡底图，省得带资源文件。
/// 上/下/左/右 4 段 cap inset：左右各 18pt，上下各 12pt，中间拉伸。
static UIImage *DTBubbleDraw(UIColor *fill, UIColor *border, CGFloat radius)
{
    CGFloat w = 60, h = 44;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 2.0;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(w, h) format:fmt];

    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect rect = CGRectMake(0.5, 0.5, w - 1, h - 1);
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];
        [fill setFill];
        [p fill];
        if (border) {
            [border setStroke];
            p.lineWidth = 1.0;
            [p stroke];
        }
    }];
    return [img resizableImageWithCapInsets:UIEdgeInsetsMake(14, 18, 14, 18)
                               resizingMode:UIImageResizingModeStretch];
}

static UIImage *DTBubbleBuiltin(NSInteger style)
{
    switch (style) {
        case 0: return DTBubbleDraw([UIColor whiteColor],
                                    [UIColor colorWithWhite:0.88 alpha:1.0], 8.0);
        case 1: return DTBubbleDraw([UIColor colorWithRed:0.62 green:0.94 blue:0.60 alpha:1.0],
                                    [UIColor colorWithRed:0.45 green:0.80 blue:0.44 alpha:1.0], 8.0);
        case 2: return DTBubbleDraw([UIColor colorWithWhite:0.16 alpha:1.0],
                                    [UIColor colorWithWhite:0.30 alpha:1.0], 8.0);
        default: return nil;
    }
}

/// 从文件夹里挑一张。约定：文件夹里放 normal.png / normal@2x.png / normal_dark.png。
static UIImage *DTBubbleFromFolder(NSString *folder)
{
    if (folder.length == 0) return nil;
    if (gBubbleCache[folder]) return gBubbleCache[folder];

    NSString *dir = [folder stringByExpandingTildeInPath];
    NSArray *names = @[@"normal@2x.png", @"normal.png", @"bubble.png", @"bubble@2x.png"];
    for (NSString *n in names) {
        NSString *p = [dir stringByAppendingPathComponent:n];
        UIImage *img = [UIImage imageWithContentsOfFile:p];
        if (img) {
            UIImage *cap = [img resizableImageWithCapInsets:UIEdgeInsetsMake(14, 18, 14, 18)
                                             resizingMode:UIImageResizingModeStretch];
            gBubbleCache[folder] = cap;
            DTLog(@"bubble: 用文件夹里的 %@", n);
            return cap;
        }
    }
    DTLog(@"bubble: %@ 里没找到可用图片", dir);
    return nil;
}

static UIImage *DTBubbleImage(void)
{
    if (gBubbleStyle == 3) {
        UIImage *img = DTBubbleFromFolder(gBubbleFolder);
        if (img) return img;
        DTLog(@"bubble: 文件夹模式下没图，回退到内置白色");
        return DTBubbleBuiltin(0);
    }
    return DTBubbleBuiltin(gBubbleStyle);
}

/// 只拦「气泡」这一类背景图，别把头像背景、页面背景一起换了。
static BOOL DTBubbleIsBubbleView(id self)
{
    NSString *cn = NSStringFromClass([self class]);
    if ([cn rangeOfString:@"Bubble"].location != NSNotFound) return YES;
    if ([cn rangeOfString:@"ChatViewCell"].location != NSNotFound) return NO;

    UIView *sup = [(UIView *)self superview];
    for (int i = 0; i < 2 && sup; i++) {
        NSString *sn = NSStringFromClass([sup class]);
        if ([sn rangeOfString:@"Bubble"].location != NSNotFound) return YES;
        sup = [sup superview];
    }
    return NO;
}

static void (*gOrigSetBgImage)(id, SEL, UIImage *);

static void DTBubbleSetBackgroundImage(id self, SEL _cmd, UIImage *img)
{
    if (gBubbleOn && DTBubbleIsBubbleView(self)) {
        UIImage *skin = DTBubbleImage();
        if (skin) { gOrigSetBgImage(self, _cmd, skin); return; }
    }
    gOrigSetBgImage(self, _cmd, img);
}

static void DTBubbleInstall(void)
{
    if (!DTBool(kBubbleEnable, NO)) { DTLog(@"bubble: off"); return; }

    gBubbleStyle  = DTInt(kBubbleStyle, 0);
    gBubbleFolder = DTStr(kBubbleFolder, @"/var/mobile/Documents/DTKiller/bubbles");
    if (!gBubbleCache) gBubbleCache = [NSMutableDictionary dictionary];
    gBubbleOn = YES;

    Class iv = NSClassFromString(@"UIImageView");
    if (!iv) return;

    gOrigSetBgImage = (void (*)(id, SEL, UIImage *))DTHookMsg(iv, @selector(setBackgroundImage:),
                                                             (IMP)DTBubbleSetBackgroundImage);
    DTLog(@"bubble: style=%ld folder=%@ hook=%d", (long)gBubbleStyle, gBubbleFolder, gOrigSetBgImage != NULL);
}

// ═══════════════════════════════════════════════════════════════════════════
#pragma mark - P0-9 界面净化
// ═══════════════════════════════════════════════════════════════════════════

#define kPureEnable @"DTPureEnable"
#define kPureAll    @"DTPureCleanAll"

/// 每一项：配置键 + 要隐藏的标题（子串匹配，大小写敏感按微信文案）
typedef struct {
    const char *key;
    const char *title;
} DTPureItem;

static const DTPureItem kPureItems[] = {
    { "DTPureHideMiniProgram",  "小程序" },
    { "DTPureHideChannels",     "视频号" },
    { "DTPureHideLive",         "直播" },
    { "DTPureHideShopping",     "购物" },
    { "DTPureHideGames",        "游戏" },
    { "DTPureHideMeMoments",    "朋友圈" },
    { "DTPureHideMeEmoji",      "表情" },
    { "DTPureHideMeFavorites",  "收藏" },
    { "DTPureHideMeWallet",     "卡包" },
    { "DTPureHideMeSticker",    "表情商店" },
    { "DTPureHideEmojiCamera",  "拍照" },
    { "DTPureHideEmojiRecent",  "最近使用" },
    { "DTPureHideEmojiSearch",  "搜索表情" },
};

static BOOL gPureOn;
static NSArray<NSString *> *gPureTitles;

static void DTPureLoad(void)
{
    NSMutableArray *a = [NSMutableArray array];
    BOOL all = DTBool(kPureAll, NO);
    for (size_t i = 0; i < sizeof(kPureItems) / sizeof(kPureItems[0]); i++) {
        NSString *k = @(kPureItems[i].key);
        if (DTBool(k, all)) [a addObject:@(kPureItems[i].title)];
    }
    gPureTitles = a;
    DTLog(@"pure: 生效 %lu 项：%@", (unsigned long)a.count, [a componentsJoinedByString:@","]);
}

static NSString *DTPureCellTitle(id cell)
{
    if (!cell) return nil;

    for (NSString *fn in @[@"title", @"text", @"m_title", @"m_nsTitle"]) {
        SEL s = NSSelectorFromString(fn);
        if ([cell respondsToSelector:s]) {
            id v = ((id (*)(id, SEL))objc_msgSend)(cell, s);
            if ([v isKindOfClass:[NSString class]] && [v length]) return v;
        }
    }
    // 有些 cell 标题在子 label 里
    if ([cell isKindOfClass:[UIView class]]) {
        UIView *found = DTFindView((UIView *)cell, ^BOOL(UIView *v) {
            return [v isKindOfClass:[UILabel class]] && ((UILabel *)v).text.length > 0;
        });
        if (found) return ((UILabel *)found).text;
    }
    return nil;
}

static BOOL DTPureShouldHide(id cell)
{
    NSString *t = DTPureCellTitle(cell);
    if (t.length == 0) return NO;
    for (NSString *want in gPureTitles) {
        if ([t rangeOfString:want].location != NSNotFound) {
            DTLog(@"pure: 隐藏「%@」", t);
            return YES;
        }
    }
    return NO;
}

/// 微信的设置页 / 发现页都是 addCell: / addSection: 往里塞，拦这两个就够。
static void DTPureAddCell(id self, SEL _cmd, id cell)
{
    IMP o = DTOrigFor(object_getClass(self), _cmd);
    if (gPureOn && DTPureShouldHide(cell)) return;
    if (o) ((void (*)(id, SEL, id))o)(self, _cmd, cell);
}

static void DTPureAddSection(id self, SEL _cmd, id sec)
{
    IMP o = DTOrigFor(object_getClass(self), _cmd);
    if (gPureOn && DTPureShouldHide(sec)) return;
    if (o) ((void (*)(id, SEL, id))o)(self, _cmd, sec);
}

static void DTPureInstall(void)
{
    if (!DTBool(kPureEnable, NO)) { DTLog(@"pure: off"); return; }

    DTPureLoad();
    if (gPureTitles.count == 0) { DTLog(@"pure: 没有选中任何项"); return; }
    gPureOn = YES;

    int n = 0;
    static const char *sels[] = { "addCell:", "addSection:" };
    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        for (NSString *cn in DTOwnerClassesForSelector(sels[i])) {
            Class c = NSClassFromString(cn);
            if (!c) continue;
            IMP imp = (i == 0) ? (IMP)DTPureAddCell : (IMP)DTPureAddSection;
            if (DTHookMsg(c, sel_registerName(sels[i]), imp)) n++;
        }
    }
    DTLog(@"pure: 装了 %d 个点", n);
}

// ═══════════════════════════════════════════════════════════════════════════

void DTModuleBubblePureInstall(void)
{
    @autoreleasepool {
        DTBubbleInstall();
        DTPureInstall();
    }
}
