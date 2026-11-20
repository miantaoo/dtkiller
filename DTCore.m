//
//  DTCore.m —— 入口与模块调度
//
//  时序设计（0.2.1 起改过，原因见文件末尾 DTCoreInit 的注释）：
//
//  - constructor 阶段**什么都不做**，只排一个主队列延时任务。dyld 还在跑微信自己的
//    initializer 时去碰 objc runtime，会和微信后台线程抢同一张类表，崩在微信侧。
//
//  - 主队列 0.6 秒后进 DTBoot：读 boot.state、写 running、等 didFinishLaunching。
//
//  - didFinishLaunching 之后才装：先反检测三件（Guard / Revoke / CallKit），
//    再按 0.35 秒一批装 UI 模块。每个模块单独 @try，一个抛异常不影响其它。
//
//  - 崩溃自愈：全部装完才把 boot.state 写成 ok。
//    下次启动若读到 running，说明上次没走到最后，自动进安全模式（只装设置页 +
//    诊断导出），保证永远能进微信、能进设置页把日志导出来。
//    想手动退出安全模式：删掉 微信/Documents/DTKiller/boot.state 即可。
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
static BOOL gBooted = NO;
static BOOL gSafeMode = NO;

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
    @try {
        fn();
        DTLog(@"core: %s ok", name);
    } @catch (NSException *e) {
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
        DTLog(@"core: SAFE MODE —— 上次启动没走完，这次只装设置页与诊断导出");
        DTRun("settings", DTModuleSettingsInstall);
        DTWriteState(@"ok");
        DTLog(@"core: safe mode ready（删掉 Documents/DTKiller/boot.state 可退出安全模式）");
        return;
    }

    @autoreleasepool {
        @try {
            DTMigrateFromLegacyIfNeeded();
        } @catch (NSException *e) {
            DTLog(@"core: migrate THREW %@", e.name);
        }
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

    NSString *prev = DTReadState();
    gSafeMode = [prev isEqualToString:@"running"];

    DTLog(@"core: injected v%@ into %@ %@ (prevState=%@%@)",
          DT_DYLIB_VERSION,
          [[NSBundle mainBundle] bundleIdentifier],
          [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
          prev ?: @"nil",
          gSafeMode ? @", SAFE MODE" : @"");

    if (!gSafeMode) {
        DTWriteState(@"running");
    }

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

    // 兜底：拿不到 didFinishLaunching 时（后台拉起 / 通知已被发过）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
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
