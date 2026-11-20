//
//  DTHook.h —— 零依赖方法拦截
//  不依赖 CydiaSubstrate / ElleKit / libhooker，只用 ObjC runtime。
//  适配 TrollStore + TrollFools 注入（无越狱环境也能跑）。
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 拦截实例方法，返回原 IMP（调用方自己决定要不要转发）。
/// 若方法继承自父类，会先 class_addMethod 保证只影响 cls 本身。
IMP DTHookMsg(Class cls, SEL sel, IMP newImp);

/// 拦截类方法。
IMP DTHookClsMsg(Class cls, SEL sel, IMP newImp);

/// 按类名 + selector 名拦截。clsName 为 NULL 时全局反查（见下）。
BOOL DTHookNamed(const char *clsName, const char *selName, IMP newImp, IMP *outOrig);

/// 在指定 dylib/主程序镜像内，按 selector 名反查所有实现了它的类并逐个拦截。
/// 返回拦截成功的类数量。orig 统一存进全局表，用 DTOrigFor(cls, sel) 取回。
int DTHookSelectorInImage(const char *imageName, const char *selName, IMP newImp);

/// 取回某个 (cls, sel) 的原 IMP。没记录过返回 NULL。
IMP DTOrigFor(Class cls, SEL sel);

/// 转发调用：DTOrigFor 的便捷封装，找不到原实现时安全返回。
#define DT_CALL_ORIG(cls, sel) ({ IMP _o = DTOrigFor((cls), (sel)); _o; })

/// 取微信 MMServiceCenter 里的服务对象（等价于 [[MMServiceCenter defaultCenter] getService:cls]）
id DTService(Class svcCls);
id DTServiceNamed(const char *clsName);

/// 判断 selector 是否存在于类（含继承）
BOOL DTClassHasSel(Class cls, const char *selName);

#ifdef __cplusplus
}
#endif
