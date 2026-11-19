//
//  DTStep.m —— P0-3 虚拟步数
//
//  只改「微信进程内读到的步数」，不改系统 HealthKit 数据库，也不动健康 App。
//  验收标准：微信运动里显示的步数 = 这里算出来的数。
//
//  开关：DTStepEnable
//        DTStepMode      0=区间随机（默认） 1=固定值
//        DTStepMin/Max   区间（默认 15000 / 35000）
//        DTStepFixed     固定值（默认 20000）
//        DTStepResetHour 每天几点归零（默认 0）
//        DTStepJitter    抖动百分比（默认 0.08）
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "DTHook.h"
#import "DTConfig.h"
#import "DTLog.h"
#import "DTClassFinder.h"
#import "DTModules.h"

#define kEnable    @"DTStepEnable"
#define kMode      @"DTStepMode"
#define kMin       @"DTStepMin"
#define kMax       @"DTStepMax"
#define kFixed     @"DTStepFixed"
#define kResetHour @"DTStepResetHour"
#define kJitter    @"DTStepJitter"

static inline uint64_t DTStepHash(uint64_t x)
{
    x += 0x9e3779b97f4a7c15ULL;
    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
    x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
    return x ^ (x >> 31);
}

static NSInteger DTStepToday(void)
{
    NSDate *now = [NSDate date];
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSInteger hour = [[cal components:NSCalendarUnitHour fromDate:now] hour];

    NSInteger resetHour = DTInt(kResetHour, 0);
    NSDate *dayStart = [cal startOfDayForDate:now];
    if (hour < resetHour) {
        dayStart = [cal dateByAddingUnit:NSCalendarUnitDay value:-1 toDate:dayStart options:0];
    }
    NSTimeInterval days = [dayStart timeIntervalSince1970] / 86400.0;
    return (NSInteger)days;
}

/// 当天的基准值（同一天内稳定）
static NSInteger DTStepBase(void)
{
    NSInteger mode  = DTInt(kMode, 0);
    NSInteger day   = DTStepToday();

    if (mode == 1) {
        return (NSInteger)MAX(0, DTInt(kFixed, 20000));
    }

    NSInteger lo = DTInt(kMin, 15000);
    NSInteger hi = DTInt(kMax, 35000);
    if (hi < lo) { NSInteger t = lo; lo = hi; hi = t; }
    if (hi == lo) return lo;

    uint64_t r = DTStepHash((uint64_t)day ^ 0x5754574543484154ULL);
    double f = (double)(r % 100000) / 100000.0;
    return lo + (NSInteger)((hi - lo) * f);
}

/// 当前应显示的值：基准值 + 随分钟缓慢波动的抖动
static NSInteger DTStepNow(void)
{
    NSInteger base = DTStepBase();
    double jitter = DTDouble(kJitter, 0.08);
    if (jitter <= 0.0) return base;
    if (jitter > 0.3) jitter = 0.3;

    NSInteger minute = (NSInteger)([[NSDate date] timeIntervalSince1970] / 60.0);
    uint64_t r = DTStepHash((uint64_t)minute ^ 0x53544550ULL);
    double f = ((double)(r % 2001) / 1000.0) - 1.0;   // -1.0 .. 1.0
    NSInteger v = base + (NSInteger)(base * jitter * f);
    return MAX(0, v);
}

#pragma mark - hook（按返回类型分三种）

static long long DTStepRetQ(id self, SEL _cmd)  { return (long long)DTStepNow(); }
static int       DTStepRetI(id self, SEL _cmd)  { return (int)DTStepNow(); }
static id        DTStepRetId(id self, SEL _cmd) { return @(DTStepNow()); }

static int DTStepHookOne(Class c, const char *selName)
{
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return 0;

    const char *rt = method_getReturnType(m);
    IMP imp = NULL;
    if (rt && (rt[0] == 'q' || rt[0] == 'Q' || rt[0] == 'l')) {
        imp = (IMP)DTStepRetQ;
    } else if (rt && (rt[0] == 'i' || rt[0] == 'I' || rt[0] == 's')) {
        imp = (IMP)DTStepRetI;
    } else if (rt && rt[0] == '@') {
        imp = (IMP)DTStepRetId;
    } else {
        DTLog(@"step: %s 返回类型 %s 不认识，跳过", selName, rt ? rt : "?");
        return 0;
    }

    if (DTHookMsg(c, sel, imp)) {
        DTLog(@"step: hooked %s on %s (ret=%s)", selName, class_getName(c), rt);
        return 1;
    }
    return 0;
}

void DTModuleStepInstall(void)
{
    if (!DTBool(kEnable, NO)) {
        DTLog(@"step: off");
        return;
    }

    static const char *sels[] = {
        "hkStepCount",       // PKC / MiYou 都 hook 这个
        "m7StepCount",
        "stepCount",
        "todayStepCount",
        "getStepCount",
    };

    int total = 0;
    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        NSArray<NSString *> *owners = DTOwnerClassesForSelector(sels[i]);
        for (NSString *cn in owners) {
            Class c = NSClassFromString(cn);
            if (c) total += DTStepHookOne(c, sels[i]);
        }
    }

    DTLog(@"step: hooked %d 个方法，当前值 %ld", total, (long)DTStepNow());
}
