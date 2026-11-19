//
//  DTLog.h —— 轻量日志
//  落在微信沙盒 Documents/DTKiller/ 下，TrollStore 注入也能写。
//  单文件上限 2MB，超了自动滚动，不会把用户存储写爆。
//

#import <Foundation/Foundation.h>
#import "DTConfig.h"

#ifdef __cplusplus
extern "C" {
#endif

/// 日志目录（微信沙盒内，可用「文件」App 或 Filza 打开）
NSString *DTLogDirectory(void);

/// 写一行日志。release 下也保留，方便用户回传。
void DTLogWrite(const char *file, int line, NSString *fmt, ...) NS_FORMAT_FUNCTION(3, 4);

/// 当前日志文件路径
NSString *DTLogCurrentPath(void);

/// 最近 N 行，用于设置页预览
NSString *DTLogTail(NSUInteger lines);

/// 清空
void DTLogClear(void);

#define DTLog(fmt, ...) DTLogWrite(__FILE__, __LINE__, (fmt), ##__VA_ARGS__)

/// 只在开启调试开关时打印
#define DTLogV(fmt, ...) do { if (DTBool(@"DTLogVerbose", NO)) \
    DTLogWrite(__FILE__, __LINE__, (fmt), ##__VA_ARGS__); } while (0)

#ifdef __cplusplus
}
#endif
