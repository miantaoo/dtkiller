//
//  DTSwipeQuote.m —— 消息左滑引用（QQ 风格）
//
//  给消息 cell 挂一个左滑手势，触发后把该消息塞进输入栏的「引用」槽。
//  微信原生已有引用能力（referingMessageWrap），这里只是给它一个手势入口。
//
//  实测依据：PKCWeChatTools 里有 `_objc_msgSend$referingMessageWrap`、
//  `referTipsView`、`setMessage:` 一组 selector —— 说明引用对象挂在输入栏/消息工具栏上，
//  不是挂在聊天 VC 上。所以下面按「vc 本身 → 视图树 → 工具栏」三层去找宿主。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "DTHook.h"
#import "DTConfig.h"
#import "DTClassFinder.h"
#import "DTLog.h"
#import "DTModules.h"
#import "DTUtil.h"

static NSString *const kEn = @"DTSwipeQuoteEnable";
static const void *kSwipeKey = &kSwipeKey;

#pragma mark - 取消息对象

static id DTRunGetter(id obj, NSArray *names) {
    for (NSString *n in names) {
        SEL s = NSSelectorFromString(n);
        if ([obj respondsToSelector:s]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id v = [obj performSelector:s];
#pragma clang diagnostic pop
            if (v) return v;
        }
    }
    return nil;
}

static id DTMsgWrapOfCell(id cell) {
    return DTRunGetter(cell, @[@"m_msgWrap", @"msgWrap", @"getMsgWrap", @"messageWrap"]);
}

#pragma mark - 找引用宿主

/// 收集候选宿主：vc 自身、它的视图树、以及视图树里对象的 ivar（工具栏常被 ivar 持有）
static NSArray *DTHostCandidates(UIViewController *vc) {
    NSMutableArray *cands = [NSMutableArray arrayWithCapacity:64];
    if (!vc) return cands;
    [cands addObject:vc];
    if (!vc.view) return cands;

    DTEnumerateViews(vc.view, ^BOOL(UIView *v) {
        [cands addObject:v];
        return NO;
    });
    return cands;
}

static BOOL DTSetRefering(id host, id msgWrap) {
    // A) ivar 直写（含父类链）
    static NSArray *ivars = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ivars = @[@"referingMessageWrap", @"m_referingMessageWrap", @"_referingMessageWrap",
                  @"m_referMsg", @"_referMsg"];
    });
    for (NSString *iv in ivars) {
        Ivar v = class_getInstanceVariable([host class], iv.UTF8String);
        if (v) {
            object_setIvar(host, v, msgWrap);
            DTLog(@"swipequote: [%@] set ivar %@", NSStringFromClass([host class]), iv);
            return YES;
        }
    }
    // B) setter
    for (NSString *s in @[@"setReferingMessageWrap:", @"setReferMsg:", @"setQuoteMsg:", @"setMessage:"]) {
        SEL sel = NSSelectorFromString(s);
        if (![host respondsToSelector:sel]) continue;
        // setMessage: 太宽泛，只对类名像工具栏的对象用
        if ([s isEqualToString:@"setMessage:"] &&
            ![NSStringFromClass([host class]) containsString:@"Tool"]) continue;
        IMP imp = [host methodForSelector:sel];
        ((void (*)(id, SEL, id))imp)(host, sel, msgWrap);
        DTLog(@"swipequote: [%@] %@", NSStringFromClass([host class]), s);
        return YES;
    }
    return NO;
}

/// 把 msgWrap 设为当前引用对象。返回 YES 表示成功。
static BOOL DTApplyQuote(UIViewController *vc, id msgWrap) {
    if (!vc || !msgWrap) return NO;

    for (id host in DTHostCandidates(vc)) {
        if (DTSetRefering(host, msgWrap)) {
            // 让输入栏刷新（多路尝试，失败也无所谓）
            for (NSString *s in @[@"refreshInputToolView", @"updateInputToolView", @"reloadInputToolView",
                                  @"updateReferMsgView", @"showReferMsg"]) {
                SEL sel = NSSelectorFromString(s);
                if ([host respondsToSelector:sel]) {
                    IMP imp = [host methodForSelector:sel];
                    ((void (*)(id, SEL))imp)(host, sel);
                    DTLog(@"swipequote: refresh via %@", s);
                    break;
                }
            }
            return YES;
        }
    }
    DTLog(@"swipequote: no host accepted referingMessageWrap in %@", NSStringFromClass([vc class]));
    return NO;
}

static UIViewController *DTVCOf(id view) {
    UIResponder *r = (UIResponder *)view;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
        r = r.nextResponder;
    }
    return nil;
}

#pragma mark - 手势

static void DTOnSwipe(UIGestureRecognizer *g) {
    if (g.state != UIGestureRecognizerStateEnded) return;
    UIView *cell = g.view;
    id wrap = DTMsgWrapOfCell(cell);
    if (!wrap) { DTLog(@"swipequote: no msgWrap on %@", NSStringFromClass([cell class])); return; }

    UIViewController *vc = DTVCOf(cell);
    if (!vc) { DTLog(@"swipequote: no vc"); return; }

    if (DTApplyQuote(vc, wrap)) {
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [fb impactOccurred];
        // 轻提示，避免用户以为没反应
        UILabel *tip = [[UILabel alloc] init];
        tip.text = @"已引用";
        tip.font = [UIFont systemFontOfSize:12];
        tip.textColor = [UIColor whiteColor];
        tip.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
        tip.textAlignment = NSTextAlignmentCenter;
        tip.layer.cornerRadius = 6;
        tip.clipsToBounds = YES;
        tip.frame = CGRectMake(cell.bounds.size.width - 76, 8, 64, 24);
        [cell addSubview:tip];
        [UIView animateWithDuration:0.9 animations:^{ tip.alpha = 0; }
                         completion:^(BOOL f) { [tip removeFromSuperview]; }];
    }
}

static void DTAttachSwipe(UIView *cell) {
    if (objc_getAssociatedObject(cell, kSwipeKey)) return;
    UISwipeGestureRecognizer *sw = [[UISwipeGestureRecognizer alloc] initWithTarget:nil action:NULL];
    sw.direction = UISwipeGestureRecognizerDirectionLeft;
    sw.numberOfTouchesRequired = 1;
    sw.cancelsTouchesInView = NO;     // 不抢 cell 自己的点击
    id proxy = [[DTGestureProxy alloc] initWithHandler:^(UIGestureRecognizer *g) { DTOnSwipe(g); }];
    [sw addTarget:proxy action:@selector(handle:)];
    objc_setAssociatedObject(sw, "dt_proxy", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [cell addGestureRecognizer:sw];
    objc_setAssociatedObject(cell, kSwipeKey, sw, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void DTModuleSwipeQuoteInstall(void) {
    if (!DTBool(kEn, NO)) { DTLog(@"swipequote: disabled"); return; }

    __block int n = 0;
    for (NSString *cn in DTWeChatClassNames()) {
        if (![cn containsString:@"Msg"] && ![cn containsString:@"Message"]) continue;
        Class c = objc_getClass(cn.UTF8String);
        if (!c) continue;
        if (![c isSubclassOfClass:[UITableViewCell class]]) continue;

        // 必须真的带消息对象（沿父类链找 ivar）
        BOOL hasWrap = NO;
        for (Class k = c; k && k != [UITableViewCell class]; k = class_getSuperclass(k)) {
            if (class_getInstanceVariable(k, "m_msgWrap")) { hasWrap = YES; break; }
        }
        if (!hasWrap) continue;

        SEL ls = @selector(layoutSubviews);
        if (!class_getInstanceMethod(c, ls)) continue;
        __block Class wc = c;
        DTHookMsg(c, ls, imp_implementationWithBlock(^(id self) {
            IMP o = DTOrigFor(wc, ls);
            if (o) ((void (*)(id, SEL))o)(self, ls);
            if (DTBool(kEn, NO)) DTAttachSwipe(self);
        }));
        n++;
    }
    DTLog(@"swipequote: armed on %d cell classes", n);
}
