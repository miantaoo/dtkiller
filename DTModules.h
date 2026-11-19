//
//  DTModules.h —— 各功能模块的统一入口
//  每个 Install 内部自行判断配置开关，关着就直接 return，不产生任何 hook。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

void DTModuleGuardInstall(void);        // 反检测 + 上报屏蔽
void DTModuleVoiceBarInstall(void);     // 语音进度条（拖动 / 时间 / 暂停 / 连播）
void DTModuleVoiceFwdInstall(void);     // 语音转发（单条 / 批量 / 对方可播放）
void DTModuleSilkInstall(void);         // SILK 编解码（音乐视频转语音消息）
void DTModuleBalanceInstall(void);      // 钱包零钱数字
void DTModuleGroupAvatarInstall(void);  // 群头像自定义
void DTModuleMomentsTailInstall(void);  // 朋友圈来源尾巴
void DTModuleSwipeQuoteInstall(void);   // 左滑引用
void DTModuleRevokeInstall(void);       // 防撤回
void DTModuleCallKitInstall(void);      // 来电转系统 CallKit

// —— 需求确认单里的 18 项 ——
void DTModuleRadiusInstall(void);       // P0-1  头像圆角
void DTModuleAutoLoginInstall(void);    // P0-2  自动确认登录
void DTModuleStepInstall(void);         // P0-3  虚拟步数
void DTModuleAdBlockInstall(void);      // P0-4~7 广告净化 / 视频号 / Safari / 自动下载
void DTModuleBubblePureInstall(void);   // P0-8~9 气泡美化 / 界面净化
void DTModuleBatch3Install(void);       // P0-10~11 / P1-12~13
void DTModuleBatch4Install(void);

/// 红包/转账统一闸门：多个模块共用一条 selector，只能挂一个 hook。
/// 处理体签名 (self, _cmd, response, request)，不要自己转发原实现。
typedef void (*DTHBExtraFn)(id self, SEL _cmd, id response, id request);
void DTSetHongbaoExtraHandler(DTHBExtraFn fn);
int  DTHBHookOnce(void);       // P1-14~18

/// 记账本按月汇总（设置页展示用）
NSDictionary<NSString *, NSNumber *> *DTLedgerMonthlySummary(void);

void DTModuleSettingsInstall(void);     // 设置页入口

/// SILK 模块的对外入口（设置页调用）
void DTSilkConvertFile(NSString *path, void (^done)(BOOL ok, NSString *msg));
void DTSilkPickFile(UIViewController *host);

/// 群头像刷缓存（设置页「应用并重启生效」按钮调用）
int  DTGroupAvatarFlushToCache(void);

#ifdef __cplusplus
}
#endif
