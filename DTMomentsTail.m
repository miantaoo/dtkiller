//
//  DTMomentsTail.m —— 朋友圈「来自 XXX」
//
//  双路生效：
//    1) 数据层：hook 朋友圈数据对象的 source / m_source getter（首选）
//    2) 视图层：朋友圈 cell 里含「来自」的 label 做片段替换（兜底，保留「2小时前」前缀）
//  只改手机端（DTMomentsTailPhone），电脑端不动。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "DTHook.h"
#import "DTConfig.h"
#import "DTClassFinder.h"
#import "DTLog.h"
#import "DTModules.h"
#import "DTUtil.h"

static NSString *const kEn     = @"DTMomentsTailEnable";
static NSString *const kPhone  = @"DTMomentsTailPhone";
static NSString *const kPrefix = @"DTMomentsTailPrefix";
/// 给「已经替换过来源的那一个 label」打的标记，避免每次 layout 重新遍历整棵树
static const NSInteger kDTTailTag = 0x7A11;

static NSString *DTTailText(void) {
    NSString *dev = DTStr(kPhone, @"iPhone 15 Pro Max");
    NSString *pre = DTStr(kPrefix, @"来自");
    return [NSString stringWithFormat:@"%@ %@", pre, dev];
}

/// 朋友圈数据类：类名带这些词的才动，避免 hook 到无关的 source
static BOOL DTIsTimelineClass(NSString *cn) {
    static NSArray *kw = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kw = @[@"TimeLine", @"Timeline", @"Moments", @"WCDataItem", @"WCContent", @"Feed", @"Sns"];
    });
    for (NSString *k in kw) if ([cn containsString:k]) return YES;
    return NO;
}

/// 把 text 里「<prefix> XXX」这段换掉，保留前面的相对时间。
/// 三个约束都是为了不误伤正文：来源行一定很短、prefix 一定落在后半段、
/// 且匹配用的是配置里的 prefix（不再硬编码「来自」，否则改了前缀就永远匹配不上）。
static NSString *DTReplaceTailWithPrefix(NSString *text, NSString *prefix, NSString *want) {
    if (text.length == 0 || text.length > 32) return nil;
    if (prefix.length == 0) prefix = @"来自";
    NSRange r = [text rangeOfString:prefix];
    if (r.location == NSNotFound && ![prefix isEqualToString:@"来自"]) {
        r = [text rangeOfString:@"来自"];          // 旧文案兜底
    }
    if (r.location == NSNotFound) return nil;
    if (r.location * 2 < text.length) return nil;   // prefix 必须落在后半段
    NSString *tail = [text substringFromIndex:r.location];
    if ([tail isEqualToString:want]) return nil;    // 已经是目标文案
    return [[text substringToIndex:r.location] stringByAppendingString:want];
}

void DTModuleMomentsTailInstall(void) {
    if (!DTBool(kEn, NO)) { DTLog(@"momentstail: disabled"); return; }

    __block int nData = 0, nView = 0;
    NSString *want = DTTailText();
    NSString *pre  = DTStr(kPrefix, @"来自");

    // ---- 1) 数据层 ----
    NSArray *sels = @[@"source", @"m_source", @"getSource", @"sourceName", @"m_nsSource"];
    NSMutableSet *hookedCls = [NSMutableSet set];
    for (NSString *s in sels) {
        for (NSString *cn in DTOwnerClassesForSelector(s.UTF8String)) {
            if (!DTIsTimelineClass(cn)) continue;
            if ([hookedCls containsObject:cn]) continue;
            Class c = objc_getClass(cn.UTF8String);
            if (!c) continue;
            SEL sel = NSSelectorFromString(s);
            Method m = class_getInstanceMethod(c, sel);
            if (!m) continue;
            char *rt = method_copyReturnType(m);        // 只取返回类型，别用 getTypeEncoding 猜
            BOOL isObj = (rt && rt[0] == '@');
            if (rt) free(rt);
            if (!isObj) continue;

            [hookedCls addObject:cn];
            __block Class wc = c;
            DTHookMsg(c, sel, imp_implementationWithBlock(^id(id self) {
                IMP o = DTOrigFor(wc, sel);
                id orig = o ? ((id (*)(id, SEL))o)(self, sel) : nil;
                if (![orig isKindOfClass:[NSString class]]) return orig;
                NSString *rep = DTReplaceTailWithPrefix(orig, pre, want);
                return rep ?: orig;
            }));
            nData++;
        }
    }

    // ---- 2) 视图层兜底 ----
    NSMutableArray *cellCls = [NSMutableArray array];
    for (NSString *cn in DTWeChatClassNames()) {
        if (!DTIsTimelineClass(cn)) continue;
        Class c = objc_getClass(cn.UTF8String);
        if (!c) continue;
        if (![c isSubclassOfClass:[UIView class]]) continue;
        if (!class_getInstanceMethod(c, @selector(layoutSubviews))) continue;
        [cellCls addObject:cn];
    }

    for (NSString *cn in cellCls) {
        Class c = objc_getClass(cn.UTF8String);
        SEL ls = @selector(layoutSubviews);
        __block Class wc = c;
        DTHookMsg(c, ls, imp_implementationWithBlock(^(id self) {
            IMP o = DTOrigFor(wc, ls);
            if (o) ((void (*)(id, SEL))o)(self, ls);

            // 先处理已标记的来源 label（通常 0 或 1 个），没有再全树找一次并打 tag，
            // 之后每次 layout 只碰带 tag 的那个，避免滚动时整棵树 DFS。
            DTEnumerateViews((UIView *)self, ^BOOL(UIView *v) {
                if (v.tag != kDTTailTag) return NO;
                UILabel *l = (UILabel *)v;
                NSString *rep = DTReplaceTailWithPrefix(l.text, pre, want);
                if (rep && ![rep isEqualToString:l.text]) l.text = rep;
                return NO;
            });
            __block BOOL hasMarked = NO;
            DTEnumerateViews((UIView *)self, ^BOOL(UIView *v) {
                if (v.tag == kDTTailTag) { hasMarked = YES; return YES; }
                return NO;
            });
            if (hasMarked) return;

            DTEnumerateViews((UIView *)self, ^BOOL(UIView *v) {
                if (![v isKindOfClass:[UILabel class]]) return NO;
                UILabel *l = (UILabel *)v;
                if (l.text.length == 0) return NO;
                NSString *rep = DTReplaceTailWithPrefix(l.text, pre, want);
                if (!rep) return NO;
                if (![rep isEqualToString:l.text]) l.text = rep;
                l.tag = kDTTailTag;          // 只认第一个命中，后续 layout 直接走上面的快路径
                return YES;
            });
        }));
        nView++;
    }

    DTLog(@"momentstail: %d data hooks, %d view hooks, text=%@", nData, nView, want);
}
