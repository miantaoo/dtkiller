//
//  DTDiag.m
//

#import "DTDiag.h"
#import "DTConfig.h"
#import "DTLog.h"
#import "DTBuild.h"

static NSString *DTDiagTimestamp(void) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyyMMdd-HHmmss";
    return [f stringFromDate:[NSDate date]];
}

NSString *DTDiagText(void) {
    NSMutableString *s = [NSMutableString string];

    UIDevice *dev = [UIDevice currentDevice];
    NSBundle *main = [NSBundle mainBundle];

    [s appendString:@"===== DTKiller 诊断 =====\n"];
    [s appendFormat:@"生成时间   : %@\n", [NSDate date]];
    [s appendFormat:@"dylib 版本 : %@\n", DT_DYLIB_VERSION];
    [s appendFormat:@"设备       : %@ (%@)\n", dev.model, dev.name ?: @"iPhone"];
    [s appendFormat:@"系统       : %@ %@\n", dev.systemName, dev.systemVersion];
    [s appendFormat:@"微信版本   : %@ (%@)\n",
        [main objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
        [main objectForInfoDictionaryKey:@"CFBundleVersion"]];
    [s appendFormat:@"Bundle     : %@\n", [main bundleIdentifier]];

    // 沙盒与日志路径 —— 反馈问题时一眼能看出装在哪个位置
    [s appendFormat:@"Documents  : %@\n", NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject];
    [s appendFormat:@"日志文件   : %@\n", DTLogCurrentPath()];

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:DTLogCurrentPath() error:NULL];
    if (attrs) {
        [s appendFormat:@"日志大小   : %llu 字节\n", (unsigned long long)[attrs fileSize]];
    }

    [s appendString:@"\n===== 配置（com.dt.killer）=====\n"];
    [s appendString:DTExportJSON() ?: @"{}"];
    [s appendString:@"\n\n===== 日志（最近 800 行）=====\n"];
    [s appendString:DTLogTail(800) ?: @"(空)"];
    [s appendString:@"\n===== END =====\n"];
    return s;
}

void DTDiagShare(UIViewController *host) {
    if (!host) return;

    NSString *txt  = DTDiagText();
    NSString *name = [NSString stringWithFormat:@"DTKiller-diag-%@.txt", DTDiagTimestamp()];
    NSString *path = [DTLogDirectory() stringByAppendingPathComponent:name];
    NSError *err = nil;
    [txt writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (err) {
        DTLog(@"diag: write failed %@", err.localizedDescription);
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"导出失败"
                                                                  message:err.localizedDescription
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [host presentViewController:a animated:YES completion:nil];
        return;
    }
    DTLog(@"diag: exported to %@", path);

    UIActivityViewController *vc = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    // iPad 上不设 popover 会直接崩
    if (vc.popoverPresentationController) {
        vc.popoverPresentationController.sourceView = host.view;
        vc.popoverPresentationController.sourceRect =
            CGRectMake(host.view.bounds.size.width / 2, host.view.bounds.size.height / 2, 1, 1);
        vc.popoverPresentationController.permittedArrowDirections = 0;
    }
    [host presentViewController:vc animated:YES completion:nil];
}

void DTDiagCopyTail(NSUInteger lines) {
    if (lines == 0) lines = 200;
    NSString *tail = DTLogTail(lines) ?: @"(暂无日志)";
    [UIPasteboard generalPasteboard].string = tail;
    DTLog(@"diag: copied %lu lines to pasteboard", (unsigned long)lines);
}
