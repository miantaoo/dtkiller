# 版本记录

版本号的唯一来源是 `out/dt/VERSION`（一行）。改它就等于升版本：编译宏、`control` 的
`Version` 行、deb 包名、产物文件名全部跟着变。**任何源码里都不许再硬编码版本号。**

---

## 0.2.6 — 2026-11-22

- 修正旧配置迁移错误：旧 `editMoney` 是金额值，不是布尔开关；不再映射到 `DTBalanceEnable`。升级时仅清理该开关键下非 0/1 的旧值，保留有效开关与现有偏移设置。诊断包中的 `2847943` 可按此问题解释。
- 启动诊断显示：生成该包时最近一次启动记录为 `diagnostic-only-ready`，当次功能总闸关闭；总闸在该次启动后才被打开，需完全退出微信再重启才会安装功能模块。后续测试建议只开一个功能，避免多模块交叉影响。

## 0.2.5 — 2026-11-21

- 微信设置页入口在调用 table manager 私有方法前校验参数数量和返回类型；不匹配时改用同一设置页导航栏备用入口。
- 语音进度条绑定当前播放的消息，避免列表复用时更新到另一条语音；停止/播放完成时释放 CADisplayLink，避免空转。
- 增加 `tools/run_dt_checks.sh`，一条命令运行结构、lint、原型和静态顺序检查。
- 0.2.4 的首启安全门闩和诊断字段保持不变；冷启动闪退尚待新的 IPS/诊断包确认，不能视作根因已定位。

## 0.2.4 — 2026-11-21

- 移除全局悬浮齿轮，改在微信「我 → 设置」列表插入独立「DTKiller 设置」入口；检测微信 table manager API，失败会记日志。
- 设置首页改为五类导航（净化/语音/钱包/增强/调试），分类内用不可交互的小节标题分组并补用途/限制说明。
- 首启功能总闸 `DTModulesEnabled` 默认关闭，只安装入口与诊断；反检测、防撤回默认关闭，需用户逐项开启。
- 启动流程兼顾 `didFinishLaunching` observer、当前应用状态检查与 6 秒兜底，三路由 `gScheduled` 去重。
- 设置入口按 host 独立持有 action target；table API 失败时在微信设置页导航栏提供备用按钮，hook 安装失败则前 20 秒高频探测、之后每 5 秒继续探测；插入过程加重入保护。
- `boot.stage` 只记录启动模块阶段，`ui.stage` 单独记录设置页刷新；正常上滑关闭留下 `running + boot-started` 不单独视为崩溃。只有上次残留 `enter:*` 或持久 `safe` 状态才进安全模式。
- 旧配置迁移移到功能总闸判断之前；分类 footer 明示总闸关闭时选项只保存、不加载。
- 更新测试指南：包含导航栏备用入口、TrollFools 停用/eject 恢复路径，以及诊断包中的独立 `ui.stage`。

## 0.2.3 — 2026-11-20

- 修复 `control` 文件 CRLF 行尾导致 Theos 打包失败；版本文件写入统一使用 LF。
- 重新构建并校验 arm64、arm64e 与 fat dylib，以及 arm64 deb 包；这是后续设置页/启动安全改造前的基线版本。

## 0.2.2 — 2026-11-20

- 一次中间构建版本；`control` 行尾仍触发打包失败，未作为最终测试包交付。该问题在 0.2.3 修复。

## 0.2.1 — 2026-11-20

修「注入后微信起不来」。这一版的目标只有一个：**保证一定能启动**，功能默认全关。

- 重写 `DTCore.m` 的启动时序：constructor 阶段不再装任何 hook，只写
  `Documents/DTKiller/boot.state`、注册 `UIApplicationDidFinishLaunchingNotification`。
  所有模块改到 `didFinishLaunching` + 1.2 秒之后安装（反检测三件在前，UI 六批在后，
  每批间隔 0.35 秒）。0.2.0 及以前在 constructor 里就替换检测方法的 IMP，一旦某个
  替换实现不对，微信会崩在启动阶段，用户连界面都看不到，也无从判断是哪个模块。
- 每个模块用 `DTRun(name, fn)` 包 `@try/@catch`：一个模块抛异常只丢这一个，不牵连
  整条启动链。
- 崩溃自愈：全部装完才把 `boot.state` 写成 `ok`。下次启动若读到 `running`，说明上次
  没走到最后，自动进**安全模式**——只装设置页与诊断导出，用户永远能进微信、能进设置
  页把日志导出来。想手动退出安全模式：删掉 `Documents/DTKiller/boot.state`。
- 反检测默认改为关：`DTGuard.m:117` 的 `DTGuardEnable`、三处 `DTBlockHookCheck`
  全部由 `YES` 改 `NO`；设置页三项默认值同步改 `NO`，副标题加「默认关，确认能启动
  再打开」。
- 防撤回默认改为关：`DTRevoke.m` 两处 `DTRevokeEnable` 由 `YES` 改 `NO`，
  `DTRevokeAllowSelf` 默认 `NO`。它的兜底扫描会遍历所有 `C/M/W` 开头的类、把所有
  名字含 `Revoke` 且签名 `void(id)` 的方法挂成空实现，风险面比其它模块大得多。
- 结论：这一版装上应该能正常启动，但**功能一个都不会自动生效**，需要在设置页手动打开。
  逐项打开的过程同时也是定位「到底是哪个模块导致崩溃」的过程。

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
