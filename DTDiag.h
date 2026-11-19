//
//  DTDiag.h —— 一键诊断：把日志、配置、设备信息打成一个 txt 分享出去
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 完整诊断文本（设备 / 微信版本 / dylib 版本 / 全部配置 / 日志尾部）
NSString *DTDiagText(void);

/// 生成诊断 txt 并弹系统分享面板（微信、文件、邮件都能发）
void DTDiagShare(UIViewController *host);

/// 只把最近 N 行日志复制到剪贴板（最省事的反馈方式）
void DTDiagCopyTail(NSUInteger lines);

#ifdef __cplusplus
}
#endif
