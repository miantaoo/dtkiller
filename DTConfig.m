//
//  DTConfig.m
//

#import "DTConfig.h"

static NSString *const kDTMigratedFlag = @"DTMigratedV1";

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

BOOL DTImportJSON(NSString *json) {
    if (!json.length) return NO;
    NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return NO;

    for (NSString *k in (NSDictionary *)obj) {
        if (![k hasPrefix:@"DT"]) continue;
        [DTDefaults() setObject:((NSDictionary *)obj)[k] forKey:k];
    }
    DTFlush();
    return YES;
}

// 旧插件键 → 本插件键。只迁移能一一对应的，其余保持原键不动（旧插件还在时仍生效）。
// 注意：旧键都在 com.tencent.xin 域，本插件写的是 com.dt.killer 域，所以这里要显式读旧域。
void DTMigrateFromLegacyIfNeeded(void) {
    if (DTBool(kDTMigratedFlag, NO)) return;
    NSUserDefaults *u = DTDefaults();
    NSUserDefaults *legacy = [NSUserDefaults standardUserDefaults];
    if (legacy == u) legacy = nil;   // suite 建失败退回标准域时，不重复读

    struct { const char *legacy; const char *mine; } table[] = {
        // 语音进度条
        {"MIsVoiceProgressKey",    "DTVoiceBarEnable"},
        // 语音转发
        {"mIsForwardVoice",        "DTVoiceFwdEnable"},
        // 改余额
        {"editMoney",              "DTBalanceEnable"},
        // 群头像
        {"theGroupHeadImageBOOL",  "DTGroupAvatarEnable"},
        // 朋友圈尾巴
        {"editTimeLinePhoneText",  "DTMomentsTailPhone"},
        {"editTimeLineComputerText","DTMomentsTailPC"},
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
