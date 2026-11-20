# 版本记录

版本号的唯一来源是 `out/dt/VERSION`（一行）。改它就等于升版本：编译宏、`control` 的
`Version` 行、deb 包名、产物文件名全部跟着变。**任何源码里都不许再硬编码版本号。**

---

## 0.2.0 — 2026-11-20

工程改动，功能与 0.1.1 完全一致。

- 新增 `VERSION` 文件作为唯一版本来源；`Makefile` 解析时生成 `DTVersion.h`，`DTBuild.h`
  用 `__has_include` 引入，`DT_DYLIB_VERSION` 由它派生。
- `Makefile` 的 `before-package` 阶段用 `sed` 把 `control` 的 `Version` 同步成 `VERSION`，
  避免两处数值打架。
- `DTVersion.h` 加入 `.gitignore`（生成物，不进仓库）。
- 新增 `tools/bump_version.py`：`python tools/bump_version.py 0.3.0 "改了什么"` 一步完成
  改号 + 同步 control + 在 CHANGELOG 顶部插条目。
- 新增 `tools/release_name.py`：统一产物命名 `DTKiller-<版本>-<架构>.dylib`，避免不同状态
  的库重名互相覆盖。
- 清掉源码里最后两处硬编码版本（`DTCore.m` 的启动日志、`DTDiag.m` 的诊断头部）。

## 0.1.1 — 2026-11-20

28 处审查修复（三个子代理逐行审查 + 自审），详见 `审查修复记录.md`。

- A 类必崩 7 处：标量 ivar 用 `object_getIvar` 读取、`DTCallGetter` 对 `unsigned int`
  属性发 `performSelector:`、`DTGuard` 对返回对象的检测方法用 void block、导入含
  `NSNull` 的 JSON、`DTSilk` 在后台线程调微信发送、时长整除算成 0 秒、CallKit 把任意
  对象强转 block 调用。
- B 类静默失效 22 处：类名表缓存 3 秒过期导致启动卡 5 秒、`DTOrigFor` 在 KVO 动态子类
  上取不到原实现、两个模块重复 hook 同一 selector 造成自递归、红包三处 hook 互相覆盖、
  `DTFindView` 返回最后一个匹配导致净化项不生效、日志只留一代导致崩溃现场被删、
  设置页默认值与模块默认值不一致等。
- C 类 10 处：进度条手势挂在 3pt 线上点不中（改 12pt 热区）、`NSLog` 在主线程热路径同步
  输出（改按需）、群头像每次 setter 都全尺寸解码、`DTInstallGear` 取不到 keyWindow 就
  永久放弃等。
- 新增 `DTDiag`：一键导出诊断 txt（设备 / 微信版本 / dylib 版本 / 全部配置 / 日志尾部
  800 行），设置页「调试」组两个入口。
- 修 CI 产物收集：`find .theos -name DTKiller.dylib` 会把 dSYM 里的同名调试文件一起拷，
  后者覆盖真库，导致注入时 `ldid: Unsupported Mach-O type`。已加 `-not -path "*dSYM*"`
  与文件头打印。
- 新增 `out/dt/测试指南.md`、`out/dt/审查修复记录.md`。

## 0.1.0 — 2026-11-19

首个能编译通过的版本。

- 18 项功能：头像圆角、自动确认登录、虚拟步数、朋友圈广告净化、视频号净化、链接转
  Safari、自动下载、气泡美化、界面净化、突破 9 图上限、抢红包、收款自动回复、@全体、
  记账本、群折叠、红点消除、拍一拍、退群提示、朋友圈尾巴。
- 11 个既有模块：语音进度条、语音转发、左滑引用、音频转语音、零钱显示、群头像、
  防撤回、CallKit、反检测、设置页、诊断导出。
- 设置页 5 组 94 项；配置域 `com.dt.killer`。
