//
//  DTCore.m —— 入口与模块调度
//
//  时序设计（关键）：
//    - constructor 阶段：微信的 ObjC 类已经 +load 完（dyld 先跑 +load 再跑 constructor），
//      所以反检测 hook 必须在这里就装好，抢在 ClientCheckMgr 第一次 checkHookWithSeq: 之前。
//    - UI 类相关的模块（语音条、输入栏、设置页）等 didFinishLaunching 之后再装，
//      否则拿不到 keyWindow / MMServiceCenter。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "DTHook.h"
#import "DTConfig.h"
#import "DTClassFinder.h"
#import "DTLog.h"
#import "DTModules.h"

static BOOL gInstalled = NO;

static void DTInstallUI(void) {
    if (gInstalled) return;
    gInstalled = YES;

    DTMigrateFromLegacyIfNeeded();

    DTModuleGuardInstall();          // 幂等，前面已经装过一次
    DTModuleVoiceBarInstall();       // 语音进度条
    DTModuleVoiceFwdInstall();       // 语音转发
    DTModuleSilkInstall();           // SILK 编解码
    DTModuleBalanceInstall();        // 改余额
    DTModuleGroupAvatarInstall();    // 群头像
    DTModuleMomentsTailInstall();    // 朋友圈尾巴
    DTModuleSwipeQuoteInstall();
    DTModuleRevokeInstall();         // 防撤回（幂等）
    DTModuleCallKitInstall();        // 来电转 CallKit（幂等）

    // —— 需求确认单里的 18 项 ——
    DTModuleRadiusInstall();         // P0-1  头像圆角
    DTModuleAutoLoginInstall();      // P0-2  自动确认登录
    DTModuleStepInstall();           // P0-3  虚拟步数
    DTModuleAdBlockInstall();        // P0-4~7 广告/视频号/Safari/自动下载
    DTModuleBubblePureInstall();     // P0-8~9 气泡美化 + 界面净化
    DTModuleBatch3Install();         // P0-10~11 / P1-12~13
    DTModuleBatch4Install();         // P1-14~18

    DTModuleSettingsInstall();       // 设置页入口

    DTLog(@"core: all UI modules installed");
}

__attribute__((constructor))
static void DTCoreInit(void) {
    @autoreleasepool {
        DTLog(@"core: injected into %@", [[NSBundle mainBundle] bundleIdentifier]);

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
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
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
