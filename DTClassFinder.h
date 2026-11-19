//
//  DTClassFinder.h —— 按 selector 反查宿主类
//  插件里绝大多数微信类名被加密/抹除，靠 selector 反查比写死类名可靠得多，
//  换微信版本也不容易挂。
//

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 微信镜像内所有类名（不含系统类）
NSArray<NSString *> *DTWeChatClassNames(void);

/// 实现了该 selector 的所有类（含继承也算，会去重）
NSArray<NSString *> *DTClassesForSelector(const char *selName);

/// 上面结果的第一个（继承链最深的优先）
Class DTFirstClassForSelector(const char *selName);

/// 只在自己声明了该方法的类里找（更精确，适合 hook）
NSArray<NSString *> *DTOwnerClassesForSelector(const char *selName);

/// 模糊类名匹配：名字包含 fragment 的类，按名字长度升序
NSArray<NSString *> *DTClassesMatching(const char *fragment);

/// 便捷：取类，不存在返回 Nil
Class DTCls(const char *name);

#ifdef __cplusplus
}
#endif
