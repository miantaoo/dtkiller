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

/// 把 text 里「来自 XXX」这一段换掉，保留前面的相对时间
static NSString *DTReplaceTail(NSString *text, NSString *want) {
    NSRange r = [text rangeOfString:@"来自"];
    if (r.location == NSNotFound) return nil;
    NSString *tail = [text substringFromIndex:r.location];
    if ([tail isEqualToString:want]) return nil;      // 已经是目标文案
    return [[text substringToIndex:r.location] stringByAppendingString:want];
}

void DTModuleMomentsTailInstall(void) {
    if (!DTBool(kEn, YES)) { DTLog(@"momentstail: disabled"); return; }

    __block int nData = 0, nView = 0;
    NSString *want = DTTailText();

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
            const char *rt = method_getTypeEncoding(m);
            if (!rt || rt[0] != '@') continue;         // 只要返回对象的

            [hookedCls addObject:cn];
            __block Class wc = c;
            DTHookMsg(c, sel, imp_implementationWithBlock(^id(id self) {
                IMP o = DTOrigFor(wc, sel);
                id orig = o ? ((id (*)(id, SEL))o)(self, sel) : nil;
                if (![orig isKindOfClass:[NSString class]]) return orig;
                NSString *rep = DTReplaceTail(orig, want);
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

            DTEnumerateViews((UIView *)self, ^BOOL(UIView *v) {
                if (![v isKindOfClass:[UILabel class]]) return NO;
                UILabel *l = (UILabel *)v;
                if (l.text.length == 0) return NO;
                NSString *rep = DTReplaceTail(l.text, want);
                if (rep) l.text = rep;
                return NO;
            });
        }));
        nView++;
    }

    DTLog(@"momentstail: %d data hooks, %d view hooks, text=%@", nData, nView, want);
}
