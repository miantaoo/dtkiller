//
//  DTBalance.m —— 钱包 / 零钱余额显示加成
//
//  只改显示层，不动任何数据模型，也不联网。退出页面即恢复真实值。
//  定位：类名含 Balance / Wallet / WCPay 的控制器，遍历其视图树里的大号金额 label。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "DTHook.h"
#import "DTConfig.h"
#import "DTClassFinder.h"
#import "DTLog.h"
#import "DTModules.h"

static NSString *const kEn     = @"DTBalanceEnable";
static NSString *const kOffset = @"DTBalanceOffset";
static const void *kOrigKey    = &kOrigKey;
static const void *kLastKey    = &kLastKey;   // 上次我们写回的显示值，用来判断文本是否被别人改过

static BOOL DTIsBalanceVC(Class c);

static BOOL DTLooksLikeMoney(NSString *s) {
    if (s.length == 0 || s.length > 20) return NO;
    NSString *t = [s stringByReplacingOccurrencesOfString:@"," withString:@""];
    t = [t stringByReplacingOccurrencesOfString:@"¥" withString:@""];
    t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    static NSRegularExpression *re = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+(\\.[0-9]{1,2})?$" options:0 error:NULL];
    });
    return [re firstMatchInString:t options:0 range:NSMakeRange(0, t.length)] != nil;
}

static NSString *DTApplyOffset(NSString *orig) {
    double off = DTDouble(kOffset, 0);
    if (off == 0) return orig;
    NSString *t = [orig stringByReplacingOccurrencesOfString:@"," withString:@""];
    t = [t stringByReplacingOccurrencesOfString:@"¥" withString:@""];
    t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    double v = t.doubleValue + off;
    if (v < 0) v = 0;

    // 保留原串的小数位与千分位风格
    BOOL hasComma = [orig rangeOfString:@","].location != NSNotFound;
    NSInteger decimals = 2;
    NSRange dot = [t rangeOfString:@"."];
    if (dot.location != NSNotFound) decimals = t.length - dot.location - 1;
    if (decimals > 4) decimals = 2;

    NSNumberFormatter *nf = [NSNumberFormatter new];
    nf.numberStyle = hasComma ? NSNumberFormatterDecimalStyle : NSNumberFormatterNoStyle;
    nf.minimumFractionDigits = decimals;
    nf.maximumFractionDigits = decimals;
    nf.usesGroupingSeparator = hasComma;
    NSString *out = [nf stringFromNumber:@(v)];
    if ([orig hasPrefix:@"¥"]) out = [@"¥" stringByAppendingString:out];
    return out ?: orig;
}

static void DTCollectMoneyLabels(UIView *root, NSMutableArray<UILabel *> *out) {
    if (!root) return;
    for (UIView *v in root.subviews) {
        if ([v isKindOfClass:[UILabel class]]) {
            UILabel *l = (UILabel *)v;
            // 余额一定是大字，小字（卡号、日期、提示）不动
            if (l.font.pointSize >= 18 && DTLooksLikeMoney(l.text)) [out addObject:l];
        }
        DTCollectMoneyLabels(v, out);
    }
}

/// 只处理一个 label。基准值的更新规则：
/// 文本被外部改过（≠ 上次我们写回的值）就以新文本为新基准，否则「入账 500 后
/// 再进钱包仍显示首次余额 + 偏移」，用户会以为钱没到账。
static void DTPatchOneLabel(UILabel *l, int *changed) {
    NSString *cur = l.text;
    if (!DTLooksLikeMoney(cur)) return;

    NSString *orig = objc_getAssociatedObject(l, kOrigKey);
    NSString *last = objc_getAssociatedObject(l, kLastKey);
    if (!orig || (last && ![last isEqualToString:cur])) {
        orig = cur;
        objc_setAssociatedObject(l, kOrigKey, cur, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSString *want = DTApplyOffset(orig);
    if (![want isEqualToString:cur]) {
        l.text = want;
        (*changed)++;
    }
    objc_setAssociatedObject(l, kLastKey, want, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void DTRunPatch(UIViewController *vc) {
    if (!DTBool(kEn, NO)) return;
    if (DTDouble(kOffset, 0) == 0) return;
    if (!DTIsBalanceVC([vc class])) return;

    NSMutableArray<UILabel *> *cands = [NSMutableArray array];
    DTCollectMoneyLabels(vc.view, cands);
    if (cands.count == 0) return;

    // 只改本页字号最大的那个金额。原来会把账单/红包/理财/收款码页的数字一起加偏移，
    // 用户看到「零钱 100、红包 50、账单 500」全变，比不改还糟。
    [cands sortUsingComparator:^NSComparisonResult(UILabel *a, UILabel *b) {
        if (a.font.pointSize > b.font.pointSize) return NSOrderedAscending;
        if (a.font.pointSize < b.font.pointSize) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    int changed = 0;
    DTPatchOneLabel(cands.firstObject, &changed);
    if (changed) DTLog(@"balance: patched on %@", NSStringFromClass([vc class]));
}

/// 只认余额页。Wallet / WCPay / Money 覆盖太广（账单、红包、理财、收款码都在里面）。
static BOOL DTIsBalanceVC(Class c) {
    NSString *n = NSStringFromClass(c);
    if ([n rangeOfString:@"Balance" options:NSCaseInsensitiveSearch].location == NSNotFound) return NO;
    static NSArray *bad = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = @[@"Bill", @"RedPacket", @"Lqt", @"Detail", @"Record", @"History", @"Confirm"];
    });
    for (NSString *b in bad) {
        if ([n rangeOfString:b options:NSCaseInsensitiveSearch].location != NSNotFound) return NO;
    }
    return YES;
}

void DTModuleBalanceInstall(void) {
    if (!DTBool(kEn, NO)) { DTLog(@"balance: disabled"); return; }

    __block int n = 0;
    for (NSString *cn in DTWeChatClassNames()) {
        Class c = objc_getClass(cn.UTF8String);
        if (!c) continue;
        if (![c isSubclassOfClass:[UIViewController class]]) continue;
        if (!DTIsBalanceVC(c)) continue;

        SEL app = sel_registerName("viewDidAppear:");
        __block Class wc = c;
        if (class_getInstanceMethod(c, app)) {
            DTHookMsg(c, app, imp_implementationWithBlock(^(id self, BOOL animated) {
                IMP o = DTOrigFor(wc, app);
                if (o) ((void (*)(id, SEL, BOOL))o)(self, app, animated);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ DTRunPatch(self); });
            }));
            n++;
        }

        SEL will = sel_registerName("viewWillAppear:");
        if (class_getInstanceMethod(c, will)) {
            DTHookMsg(c, will, imp_implementationWithBlock(^(id self, BOOL animated) {
                IMP o = DTOrigFor(wc, will);
                if (o) ((void (*)(id, SEL, BOOL))o)(self, will, animated);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ DTRunPatch(self); });
            }));
        }
        DTLogV(@"balance: armed %@", cn);
    }
    DTLog(@"balance: %d controllers armed, offset=%.2f", n, DTDouble(kOffset, 0));
}
