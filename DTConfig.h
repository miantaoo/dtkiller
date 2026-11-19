//
//  DTConfig.h —— 配置读写 + 导入导出
//  配置落在微信自己的偏好域 com.tencent.xin，和现有插件同域，方便直接迁移。
//

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

BOOL   DTBool(NSString *key, BOOL def);
void   DTSetBool(NSString *key, BOOL v);
NSInteger DTInt(NSString *key, NSInteger def);
void   DTSetInt(NSString *key, NSInteger v);
double DTDouble(NSString *key, double def);
void   DTSetDouble(NSString *key, double v);
NSString *DTStr(NSString *key, NSString *def);
void   DTSetStr(NSString *key, NSString *v);
id     DTObj(NSString *key);
void   DTSetObj(NSString *key, id v);

void   DTFlush(void);

/// 导出全部 DT* 前缀配置为 JSON 字符串
NSString *DTExportJSON(void);
/// 从 JSON 导入（只覆盖 JSON 里出现的键）
BOOL DTImportJSON(NSString *json);

/// 从旧插件配置做一次性迁移（HB/Misaka/MiYou/WCPure 的键 → 本插件键）
void DTMigrateFromLegacyIfNeeded(void);

#ifdef __cplusplus
}
#endif
