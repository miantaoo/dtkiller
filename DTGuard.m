//
//  DTGuard.m —— 反检测 + 选择性上报屏蔽
//
//  原则（避免「什么都不上报」反而更可疑）：
//    拦：hook 检测、文件校验、越狱/注入检测、调试日志开关、dyld image 枚举
//    放：业务统计（doSSReport 等）原样上报
//
//  关键点（来自 TrollFools/ElleKit 注入模型与公开 class-dump）：
//    - 微信的检测集中在 ClientCheckMgr（checkHook: / checkHookWithSeq: /
//      checkConsistency: / registerAddImageCallBack / getImageList）与 JailBreakHelper。
//    - 这些必须**直接 no-op、不调原实现**；先调再补救等于已经上报完了。
//    - ObjC swizzle 只改 __DATA，不动 __TEXT，所以不会命中段哈希校验；
//      真正的风险是 image 列表里出现我们的 dylib 名 → 见 getImageList 过滤。
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "DTHook.h"
#import "DTConfig.h"
#import "DTClassFinder.h"
#import "DTLog.h"
#import "DTModules.h"

static NSString *const kGuardOn   = @"DTGuardEnable";
static NSString *const kBlockFile = @"DTBlockFileConsistency";
static NSString *const kBlockHook = @"DTBlockHookCheck";
static NSString *const kSpoofID   = @"DTSpoofBundleID";

// A 组：命中就返回 NO / 0（布尔/数值型检测）
static const char *kDenySels[] = {
    "checkHook:",
    "checkHookWithSeq:",
    "checkHookWithSeq:seq:",
    "checkConsistency:",
    "isBeingDebugged",
    "IsJailBreak",
    "JailBroken",
    "HasInstallJailbreakPlugin:",
    "HasInstallJailbreakPluginInvalidIAPPurchase",
    "getJailbreakPath",
    "getJailbreakRootDir",
    "shouldEnableDebugLog",
    "isJailbreakDetected",
    NULL
};

// B 组：void 型，直接吞掉
static const char *kMuteSels[] = {
    "registerAddImageCallBack",
    "reportFileConsistency:fileName:offset:bufferSize:seq:",
    "reportAppList:",
    NULL
};

// C 组：返回集合/数组的枚举接口，返回空容器（比返回 nil 安全）
static const char *kEmptySels[] = {
    "getImageList",
    "runningProcesses",
    "runningProcesses:",
    NULL
};

// D 组：bundleId 伪造（只在这些类名里做，避免误伤）
static const char *kSpoofSels[] = {
    "bundleId",
    "bundleID",
    NULL
};

static BOOL DTIsAuthClass(NSString *cn) {
    static NSArray *kw = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kw = @[@"Auth", @"ReqData", @"BaseObject", @"Login", @"WWK", @"DeviceInfo"];
    });
    for (NSString *k in kw) if ([cn containsString:k]) return YES;
    return NO;
}

static IMP DTMakeNoHook(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    const char *types = method_getTypeEncoding(m);
    char ret = types ? types[0] : 'v';
    if (ret == 'B' || ret == 'c') {
        return DTHookMsg(cls, sel, imp_implementationWithBlock(^BOOL(id self) { return NO; }));
    }
    if (ret == 'i' || ret == 'q' || ret == 'I' || ret == 'Q' || ret == 'd' || ret == 'f') {
        return DTHookMsg(cls, sel, imp_implementationWithBlock(^long long(id self) { return 0; }));
    }
    // void 或对象：什么也不做
    return DTHookMsg(cls, sel, imp_implementationWithBlock(^(id self) {}));
}

void DTModuleGuardInstall(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;

    if (!DTBool(kGuardOn, YES)) { DTLog(@"guard: disabled"); return; }

    int hooked = 0;

    // ---- A 组 ----
    if (DTBool(kBlockHook, YES)) {
        for (int i = 0; kDenySels[i]; i++) {
            const char *s = kDenySels[i];
            NSArray *owners = DTOwnerClassesForSelector(s);
            if (owners.count == 0) { DTLogV(@"guard: %s not found", s); continue; }
            for (NSString *cn in owners) {
                Class c = objc_getClass(cn.UTF8String);
                if (!c) continue;
                if (DTMakeNoHook(c, sel_registerName(s))) {
                    hooked++;
                    DTLogV(@"guard: killed -[%@ %s]", cn, s);
                }
            }
        }
    }

    // ---- B 组：吞掉（文件校验 + dyld 回调注册 + app 列表上报）----
    if (DTBool(kBlockFile, DTBool(@"DTGuardBlockReport", YES))) {   // 旧键兼容
        for (int i = 0; kMuteSels[i]; i++) {
            const char *s = kMuteSels[i];
            for (NSString *cn in DTOwnerClassesForSelector(s)) {
                Class c = objc_getClass(cn.UTF8String);
                if (!c) continue;
                if (DTHookMsg(c, sel_registerName(s), imp_implementationWithBlock(^(id self) {}))) {
                    hooked++;
                    DTLogV(@"guard: muted -[%@ %s]", cn, s);
                }
            }
        }
    }

    // ---- C 组：image 列表 / 进程列表返回空 ----
    if (DTBool(kBlockHook, YES)) {
        for (int i = 0; kEmptySels[i]; i++) {
            const char *s = kEmptySels[i];
            for (NSString *cn in DTOwnerClassesForSelector(s)) {
                Class c = objc_getClass(cn.UTF8String);
                if (!c) continue;
                if (DTHookMsg(c, sel_registerName(s), imp_implementationWithBlock(^id(id self) {
                    return [NSMutableArray array];
                }))) {
                    hooked++;
                    DTLogV(@"guard: emptied -[%@ %s]", cn, s);
                }
            }
        }
    }

    // ---- D 组：bundleId 伪造 ----
    if (DTBool(kSpoofID, YES)) {
        for (int i = 0; kSpoofSels[i]; i++) {
            const char *s = kSpoofSels[i];
            for (NSString *cn in DTOwnerClassesForSelector(s)) {
                if (!DTIsAuthClass(cn)) continue;
                Class c = objc_getClass(cn.UTF8String);
                if (!c) continue;
                SEL sel = sel_registerName(s);
                Method m = class_getInstanceMethod(c, sel);
                if (!m) continue;
                const char *types = method_getTypeEncoding(m);
                if (!types || types[0] != '@') continue;
                if (DTHookMsg(c, sel, imp_implementationWithBlock(^id(id self) {
                    return @"com.tencent.xin";
                }))) {
                    hooked++;
                    DTLogV(@"guard: spoofed -[%@ %s]", cn, s);
                }
            }
        }
    }

    // ---- 类方法版本（有些检测放在 + 方法里）----
    for (int i = 0; kDenySels[i]; i++) {
        const char *s = kDenySels[i];
        for (NSString *cn in DTWeChatClassNames()) {
            Class c = objc_getClass(cn.UTF8String);
            if (!c) continue;
            Method m = class_getClassMethod(c, sel_registerName(s));
            if (!m) continue;
            const char *types = method_getTypeEncoding(m);
            char ret = types ? types[0] : 'v';
            IMP ni = (ret == 'B' || ret == 'c')
                ? imp_implementationWithBlock(^BOOL(id self) { return NO; })
                : imp_implementationWithBlock(^(id self) {});
            if (DTHookClsMsg(c, sel_registerName(s), ni)) hooked++;
        }
    }

    DTLog(@"guard: %d hooks installed", hooked);
}
