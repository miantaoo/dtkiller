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

void DTEnumerateViews(UIView *root, BOOL (^block)(UIView *v)) {
    if (!root || !block) return;
    if (block(root)) return;
    for (UIView *sub in root.subviews) {
        DTEnumerateViews(sub, block);
    }
}

UIView *DTFindView(UIView *root, BOOL (^pred)(UIView *v)) {
    if (!root || !pred) return nil;
    __block UIView *found = nil;
    DTEnumerateViews(root, ^BOOL(UIView *v) {
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
        if (![obj respondsToSelector:s]) continue;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id v = [obj performSelector:s];
#pragma clang diagnostic pop
        if (v) return v;
    }
    return nil;
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
