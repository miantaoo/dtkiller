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

    // 滚动
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
    if (attrs && [attrs fileSize] > kMaxSize) {
        NSString *bak = [DTLogDirectory() stringByAppendingPathComponent:@"app.1.log"];
        [fm removeItemAtPath:bak error:NULL];
        [fm moveItemAtPath:path toPath:bak error:NULL];
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
    NSString *path = DTLogCurrentPath();
    NSString *all = [NSString stringWithContentsOfFile:path
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    if (!all) return @"(暂无日志)";
    NSArray *arr = [all componentsSeparatedByString:@"\n"];
    if (arr.count <= lines) return all;
    NSArray *tail = [arr subarrayWithRange:NSMakeRange(arr.count - lines, lines)];
    return [tail componentsJoinedByString:@"\n"];
}

void DTLogClear(void) {
    pthread_mutex_lock(&gLogLock);
    [[NSFileManager defaultManager] removeItemAtPath:DTLogCurrentPath() error:NULL];
    pthread_mutex_unlock(&gLogLock);
}
