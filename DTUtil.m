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
    if (!obj) return nil;
    Class c = object_getClass(obj);
    while (c) {
        Ivar v = class_getInstanceVariable(c, name);
        if (v) return object_getIvar(obj, v);
        c = class_getSuperclass(c);
    }
    return nil;
}

BOOL DTSetIvar(id obj, const char *name, id value) {
    if (!obj) return NO;
    Class c = object_getClass(obj);
    while (c) {
        Ivar v = class_getInstanceVariable(c, name);
        if (v) { object_setIvar(obj, v, value); return YES; }
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
