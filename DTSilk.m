//
//  DTSilk.m —— 音乐 / 视频 → 微信语音消息
//
//  链路：文件选择 → AVAssetReader 解 24k/mono/16bit PCM → SILK 编码（DTSilkCodec）
//        → 写成微信语音文件（0x02#!SILK_V3）→ 交给上传管理器
//
//  格式依据（实测）：微信语音 = 0x02 + "#!SILK_V3" + Σ(uint16LE len + frame)，无 FF FF；
//  24 kHz mono，20ms/帧，线上实测约 12.5 kbps。详见 DTSilkCodec.h。
//
//  编码器需要 Skype SILK SDK（vendor/silk），没编进来时只落 PCM，见 README。
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import "DTHook.h"
#import "DTConfig.h"
#import "DTClassFinder.h"
#import "DTLog.h"
#import "DTModules.h"
#import "DTUtil.h"
#import "DTSilkCodec.h"

static NSString *const kEn     = @"DTSilkEnable";
static NSString *const kMaxSec = @"DTSilkMaxSeconds";

#pragma mark - 音频解码（24 kHz / mono / s16le）

static NSData *DTPCMFromURL(NSURL *url, NSTimeInterval maxSec) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    NSError *err = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (!reader) { DTLog(@"silk: reader fail %@", err); return nil; }

    NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (tracks.count == 0) { DTLog(@"silk: no audio track"); return nil; }

    AVAssetReaderTrackOutput *out =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:tracks.firstObject
                                                   outputSettings:@{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVSampleRateKey: @24000,
            AVNumberOfChannelsKey: @1,
            AVLinearPCMBitDepthKey: @16,
            AVLinearPCMIsFloatKey: @NO,
            AVLinearPCMIsBigEndianKey: @NO,
            AVLinearPCMIsNonInterleaved: @NO,
        }];
    out.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:out]) { DTLog(@"silk: cannot add output"); return nil; }
    [reader addOutput:out];
    [reader startReading];

    NSMutableData *pcm = [NSMutableData data];
    const int64_t maxBytes = (int64_t)(maxSec > 0 ? maxSec : 60) * 24000 * 2;
    while (reader.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef sb = [out copyNextSampleBuffer];
        if (!sb) break;
        CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
        if (bb) {
            size_t len = CMBlockBufferGetDataLength(bb);
            uint8_t *buf = malloc(len);
            if (buf && CMBlockBufferCopyDataBytes(bb, 0, len, buf) == kCMBlockBufferNoErr) {
                [pcm appendBytes:buf length:len];
            }
            free(buf);
        }
        CFRelease(sb);
        if ((int64_t)pcm.length >= maxBytes) break;
    }
    [reader cancelReading];
    // 截到 480 的整数倍，编码器要求整帧
    NSUInteger usable = pcm.length / (480 * 2) * (480 * 2);
    DTLog(@"silk: decoded %lu bytes pcm (usable %lu)",
          (unsigned long)pcm.length, (unsigned long)usable);
    if (usable == 0) return nil;
    return [pcm subdataWithRange:NSMakeRange(0, usable)];
}

#pragma mark - 落盘 + 发送

/// 微信 iOS 语音目录：Documents/<hash>/Audio/<hash>/，这里退到 Documents/voice2 与 tmp
static NSString *DTVoiceFilePath(unsigned int localId) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSArray *cands = @[
        [docs stringByAppendingPathComponent:@"voice2"],
        [docs stringByAppendingPathComponent:@"Audio"],
        NSTemporaryDirectory(),
    ];
    for (NSString *dir in cands) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:dir]) continue;
        return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%u.aud", localId]];
    }
    return [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%u.aud", localId]];
}

/// 多路尝试把语音发出去。返回 YES 表示至少调用了一条通道。
static BOOL DTSendVoice(NSData *silk, NSUInteger seconds) {
    if (!silk.length) return NO;
    unsigned int ms = (unsigned int)(seconds * 1000);
    id mgr = DTServiceNamed("CMessageMgr");

    // 先把文件写好 —— 上传管理器是按 localId 找文件的
    unsigned int localId = (unsigned int)([NSDate date].timeIntervalSince1970);
    NSString *path = DTVoiceFilePath(localId);
    [silk writeToFile:path atomically:YES];
    DTLog(@"silk: wrote %lu bytes -> %@", (unsigned long)silk.length, path);

    // 路径 1：MMNewUploadVoiceMgr（调研里抓到的真实上传入口）
    for (NSString *cn in @[@"MMNewUploadVoiceMgr", @"MMUploadVoiceMgr"]) {
        id up = DTServiceNamed(cn.UTF8String);
        if (!up) continue;
        SEL s = NSSelectorFromString(@"insertNewRowInUploadVoice:");
        if ([up respondsToSelector:s]) {
            DTLog(@"silk: %@ responds to insertNewRowInUploadVoice:", cn);
            // 参数是内部结构，没有公开构造方式，这里只记录不硬调，避免崩
        }
    }
    // 60 秒是微信语音上限，超了对方收不到
    if (ms < 1000)  ms = 1000;
    if (ms > 60000) ms = 60000;


    // 路径 2：CMessageMgr 的发送语音（MiYou / HB 都用这条）
    if (mgr) {
        SEL s1 = NSSelectorFromString(@"PutsendVoice:tovoicedata:");
        if ([mgr respondsToSelector:s1]) {
            IMP imp = [mgr methodForSelector:s1];
            ((void (*)(id, SEL, unsigned int, id))imp)(mgr, s1, ms, silk);
            DTLog(@"silk: sent via PutsendVoice:tovoicedata: (%ums)", ms);
            return YES;
        }
        SEL s2 = NSSelectorFromString(@"SendVoice:VoiceData:");
        if ([mgr respondsToSelector:s2]) {
            IMP imp = [mgr methodForSelector:s2];
            ((void (*)(id, SEL, unsigned int, id))imp)(mgr, s2, ms, silk);
            DTLog(@"silk: sent via SendVoice:VoiceData:");
            return YES;
        }
        SEL s3 = NSSelectorFromString(@"ResendVoiceMsg:");
        if ([mgr respondsToSelector:s3]) {
            DTLog(@"silk: CMessageMgr has ResendVoiceMsg: but needs a wrap, skip");
        }
    }
    DTLog(@"silk: no send path matched");
    return NO;
}

#pragma mark - 对外入口

void DTSilkConvertFile(NSString *path, void (^done)(BOOL ok, NSString *msg)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTimeInterval maxSec = DTInt(kMaxSec, 60);
        NSData *pcm = DTPCMFromURL([NSURL fileURLWithPath:path], maxSec);
        if (!pcm) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(NO, @"解码失败（无音轨或格式不支持）"); });
            return;
        }

        // 无论如何都留一份 PCM 方便排查
        [pcm writeToFile:[DTLogDirectory() stringByAppendingPathComponent:@"last.pcm"] atomically:YES];

        if (!DTSilkAvailable()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (done) done(NO, [NSString stringWithFormat:
                    @"已解码 %lu 字节 PCM（24kHz mono）到 Documents/DTKiller/last.pcm\n"
                    @"但 SILK 编码器没编进这个 dylib。\n"
                    @"把 Skype SILK SDK 放进 vendor/silk/ 后重新编译即可启用。",
                    (unsigned long)pcm.length]);
            });
            return;
        }

        int bitrate = (int)DTInt(@"DTSilkBitrate", 25000);
        NSData *silk = DTSilkEncodePCM(pcm, bitrate);
        if (!silk) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(NO, @"SILK 编码失败，见日志"); });
            return;
        }

        NSUInteger frames = 0, bytes = 0;
        DTSilkInspect(silk, &frames, &bytes);
        // 向上取整：49 帧 = 0.98 秒，整除会算成 0 秒，微信收到就是一条 0 秒语音。
        NSUInteger sec = (frames * 480 + 23999) / 24000;
        if (sec < 1) sec = 1;
        DTLog(@"silk: encoded frames=%lu bytes=%lu sec=%lu", (unsigned long)frames, (unsigned long)bytes, (unsigned long)sec);

        // 发送必须回主线程：DTSendVoice 里走 CMessageMgr 切会话 / 写 DB / 刷 UI，
        // 这些接口不是线程安全的，后台线程调用表现为「没反应」或写库卡死。
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL ok = DTSendVoice(silk, sec);
            if (done) done(ok, ok
                ? [NSString stringWithFormat:@"已发送 %lu 秒语音", (unsigned long)sec]
                : @"编码成功但发送通道未命中，见日志");
        });
    });
}

void DTSilkPickFile(UIViewController *host) {
    if (!DTBool(kEn, YES)) return;
    UIDocumentPickerViewController *pk =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.audio"]
                                                               inMode:UIDocumentPickerModeImport];
    pk.allowsMultipleSelection = NO;

    DTDocumentPickerDelegate *del = [DTDocumentPickerDelegate new];
    del.onPick = ^(NSURL *url) {
        DTLog(@"silk: picked %@", url.path);
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"正在转码"
                                                                      message:@"解码 + SILK 编码，稍等…"
                                                               preferredStyle:UIAlertControllerStyleAlert];
            [host presentViewController:a animated:YES completion:nil];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [a dismissViewControllerAnimated:YES completion:nil]; });
        });
        DTSilkConvertFile(url.path, ^(BOOL ok, NSString *msg) {
            DTLog(@"silk: result %d %@", ok, msg);
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"转语音"
                                                                      message:msg
                                                               preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [host presentViewController:a animated:YES completion:nil];
        });
    };
    pk.delegate = del;
    objc_setAssociatedObject(pk, "dt_del", del, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [host presentViewController:pk animated:YES completion:nil];
}

void DTModuleSilkInstall(void) {
    if (!DTBool(kEn, YES)) { DTLog(@"silk: disabled"); return; }
    DTLog(@"silk: installed, sdk=%d max=%ds", (int)DTSilkAvailable(), (int)DTInt(kMaxSec, 60));
    if (!DTSilkAvailable()) DTLog(@"silk: 要启用音乐转语音，请按 README 集成 vendor/silk");
}
