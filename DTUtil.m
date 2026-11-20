//
//  DTUtil.m
//

#import "DTUtil.h"
#import <objc/runtime.h>

@implementation DTGestureProxy {
    void (^_handler)(UIGestureRecognizer *);
}

- (instancetype)initWithHandler:(void (^)(UIGestureRecognizer *))handler {
    if ((self = [super init])) _handler = [handler copy];
    return self;
}

- (void)handle:(UIGestureRecognizer *)g {
    if (_handler) _handler(g);
}

@end

@implementation DTDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (self.onPick && urls.count) self.onPick(urls.firstObject);
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    // 无操作
}

@end

// block 返回 YES = 整棵树停止（原来只是跳过当前子树，外层 for 还会继续，
// 于是 DTFindView 实际返回的是 DFS 里最后一个匹配 —— 净化项拿到副标题就匹配不上了）。
static BOOL DTWalkViews(UIView *v, BOOL (^block)(UIView *v)) {
    if (!v) return NO;
    if (block(v)) return YES;
    for (UIView *sub in v.subviews) {
        if (DTWalkViews(sub, block)) return YES;
    }
    return NO;
}

void DTEnumerateViews(UIView *root, BOOL (^block)(UIView *v)) {
    if (!root || !block) return;
    DTWalkViews(root, block);
}

UIView *DTFindView(UIView *root, BOOL (^pred)(UIView *v)) {
    if (!root || !pred) return nil;
    __block UIView *found = nil;
    DTWalkViews(root, ^BOOL(UIView *v) {
        if (pred(v)) { found = v; return YES; }
        return NO;
    });
    return found;
}

UIViewController *DTViewControllerOf(UIView *view) {
    UIResponder *r = (UIResponder *)view;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
        r = r.nextResponder;
    }
    return nil;
}

id DTGetIvar(id obj, const char *name) {
    if (!obj || !name) return nil;
    Class c = object_getClass(obj);
    while (c) {
        Ivar v = class_getInstanceVariable(c, name);
        if (v) {
            const char *t = ivar_getTypeEncoding(v);
            if (!t || !t[0]) return nil;
            char *p = (char *)((__bridge void *)obj) + ivar_getOffset(v);
            switch (t[0]) {
                case '@':
                case '#':
                    return object_getIvar(obj, v);
                case 'c': return @(*(char *)p);
                case 'B': return @(*(unsigned char *)p != 0);
                case 's': return @(*(short *)p);
                case 'S': return @(*(unsigned short *)p);
                case 'i': return @(*(int *)p);
                case 'I': return @(*(unsigned int *)p);
                case 'l': return @(*(long *)p);
                case 'L': return @(*(unsigned long *)p);
                case 'q': return @(*(long long *)p);
                case 'Q': return @(*(unsigned long long *)p);
                case 'f': return @(*(float *)p);
                case 'd': return @(*(double *)p);
                default:  return nil;
            }
        }
        c = class_getSuperclass(c);
    }
    return nil;
}

BOOL DTSetIvar(id obj, const char *name, id value) {
    if (!obj || !name) return NO;
    Class c = object_getClass(obj);
    while (c) {
        Ivar v = class_getInstanceVariable(c, name);
        if (v) {
            const char *t = ivar_getTypeEncoding(v);
            if (!t || !t[0]) return NO;
            if (t[0] == '@' || t[0] == '#') {
                object_setIvar(obj, v, value);
                return YES;
            }
            NSNumber *n = [value isKindOfClass:[NSNumber class]] ? (NSNumber *)value : nil;
            if (!n) return NO;
            char *p = (char *)((__bridge void *)obj) + ivar_getOffset(v);
            switch (t[0]) {
                case 'c': *(char *)p = (char)n.charValue; return YES;
                case 'B': *(unsigned char *)p = n.boolValue ? 1 : 0; return YES;
                case 's': *(short *)p = (short)n.shortValue; return YES;
                case 'S': *(unsigned short *)p = (unsigned short)n.unsignedShortValue; return YES;
                case 'i': *(int *)p = (int)n.intValue; return YES;
                case 'I': *(unsigned int *)p = (unsigned int)n.unsignedIntValue; return YES;
                case 'l': *(long *)p = (long)n.longValue; return YES;
                case 'L': *(unsigned long *)p = (unsigned long)n.unsignedLongValue; return YES;
                case 'q': *(long long *)p = (long long)n.longLongValue; return YES;
                case 'Q': *(unsigned long long *)p = (unsigned long long)n.unsignedLongLongValue; return YES;
                case 'f': *(float *)p = n.floatValue; return YES;
                case 'd': *(double *)p = n.doubleValue; return YES;
                default:  return NO;
            }
        }
        c = class_getSuperclass(c);
    }
    return NO;
}

id DTCallGetter(id obj, NSArray<NSString *> *names) {
    if (!obj) return nil;
    for (NSString *n in names) {
        SEL s = NSSelectorFromString(n);
        Method m = class_getInstanceMethod(object_getClass(obj), s);
        if (!m) continue;
        // 只接受「返回对象」的方法。以前这里用 performSelector:，而 CMessageWrap 的
        // m_uiMessageType / m_uiVoiceTime 是 unsigned int —— ARC 会把 34 这个整数当对象
        // retain 一次，第一次长按消息就 EXC_BAD_ACCESS。
        char *rt = method_copyReturnType(m);
        BOOL isObj = (rt && rt[0] == '@');
        free(rt);
        if (!isObj) continue;
        IMP imp = method_getImplementation(m);
        if (!imp) continue;
        id v = ((id (*)(id, SEL))imp)(obj, s);
        if (v) return v;
    }
    return nil;
}

BOOL DTIntValue(id obj, NSArray<NSString *> *names, NSInteger *out) {
    if (!obj || !out) return NO;
    for (NSString *n in names) {
        SEL s = NSSelectorFromString(n);
        Method m = class_getInstanceMethod(object_getClass(obj), s);
        if (!m) continue;
        char *rt = method_copyReturnType(m);
        char r = rt ? rt[0] : 0;
        free(rt);
        IMP imp = method_getImplementation(m);
        if (!imp || !r) continue;
        switch (r) {
            case 'c': *out = ((char (*)(id, SEL))imp)(obj, s);            return YES;
            case 'C': case 'B': *out = ((unsigned char (*)(id, SEL))imp)(obj, s); return YES;
            case 's': *out = ((short (*)(id, SEL))imp)(obj, s);           return YES;
            case 'S': *out = ((unsigned short (*)(id, SEL))imp)(obj, s);  return YES;
            case 'i': *out = ((int (*)(id, SEL))imp)(obj, s);             return YES;
            case 'I': *out = (NSInteger)((unsigned int (*)(id, SEL))imp)(obj, s); return YES;
            case 'q': *out = (NSInteger)((long long (*)(id, SEL))imp)(obj, s);    return YES;
            case 'Q': *out = (NSInteger)((unsigned long long (*)(id, SEL))imp)(obj, s); return YES;
            case '@': {
                id v = ((id (*)(id, SEL))imp)(obj, s);
                if ([v respondsToSelector:@selector(integerValue)]) { *out = [v integerValue]; return YES; }
                break;
            }
            default: break;
        }
    }
    return NO;
}

BOOL DTCallSetter(id obj, NSArray<NSString *> *names, id arg) {
    if (!obj) return NO;
    for (NSString *n in names) {
        SEL s = NSSelectorFromString(n);
        if (![obj respondsToSelector:s]) continue;
        IMP imp = [obj methodForSelector:s];
        ((void (*)(id, SEL, id))imp)(obj, s, arg);
        return YES;
    }
    return NO;
}
