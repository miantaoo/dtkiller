//
//  DTCore.m —— 入口与模块调度
//
//  时序设计（关键）：
//    - constructor 阶段：微信的 ObjC 类已经 +load 完（dyld 先跑 +load 再跑 constructor），
//      所以反检测 hook 必须在这里就装好，抢在 ClientCheckMgr 第一次 checkHookWithSeq: 之前。
//    - UI 类相关的模块等 didFinishLaunching 之后再装，否则拿不到 keyWindow / MMServiceCenter。
//    - 装 hook 时要按 selector 反查宿主类，一次全量扫描几百毫秒，
//      所以分成 4 批错开执行，避免微信启动时卡一下。
//

#import <Foundation/Foundation.h>
#import "DTBuild.h"
#import <UIKit/UIKit.h>
#import "DTHook.h"
#import "DTConfig.h"
#import "DTClassFinder.h"
#import "DTLog.h"
#import "DTModules.h"

static BOOL gScheduled = NO;

/// 一批模块安装：包一层 autoreleasepool，单个模块抛异常不影响后面的
static void DTRunBatch(int idx) {
    @autoreleasepool {
        switch (idx) {
            case 0:
                DTModuleVoiceBarInstall();
                DTModuleVoiceFwdInstall();
                DTModuleSwipeQuoteInstall();
                break;
            case 1:
                DTModuleSilkInstall();
                DTModuleBalanceInstall();
                DTModuleGroupAvatarInstall();
                DTModuleMomentsTailInstall();
                break;
            case 2:
                DTModuleRadiusInstall();
                DTModuleAutoLoginInstall();
                DTModuleStepInstall();
                break;
            case 3:
                DTModuleAdBlockInstall();
                DTModuleBubblePureInstall();
                break;
            case 4:
                DTModuleBatch3Install();
                DTModuleBatch4Install();
                break;
            case 5:
                DTModuleSettingsInstall();
                break;
            default:
                break;
        }
        DTLog(@"core: batch %d done", idx);
    }
}

static void DTInstallUI(void) {
    if (gScheduled) return;
    gScheduled = YES;

    @autoreleasepool {
        DTMigrateFromLegacyIfNeeded();

        // 这三个在 constructor 里已经装过一次，这里是幂等补齐
        DTModuleGuardInstall();
        DTModuleRevokeInstall();
        DTModuleCallKitInstall();
    }

    // 18 项功能 + 设置页，按 0.35 秒间隔分批，每批控制在百毫秒级
    for (int i = 0; i < 6; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            DTRunBatch(i);
            if (i == 5) DTLog(@"core: all UI modules installed");
        });
    }
}

__attribute__((constructor))
static void DTCoreInit(void) {
    @autoreleasepool {
        DTLog(@"core: injected into %@ v%@ (dylib %@)",
              [[NSBundle mainBundle] bundleIdentifier],
              [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
              DT_DYLIB_VERSION);

        // 1) 反检测：立刻装，越早越好
        DTModuleGuardInstall();
        DTModuleRevokeInstall();     // 防撤回必须早于第一条消息到达
        DTModuleCallKitInstall();    // PushKit 来电可能在 didFinishLaunching 之前就到

        // 2) UI 模块：等启动完成
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                DTInstallUI();
            });
        }];

        // 3) 兜底：某些注入方式拿不到 didFinishLaunching（比如后台被拉起）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            DTInstallUI();
        });
    }
}
