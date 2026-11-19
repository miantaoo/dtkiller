# 外部审查 Prompt（可直接复制发给其他模型）

> 用法：整段复制。下面所有技术事实都是已经静态分析确认过的，不是猜测；请基于这些事实判断，不要泛泛而谈。

---

你是 iOS 逆向工程师，做过微信越狱插件开发。请审查下面这份「微信增强插件」的需求规格，找出会导致返工、做不出来、或者做出来是假功能的问题。

**不要复述需求，不要给鼓励性评价，只输出问题。**

## 一、运行环境（硬约束，不可协商）

- 设备：iPhone 12 及以后（A14+ 芯片），iOS 16.x，arm64e
- 微信：8.0.50，App Store 正版（**本体是 arm64**，不是 arm64e）
- **设备未越狱**
- 注入方式：TrollFools 把 dylib 注入已安装的微信 App
  - 原理：改 Mach-O 加 `LC_LOAD_DYLIB` + `LC_RPATH`，dylib 拷到 `WeChat.app/Frameworks/`，`ldid -S` 伪签 + `ct_bypass` 伪造 App Store 双签
  - TrollFools 自带一份 **ElleKit 伪装成 `CydiaSubstrate.framework`**，导出 `_MSHookMessageEx`，依赖被重写成 `@executable_path/Frameworks/CydiaSubstrate.framework/CydiaSubstrate`
- **因此只能做 ObjC method swizzle**：
  - `MSHookFunction` / inline hook 需要 JIT（只有 TrollStore 模式才有），**用不了**
  - `fishhook` 篡改导入符号表会改 `__DATA` 的 lazy pointer，触发微信 `__TEXT` 段完整性校验，**不用**
  - `class_replaceMethod` 在本类没有实现时等价于 `class_addMethod` 且返回 NULL，取原实现必须回 superclass 找，否则崩
- dylib 必须含 **arm64 slice**（不是只有 arm64e），否则注入后 `dlopen` 失败
- 微信更新会整个替换 `.app`，注入失效，需重新注入

## 二、已静态分析确认的微信内部接口

以下全部来自 10 个真实插件 dylib 的 Mach-O 逆向 + 微信 8.0.54 全量 class-dump（42,134 个头文件）。

**语音链路**
```
BaseMsgContentLogicController  -StartPlaying:Resume:
PlayingController              -StartPlayMessage:Resume:  -StopPlayMessage:  -SeekVoiceMsg:toTime:
                               currentPlayingMsg
AudioReceiver                  -StartPlay:  -StartPlay:Path:  -StartPlay:Path:Resume:
                               -getCurrentTimeMs  -setProgress:  -StopPlay  -isPlaying
                               -generatePlayerWithAudioFormat:  持有 m_audioPlayer
SilkAudioPlayer                只有 playAtTime:（毫秒）/ setProgress: / getCurrentTimeMs /
                               stop / autostop / replay / preparePlayWithFile:sync: / openSilkFile:
                               **没有 play / pause / isPlaying / duration / currentTime**
SilkAudioPlayerV2              有 duration / isPlaying / start / resume / pause / stop
AutoplayController             -PlayList  autoPlayEnabled  -OnEndPlaying:isForceStop:
CMessageWrap                   -IsVoiceMsg   m_uiVoiceTime  m_uiVoiceFormat(=4)  m_dtVoice(NSData)
```
- cell 类名在 8.0.54 全量头文件里**找不到**（没有 `VoiceMsgContentCell`、没有 `BaseMsgContentTableViewCell`），6.x 的 `VoiceMessageNodeView` 体系已废弃

**消息 / 撤回**
```
CMessageMgr   -AsyncOnAddMsg:MsgWrap:  -onRevokeMsg:  -OnRevokeMsg:  -AddMsg:MsgWrap:
              -GetSelfUserName
CMessageWrap  m_uiMessageType(=34 语音)  m_nsFromUsr  m_nsToUsr  m_uiMesLocalID
              referingMessageWrap（引用状态）
```

**红包**
```
WCRedEnvelopesLogicMgr  -OnWCToHongbaoCommonResponse:Request:  -OpenRedEnvelopesRequest:
                        -ReceiverQueryRedEnvelopesRequest:
红包消息 XML: <voicemsg .../> 同族的 <wcpayinfo> 里 timingIdentifier 是抢包必需的
```

**会话列表 / 设置页**
```
WCTableViewManager     addSection:  addCell:
MoreViewController
switchCellForSel:target:title:on:
normalCellForSel:target:title:accessoryType:
```

**朋友圈**
```
WCDataItem / WCContent / 类名含 TimeLine 的控制器
likeDataItem:   isAd   getTimelineDataItemOfIndex:
```

**反检测（微信自己会查）**
```
ClientCheckMgr  +shareInstance  checkHook:  checkHookWithSeq:  checkHookWithSeq:seq:
                checkConsistency:
                reportFileConsistency:fileName:offset:bufferSize:seq:   ← 按 offset 读文件页做哈希，校 __TEXT
                reportAppList:  runningProcesses  registerAddImageCallBack  addImage:
JailBreakHelper +JailBroken  +getJailbreakPath  +getJailbreakRootDir
                -IsJailBreak  -HasInstallJailbreakPlugin:
```

**CallKit**
```
微信自己的 VoIP 入口（8 个 selector）：
  isDeviceCallkitAvailable  isCallkitAvailable  getIfCanUseCX:
  onServiceEnterBackground  onServiceEnterForeground
  reportIncomingCallFromUser:ofType:withMsg:isPushKit:
  reportIncomingCallFromUser:ofType:withMsg:isPushKit:displayName:completion:
  handleVoIPPushInfoContent:VoIPPushInfo:type:completion:
```

**SILK 语音编码**
```
格式 = 0x02 + "#!SILK_V3" + Σ(uint16 小端帧长 + 帧数据)，头 10 字节，无 FF FF 结尾
参数 = 24000 Hz / 单声道 / 16bit / 20ms(480 样本) / 帧上限 250 字节 / complexity 2 / 线上实测约 12.5 kbps
发送语音消息的 XML 里 aeskey 与 voiceurl 由服务端 CDN 下发，本地无法自造
```

## 三、待审查的 19 项需求

### P0-1 头像圆角（40 行）
- 位置：所有头像（会话列表、聊天页、通讯录、群成员、朋友圈）
- 做法：hook 头像 `UIImageView` 的 `setImage:`，把图离屏裁成圆角再换上去（**不是改 layer.cornerRadius**），LRU 缓存 200 张
- 参数：圆角比例 0.22；另留开关可切到 layer 模式
- 边界：动图头像会变静态；只处理边长 ≥ 24pt 的图

### P0-2 自动确认登录（40 行）
- 位置：新设备登录 / 清除数据后的「确认登录」弹窗
- 行为：弹窗出现 0.8 秒后自动点「登录」
- 异常登录的红色警告页**不自动点**

### P0-3 虚拟步数（90 行）
- 位置：微信运动（排行榜、步数详情）
- 行为：每天 00:05 在 [15000, 35000] 随机一个值，全天恒定上报；可选每小时 ±8% 自然抖动
- 计划同时 hook `CMPedometer` 与微信的 `hkStepCount`，「避免微信运动 20000、健康 App 8000 的矛盾」

### P0-4 广告净化（60 行）
- 4 处：朋友圈广告、公众号文末广告、小程序启动广告、搜一搜结果广告
- 行为：**完全移除并重排**（不留白）
- 边界：朋友圈广告移除后「上次看到这里」提示要顺延

### P0-5 视频号净化（50 行）
- 隐藏：发现页入口、我页入口、朋友圈卡片
- **保留**：聊天里的视频号分享卡片

### P0-6 链接转 Safari（50 行）
- 聊天里点 http/https 链接直接 `openURL` 到 Safari
- 排除：公众号文章、微信支付、小程序、`weixin://` 协议

### P0-7 自动下载（80 行）
- 11 个细项：图片/视频/文件/语音、仅 WiFi、允许蜂窝、私聊、群聊、公众号、单文件大小上限、会话黑名单
- 默认：图片+视频开、文件+语音关、仅 WiFi、私聊+群聊开、上限 10MB
- 边界：群里刷屏时加 300ms 间隔队列

### P0-8 气泡美化（140 行）
- `Documents/DTKiller/bubbles/<名字>/` 放 4 张图（我方普通/我方按压/对方普通/对方按压）
- 内置 3 套；直接读原插件 WCPure 的图片目录
- 用 `resizableImageWithCapInsets:` 做九宫格拉伸
- 深色模式另一套图

### P0-9 界面净化（260 行，22 项）
一键全净 + 22 个逐项开关（总开关不覆盖手动改动），22 项：
1. 发现页「视频号」入口 2. 朋友圈广告 3. 朋友圈折叠提示
4. 我-朋友圈 5. 我-表情 6. 我-收藏 7. 我-卡包 8. 我-视频号
9. 设置-青少年模式 10. 设置-通用某一项 11. 小程序启动广告
12-14. 表情面板的「拍照」「最近使用」「搜索」
15. 首页左滑删除 16. 被拦截链接提示页 17. 聊天页「+」里某项
18. 语音转文字提示横幅 19. 朋友圈「谁看过我」 20. 长按消息某项
21. 小程序分享进群 22. 拍一拍后缀
（其中 17/18/19/20/21 这 5 项的准确语义尚未反汇编确认，目前是猜的）

### P0-10 突破「一次最多发 9 张图」（60 行）
- 依据：原插件 hook 了 `setMaxImageCount:`
- 行为：hook 该 setter，把值改成配置值（默认 20，可配 9–99）
- 计划让 getter 也返回一致的值

### P0-11 抢红包（150 行）
- 群里有红包 → 延迟 [0.8, 2.4] 秒随机 → 调 `OpenRedEnvelopesRequest:`
- 只抢设置页勾选的群；跳过自己发的、已领完的、专属红包
- 抢到**不发感谢语**

### P1-12 收款自动回复（110 行）
- 收到转账/群收款 → 自动回文本，支持 `[金额]` 变量
- 白名单模式：只在设置页点名的会话里回

### P1-13 @全体成员（60 行）
- 输入框输入「@所有人」或「@全体成员」→ 转成本群真实 @
- 非管理员时提示失败

### P1-14 记账本（200 行）
- 统计红包收发、转账收发，按月汇总 + 明细列表
- 数据源：hook 红包/转账回调累计

### P1-15 群折叠（40 行）
- 把「免打扰的群」在会话列表折叠成一行，点开展开

### P1-16 红点消除（40 行）
- 去掉「发现」「我」tab 的红点、以及发现页/我页各入口的红点
- **保留**底部「微信」tab 的未读数字

### P1-17 拍一拍后缀（30 行）
- 双击头像时显示自定义后缀，只对自己生效

### P1-18 退群通知（90 行）
- 成员退群时本地弹横幅「XX 退出了群聊」，不发到群里

### P1-19 朋友圈电脑端尾巴（20 行）
- 发朋友圈时可选显示「手机」或「电脑」的来源尾巴，两套值可切

## 四、已经实现的 11 个模块（不在本次审查范围，但会影响集成）

语音进度条（自绘 QQ 风格，挂气泡底部）、语音转发（长按菜单加一项）、左滑引用、SILK 编解码、零钱显示加成（只改 UILabel）、群头像、朋友圈尾巴、反检测（10 个检测方法返回 NO + 4 类上报吞掉）、设置页、防撤回、CallKit。

## 五、我自己已经识别出的风险（请复核，并补充我漏的）

1. **P0-10**：`setMaxImageCount:` 只是 setter，选图 UI 分页、发送前校验、服务端单条消息图片数上限可能各自独立。iPad 能发 20 可能是服务端按平台放行。
2. **P0-3**：非越狱改不了 HealthKit 数据库，健康 App 一定还是真实步数，「两边一致」做不到。
3. **P0-11**：0.8–2.4 秒是典型秒抢特征，风控风险高（原插件作者用 60 秒）。
4. **P1-14**：历史账单拿不到，只能记装插件之后的新数据。
5. **P0-9**：22 项里 5 项语义未知（上面第 17–21 项）。
6. **配置域**：30+ 个开关如果写进微信自己的 `com.tencent.xin` 域，会和用户已装的原插件互相覆盖 `NSUserDefaults`。
7. **防撤回**：现在会把「自己撤回」也拦掉。

## 六、请按这个格式输出

按 **严重 / 中等 / 轻微** 三级，每条给：

```
### [级别] 编号 + 一句话问题
- 现状：需求里怎么写的
- 为什么有问题：（给技术依据，别提"建议咨询专业人士"）
- 怎么改：具体到 hook 哪个方法、或明确说这个功能在这个环境下做不到
```

另外单独回答三个问题：

1. **这 19 项里，哪几项在「非越狱 + TrollFools + 只能 swizzle」的条件下根本做不到？**（点名，并说明是哪个环节卡住）
2. **哪几项会触发微信的反检测（`checkHookWithSeq:` / `reportFileConsistency:`）？** 以及现在的「检测方法返回 NO」够不够。
3. **19 项全写进一个 dylib（约 5400 行、注入后会常驻 30+ 个 hook），有没有架构上的隐患？** 比如加载时序、hook 冲突、启动耗时。

最后，如果你认为某一项的默认参数（延迟、上限、比例）明显不合理，直接给建议值。
