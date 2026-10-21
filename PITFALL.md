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

---

## 11. 两个 AVAudioEngine：输出引擎先启动 → 输入 tap 永远收不到回调

**现象**

`[AudioRecorder] engine started` / `capture started` 之后**没有** `TAP: first callback`，
界面永远停在 `listening`。单独跑一个"只开输入"的 probe 却完全正常
（`callbacks=40, peak=0.09`），说明麦克风、权限、设备都没问题。

**复现（本机实测）**

1. 先启动一个 output-only 的 `AVAudioEngine`（播放静音循环，即 Now Playing keep-alive）；
2. 再创建**第二个** `AVAudioEngine`，`installTap` 到 inputNode，`start()`。

结果：`start()` 返回成功，但 `isRunning` 随后变成 `false`，4 秒内 **0 个 input 回调**，
两个引擎都停止。反过来（先输入、后输出）则一切正常。

**原因**

两个 engine 同时争用同一个音频设备；蓝牙 A2DP↔HFP 切换的窗口里，输出引擎先占住设备，
输入引擎静默失败（不抛错）。22:22 那次偶尔成功，是因为 keep-alive 引擎恰好在"重启之间的空档"，
输入抢到了设备。

**修复**

**任何时刻只允许一个 `AVAudioEngine` 运行**：

* 开始录音前：`MediaKeyController.pauseKeepAliveForRecording()` 停掉 output-only keep-alive 引擎。
* 录音引擎自带一个静音 `AVAudioPlayerNode`，让进程在录音期间仍然算 Now Playing，媒体键可用。
  **attach/connect/schedule 必须在 `engine.start()` 之前完成，`play()` 放在 start 之后**；
  在引擎运行中修改 graph 会卡死/崩溃（实测）。
* 停止录音后：录音引擎 `stop()` + `reset()`，再 `resumeKeepAliveAfterRecording()` 重建
  output-only keep-alive 引擎。
* `ViewModel.stopRecordingAndResumeKeepAlive()` 统一封装"停录音 + 恢复 keep-alive"。

**排查口诀**：`capture started` 但没有 `TAP: first callback` → 检查进程里是不是还有另一个 engine 在跑。

**补充：停止 keep-alive 后需要给音频设备约 0.5–1.5s 的 settle 时间**

停止 keep-alive 引擎后**立刻** `engine.start()` 录音引擎，会出现：

* `engine.start()` 直接挂住（实测 probe 卡死），或
* 返回成功但随后 0 个 input 回调（app 日志：`TAP` 缺失，直到 60s 超时）。

实测在停止 keep-alive 后等待 **0.5s / 1.5s** 都能稳定拿到 `callbacks=30`。因此
`ViewModel.startListening()` 现在：

1. `mediaKeys.pauseKeepAliveForRecording()`
2. `Task.sleep(0.6s)`（期间状态保持 `listening`）
3. 再次校验 `generation` 与 `state == .listening` 后才 `recorder.startRecording()`

用户在这 0.6s 内双击会走 `stopConversation`，generation 改变，延迟任务自动作废。

---

## 12. 第二轮录音绑定了错误的输入端点（44.1 kHz 而非耳机 16 kHz HFP）

**现象**

第一轮正常（`input format 1 ch, 16000 Hz`，有 `TAP`、`peak`）；第二轮：

```
[AudioRecorder] input format=<1 ch, 44100 Hz>
[AudioRecorder] engine started
[AudioRecorder] capture started
（没有 TAP: first callback，直到 maxRecordingDuration 60s 超时，0 samples）
```

**原因**

第一轮结束后 keep-alive/TTS 把蓝牙切回 A2DP；第二次录音时设备正在切回 HFP，
`AVAudioEngine` 可能先拿到一个陈旧的/错误的输入端点（44.1k），把 tap 装成 44.1k；
随后设备切到 16k，tap 与节点格式不再匹配，永远不触发。

**修复**

`AudioRecorder` 现在：

1. **每次 capture 尝试都新建 `AVAudioEngine()`**（不重用旧 engine 的格式/端点）。
2. **tap watchdog**：启动后 0.9s 内 `tapFireCount == 0` → teardown、等待 0.5s、用新 engine 重试，
   最多 3 次。
3. 每次尝试都记录 `defaultInput=<设备名 id 采样率>`，可直接看出是不是选错了设备。
4. 3 次都失败 → `onCaptureFailed` → 界面红色报错并停止，不再干等 60s。
5. `captureToken` 防止旧的 tap / 延迟重试在停止后继续写数据。

**排查口诀**：日志里 `input format` 的采样率不是 16000、或 `defaultInput` 不是耳机 →
输入端点选错了；看 `attempt 1/3 ... attempt 2/3 ...` 是否重试成功。

---

## 13. HFP 录音时耳机双击被固件映射成"语音助手"（Siri），App 收不到

**现象**

* Idle（A2DP）双击右耳：App 收到 `[MediaKeys] (MPRemote) playPause fired`，正常开始录音。
* 录音中（HFP，麦克风打开）双击右耳：直接唤起 Siri，App 日志**没有任何 `[MediaKeys]` 事件**。

**原因**

双击在 A2DP 音乐模式下是普通媒体键（AVRCP play/pause）；一旦进入 HFP 通话模式，耳机固件
把同一手势重新映射为 HFP 语音助手（AT+BVRA），macOS 直接交给 Siri。这个事件不走
`MPRemoteCommandCenter`，App 无法拦截，也无法"用同样方法"收到。

**处置**

* 已把"退出到 Idle"改为**右耳三击**（`nextTrack`，HFP 下通常仍是媒体命令），双击只负责开始。
  * 录音/等静默/识别中 → 丢弃音频或识别结果，直接 Idle。
  * 生成中 → 停止朗读，但等 LLM 生成完、把完整文本写入历史后再 Idle（不丢文本）。
  * 生成完成、朗读中 → 停止朗读，保留文本，Idle。
* TTS 语速固定为 `tts.fastRate`（高速），不再占用三击。
* 如果三击在 HFP 下也被 Siri 抢走，则只能：用界面停止按钮、在厂商 App 改通话模式手势、
  或换独立麦克风让耳机保持 A2DP。

---

## 14. 录音引擎一旦连接 output（静音 player），输入会被绑到 44.1 kHz 输出设备

**现象（第二轮）**

```
defaultInput=EDIFIER X Fit id=152 sr=16000
attempt 1/3 input=<1 ch, 44100 Hz> ... engine started ... no input callbacks
attempt 2/3 ... 44100 Hz ... no callbacks
attempt 3/3 ... 44100 Hz ... capture failed
```

即设备明明是对的 16 kHz 输入，`AVAudioEngine` 却报 44.1 kHz，tap 永不触发。

**原因**

录音 engine 上连接了一个静音 `AVAudioPlayerNode`（为了维持 Now Playing）。AVAudioEngine
会把整个 I/O 绑定到输出设备（A2DP 44.1k），于是 `inputNode.inputFormat` 变成 44.1k；而耳机
的麦克风只在 HFP 16k 下可用，于是 tap 静默失败。

**验证**

同样的 post-TTS/A2DP 状态：

* 录音 engine 带 output：input=44.1k，0 回调；
* **input-only** engine：input=16k，`callbacks=30`。

**修复**

1. `AudioRecorder` 改为 **input-only**（不再连接静音 player）。
2. 录音期间保持 Now Playing 改由**独立 output-only engine** 负责，但必须**在第一个 tap
   回调之后**才启动（input-first）。顺序反了会饿死输入；input-first 时 probe 显示输入回调
   持续正常。
   * `AudioRecorder.onFirstTap` → `MediaKeyController.startKeepAliveDuringRecording()`。
3. 停止录音：先停 input engine，再 `stopSilentPlayback()` + `startSilentPlayback()`
   重建 output（回到 A2DP，TTS 才能正常出声）。

**排查口诀**：`defaultInput` 对但 `input format` 是 44100 → 录音 engine 上是不是还挂着
output 节点。

**后续修正（重要）**：在输入引擎运行后再启动第二个 output-only engine 虽然 probe 看起来正常，
但在真实 App 里会让第二轮录音在首个 tap 之后中断/卡住（日志停在 `Silent playback stopped`）。
现在改为**录音期间只运行 input-only engine**，不再启动 output engine；`pingNowPlaying` 仍持续
断言 `nowPlayingInfo/playbackState`。停止录音后才重建 A2DP output engine。
代价：录音期间媒体键是否能路由到 App 需要实测；若不行，只能靠 UI 停止按钮 / 独立麦克风 /
厂商手势设置。

**再补充：输入引擎可能"只回调一次就静默停止"**

第二轮日志：

```
attempt 1/3 input=16 kHz ... engine started ... TAP: first callback
（之后没有 VAD / 没有任何日志，界面卡在 listening）
```

也就是说设备在 A2DP→HFP 的过渡中让引擎只交付了一个 buffer 就停了。旧 watchdog 只检查
"0 个回调"，`tapFireCount == 1` 就认为成功，因此永远不会重试。

现在 `AudioRecorder` 有 0.5s 周期的 stall watchdog：

* 0 回调超过 1.0s → 重试；
* 有回调但超过 1.2s 没有**新的**回调 → 判定输入已停，teardown、0.5s 后用**新
  `AVAudioEngine`** 重试（最多 3 次）；
* 全部失败 → `onCaptureFailed`，界面报错并停止。

这能覆盖"启动成功但中途静默死掉"的情况；日志会显示
`input stalled for X.Xs (callbacks=N); restarting capture` 以及后续 attempt 结果。

---

## 15. TTS/keep-alive 占着音频路由 → 下一轮 HFP 麦克风只出静音

**日志证据（第二轮）**

```
attempt 1/3 input=16 kHz ... TAP ... level taps=16 periodPeak=0.0000   ← 全是静音
attempt 2/3 input=44.1 kHz ... engineRunning=false                     ← 退到输出设备
attempt 3/3 input=44.1 kHz ... capture failed
```

默认输入、采样率都对，但 16 kHz 的输入数据**全是 0**；说明耳机没有真正进入 HFP 音频，
麦克风链路没建立。紧接着重试时引擎退回到 44.1 kHz 输出端点并停摆。

**原因**

上一轮回复结束后，`AVSpeechSynthesizer` 和静音 keep-alive 引擎仍在占用/切换输出路由；
下一轮打开输入时蓝牙没有切到 HFP，拿到的是空输入。

**修复**

1. TTS 开始前 `MediaKeyController.suspendKeepAliveForSpeech()`：停掉静音 keep-alive，
   让 `AVSpeechSynthesizer` 独占输出（同时避免它抢路由导致开头几个字被吞）。
2. 第一句加 `preUtteranceDelay = 0.15`，给蓝牙路由切换留时间。
3. 回复结束后 `enterIdle()` 里 `resumeKeepAliveAfterSpeech()` 重新起 keep-alive，并
   `resetSpeechSynthesizer()` **替换** synthesizer，释放它占用的音频单元/路由。
4. 录音引擎仍是 input-only；音频路由被释放后，下一轮的 16 kHz 输入应能拿到真实音频。

**补充：用 CoreAudio 强制蓝牙输出进入 16 kHz（HFP）**

多轮之后耳机可能不再自动进入 HFP：16 kHz 输入回调存在但全是 0，重试退到 44.1 kHz 后停摆。
`AudioRoute.preferHFPForInput()` 在停止 keep-alive 后、录音引擎启动前，把**默认蓝牙输出设备**
的 nominal sample rate 设为 16000（`kAudioDevicePropertyNominalSampleRate`），促使设备重新协商
HFP；停止录音后 `restoreOutputRate()` 恢复原采样率（通常 44.1 kHz）再重建 A2DP keep-alive。
日志会打印 `[AudioRoute] forcing HFP ...` / `restoring ...`。

注意：这是在系统层面短暂改变蓝牙输出采样率，会影响该设备上的其他音频；如果设备不支持或
恢复失败，需要改用独立麦克风 / 扬声器输出方案。

---

## 16. 耳机掉线后 macOS 把默认输入/输出切到虚拟设备 → 随机 capture failed / TTS 听不到 / 双击变 Siri

**决定性证据**

用户说蓝牙断开后，CoreAudio 设备列表里已经没有 EDIFIER，默认设备变成：

```
default input  = Virtual Desktop Mic (44.1 kHz)
default output = Mac mini扬声器
```

App 的 `defaultInput` 日志和录音引擎因此拿到的是**虚拟麦克风**（全静音）或 44.1 kHz 端点；
TTS 也被送到 Mac 扬声器（耳机里听不到）。耳机不在默认输出/Now Playing 上，
双击自然回到耳机固件的语音助手 → Siri。

重新用 IOBluetooth `openConnection()` 连接后，EDIFIER 的音频设备（input 152 / output 146）
回来；再把默认输入/输出 pin 到 EDIFIER，输入引擎立刻 `callbacks=30, peak=0.10`。

**修复：`HeadsetManager`（IOBluetooth + CoreAudio）**

* `pinDefaults()`：把名称含 EDIFIER 的输入/输出设备设为系统默认输入/输出。
* `ensureReady()`：若音频设备不在，则对已配对的耳机 `openConnection()`，轮询最多 10s 等
  音频设备出现并 pin。
* `reconnect()`：先 `closeConnection()` 再 `openConnection()`，用于 capture 失败后的硬重置。
* 接入点：
  * 启动：`pinDefaults()` + 异步 `ensureReady()`，成功后重建 keep-alive（保证 Now Playing 在耳机上）。
  * 每次录音前：`await ensureReady()`，失败则显示"Bluetooth headset not connected"而不是录虚拟麦克风。
  * 每次 TTS 前：`pinDefaults()`，避免回复被送到 Mac 扬声器。
  * 停止录音后：`pinDefaults()` 再恢复 A2DP keep-alive。
  * capture 失败：自动 `reconnect()` + 重试（最多 2 次）。
* Package 增加 `IOBluetooth` framework；Info.plist 增加 `NSBluetoothAlwaysUsageDescription`。

**注意**：如果耳机真的关机/超出范围，App 现在会明确报"蓝牙耳机未连接"，不会静默录虚拟麦克风。
虚拟音频软件（Immersed / Virtual Desktop）仍可能抢默认设备；App 在关键操作前会重新 pin。

**不要再自动 close/open 蓝牙连接（会制造"反复断开重连"）**

日志里 capture 失败后调用 `reconnect()`（closeConnection + openConnection），设备 ID 会变化
（214 → 250 → 283），而且重连后经常仍是 44.1 kHz / 0 回调，反而更糟；用户能听到反复断开/重连。

现在的策略：

* `ensureReady()` 只在**蓝牙链路本身断开**（`isConnected()==false`）时才 `openConnection()`；
  链路还在、只是音频设备暂时没注册时，**只等待**，不拆连接。
* `pinDefaults()` 先比较当前默认设备，只有不同才 set，避免无谓的重新配置/切换。
* capture 失败只做**软恢复**：等 1.5s、重新 pin、重试一次；不再 close/open 蓝牙。
* `reconnect()`（close/open）保留但不再自动调用；需要时由用户手动触发/重启 App。
* 耳机自身在 A2DP↔HFP 之间的切换提示音是固件/蓝牙协议行为，App/驱动无法消除；
  要完全避免只能在硬件上让耳机只承担一种角色（USB/2.4G 接收器，或独立麦克风/扬声器）。

---

## 17. 录音时不是 Now Playing → AVRCP 三击到不了 App

日志里整段只有启动时的 `(MPRemote) playPause fired`，录音期间的右耳三击没有任何
`nextTrack`/`previousTrack` 事件。原因是 `pauseKeepAliveForRecording()` 把静音 keep-alive
停了：没有音频在播放，macOS 不再把 App 当作 Now Playing，蓝牙 AVRCP 媒体键就不会路由过来
（HFP 下耳机按钮还可能被固件当成语音助手）。

**修复（待实测）**：录音期间把静音 keep-alive 放到 **Mac 内置扬声器**上（不是耳机，耳机在
HFP 里做麦克风），App 继续是 Now Playing，输入仍从耳机采；AI 声音不走扬声器（只是静音）。
停止录音时停掉扬声器 keep-alive、恢复原输出设备，再重建耳机 A2DP keep-alive。
`MediaKeyController.startRecordingKeepAliveOnSpeakers()` /
`stopRecordingKeepAliveAndRestoreOutput()`。若录音中三击仍无事件，说明耳机固件在 HFP 下
根本不发 AVRCP，只能改用界面按钮退出。

**提示音**：capture 失败/重试时用 `NSSound("Basso")`，软重试进入 listening 时用
`NSSound("Glass")`，让用户知道需要重说；提示音在恢复耳机输出之后播放。

**扬声器 keep-alive 方案失败（保持 Now Playing 但三击仍无事件，且 TTS 变噪音）**

实测日志：录音期间 `output -> built-in speakers` / `silent keep-alive on speakers` 已生效，
App 确实是 Now Playing，但整段仍然**没有任何 `[MediaKeys]` 事件**。结论：耳机在 HFP 通话
模式下固件根本不发送 AVRCP 的 nextTrack/previousTrack。保持 Now Playing 也无法收到"根本没
发出来的键"。

同时，录音结束后从扬声器切回耳机 A2DP 的路由状态会让 TTS 变成噪音。该方案已回退：
录音前仍 `pauseKeepAliveForRecording()`（停输出引擎），录音后 pin 耳机 + 重建 A2DP。
TTS 只恢复了可听；三击在录音期间作为退出手段不可行，只能用界面按钮。

---

## 18. 每轮 A2DP↔HFP 切换才是根因；改为整个会话保持 HFP

用户指出耳机能"一边播放一边麦克风"（视频通话）。这是对的，但那是 **HFP 双向音频**
（单声道/16 kHz）；A2DP 只能输出、不能带麦克风。所以"mic + 播放"必然在 HFP 里，
视频通话就是 HFP。App 之前每轮 TTS 用 A2DP、录音切 HFP，反复 profile 切换在这只耳机/
macOS 上不可靠（第二轮起 16k 静音、44.1k 停摆）。

**新架构（persistent HFP）**

* 第一轮录音时启动一次 input-only `AVAudioEngine`（进入 HFP）。
* 说完只 `finishCapture()`：停止收集样本，但**保留 engine + tap**，不 teardown。
* TTS 在这个 HFP 会话里播放（通话音质，非音乐音质），不再切 A2DP。
* 下一轮 `startListening()` 直接 `resumeCapture()` 复用同一个 engine/tap，
  完全没有 profile 切换。
* 只有真正离开会话（idle / 三击 / 打断 / 撤销）才 `stopRecording()` 拆 engine 并恢复
  A2DP keep-alive。
* `AudioRecorder` 新增 `isEngineRunning` / `finishCapture()` / `resumeCapture()`；
  `startRecording()` 检测到 engine 还在跑时自动 resume。
* 代价：会话期间 TTS 是 HFP 通话音质（16 kHz），麦克风一直开着（未收集时丢弃样本）。

三击在 HFP 下仍然收不到（固件不发 AVRCP，见 #17）；录音中退出只能用界面按钮。

**不要再把"用户沉默"当成麦克风故障**

持久 HFP 下用户可能长时间不说话，tap 回调仍在、数据全 0。旧的 `silent input` watchdog
把 `periodPeak==0` 当成输入端点失效，2 秒后 teardown + 重试；重试时设备退到 44.1k/0 回调，
最终 `capture failed` → 两次提示音 + "Bluetooth headset not connected"。已删除该静音重试：
只有 **0 个回调**（引擎真的死了）才重试；回调在跑、数据为 0 视为正常沉默。

录音超时现在：
* 默认 60s（`recordingTimeout`，设置面板可改）；
* 超时后如果整段音频 peak < 0.003（一直没说话），直接 `stopConversation` 回 idle，
  不再跑 ASR/LLM；有声音才进管线。

---

## 19. 静音时 VAD 假结束 → ASR 幻觉出英文，且永远不回 idle

现象：长时间不说话，App 会输入从未说过的英文句子，且一直不进 idle。

原因链：

1. Silero VAD 把环境噪声当成语音，触发 `onSpeechEnded`；
2. `onSpeechEnded` 立刻 `maxRecordingTimer.invalidate()`，真正的录音超时被取消；
3. 静音音频被送进 ASR；Qwen3-ASR 在静音上会"脑补"英文句子；
4. 幻觉文本进入 LLM → TTS → 自动再 listening，循环，永远 idle 不了。

修复：

* `onSpeechEnded` 先算 `pendingAudio` 的 peak；`peak < 0.005` 判定为假结束 →
  `SoundFeedback.timeout()` + `stopConversation()` 回 idle，**不送 ASR**。
* 录音超时路径同样检查 peak（<0.003）→ 直接 idle，不跑 ASR/LLM。
* 提示音改为：
  * 开始录音：`Pop` 一次；
  * 说完进入 waiting：`Tink` 一次；
  * 开始 transcribe：`Morse` 一次；
  * 超时/假结束回 idle：`Basso` 一次。
  删除了原先每秒一次的倒计时 `Tink`。

**HFP 输入 16 kHz 但全 0：input-only engine 没有激活 SCO**

日志：`attempt 1/3 input=1 ch, 16000 Hz`，tap 持续回调 60 秒，但每一行
`periodPeak=0.0000`；用户说话也没有任何峰值。即 HFP 输入端点存在，但麦克风的 SCO
音频链路没被激活。视频通话类 App 会打开 **voice processing**（VPIO，麦克风+输出，
即"通话"路径），这才会真正激活耳机麦克风。

修复：在 `AVAudioRecorder.beginCapture` 里，installTap 之前调用：

```swift
try inputNode.setVoiceProcessingEnabled(true)
```

这会启用 Apple 的 voice-processing IO（AEC/通话路径），让 HFP SCO 真正建立。
日志会打印 `[AudioRecorder] voice processing enabled`；若抛错会打印失败原因。
如果仍全 0，下一步是给 engine 接一个 16 kHz 的静音 player（duplex，模拟通话的双向流）。

---

## 20. VPIO 把麦克风电平压到接近 0；静音门限太低导致幻觉

启用 `setVoiceProcessingEnabled(true)` 后，日志里即使说话 `periodPeak` 也只有
0.0003–0.005（正常语音约 0.07），ASR 只能识别出"你好。"，60 秒静音 clip 的峰值恰好到
0.005，越过了 `peak < 0.005` 的门限，被送进 ASR → 幻觉出
`The heartbeat of the city.`。VPIO 已回退。

同时修了两个真 bug：

* **只识别一半**：VAD `onSpeechEnded` 时立刻 `finishCapture()`，之后 5 秒等待期间的
  语音全部丢弃。现在 waiting 期间**继续采集**；`onSpeechStarted` 时取消发送、继续收集，
  最终送 ASR 的是完整句子。
* **静音门限**：从 peak 0.005 改为整段 **RMS < 0.003** 判定无语音；60 秒噪声 clip 的
  RMS 远低于此，不会再进 ASR。
* 录音超时路径同样用 RMS < 0.002 直接回 idle。

---

## 21. input-only 无法激活耳机麦克风：加 duplex 静音输出

日志：16k 输入 tap 连续回调 60 秒，`periodPeak=0.0000`，超时正常回 idle。说明 HFP 输入
端点存在但没有 SCO 音频；input-only 引擎没有让耳机进入真正的双向通话。

修复：在同一个 `AVAudioEngine` 上，除了 input tap，再 attach 一个 `AVAudioPlayerNode`，
用 16 kHz 单声道格式连接到 `mainMixerNode`，循环播放**静音** buffer（volume 0）。
这样耳机同时看到输入和输出流，等价于通话 App 的双向 HFP，SCO 才会被激活。

日志会打印：

```
[AudioRecorder] duplex silent player format=<1 ch, 16000 Hz>, outputNode=<...>
```

然后看 `level periodPeak` 是否变成 0.0x。若 outputNode 仍是 44.1 kHz 且 peak 仍为 0，
下一步需要把耳机输出强制到 16 kHz/HFP（CoreAudio nominal rate）后再建 duplex engine。

---

## 22. 结论：AVAudioEngine 用不了这只耳机的 HFP 麦克风，改用 AVCaptureSession

系统性验证（同一只 EDIFIER、同样已 pin 到默认设备）：

| 方案 | 结果 |
| --- | --- |
| input-only AVAudioEngine | 16 kHz、tap 持续回调，但 `periodPeak` 全 0（SCO 没激活） |
| input+16k 静音 player（duplex） | outputNode 16 kHz，但 input **0 回调**（引擎互相饿死） |
| `setVoiceProcessingEnabled(true)` | 有回调，但电平被压到 0.0003–0.005，只识别半句/幻觉 |
| **AVCaptureSession** | **5 秒 250 个 buffer，peak 0.366** |

视频通话类 App 用的是 AVCaptureSession/系统通话路径，不是 AVAudioEngine。已把
`AudioRecorder` 重写为：

* `AVCaptureSession` + `AVCaptureDeviceInput`（显式选 EDIFIER）+ `AVCaptureAudioDataOutput`
* `audioSettings` 直接要 16 kHz、单声道、Float32
* delegate 回调里直接拿 PCM 送 VAD；首 buffer 时播 `Pop` 提示音
* 会话跨轮保持运行（`finishCapture` 不停 session，`startRecording` 复用），
  只有 idle/退出才 `stopRunning`
* 4 秒无首 buffer 才报 capture failed

不要再回到 AVAudioEngine / VPIO / duplex / 强制采样率这些路径。
