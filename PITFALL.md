# PITFALL.md — 踩坑记录

本文件记录本项目遇到的陷阱、报错、失败尝试与修复方法。按 AGENTS.md 第 4 节约定维护。

---

## 1. 构建：默认 SwiftPM 构建系统编译 mlx-swift 的 Metal kernel 失败

**现象**

```
error: CompileMetalFile .../mlx-swift/Source/Cmlx/mlx-generated/metal/rope.metal failed with a nonzero exit code
warning: ... Could not read serialized diagnostics file: ... .dia couldn't be opened because there is no such file
error: Build failed
```

`swift build` 直接失败，且报错只指向 mlx-swift（依赖），与项目源码无关。

**原因**

Swift 6.x 工具链的 SwiftPM 默认使用新的 `swiftbuild` 构建系统（产物在 `.build/out/`），
在本机（Xcode 26/27 工具链 + macOS 27 SDK）编译 mlx-swift 的 Metal 源时失败。

**解决办法**

改用旧的 native 构建系统：

```bash
swift build --disable-sandbox --build-system native
```

`.build/arm64-apple-macosx/debug/` 下即为产物；`build.sh` 里的 `swift build` 目前会踩到同样的问题，
如需本地构建可临时加上 `--build-system native`（会提示 deprecated，但可用）。

---

## 2. `Task { }` 会继承 actor 隔离，在 `@MainActor` 上下文里并不会切到后台

**现象（本次核心 bug 之一）**

`ViewModel` 是 `@MainActor` 的，原来的 ASR 推理写成：

```swift
let asrText = await Task {
    asr.transcribe(audio: ..., sampleRate: 16000, language: "en")
}.value
```

看起来像"丢到后台任务"，但非结构化 `Task {}` **继承当前 actor 隔离**，
而 `processAndSend` 本身就是 `@MainActor`，所以 `transcribe` 实际跑在主线程上。
ASR 推理耗时以秒计，期间主线程 RunLoop 被占死：

* `NSEvent` 媒体键监听回调无法执行 → 按键"不生效"；
* `Timer` 全部停摆 → Now Playing 的 keep-alive ping 停顿，系统可能把媒体键路由给别的 App；
* UI 卡住。

**修复**

用专用串行队列 + `withCheckedContinuation` 把推理放到后台，
并用 `@unchecked Sendable` 盒子明确"该模型只在这条串行队列上访问"。
注意 `Qwen3ASRModel` 官方注释明确写了 not thread-safe，所以必须串行化，不能并发调用。

---

## 3. 媒体键"一次按键触发多次回调"

**现象**

一次物理按键可能同时经三条通道到达：全局 `NSEvent` monitor、本地 `NSEvent` monitor、
`MPRemoteCommandCenter`（play/pause/togglePlayPause）。原作者在 `ViewModel` 里用 500ms 去抖兜底，
代价是用户 0.5s 内的第二次真实按键被吞掉（表现为"打断不了 / 按键没反应"）。

**修复**

把去抖上移到 `MediaKeyController.fire(_:source:)`，统一收口三个来源，
按 action 各自记录时间戳，窗口 0.4s。业务层不再去抖。

---

## 4. 延迟重启任务不可取消 → 打断后"复活"

**现象**

`startListening()` / `interruptConversation()` / `undoLastConversation()` 以及 TTS 完成回调里
都存在：

```swift
Task { try? await Task.sleep(...); self.startListening() }
```

这些 Task 没有被持有、无法取消。用户按停止后，之前排队的重启任务照样执行，
表现为"按了没反应"或者"停了又自己开始录音"。

**修复**

引入单调递增的 `generation` 令牌：每次进入新周期/停止/打断都 `generation &+= 1`。
所有异步续体（延迟重启、VAD 回调、TTS 完成、LLM 完成、ASR 结果）都捕获自己的 generation，
不匹配就直接丢弃；延迟重启任务同时持有句柄（`restartTask`）以便取消。

---

## 5. 音频 tap 重复安装会抛 ObjC 异常

**现象**

`AudioRecorder.startRecording()` 无条件 `installTap`，`stopRecording()` 无条件 `removeTap`。
一旦 `startListening` 因竞态被重入，就会重复安装 tap → AVFoundation 抛异常崩溃；
重复 removeTap 也会走到未安装的分支。

**修复**

`isRecording` 纳入锁保护：`startRecording` 已录制则直接返回（幂等），
`stopRecording` 未录制则返回空数组、不 removeTap；VAD 处理与 `reset()` 之间加 `vadLock`；
tap 回调先检查 active 标志，停止后立即返回。

---

## 6. 空格键监听吞掉文本框输入

`NSEvent.addLocalMonitorForEvents(matching: .keyDown)` 对 keyCode 49（空格）`return nil`，
会在设置面板的 `TextField` 里把空格吞掉（打不出空格，反而触发播放/暂停）。

**修复**

先判断 `NSApp.keyWindow?.firstResponder is NSTextView`，正在编辑文本时不拦截；
同时保存 monitor 句柄，`deinit` 时移除。

---

## 7. `MPRemoteCommandCenter` 命令能力与 `nowPlayingInfo` 速率不一致

* 注销了 `changePlaybackPosition` / `like` / `dislike` / `bookmark` 的 handler 后仍 `isEnabled = true`，
  等同于向系统宣称支持却什么都不做；现统一设为 `false`（不支持的不要注册）。
* keep-alive 每 0.5s 把 `PlaybackRate` 强制写回 1.0，即使已 `.paused`，会让系统认为仍在播放。
  现根据 `playbackState` 决定 rate 与是否推进 elapsed time。

---

## 8. 蓝牙耳机（EDIFIER X Fit）的按键只走 AVRCP/MediaRemote，且必须先当上 Now Playing App

**实测（`scripts/HeadsetMonitor.swift`）**

* 耳机按键**不会**产生 HID 输入、`NX_SYSDEFINED` 或 NSEvent 系统事件；
  唯一来源是 `MPRemoteCommandCenter` 的 `play` / `pause` / `nextTrack`。
* 同一时间键盘事件能被 CGEventTap 正常记录，所以不是权限问题。
* 手势映射（用带悬浮窗 HUD 的版本逐条确认）：
  **单击（左/右）❌ 无任何事件**；**双击（左/右）✅ `play/pause`**；
  左耳三击 ❌ 无事件；**右耳三击 ✅ `nextTrack`**（Idle 时撤销上一轮；进行中切 TTS 语速）。
* 注意：不要只靠日志时间戳去猜手势——最初的推断就把单击误判成了 `play/pause`。
  一定要让用户看着"每条命令 +1"的 HUD 逐条确认。

**结论**

1. 这类耳机**只有 App 是 Now Playing App 时**才能收到按键；一旦丢掉 Now Playing，按键全灭。
   所以 `MPNowPlayingInfoCenter` 的 info/state 必须持续保持，且 keep-alive 用的静音
   `AVAudioEngine` 必须是 output-only、不能被录音 tap 污染，并要能自愈重启。
2. 旧实现把录音引擎和伪装播放引擎合成一个：`installTap` 让麦克风常开，蓝牙在 A2DP/HFP
   之间来回切，keep-alive 引擎在设备重配时挂掉 → 丢 Now Playing → "有时候按了没反应"。
   现改为录音使用独立 engine，并在 `stopRecording()` 里 `engine.stop()` 释放麦克风。
3. 不要因为"暂停了"就把 `playbackState` 设成 `.paused`：本 App 是语音助手，必须持续
   接收按键。`pingNowPlaying` 每 0.5s 重新断言 `.playing` 并重启挂掉的 keep-alive 引擎。
4. 这只耳机的**单击不会发送任何事件**，属于耳机固件行为，软件层无法修复；可用手势是
   **双击**（主操作）和**右耳三击**（`nextTrack` → TTS 语速）。左耳三击同样无事件。
   诊断脚本可用于确认任意耳机的行为。
5. 切换 TTS 语速时不要 `stopSpeaking` 后重播 `pendingSentence`：那只是"还没说出口的 token 缓冲"，
   不是正在朗读的句子；会丢句子，而且清空计数后可能再也回不到监听。现在用显式句子队列
   （`ttsQueue` + `currentlySpeakingText`），切速时把当前句放回队首重播。

---

## 9. 配置优先级 + 后端切换不持久 + 失败静默 → "切到 llamacpp 后怎么说都没反应"

**现象**

录音、ASR 都正常（日志里有 `USER:`），但 `generating` 后 0.3s 直接 `inactive`，没有任何回复；
重启后换成 llamacpp 依旧如此。

**根因**

1. `AppConfig.load()` 的查找顺序是 `~/.config/my-llama-speech-assistant/config.json` **优先**于
   项目里的 `config.json`。用户界面里的 backend 切换（`applyBackendSettings`）原来**只改内存**，
   不写回配置；所以每次重启又回到 `~/.config` 里的 `opencode`。
2. 该机器上 opencode 服务（`127.0.0.1:9999`）当时没在运行。`ensureOpencodeServer()` 启动
   `opencode serve` 后固定 `sleep 3s`，健康检查失败也**不中止**，继续发请求 → 连接失败 →
   `onComplete()` → 直接回 Idle。日志里的 3 秒空档就是这段 sleep。
3. 失败只 `print` 到 stdout，界面既不显示 `errorMessage` 也不显示 `debugInfo`，所以看起来像
   "没反应/崩溃"。

**修复**

* `AppConfig.save()`：`applyBackendSettings()` 把当前 backend/URL 写回
  `~/.config/my-llama-speech-assistant/config.json`，重启后保持选择。
* `ensureOpencodeServer()` 返回 `Bool`；服务不可用时 `sendToOpencode` 直接报错并停在 Idle，
  不再假装发请求。
* ContentView 增加 `statusBanner`：优先显示 `errorMessage`，其次 `loadingStatus`，否则
  `debugInfo`。后端/模型/撤销/语速等状态现在都可见。
* 空回复也会报错（`llama.cpp/opencode returned no text`），不再静默。
* 关键诊断写入会话日志：`[AudioRecorder]`（输入格式、首帧、样本数、peak）、`[VAD]`、
  `ASR:`、`PIPELINE:`、`[LlamaCpp]` / `[Opencode]`（URL、HTTP 状态、错误体）。
* 用户机器上的 `~/.config` 已改为 `"backend": "llamacpp"`（llama.cpp 8080 实测可用）。

**排查顺序（下次遇到类似问题）**

1. 看界面顶部 `statusBanner` 的错误文字。
2. 看最新 `~/source/ai_talk_ideas/conversation_*.log`：有没有 `ASR:`、`PIPELINE: audio=...`、
   `[LlamaCpp] HTTP ...`。
3. 直接 `curl -s http://127.0.0.1:8080/v1/models` 确认后端；opencode 则
   `curl -s http://127.0.0.1:9999/global/health`。

---

## 10. `swift build` 不带 `-sectcreate` → 二进制缺少内嵌 Info.plist → 麦克风静默失效

**现象**

界面一直停在 `listening`，日志里只有：

```
[AudioRecorder] input format=<AVAudioFormat ... 1 ch, 16000 Hz, Float32>
[AudioRecorder] engine started
[AudioRecorder] capture started (AVAudioEngine tap)
（之后没有 TAP / VAD / 任何状态变化）
```

即 `AVAudioEngine` 能启动，但 input tap **一次回调都没有**。用户会以为"崩溃了/没反应"，
实际上要等 `maxRecordingDuration`（默认 60s）才会自动停。

**原因**

`Sources/Info.plist` 里有 `NSMicrophoneUsageDescription`，`build.sh` 通过
`-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Sources/Info.plist`
把它嵌进可执行文件。用普通 `swift build` 重新链接时**没有带这些参数**，内嵌 section 就消失了：

```bash
otool -s __TEXT __info_plist .build/debug/MyLlamaSpeechAssistant
# 修复前：只有一行文件名，没有 "Contents of (__TEXT,__info_plist) section"
```

没有 `NSMicrophoneUsageDescription` 时，macOS 不会弹权限框，也不会把麦克风数据交给进程，
但 `AVAudioEngine.start()` 仍然返回成功 —— 于是表现为"启动正常、永远收不到音频"。
（每次 `codesign -s -` 重新签名还会改变代码身份，TCC 授权可能被重置，更容易踩到。）

**修复**

```bash
swift build --disable-sandbox --build-system native \
  -Xlinker -sectcreate -Xlinker __TEXT \
  -Xlinker __info_plist -Xlinker Sources/Info.plist
codesign --entitlements Sources/LlamaStreamingDemo.entitlements --force -s - \
  .build/debug/MyLlamaSpeechAssistant
otool -s __TEXT __info_plist .build/debug/MyLlamaSpeechAssistant   # 必须能看到 section 内容
```

`build.sh` 已补上 `--build-system native`（默认 swiftbuild 会因 mlx-swift Metal kernel 失败）。
另外 `ViewModel.ensureMicrophonePermission()` 现在会显式检查 `AVCaptureDevice.authorizationStatus`
并在 `.notDetermined` 时请求权限；被拒绝时界面顶部会显示红色错误。

**排查口诀**：`listening` 卡住 + 没有 `TAP: first callback` → 先查内嵌 Info.plist，再查
系统设置里的麦克风授权。
