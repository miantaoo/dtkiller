//
//  DTUtil.h —— 小工具：手势/定时器的 block target、视图树遍历、金额字体判断
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 手势的 block target。必须被强引用（存到 recognizer 的关联对象里），
/// 否则 UIGestureRecognizer 的 target 是弱引用会立即释放。
@interface DTGestureProxy : NSObject
- (instancetype)initWithHandler:(void (^)(UIGestureRecognizer *g))handler;
- (void)handle:(UIGestureRecognizer *)g;
@end

/// 文件选择器 delegate（弱引用友好：由调用方通过关联对象持有）
@interface DTDocumentPickerDelegate : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, copy) void (^onPick)(NSURL *url);
@end

/// 深度遍历视图树（含自身），block 返回 YES 可提前结束。
void DTEnumerateViews(UIView *root, BOOL (^block)(UIView *v));

/// 在视图树里找第一个满足条件的视图，没有返回 nil。
UIView *DTFindView(UIView *root, BOOL (^pred)(UIView *v));

/// 取视图所属控制器（沿 nextResponder 上溯）。
UIViewController *DTViewControllerOf(UIView *view);

/// 安全读 ivar（含父类链），返回对象或 nil。
id DTGetIvar(id obj, const char *name);

/// 安全写 ivar（含父类链），返回 YES 表示写成功。
BOOL DTSetIvar(id obj, const char *name, id value);

/// 依次尝试调用无参 getter，返回第一个非 nil 结果。
id DTCallGetter(id obj, NSArray<NSString *> *names);
/// 按方法真实返回类型取整数值。标量属性千万别走 DTCallGetter / performSelector:。
BOOL DTIntValue(id obj, NSArray<NSString *> *names, NSInteger *out);

/// 依次尝试调用单参 setter，返回 YES 表示成功。
BOOL DTCallSetter(id obj, NSArray<NSString *> *names, id arg);

#ifdef __cplusplus
}
#endif
