//
//  DTAutoLogin.m —— P0-2 自动确认登录
//
//  只处理「确认登录」这类页面：弹窗出现后按按钮标题点一次。
//  异常登录 / 风险提示页（红色警告）一律不点 —— 那种页面需要人判断。
//
//  开关：DTAutoLoginEnable（默认关）、DTAutoLoginDelay（默认 0.8 秒）
//

#import <UIKit/UIKit.h>
#import "DTHook.h"
#import "DTConfig.h"
#import "DTLog.h"
#import "DTClassFinder.h"
#import "DTUtil.h"
#import "DTModules.h"

#define kEnable @"DTAutoLoginEnable"
#define kDelay  @"DTAutoLoginDelay"

static NSMutableSet<NSString *> *gFired;

#pragma mark - 找按钮

static UIButton *DTAutoLoginFindButton(UIView *root)
{
    __block UIButton *found = nil;
    DTFindView(root, ^BOOL(UIView *v) {
        if (![v isKindOfClass:[UIButton class]]) return NO;
        UIButton *b = (UIButton *)v;
        if (b.hidden || b.alpha < 0.05 || !b.window) return NO;
        if (!b.enabled) return NO;

        NSString *t = [b titleForState:UIControlStateNormal];
        if (t.length == 0) t = [b titleForState:UIControlStateSelected];
        if (t.length == 0) t = b.currentTitle;
        if (t.length == 0) return NO;

        // 只认「登录」，不认「切换账号」「其他方式登录」「取消」
        if (![t containsString:@"登录"]) return NO;
        if ([t containsString:@"其他"] || [t containsString:@"切换"] ||
            [t containsString:@"取消"] || [t containsString:@"退出"]) return NO;

        found = b;
        return YES;
    });
    return found;
}

static BOOL DTAutoLoginLooksAbnormal(UIView *root)
{
    __block BOOL bad = NO;
    static NSString *words[] = { @"异常", @"风险", @"安全提示", @"被盗", @"冻结", @"验证身份" };
    DTEnumerateViews(root, ^BOOL(UIView *v) {
        if (![v isKindOfClass:[UILabel class]]) return NO;
        NSString *t = ((UILabel *)v).text;
        if (t.length == 0 || t.length > 200) return NO;
        for (size_t i = 0; i < sizeof(words) / sizeof(words[0]); i++) {
            if ([t containsString:words[i]]) { bad = YES; return YES; }
        }
        return NO;
    });
    return bad;
}

#pragma mark - hook

static void DTAutoLoginViewDidAppear(id self, SEL _cmd)
{
    IMP o = DTOrigFor(object_getClass(self), _cmd);
    if (o) ((void (*)(id, SEL))o)(self, _cmd);

    if (!DTBool(kEnable, NO)) return;

    UIViewController *vc = (UIViewController *)self;
    UIView *root = vc.view;
    if (!root) return;

    if (DTAutoLoginLooksAbnormal(root)) {
        DTLog(@"autologin: %@ 是异常/风险页，不点", NSStringFromClass([vc class]));
        return;
    }

    double delay = DTDouble(kDelay, 0.8);
    if (delay < 0.2) delay = 0.2;

    NSString *tag = [NSString stringWithFormat:@"%p", vc];
    if ([gFired containsObject:tag]) return;

    __weak UIViewController *wvc = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *svc = wvc;
        if (!svc || !svc.view.window) return;

        UIButton *b = DTAutoLoginFindButton(svc.view);
        if (!b) return;

        if ([gFired containsObject:tag]) return;
        [gFired addObject:tag];

        DTLog(@"autologin: 点击「%@」@%@", b.currentTitle, NSStringFromClass([svc class]));
        [b sendActionsForControlEvents:UIControlEventTouchUpInside];
    });
}

#pragma mark - 安装

void DTModuleAutoLoginInstall(void)
{
    if (!DTBool(kEnable, NO)) {
        DTLog(@"autologin: off");
        return;
    }

    if (!gFired) gFired = [NSMutableSet set];

    NSArray<NSString *> *names = DTClassesMatching("Login");
    int n = 0;
    for (NSString *cn in names) {
        Class c = NSClassFromString(cn);
        if (!c) continue;
        if (!DTClassHasSel(c, "viewDidAppear:")) continue;
        if (DTHookMsg(c, @selector(viewDidAppear:), (IMP)DTAutoLoginViewDidAppear)) n++;
    }

    DTLog(@"autologin: 装了 %d 个类（候选 %lu）", n, (unsigned long)names.count);
}
