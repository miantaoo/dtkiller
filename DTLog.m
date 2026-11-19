//
//  DTLog.m
//

#import "DTLog.h"
#import "DTConfig.h"
#import <pthread.h>

static NSString *gDir  = nil;
static NSString *gPath = nil;
static pthread_mutex_t gLogLock = PTHREAD_MUTEX_INITIALIZER;
static NSDateFormatter *gFmt = nil;
static const unsigned long long kMaxSize = 2 * 1024 * 1024;

NSString *DTLogDirectory(void) {
    if (gDir) return gDir;
    // 微信沙盒 Documents，TrollStore 注入下也一定可写
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs) docs = NSTemporaryDirectory();
    gDir = [docs stringByAppendingPathComponent:@"DTKiller"];
    [[NSFileManager defaultManager] createDirectoryAtPath:gDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return gDir;
}

NSString *DTLogCurrentPath(void) {
    if (gPath) return gPath;
    gPath = [DTLogDirectory() stringByAppendingPathComponent:@"app.log"];
    return gPath;
}

void DTLogWrite(const char *file, int line, NSString *fmt, ...) {
    if (!fmt) return;

    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    pthread_mutex_lock(&gLogLock);
    if (!gFmt) {
        gFmt = [NSDateFormatter new];
        gFmt.dateFormat = @"MM-dd HH:mm:ss.SSS";
    }
    const char *base = file ? strrchr(file, '/') : NULL;
    base = base ? base + 1 : (file ? file : "?");

    NSString *line0 = [NSString stringWithFormat:@"[%@][%@] %s:%d %@\n",
                       [gFmt stringFromDate:[NSDate date]],
                       [NSThread isMainThread] ? @"M" : @"B",
                       base, line, msg];

    NSString *path = DTLogCurrentPath();
    NSFileManager *fm = [NSFileManager defaultManager];

    // 滚动：保留三代（app.log / app.1.log / app.2.log / app.3.log）。
    // 原来只留一代，崩溃前那段日志正好在被删掉的 app.1.log 里，导出永远看不到现场。
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
    if (attrs && [attrs fileSize] > kMaxSize) {
        NSString *dir = DTLogDirectory();
        NSString *l1 = [dir stringByAppendingPathComponent:@"app.1.log"];
        NSString *l2 = [dir stringByAppendingPathComponent:@"app.2.log"];
        NSString *l3 = [dir stringByAppendingPathComponent:@"app.3.log"];
        [fm removeItemAtPath:l3 error:NULL];
        [fm moveItemAtPath:l2 toPath:l3 error:NULL];
        [fm moveItemAtPath:l1 toPath:l2 error:NULL];
        [fm moveItemAtPath:path toPath:l1 error:NULL];
    }

    if (![fm fileExistsAtPath:path]) {
        [line0 writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } else {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh) {
            @try {
                [fh seekToEndOfFile];
                [fh writeData:[line0 dataUsingEncoding:NSUTF8StringEncoding]];
            } @catch (NSException *e) {
                // 写失败不抛给调用方
            } @finally {
                [fh closeFile];
            }
        }
    }

    // 同时进系统日志，方便 idevicesyslog
    NSLog(@"[DT] %@", msg);
    pthread_mutex_unlock(&gLogLock);
}

NSString *DTLogTail(NSUInteger lines) {
    // 3 → 0 拼接：老的在前，新的在后。只看 app.log 会漏掉崩溃前那一代。
    NSMutableString *all = [NSMutableString string];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (int i = 3; i >= 0; i--) {
        NSString *p = i == 0 ? DTLogCurrentPath()
                             : [DTLogDirectory() stringByAppendingPathComponent:
                                [NSString stringWithFormat:@"app.%d.log", i]];
        if (![fm fileExistsAtPath:p]) continue;
        NSString *s0 = [NSString stringWithContentsOfFile:p
                                                 encoding:NSUTF8StringEncoding
                                                    error:NULL];
        if (s0.length) [all appendString:s0];
    }
    if (all.length == 0) return @"(暂无日志)";
    NSArray *arr = [all componentsSeparatedByString:@"\n"];
    if (arr.count <= lines) return all;
    NSArray *tail = [arr subarrayWithRange:NSMakeRange(arr.count - lines, lines)];
    return [tail componentsJoinedByString:@"\n"];
}

void DTLogClear(void) {
    pthread_mutex_lock(&gLogLock);
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:DTLogCurrentPath() error:NULL];
    for (int i = 1; i <= 3; i++) {
        NSString *p = [DTLogDirectory() stringByAppendingPathComponent:
                       [NSString stringWithFormat:@"app.%d.log", i]];
        [fm removeItemAtPath:p error:NULL];
    }
    pthread_mutex_unlock(&gLogLock);
}
