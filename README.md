# DTKiller — 微信增强（自研重写版）

把 10 个第三方插件里你**实际在用**的功能，用一个 <500KB 的 dylib 重做。
不依赖 CydiaSubstrate，全部走 ObjC runtime，TrollFools 注入已装微信即可用。

> **版本号规则**：唯一来源是 `out/dt/VERSION`（一行，如 `0.2.0`）。改它就等于升版本——
> Makefile 生成 `DTVersion.h` 供 `DTBuild.h` 引入，`control` 的 `Version` 在打包前同步，
> deb 包名与产物文件名全部跟着走。升版本一条命令：
> `python tools/bump_version.py 0.2.1 "这次改了什么"`。
> 产物统一命名 `DTKiller-<版本>-<架构>.dylib`，旧版本文件不覆盖，出问题能回退。
> 任何 `.m` / `.h` 里都不许硬编码版本号。

```
out/dt/
├── DTCore.m            入口：安全启动门闩、持久阶段诊断，模块分批安装
├── DTHook.h/.m         零依赖 hook（method_setImplementation / class_addMethod）
├── DTConfig.h/.m       配置读写（com.dt.killer 域，启动时从旧插件域迁移）
├── DTClassFinder.h/.m  按 selector 反查宿主类（应对类名加密/动态注册）
├── DTLog.h/.m          日志 + 导出（Documents/DTKiller/app.log，2MB 滚动）
├── DTUtil.h/.m         手势 proxy / 视图树遍历 / ivar 安全读写
├── DTGuard.m           反检测 + 选择性上报屏蔽
├── DTVoiceBar.m        QQ 风格语音进度条（3pt 视觉线 / 12pt 手势热区 + 倍速 + 拖动预览）
├── DTVoiceFwd.m        语音转发（长按菜单 + 原生通道优先）
├── DTSilk.m            音乐/视频 → 语音
├── DTSilkCodec.h/.m    SILK v3 编解码封装（可选 vendor/silk）
├── DTSwipeQuote.m      左滑引用
├── DTBalance.m         零钱显示加成
├── DTGroupAvatar.m     群头像自定义
├── DTMomentsTail.m     朋友圈尾巴
├── DTSettings.m        设置页
├── Makefile
├── 注入与反检测.md       TrollFools 注入 / 签名链 / 检测绕过说明
├── 实现对照表.md         需求 → 代码位置对照
├── 调研-微信8.0.54语音链路.md  播放器/连播/落盘/cell 的调研存档
├── 真机校准清单.md       6 个必须上真机确认的点（含失败改法）
└── .github/workflows/build.yml   云端编译
```

---

## 编译

> 没有 Mac：直接看 [编译发布指南.md](编译发布指南.md)，用 GitHub Actions 出包，5 分钟。

两条路，任选：

**A. 本地 Theos**

```bash
export THEOS=~/theos
cd out/dt
make package FINALPACKAGE=1
# 产物：packages/com.dt.wechatkiller_*.deb
dpkg-deb -x packages/*.deb /tmp/dtk
# dylib 在 /tmp/dtk/Library/MobileSubstrate/DynamicLibraries/DTKiller.dylib
```

**B. 云端（不用 Mac）**

推到 GitHub，Actions 自动出 deb，见 `.github/workflows/build.yml`。

**C. 直接 clang（有 Xcode 没 Theos）**

```bash
xcrun -sdk iphoneos clang -arch arm64 -arch arm64e \
  -dynamiclib -fobjc-arc -O2 -undefined dynamic_lookup \
  -framework UIKit -framework Foundation -framework AVFoundation \
  -framework CoreMedia -framework CoreGraphics -framework QuartzCore \
  *.m -o DTKiller.dylib
```

编译前静态自检（不需要任何 SDK）：

```bash
python tools/selfcheck.py out/dt   # 括号 / @end 配对 / #import 存在性
python tools/lint.py    out/dt     # 未定义函数 / 全局变量 / 可见性（抓链接期 undefined）
python tools/precheck.py out/dt    # C 函数参数个数 / @interface 未实现 / @selector 不存在
python tools/ordercheck.py out/dt  # static 全局变量先用后声明（三个脚本都抓不到的那类编译错误）
bash tools/run_dt_checks.sh        # 上述四项的统一入口
```

---

## 注入

详细步骤、签名链、失败排查见 **[注入与反检测.md](注入与反检测.md)**。要点：

1. iPhone 12+ / iOS 16.x / TrollStore + TrollFools
2. 微信 **8.0.56**（当前测试基准；内部 selector 仍按运行时检查，缺失则跳过并记日志）
3. TrollFools → 微信 → 注入 `DTKiller.dylib` → 冷启
4. 日志：微信沙盒 `Documents/DTKiller/app.log`

> **不需要给微信开 JIT**：本项目只做 ObjC swizzle，改的是 `__DATA` 里的 imp 字段，
> 不新增可执行页，也不碰 `__TEXT`。

---

## 配置

配置落在 **`com.dt.killer`** 独立域，避免和 HB / Misaka / MiYou / WCPure 抢同一个 key。
首次启动会从旧域 `com.tencent.xin` 一次性迁移旧键（`MIsVoiceProgressKey → DTVoiceBarEnable`、
`mIsForwardVoice → DTVoiceFwdEnable`、`editMoney → DTBalanceEnable`、`theGroupHeadImageBOOL → DTGroupAvatarEnable`、
`editTimeLinePhoneText → DTMomentsTailPhone`）。电脑端尾巴映射未接入本版，旧键会保留在原域而不参与显示。

**入口**：微信「我 → 设置」→「DTKiller 设置」；不创建全局悬浮按钮。优先插入独立 section/cell；若微信表格 API 不匹配，则在同一个设置页导航栏添加 `DTKiller` 备用按钮。入口按每个设置控制器独立持有 target，并防止刷新重入。

设置页包含约 100 个可配置 / 操作项（另有小节说明行）：

| 组 | 内容 |
|---|---|
| 净化 | 全局入口净化 + 13 个子项、广告、发现页、Safari、自动下载策略 |
| 语音 | 进度条、转发、引用、音频转换、CallKit |
| 钱包 | 零钱显示、抢红包范围、收款回复白名单、本地记账 |
| 增强 | 头像圆角、气泡、朋友圈、群头像、列表、步数 |
| 调试 | 模块总闸、安全模式恢复、兼容项、防撤回、自动登录、日志与诊断 |

**缺省值**：`DTModulesEnabled` 默认关闭，首次安装只挂设置入口与诊断能力；各功能开关默认关闭。反检测兼容项也默认关闭。总闸关闭期间，分类设置可以编辑和保存，但不会加载功能 hook；先在「调试」打开总闸并重启，再逐项测试。

**启动恢复**：`boot.stage` 记录模块安装阶段，`ui.stage` 单独记录设置页刷新；正常上滑关闭留下的 `running + boot-started` 不会单独触发安全模式。若 UI 入口失效，先用 TrollFools 停用/eject 插件恢复微信，不要仅删除 `boot.state` 后继续启动已开启的模块。

改完开关**必须重启微信**：hook 在启动时一次性装好，hook 体内部才去读配置。

完整键表见 [配置键总表.md](配置键总表.md)。

---

## 各模块状态

| 模块 | 状态 | 说明 |
|---|---|---|
| 语音进度条 | ✅ 需真机校准 | 视图自绘；播放器候选名来自 8.0.54 class-dump，运行时再按 selector/能力筛选，8.0.56 实际类名需看诊断日志；进度走 `getCurrentTimeMs` 毫秒，总时长取自 `CMessageWrap.m_uiVoiceTime`；12fps `CADisplayLink`，停止或结束会 invalidate |
| 左滑引用 | ✅ 可跑 | vc → 视图树 → 工具栏三层找 `referingMessageWrap` 宿主，多路 refresh |
| 语音转发 | ⚠️ 需真机校准 | 语音数据优先读 `CMessageWrap.m_dtVoice`，其次路径字段，最后在 `Documents` 下递归找 `.aud`；优先原生 `ForwardMsg:ToContact:Scene:`，退回重发 |
| 零钱加成 | ✅ 可跑 | 只改 `font >= 18` 且匹配金额的 UILabel，每次 `viewDidAppear` 重打 |
| 群头像 | ✅ 可跑 | 图片放 `Documents/DTKiller/avatars/<群id>.png`，运行时换 + 刷 `mmsf` 缓存 |
| 朋友圈尾巴 | ✅ 可跑 | 数据层 getter + cell label 片段替换（保留「2小时前」前缀） |
| 反检测 | ✅ 可跑 | `ClientCheckMgr` 全链路 no-op + `JailBreakHelper` 返回 NO + bundleId 伪造 |
| 音乐转语音 | ⚠️ 需 vendor/silk | 解码/编码/落盘/发送全通；SILK SDK 需自己放进 `vendor/silk`（Makefile 已自动识别） |
| 防撤回 | ⚠️ 需真机校准 | 总闸开启后在启动批次安装；hook `onRevokeMsg:` / `OnRevokeMsg:` 并探测其它候选；构造阶段不触碰微信类表 |
| CallKit | ⚠️ 需真机校准 | 8 个 selector 按 WeCallKit 还原结果打；`reportNewIncomingCall` 失败会自动降级成「本地通知 + 震动」；answer/end 要转发回 `MMVoIPService`，selector 名随版本变，见校准清单 |
| 头像圆角 | ✅ 可跑 | 离屏重绘 + LRU 200；`DTIconRadiusLayerMode` 可切 layer 模式 |
| 自动确认登录 | ⚠️ 需真机校准 | 只点标题含「登录」的按钮；异常/风险页跳过 |
| 虚拟步数 | ✅ 可跑 | 按返回类型分 3 种 IMP；按重置小时归日 + 自然抖动 |
| 广告净化 | ⚠️ 需真机校准 | hook `LL_onBeforeReturnDataItem:` 返回 nil；广告字段名随版本变 |
| 视频号净化 | ⚠️ 需真机校准 | 入口级过滤，与界面净化可能重叠 |
| 链接转 Safari | ✅ 可跑 | 排除公众号/支付/h5 桥接 + 消息类型 49 |
| 自动下载 | ✅ 可跑 | 拦 `canMediaDownloadedNow:` / `allowSilentDownload` / `canAutoDownloadMedia:` |
| 气泡美化 | ✅ 可跑 | 内置 3 套代码绘制，可选文件夹图片 |
| 界面净化 | ✅ 可跑 | `addCell:` / `addSection:` 标题黑名单 13 条 + 一键全净 |
| 突破 9 图上限 | ⚠️ 需真机校准 | 依赖 `setMaxImageCount:` 存在；不存在则整模块不装并写日志 |
| 抢红包 | ⚠️ 需真机校准 | 参数顺序待确认；msgId 去重 + `req-sent/ok/fail` 三态；只抢指定群 |
| 收款自动回复 | ✅ 可跑 | 白名单 + 5 秒去重 + `[金额]` 占位符 |
| @全体 | ⚠️ 需真机校准 | 非管理员只发普通文本，做不到真 @ |
| 记账本 | ✅ 可跑 | `Documents/DTKiller/ledger.json`，按 msgId 幂等，按月汇总 |
| 群折叠 | ⚠️ 需真机校准 | 行高压到 0.01，不改数据源 |
| 红点消除 | ✅ 可跑 | 只隐藏类名含 `Dot`/`Badge` 的控件，保留未读数 |
| 拍一拍后缀 | ⚠️ 需真机校准 | 文案拼接，接收端显示未验证 |
| 退群通知 | ⚠️ 需真机校准 | 事件存在性待验证，拿不到身份就只说「群成员有变动」 |
| 设置页 | ⚠️ 需真机验证 | 微信「我→设置」独立入口；table manager 失败时同页导航栏备用按钮；每 host 独立 target、刷新防重入；诊断包含 `boot.stage`/`ui.stage` |

### SILK 编码器（可选依赖）

`DTSilkCodec.m` 已把编解码写完整，只差 SDK 源码：

```bash
git clone https://github.com/kn007/silk-v3-decoder
cp -R silk-v3-decoder/silk vendor/silk
rm -rf vendor/silk/src/*.S          # 32 位 ARM 汇编，arm64 编不了
make package
```

没有 `vendor/silk` 时也能编译，只是 `DTSilkAvailable()` 返回 NO，转换会把 PCM 落到
`Documents/DTKiller/last.pcm`。

格式细节（实测）：微信语音 = `0x02` + `#!SILK_V3` + Σ(uint16LE 帧长 + 帧)，
**没有** 标准 SILK 的 `FF FF` 结尾；24 kHz / 单声道 / 16bit / 20ms 一帧（480 样本），
线上实测约 12.5 kbps。

---

## 为什么类名都运行时反查

WCPure / WeCallKit 这批插件的类名是**加密**的（`__objc_classname` 里是密文），
而且微信自己会 `objc_allocateClassPair` 动态注册类。所以本工程不写死任何微信内部类名：

- `DTClassesForSelector("onRevokeMsg:")` → 所有实现该 selector 的类
- `DTWeChatClassNames()` → 枚举主二进制全部类（进程内永久缓存；需要时可显式失效）

代价是首次 hook 几十毫秒，换来**换微信版本不用改代码**。

---

## 已知限制

1. **改余额只改显示**。钱包页刷新、进零钱详情会重读，本工程每次 `viewDidAppear` 重打；转账/支付仍走真实值。
2. **群头像需要重启微信**才在所有界面一致（运行时替换只覆盖当前可见的头像视图）。
3. **语音转发**能否让对方直接播放，取决于目标微信版本是否允许重发走网络通道 —— 要真机验证。
4. **反检测**不隐藏 dylib（不改 `__DATA` 段、不上 fishhook）：`getImageList` 返回空数组是当前的隐藏手段，够用但不绝对。
5. **防撤回是单边的**：消息留在你手机上，对方那边仍然显示「已撤回」。要连服务端一起拦需要改 `sysmsg` 解析，属于改协议，本工程不做。
6. **CallKit 可能被 iOS 拒绝**：微信没有 `voip` 后台模式时 `reportNewIncomingCall` 返回错误，工程会自动降级成通知 + 震动（锁屏能看到是谁，但接不了）。
7. **不要在这个工程里链第三方库**：TrollFools 注入的 dylib 靠 `-undefined dynamic_lookup` 解析符号，多一层依赖就多一个加载失败点。

---

## 调试

```bash
# 电脑侧（ssh / Filza）
tail -f /var/mobile/Containers/Data/Application/<微信UUID>/Documents/DTKiller/app.log
```

日志里每个模块装完都会打一行 `xxx: ... N ...`，N=0 说明这个版本没匹配到宿主类，
把那一行发出来就能按新 selector 补匹配串。

日志是**逐行刷盘**的，所以闪退时最后一行就是崩点。
