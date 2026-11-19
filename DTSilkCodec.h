//
//  DTSilkCodec.h —— 微信 SILK 编解码封装
//
//  格式（实测结论）：0x02 + "#!SILK_V3" + Σ(uint16LE 帧长 + 帧载荷)，**没有** FF FF 结尾。
//  参数：24 kHz / 单声道 / 16bit / 20ms 一帧(480 样本) / 码率 12000~25000 / complexity 2
//
//  依赖 Skype SILK SDK 1.0.9（BSD 式许可，无专利授权条款）。
//  把 SDK 的 src/ interface/ 放进 vendor/silk/，Makefile 里加：
//      DTKiller_CFLAGS += -Ivendor/silk/interface -Ivendor/silk/src -DNO_ASM
//      DTKiller_FILES  += $(wildcard vendor/silk/src/*.c)
//  没有 SDK 时本文件仍可编译，只是 DTSilkAvailable() 返回 NO。
//

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// SDK 是否可用（编译期决定）
BOOL DTSilkAvailable(void);

/// PCM(s16le, 24000Hz, mono) → 微信 SILK（含 0x02 + #!SILK_V3 头）
/// bitrate 建议 12000~25000；复杂度和包长按微信默认走。
NSData *DTSilkEncodePCM(NSData *pcm, int bitrate);

/// 微信 SILK → PCM(s16le, 24000Hz, mono)
NSData *DTSilkDecode(NSData *silk);

/// 从微信 SILK 里读帧信息（没有 SDK 也能用）：总样本数 = frames * 480
BOOL DTSilkInspect(NSData *silk, NSUInteger *outFrames, NSUInteger *outBytes);

/// 给裸 SILK 帧流补微信头 / 去掉微信头，用于兼容各式文件
NSData *DTSilkWrapTencent(NSData *rawFrames);
NSData *DTSilkStripHeader(NSData *anySilk);

#ifdef __cplusplus
}
#endif
