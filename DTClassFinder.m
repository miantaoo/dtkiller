//
//  DTClassFinder.m
//

#import "DTClassFinder.h"
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <string.h>

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

NSArray<NSString *> *DTWeChatClassNames(void) {
    static NSArray *cache = nil;
    static dispatch_once_t once;
    // 注意：微信会在启动后动态注册类（WCPure 那类做法），所以缓存 3 秒后失效一次
    static NSTimeInterval cachedAt = 0;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (cache && (now - cachedAt) < 3.0) return cache;

    unsigned int c = 0;
    const char **names = objc_copyClassNamesForImage((const char *)DTWeChatImage(), &c);
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:c];
    if (names) {
        for (unsigned int i = 0; i < c; i++) {
            if (names[i]) [arr addObject:@(names[i])];
        }
        free(names);
    }
    cache = arr;
    cachedAt = now;
    return arr;
}

NSArray<NSString *> *DTClassesForSelector(const char *selName) {
    if (!selName) return @[];
    SEL sel = sel_registerName(selName);
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in DTWeChatClassNames()) {
        Class c = objc_getClass(n.UTF8String);
        if (!c) continue;
        if (class_getInstanceMethod(c, sel)) [out addObject:n];
    }
    return out;
}

NSArray<NSString *> *DTOwnerClassesForSelector(const char *selName) {
    if (!selName) return @[];
    SEL sel = sel_registerName(selName);
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in DTWeChatClassNames()) {
        Class c = objc_getClass(n.UTF8String);
        if (!c) continue;
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(c, &mc);
        BOOL own = NO;
        for (unsigned int k = 0; k < mc; k++) {
            if (method_getName(ms[k]) == sel) { own = YES; break; }
        }
        free(ms);
        if (own) [out addObject:n];
    }
    return out;
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
