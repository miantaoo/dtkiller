//
//  DTConfig.m
//

#import "DTConfig.h"
#import "DTLog.h"

static NSString *const kDTMigratedFlag = @"DTMigratedV1";
static NSString *const kDTBalanceTypeFixFlag = @"DTBalanceEnableTypeFixV1";

static NSUserDefaults *DTDefaults(void) {
    // 独立域 com.dt.killer。
    // 不用 standardUserDefaults 的原因：微信进程的 standard 域就是 com.tencent.xin，
    // 用户装的原插件（Misaka/HB/MiYou/WCPure）全都写同一个域，双方的 synchronize
    // 会互相覆盖整个 plist。独立域之后，只在迁移时读一次旧域。
    static NSUserDefaults *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = [[NSUserDefaults alloc] initWithSuiteName:@"com.dt.killer"];
        if (!d) {
            // 极少数情况下 suite 建不出来，退回标准域，功能不至于全失效
            d = [NSUserDefaults standardUserDefaults];
        }
    });
    return d;
}

BOOL DTBool(NSString *key, BOOL def) {
    id v = [DTDefaults() objectForKey:key];
    return v ? [DTDefaults() boolForKey:key] : def;
}

void DTSetBool(NSString *key, BOOL v) {
    [DTDefaults() setBool:v forKey:key];
    DTFlush();
}

NSInteger DTInt(NSString *key, NSInteger def) {
    id v = [DTDefaults() objectForKey:key];
    return v ? [DTDefaults() integerForKey:key] : def;
}

void DTSetInt(NSString *key, NSInteger v) {
    [DTDefaults() setInteger:v forKey:key];
    DTFlush();
}

double DTDouble(NSString *key, double def) {
    id v = [DTDefaults() objectForKey:key];
    return v ? [DTDefaults() doubleForKey:key] : def;
}

void DTSetDouble(NSString *key, double v) {
    [DTDefaults() setDouble:v forKey:key];
    DTFlush();
}

NSString *DTStr(NSString *key, NSString *def) {
    id v = [DTDefaults() objectForKey:key];
    if (!v) return def;
    return [v isKindOfClass:[NSString class]] ? v : [v description];
}

void DTSetStr(NSString *key, NSString *v) {
    [DTDefaults() setObject:v forKey:key];
    DTFlush();
}

id DTObj(NSString *key) {
    return [DTDefaults() objectForKey:key];
}

void DTSetObj(NSString *key, id v) {
    if (!v) {
        [DTDefaults() removeObjectForKey:key];
    } else {
        [DTDefaults() setObject:v forKey:key];
    }
    DTFlush();
}

void DTFlush(void) {
    [DTDefaults() synchronize];
}

NSString *DTExportJSON(void) {
    NSDictionary *all = [DTDefaults() dictionaryRepresentation];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *k in all) {
        if ([k hasPrefix:@"DT"]) out[k] = all[k];
    }
    NSData *d = [NSJSONSerialization dataWithJSONObject:out
                                                options:NSJSONWritingPrettyPrinted
                                                  error:NULL];
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
}

/// 递归清洗成 property-list 安全的值。
/// 写成 C 函数而不是 block：block 自递归要 __block 强捕获自己，clang 会报
/// -Warc-retain-cycles；CI 开着 -Werror，那样直接编译失败。
static id DTCleanPlist(id v) {
    if (!v || [v isKindOfClass:[NSNull class]]) return nil;
    if ([v isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray array];
        for (id e in (NSArray *)v) {
            id c = DTCleanPlist(e);
            if (c) [a addObject:c];
        }
        return a;
    }
    if ([v isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (id k in (NSDictionary *)v) {
            id c = DTCleanPlist(((NSDictionary *)v)[k]);
            if (c) m[(NSString *)k] = c;
        }
        return m;
    }
    if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) return v;
    return nil;
}

BOOL DTImportJSON(NSString *json) {
    if (!json.length) return NO;
    NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return NO;

    // JSON 的 null 会解成 NSNull，而 NSNull 不是 property-list 类型：
    // 直接 setObject: 会抛 NSInvalidArgumentException（控制台复现即闪退）。
    // 这里递归清洗：NSNull → 删除键，非 plist 类型 → 丢弃，数组/字典同步递归。

    NSUserDefaults *u = DTDefaults();
    BOOL ok = YES;
    for (NSString *k in (NSDictionary *)obj) {
        if (![k hasPrefix:@"DT"]) continue;
        id v = DTCleanPlist(((NSDictionary *)obj)[k]);
        @try {
            if (v) [u setObject:v forKey:k];
            else   [u removeObjectForKey:k];    // null / 非法类型 = 恢复内置默认
        } @catch (NSException *e) {
            DTLog(@"config: import skip %@ (%@)", k, e.reason);
            ok = NO;
        }
    }
    DTFlush();
    return ok;
}

// 旧插件键 → 本插件键。只迁移能一一对应的，其余保持原键不动（旧插件还在时仍生效）。
// 注意：旧键都在 com.tencent.xin 域，本插件写的是 com.dt.killer 域，所以这里要显式读旧域。
void DTMigrateFromLegacyIfNeeded(void) {
    NSUserDefaults *u = DTDefaults();

    // editMoney 是旧插件的金额值（用户配置里曾出现 2847943），不是 BOOL 开关。
    // 0.2.5 曾误把它迁到 DTBalanceEnable，导致 UI 读到真值但类型错误；一次性清理
    // 非 0/1 值，保留合法开关，并且不把旧“绝对余额”误当成“余额偏移”。
    if (![u boolForKey:kDTBalanceTypeFixFlag]) {
        id rawEnable = [u objectForKey:@"DTBalanceEnable"];
        if (rawEnable) {
            if ([rawEnable isKindOfClass:[NSNumber class]]) {
                double n = [rawEnable doubleValue];
                if (n == 0.0 || n == 1.0) {
                    [u setBool:(n == 1.0) forKey:@"DTBalanceEnable"];
                } else {
                    [u removeObjectForKey:@"DTBalanceEnable"];
                    DTLog(@"config: removed invalid legacy DTBalanceEnable value (%@)", rawEnable);
                }
            } else {
                [u removeObjectForKey:@"DTBalanceEnable"];
                DTLog(@"config: removed non-boolean DTBalanceEnable value (%@)", rawEnable);
            }
        }
        [u setBool:YES forKey:kDTBalanceTypeFixFlag];
        [u synchronize];
    }

    if (DTBool(kDTMigratedFlag, NO)) return;
    NSUserDefaults *legacy = [NSUserDefaults standardUserDefaults];
    if (legacy == u) legacy = nil;   // suite 建失败退回标准域时，不重复读

    struct { const char *legacy; const char *mine; } table[] = {
        // 语音进度条
        {"MIsVoiceProgressKey",    "DTVoiceBarEnable"},
        // 语音转发
        {"mIsForwardVoice",        "DTVoiceFwdEnable"},
        // 群头像
        {"theGroupHeadImageBOOL",  "DTGroupAvatarEnable"},
        // 朋友圈尾巴
        {"editTimeLinePhoneText",  "DTMomentsTailPhone"},
        // editTimeLineComputerText 不迁移：本插件只改手机端来源，DTMomentsTail.m 里
        // 没有对应实现，迁过来会变成一个谁也不读的孤儿键。
    };
    for (size_t i = 0; i < sizeof(table)/sizeof(table[0]); i++) {
        NSString *src = @(table[i].legacy);
        NSString *dst = @(table[i].mine);
        if ([u objectForKey:dst]) continue;                 // 已有值，不覆盖
        id v = legacy ? [legacy objectForKey:src] : nil;
        if (!v) v = [u objectForKey:src];
        if (v) [u setObject:v forKey:dst];
    }
    [u setBool:YES forKey:kDTMigratedFlag];
    [u synchronize];
}
