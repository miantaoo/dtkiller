//
//  DTHook.m
//

#import "DTHook.h"
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <pthread.h>

static NSMutableDictionary<NSString *, id> *gOrig      = nil;
static NSMutableDictionary<NSString *, id> *gOrigClass = nil;  // 类方法单独一张表
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;

static inline NSString *DTKey(Class c, SEL s) {
    return [NSString stringWithFormat:@"%s>%s", class_getName(c), sel_getName(s)];
}

static void DTEnsureTables(void) {
    if (!gOrig) {
        gOrig = [NSMutableDictionary new];
        gOrigClass = [NSMutableDictionary new];
    }
}

// 把 IMP 用 NSValue 存（64 位下 IMP 是小整数，直接装箱没有坑，但仍走指针语义）
static inline NSValue *DTBox(IMP i)  { return [NSValue valueWithPointer:(const void *)i]; }
static inline IMP     DTUnbox(id v)  { return v ? (IMP)[v pointerValue] : NULL; }

IMP DTHookMsg(Class cls, SEL sel, IMP newImp) {
    if (!cls || !sel || !newImp) return NULL;

    Method m = class_getInstanceMethod(cls, sel);
    // 没有这个方法就退出。以前这里硬加一个 "@@:"（返回 id）进去，
    // 结果给几千个类种上了类型错位的 isAd —— respondsToSelector 从 false 变 true，
    // 谁用 KVC / NSInvocation 读一下就拿到野指针。宁可不 hook。
    if (!m) return NULL;

    IMP old = method_getImplementation(m);
    if (old == newImp) return old;

    const char *types = method_getTypeEncoding(m);
    // addMethod 成功 = 原来没有自己的实现（继承来的），此时 old 是父类的
    // addMethod 失败 = 本类已有实现，直接换
    if (!class_addMethod(cls, sel, newImp, types)) {
        method_setImplementation(m, newImp);
    }

    pthread_mutex_lock(&gLock);
    DTEnsureTables();
    // 只记第一份原实现。同一条 selector 被两个模块 hook 时，第二个 wrapper
    // 会变成第一个 wrapper 的 orig，两边互相调 → 栈溢出。合并 hook 仍是首选，
    // 这一行只是兜底，保证最坏情况下不炸栈。
    NSString *k = DTKey(cls, sel);
    if (!gOrig[k]) gOrig[k] = DTBox(old);
    pthread_mutex_unlock(&gLock);
    return old;
}

IMP DTHookClsMsg(Class cls, SEL sel, IMP newImp) {
    if (!cls || !sel || !newImp) return NULL;
    Class meta = object_getClass(cls);
    if (!meta) return NULL;

    Method m = class_getClassMethod(cls, sel);
    if (!m) return NULL;

    IMP old = method_getImplementation(m);
    if (old == newImp) return old;

    const char *types = method_getTypeEncoding(m);
    if (!class_addMethod(meta, sel, newImp, types)) {
        method_setImplementation(m, newImp);
    }

    pthread_mutex_lock(&gLock);
    DTEnsureTables();
    NSString *k2 = DTKey(cls, sel);
    if (!gOrigClass[k2]) gOrigClass[k2] = DTBox(old);
    pthread_mutex_unlock(&gLock);
    return old;
}

IMP DTOrigFor(Class cls, SEL sel) {
    if (!cls || !sel) return NULL;
    pthread_mutex_lock(&gLock);
    IMP r = NULL;
    // 沿父类链找：微信大量用 KVO / 动态子类，object_getClass(self) 是
    // NSKVONotifying_XXX，精确查表查不到，wrapper 就会直接 return ——
    // 表现是设置页白屏、点了没反应、文案空白。
    for (Class c = cls; c && !r; c = class_getSuperclass(c)) {
        id v = gOrig ? gOrig[DTKey(c, sel)] : nil;
        if (v) r = DTUnbox(v);
    }
    pthread_mutex_unlock(&gLock);
    return r;
}

BOOL DTHookNamed(const char *clsName, const char *selName, IMP newImp, IMP *outOrig) {
    if (!selName || !newImp) return NO;
    SEL sel = sel_registerName(selName);

    if (!clsName) {
        int n = DTHookSelectorInImage("WeChat", selName, newImp);
        return n > 0;
    }

    Class cls = objc_getClass(clsName);
    if (!cls) return NO;

    IMP old = DTHookMsg(cls, sel, newImp);
    if (outOrig) *outOrig = old;
    return old != NULL;
}

int DTHookSelectorInImage(const char *imageName, const char *selName, IMP newImp) {
    if (!selName || !newImp) return 0;

    // 镜像匹配：不严格相等，取名字里包含 imageName 的（WeChat 主二进制的名字是 WeChat）
    void *target = NULL;
    uint32_t cnt = _dyld_image_count();
    for (uint32_t i = 0; i < cnt; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm) continue;
        if (imageName && !strstr(nm, imageName)) continue;
        if (imageName == NULL) { target = (void *)_dyld_get_image_header(i); break; }
        target = (void *)_dyld_get_image_header(i);
        break;
    }
    if (!target) target = (void *)_dyld_get_image_header(0); // 兜底：主二进制

    unsigned int c = 0;
    const char **names = objc_copyClassNamesForImage((const char *)target, &c);
    if (!names) return 0;

    SEL sel = sel_registerName(selName);
    int hit = 0;
    for (unsigned int i = 0; i < c; i++) {
        Class cls = objc_getClass(names[i]);
        if (!cls) continue;
        if (!class_getInstanceMethod(cls, sel)) continue;
        // 只 hook 自己声明了实现的类（避免把父类的实现重复挂一遍）
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(cls, &mc);
        BOOL own = NO;
        for (unsigned int k = 0; k < mc; k++) {
            if (method_getName(ms[k]) == sel) { own = YES; break; }
        }
        free(ms);
        if (!own) continue;
        IMP old = DTHookMsg(cls, sel, newImp);
        if (old) hit++;
    }
    free(names);
    return hit;
}

id DTService(Class svcCls) {
    Class center = objc_getClass("MMServiceCenter");
    if (!center || !svcCls) return nil;
    id inst = nil;
    if ([center respondsToSelector:@selector(defaultCenter)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        inst = [center performSelector:@selector(defaultCenter)];
    }
    if (!inst || ![inst respondsToSelector:@selector(getService:)]) return nil;
    // getService: 的参数是一个 Class，用 IMP 直接调避免 ARC 下 objc_msgSend 的类型问题
    SEL s = @selector(getService:);
    Method m = class_getInstanceMethod(object_getClass(inst), s);
    if (!m) m = class_getInstanceMethod([inst class], s);
    if (!m) return nil;
    id (*fn)(id, SEL, Class) = (void *)method_getImplementation(m);
    return fn(inst, s, svcCls);
}

id DTServiceNamed(const char *clsName) {
    if (!clsName) return nil;
    Class c = objc_getClass(clsName);
    return c ? DTService(c) : nil;
}

BOOL DTClassHasSel(Class cls, const char *selName) {
    if (!cls || !selName) return NO;
    return class_getInstanceMethod(cls, sel_registerName(selName)) != NULL;
}
