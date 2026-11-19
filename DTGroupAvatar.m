//
//  DTGroupAvatar.m —— 群头像自定义（按群 id 映射到本地图片）
//
//  两种生效方式并用：
//    1) 运行时：hook 头像视图的 setUsrName: / setContact:，命中映射就直接换图
//    2) 磁盘：把图片按 md5(群id) 写进微信头像缓存目录，重启后所有界面一致
//  图片存放：微信沙盒 Documents/DTKiller/avatars/<群id>.png
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>
#import "DTHook.h"
#import "DTConfig.h"
#import "DTClassFinder.h"
#import "DTLog.h"
#import "DTModules.h"

static NSString *const kEn = @"DTGroupAvatarEnable";

static NSString *DTAvatarDir(void) {
    // 原来每次调用都 createDirectory，setter 在列表滚动时每帧都会走到 → 主线程同步 IO。
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *d = [DTLogDirectory() stringByAppendingPathComponent:@"avatars"];
        [[NSFileManager defaultManager] createDirectoryAtPath:d
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        dir = d;
    });
    return dir;
}

/// 群 id → 图片。支持 <群id>.png/.jpg/.jpeg/.webp
static UIImage *DTImageForGroup(NSString *gid) {
    if (![gid isKindOfClass:[NSString class]] || gid.length == 0) return nil;

    static NSCache<NSString *, UIImage *> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 200; });

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *e in @[@"png", @"jpg", @"jpeg", @"webp", @"PNG", @"JPG"]) {
        NSString *p = [DTAvatarDir() stringByAppendingPathComponent:
                       [NSString stringWithFormat:@"%@.%@", gid, e]];
        if (![fm fileExistsAtPath:p]) continue;
        // 键带 mtime：换了图立刻生效，同时避免每帧重新解码原图（列表滚动掉帧的主因）
        NSDate *mt = [[fm attributesOfItemAtPath:p error:NULL] fileModificationDate];
        NSString *key = [NSString stringWithFormat:@"%@|%.0f", p, mt.timeIntervalSince1970];
        UIImage *hit = [cache objectForKey:key];
        if (hit) return hit;
        UIImage *img = [UIImage imageWithContentsOfFile:p];
        if (img) { [cache setObject:img forKey:key]; return img; }
    }
    return nil;
}

static BOOL DTIsChatroom(id usrName) {
    return [usrName isKindOfClass:[NSString class]] &&
           [usrName hasSuffix:@"@chatroom"];
}

/// 从任意对象里取 userName（不同版本字段名不同）
static NSString *DTUsrNameOf(id obj) {
    if (!obj) return nil;
    if ([obj isKindOfClass:[NSString class]]) return obj;
    NSArray *sels = @[@"m_nsUsrName", @"usrName", @"getUsrName", @"m_nsUserName", @"userName"];
    for (NSString *s in sels) {
        SEL sel = NSSelectorFromString(s);
        if ([obj respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id v = [obj performSelector:sel];
#pragma clang diagnostic pop
            if ([v isKindOfClass:[NSString class]] && [v length]) return v;
        }
    }
    return nil;
}

void DTModuleGroupAvatarInstall(void) {
    if (!DTBool(kEn, NO)) { DTLog(@"groupavatar: disabled"); return; }

    int n = 0;
    NSArray *sels = @[@"setUsrName:", @"setContact:", @"setUserName:", @"setHeadImageViewUsrName:"];

    for (NSString *selStr in sels) {
        SEL sel = sel_registerName(selStr.UTF8String);
        for (NSString *cn in DTOwnerClassesForSelector(selStr.UTF8String)) {
            Class c = objc_getClass(cn.UTF8String);
            if (!c) continue;
            if (![c isSubclassOfClass:[UIView class]]) continue;

            __block Class wc = c;
            DTHookMsg(c, sel, imp_implementationWithBlock(^(id self, id arg) {
                IMP o = DTOrigFor(wc, sel);
                if (o) ((void (*)(id, SEL, id))o)(self, sel, arg);

                NSString *gid = DTUsrNameOf(arg);
                if (!DTIsChatroom(gid)) return;
                UIImage *img = DTImageForGroup(gid);
                if (!img) return;

                // 头像视图一般是 UIImageView 或含一个 IMG 子视图
                if ([self isKindOfClass:[UIImageView class]]) {
                    [(UIImageView *)self setImage:img];
                } else if ([self respondsToSelector:@selector(setImage:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [self performSelector:@selector(setImage:) withObject:img];
#pragma clang diagnostic pop
                }
            }));
            n++;
        }
    }

    DTLog(@"groupavatar: hooked %d setters, dir=%@", n, DTAvatarDir());
}

#pragma mark - 磁盘写缓存（可选，重启后全局一致）

/// md5 小写，微信缓存文件名就是 md5(usrname)
static NSString *DTMD5(NSString *s) {
    const char *c = s.UTF8String;
    unsigned char d[CC_MD5_DIGEST_LENGTH];
    CC_MD5(c, (CC_LONG)strlen(c), d);
    NSMutableString *out = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [out appendFormat:@"%02x", d[i]];
    return out;
}

/// 把自定义图铺进微信的品牌头像缓存目录（尽力而为，找不到目录就跳过）
int DTGroupAvatarFlushToCache(void) {
    if (!DTBool(kEn, NO)) return -1;     // -1 = 功能没开
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSArray *cands = @[
        [docs stringByAppendingPathComponent:@"mmsf"],
        [docs stringByAppendingPathComponent:@"MMAssets"],
    ];
    NSString *dir = nil;
    for (NSString *c in cands) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:c]) { dir = c; break; }
    }
    if (!dir) { DTLog(@"groupavatar: cache dir not found, runtime-only"); return -2; }   // -2 = 没有缓存目录

    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:DTAvatarDir() error:NULL];
    int copied = 0;
    for (NSString *f in files) {
        NSString *gid = [f stringByDeletingPathExtension];
        if (!DTIsChatroom(gid)) continue;
        NSString *src = [DTAvatarDir() stringByAppendingPathComponent:f];
        NSString *dst = [dir stringByAppendingPathComponent:DTMD5(gid)];
        // 微信缓存可能带后缀，几种都试
        for (NSString *suffix in @[@"", @".png", @".jpg"]) {
            NSString *real = [dst stringByAppendingString:suffix];
            if ([[NSFileManager defaultManager] fileExistsAtPath:real]) {
                [[NSFileManager defaultManager] removeItemAtPath:real error:NULL];
                [[NSFileManager defaultManager] copyItemAtPath:src toPath:real error:NULL];
                copied++;
                break;
            }
        }
    }
    DTLog(@"groupavatar: flushed %d avatars into %@", copied, dir);
    return copied;                        // 0 = 群里还没有头像缓存，>0 = 已写入张数
}
