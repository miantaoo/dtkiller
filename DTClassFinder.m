//
//  DTClassFinder.m
//
//  按 selector / 名字片段反查微信里承载它的类。
//  性能要点：微信有 2 万多个类，一次全量枚举要 0.2~1 秒，
//  所以类名表只枚举一次并缓存，每个 selector 的查询结果也缓存。
//

#import "DTClassFinder.h"
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <pthread.h>
#import <string.h>

static NSArray<NSString *> *gNames = nil;
static NSMutableDictionary<NSString *, NSArray<NSString *> *> *gBySel = nil;
static NSMutableDictionary<NSString *, NSArray<NSString *> *> *gOwner = nil;
static pthread_mutex_t gCFLock = PTHREAD_MUTEX_INITIALIZER;

static void *DTWeChatImage(void) {
    uint32_t cnt = _dyld_image_count();
    for (uint32_t i = 0; i < cnt; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm) continue;
        const char *base = strrchr(nm, '/');
        base = base ? base + 1 : nm;
        if (strncmp(base, "WeChat", 6) == 0) return (void *)_dyld_get_image_header(i);
    }
    return (void *)_dyld_get_image_header(0);
}

void DTInvalidateClassCache(void) {
    pthread_mutex_lock(&gCFLock);
    gNames = nil;
    gBySel = nil;
    gOwner = nil;
    pthread_mutex_unlock(&gCFLock);
}

NSArray<NSString *> *DTWeChatClassNames(void) {
    pthread_mutex_lock(&gCFLock);
    NSArray *cached = gNames;
    pthread_mutex_unlock(&gCFLock);
    if (cached) return cached;

    // —— 枚举放在锁外：这一步可能耗时几百毫秒，不能持锁 ——
    unsigned int c = 0;
    const char **names = objc_copyClassNamesForImage((const char *)DTWeChatImage(), &c);
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:(c ? c : 64)];
    if (names) {
        for (unsigned int i = 0; i < c; i++) {
            if (names[i]) [arr addObject:@(names[i])];
        }
        free(names);
    }

    // 兜底：镜像定位失败（比如注入到的镜像名不带 WeChat）时退回全量枚举
    if (arr.count == 0) {
        int total = objc_getClassList(NULL, 0);
        if (total > 0) {
            Class *cls = (Class *)malloc(sizeof(Class) * (size_t)total);
            if (cls) {
                total = objc_getClassList(cls, total);
                for (int i = 0; i < total; i++) {
                    const char *nm = class_getName(cls[i]);
                    if (nm) [arr addObject:@(nm)];
                }
                free(cls);
            }
        }
    }

    NSArray *res = [arr copy];
    pthread_mutex_lock(&gCFLock);
    if (!gNames) {
        gNames = res;
        gBySel = [NSMutableDictionary dictionary];
        gOwner = [NSMutableDictionary dictionary];
    }
    NSArray *r = gNames;
    pthread_mutex_unlock(&gCFLock);
    return r;
}

NSArray<NSString *> *DTClassesForSelector(const char *selName) {
    if (!selName) return @[];
    NSString *key = @(selName);
    SEL sel = sel_registerName(selName);

    pthread_mutex_lock(&gCFLock);
    NSArray *hit = gBySel[key];
    pthread_mutex_unlock(&gCFLock);
    if (hit) return hit;

    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in DTWeChatClassNames()) {
        Class c = objc_getClass(n.UTF8String);
        if (c && class_getInstanceMethod(c, sel)) [out addObject:n];
    }
    NSArray *res = [out copy];

    pthread_mutex_lock(&gCFLock);
    if (!gBySel) gBySel = [NSMutableDictionary dictionary];
    gBySel[key] = res;
    pthread_mutex_unlock(&gCFLock);
    return res;
}

NSArray<NSString *> *DTOwnerClassesForSelector(const char *selName) {
    if (!selName) return @[];
    NSString *key = @(selName);
    SEL sel = sel_registerName(selName);

    pthread_mutex_lock(&gCFLock);
    NSArray *hit = gOwner[key];
    pthread_mutex_unlock(&gCFLock);
    if (hit) return hit;

    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in DTWeChatClassNames()) {
        Class c = objc_getClass(n.UTF8String);
        if (!c) continue;
        // 便宜的预过滤：没这个方法（含继承来的）就不用 malloc 方法表了
        if (!class_getInstanceMethod(c, sel)) continue;

        unsigned int mc = 0;
        Method *ms = class_copyMethodList(c, &mc);
        BOOL own = NO;
        for (unsigned int k = 0; k < mc; k++) {
            if (method_getName(ms[k]) == sel) { own = YES; break; }
        }
        if (ms) free(ms);
        if (own) [out addObject:n];
    }
    NSArray *res = [out copy];

    pthread_mutex_lock(&gCFLock);
    if (!gOwner) gOwner = [NSMutableDictionary dictionary];
    gOwner[key] = res;
    pthread_mutex_unlock(&gCFLock);
    return res;
}

Class DTFirstClassForSelector(const char *selName) {
    for (NSString *n in DTClassesForSelector(selName)) {
        Class c = objc_getClass(n.UTF8String);
        if (c) return c;
    }
    return Nil;
}

NSArray<NSString *> *DTClassesMatching(const char *fragment) {
    if (!fragment) return @[];
    NSString *f = @(fragment);
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in DTWeChatClassNames()) {
        if ([n rangeOfString:f].location != NSNotFound) [out addObject:n];
    }
    [out sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        if (a.length != b.length) return a.length < b.length ? NSOrderedAscending : NSOrderedDescending;
        return [a compare:b];
    }];
    return out;
}

Class DTCls(const char *name) {
    return name ? objc_getClass(name) : Nil;
}
