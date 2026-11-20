//
//  DTCore.m —— 入口与模块调度
//
//  时序设计（0.2.1 起改过，原因见文件末尾 DTCoreInit 的注释）：
//
//  - constructor 阶段**什么都不做**，只排一个主队列延时任务。dyld 还在跑微信自己的
//    initializer 时去碰 objc runtime，会和微信后台线程抢同一张类表，崩在微信侧。
//
//  - 主队列 0.6 秒后进 DTBoot：记录前次 boot.stage，写入 running，监听 launch 通知；
//    若通知已发出则检查 UIApplication 状态，另设 6 秒兜底，三路都由 gScheduled 去重。
//
//  - 首次安装 DTModulesEnabled 默认 NO：只装微信设置页入口，不装功能 hook。
//    用户确认冷启动稳定后手动打开总闸并重启；此后功能模块分批安装。
//
//  - 每个模块写入 enter/done 阶段；只有残留 enter:* 或持久 safe 状态时，下次进入安全模式，
//    只装设置入口和诊断。正常上滑关闭留下的 running + boot-started 不视为崩溃。

#import <Foundation/Foundation.h>
#import "DTBuild.h"
#import <UIKit/UIKit.h>
#import "DTHook.h"
#import "DTConfig.h"
#import "DTClassFinder.h"
#import "DTLog.h"
#import "DTModules.h"

static BOOL gScheduled = NO;
static BOOL gBooted = NO;
static BOOL gSafeMode = NO;
static NSString *gPrevStage = nil;

#pragma mark - 启动状态

static NSString *DTStatePath(void) {
    NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [doc stringByAppendingPathComponent:@"DTKiller"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return [dir stringByAppendingPathComponent:@"boot.state"];
}

static NSString *DTStagePath(void) {
    return [[DTStatePath() stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"boot.stage"];
}

static void DTWriteStage(NSString *stage) {
    [stage writeToFile:DTStagePath() atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static NSString *DTUIStagePath(void) {
    return [[DTStatePath() stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"ui.stage"];
}

static void DTWriteUIStage(NSString *stage) {
    [stage writeToFile:DTUIStagePath() atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

void DTCoreRecordUIStage(NSString *stage) {
    DTWriteUIStage(stage ?: @"unknown");
}

static NSString *DTReadState(void) {
    return [NSString stringWithContentsOfFile:DTStatePath()
                                     encoding:NSUTF8StringEncoding
                                        error:NULL];
}

static void DTWriteState(NSString *s) {
    [s writeToFile:DTStatePath() atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

#pragma mark - 单个模块的安全安装

/// 包一层 @try：模块内部抛 NSException 只丢这一个模块，不牵连整条启动链
static void DTRun(const char *name, void (*fn)(void)) {
    DTWriteStage([NSString stringWithFormat:@"enter:%s", name ?: "?"]);
    @try {
        fn();
        DTLog(@"core: %s ok", name);
        DTWriteStage([NSString stringWithFormat:@"done:%s", name ?: "?"]);
    } @catch (NSException *e) {
        DTWriteStage([NSString stringWithFormat:@"exception:%s:%@", name ?: "?", e.name ?: @"?"]);
        DTLog(@"core: %s THREW %@ — %@", name, e.name, e.reason);
    }
}

#pragma mark - 分批安装 UI 模块

static void DTRunBatch(int idx) {
    @autoreleasepool {
        switch (idx) {
            case 0:
                DTRun("voicebar", DTModuleVoiceBarInstall);
                DTRun("voicefwd", DTModuleVoiceFwdInstall);
                DTRun("swipequote", DTModuleSwipeQuoteInstall);
                break;
            case 1:
                DTRun("silk", DTModuleSilkInstall);
                DTRun("balance", DTModuleBalanceInstall);
                DTRun("groupavatar", DTModuleGroupAvatarInstall);
                DTRun("momentstail", DTModuleMomentsTailInstall);
                break;
            case 2:
                DTRun("radius", DTModuleRadiusInstall);
                DTRun("autologin", DTModuleAutoLoginInstall);
                DTRun("step", DTModuleStepInstall);
                break;
            case 3:
                DTRun("adblock", DTModuleAdBlockInstall);
                DTRun("bubblepure", DTModuleBubblePureInstall);
                break;
            case 4:
                DTRun("batch3", DTModuleBatch3Install);
                DTRun("batch4", DTModuleBatch4Install);
                break;
            case 5:
                DTRun("settings", DTModuleSettingsInstall);
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

    if (gSafeMode) {
        DTWriteStage(@"safe-mode-settings");
        DTLog(@"core: SAFE MODE — previous stage=%@; only settings and diagnostics will load",
              gPrevStage ?: @"unknown");
        DTRun("settings", DTModuleSettingsInstall);
        DTWriteState(@"safe");
        DTWriteStage(@"safe-mode-ready");
        DTLog(@"core: safe mode remains active; use Debug → 下次启动退出安全模式 to leave it");
        return;
    }

    // 首次安装默认先提供设置入口与诊断包，不加载功能 hook。
    // 用户确认微信能正常启动后，再显式开启「功能模块总开关」并重启。
    if (!DTBool(@"DTModulesEnabled", NO)) {
        DTWriteStage(@"diagnostic-only-settings");
        DTRun("settings", DTModuleSettingsInstall);
        DTWriteState(@"ok");
        DTWriteStage(@"diagnostic-only-ready");
        DTLog(@"core: functional modules are disabled; settings entry is available");
        return;
    }

    // 反检测与消息相关：先装。晚于 didFinishLaunching 会少挡几次启动期检测，
    // 但换来的是「模块崩了不会拖着微信一起起不来」。
    DTRun("guard", DTModuleGuardInstall);
    DTRun("revoke", DTModuleRevokeInstall);
    DTRun("callkit", DTModuleCallKitInstall);

    for (int i = 0; i < 6; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            DTRunBatch(i);
            if (i == 5) {
                DTWriteState(@"ok");
                DTLog(@"core: all UI modules installed");
            }
        });
    }
}

#pragma mark - 入口

/// 真正的启动逻辑。**必须等主 run loop 跑起来之后再调用**，理由见 DTCoreInit。
static void DTBoot(void) {
    if (gBooted) return;
    gBooted = YES;

    @autoreleasepool {
        @try {
            DTMigrateFromLegacyIfNeeded();
        } @catch (NSException *e) {
            DTLog(@"core: migrate THREW %@", e.name);
        }
    }

    NSString *prev = DTReadState();
    gPrevStage = [NSString stringWithContentsOfFile:DTStagePath()
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
    BOOL leaveSafeMode = DTBool(@"DTSafeModeNextBoot", NO);
    if (leaveSafeMode) {
        DTSetBool(@"DTSafeModeNextBoot", NO);
        DTFlush();
        DTWriteState(@"ok");
        DTWriteStage(@"safe-mode-exit-requested");
    }
    BOOL stageWasIncomplete = [gPrevStage hasPrefix:@"enter:"];
    gSafeMode = !leaveSafeMode &&
        ([prev isEqualToString:@"safe"] || stageWasIncomplete);

    DTLog(@"core: injected v%@ into %@ %@ (prevState=%@, prevStage=%@%@)",
          DT_DYLIB_VERSION,
          [[NSBundle mainBundle] bundleIdentifier],
          [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
          prev ?: @"nil",
          gPrevStage ?: @"none",
          gSafeMode ? @", SAFE MODE" : @"");

    if (!gSafeMode) {
        DTWriteState(@"running");
        DTWriteStage(@"boot-started");
    }

    void (^scheduleInstall)(NSString *) = ^(NSString *reason) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            DTLog(@"core: UI install trigger=%@", reason);
            DTInstallUI();
        });
    };
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        scheduleInstall(@"didFinishLaunching");
    }];

    // DTBoot 由主队列延时任务触发；若通知早已发出，直接依据应用状态补装。
    UIApplication *app = [UIApplication sharedApplication];
    if (app.applicationState == UIApplicationStateActive || app.keyWindow != nil) {
        scheduleInstall(@"already-launched");
    }

    // 兜底：后台拉起、窗口建立较晚或通知路径未执行。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DTLog(@"core: UI install trigger=fallback");
        DTInstallUI();
    });
}

// dyld 跑 initializer 的阶段**什么都不要做**。
//
// 2026-11-20 22:26 的崩溃日志（WeChat-2026-11-20-222605.ips）：
//   faulting thread = com.apple.root.default-qos（后台队列，微信自己的初始化代码）
//   EXC_BAD_ACCESS (SIGSEGV), KERN_INVALID_ADDRESS at 0x90
//   同一时刻主线程栈：dyld runAllInitializersForMain → 我们的 constructor
//                     → class_getInstanceMethod → objc::DenseMapBase::LookupBucketFor
//
// 也就是说：我们在 dyld 还在跑 initializer 的时候就去遍历类、查方法，触发 objc
// runtime 的类表懒初始化；微信自己的后台线程同时在读写同一张表，两条路径撞在一起，
// 崩在了微信那一侧。这里改成一个纯粹的主队列延时任务——dyld 阶段不留任何副作用，
// 等 App 跑起来再干重活。
__attribute__((constructor))
static void DTCoreInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DTBoot();
    });
}
