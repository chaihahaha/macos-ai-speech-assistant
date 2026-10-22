# MEMO.md — 项目记忆 / 进度 / 决策

本文件记录待办、用户要求、背景、当前进度与关键决策。按 AGENTS.md 第 4 节约定维护。

---

## 当前任务：修复 mediakey 异步逻辑（已完成，待用户验证）

### 用户诉求

> mediakey 相关异步逻辑有很多 bug，导致 mediakey 很多时候会因为录音状态或其他状态无法打断，
> 导致 mediakey 按键不生效。请彻查并修复。

### 根因清单（已全部修复）

| # | 问题 | 影响 | 位置 |
| --- | --- | --- | --- |
| 1 | ASR 推理跑在主线程（`Task {}` 继承 `@MainActor`） | 转录期间主线程冻结，媒体键监听/Timer 全部停摆 | `ViewModel.processAndSend` |
| 2 | `.transcribing` 状态对 play/pause 直接 `break` | 识别阶段按键完全无效 | `ViewModel.handlePlayPause` |
| 3 | 延迟重启 Task 不可取消、无状态校验 | 停止/打断后又被"复活"，按键像没生效 | `startListening` / `interruptConversation` / `undoLastConversation` / TTS 完成回调 |
| 4 | opencode 在途请求无法中止，晚到的 `onComplete` 会追加回复并重启监听 | 打断后对话自动复活 | `OpencodeClient` / `sendToLlamaCpp` / `sendToOpencode` |
| 5 | 500ms 去抖在 ViewModel，吞掉真实连按 | 打断后再按停止无效 | `ViewModel.handlePlayPause` |
| 6 | 音频 tap 重复安装 / 重复移除 | 竞态下抛 ObjC 异常崩溃 | `AudioRecorder` |
| 7 | 空格键 monitor 吞掉 TextField 里的空格 | 设置面板无法输入空格 | `MediaKeyController.setupEventMonitors` |
| 8 | Now Playing keep-alive 强制 rate=1.0；无效命令仍 isEnabled | 暂停状态被系统误判，媒体键可能被路由走 | `MediaKeyController` |
| 9 | 录音引擎与伪装播放引擎是同一个 `AVAudioEngine`，停止录音时不 `engine.stop()` | 麦克风常开 → 蓝牙停留在 HFP；keep-alive 引擎在 A2DP/HFP 切换时挂掉 → 丢 Now Playing → 媒体键失效；TTS 走 HFP 可能完全听不到 | `AudioRecorder` / `ViewModel.loadModels` |
| 10 | 停止会话时把 `playbackState` 设为 `.paused` | macOS 可能不再把媒体键投给本 App | `ViewModel.stopConversation` |
| 11 | `toggleTTSSpeed` 停掉当前朗读后只重播 `pendingSentence`（错误的 buffer），且清空计数后不再回到监听 | 三击可能卡在 `.speaking`，看起来"没反应" | `ViewModel.toggleTTSSpeed` |

### 真机诊断：EDIFIER X Fit（蓝牙）按键实测

用 `scripts/HeadsetMonitor.swift`（`binaries/HeadsetMonitor`）实测。先用日志时间戳推断、再用
带**悬浮窗 HUD** 的版本逐一手势确认（用户亲眼看到窗口计数 +1 的手势才算），结论：

* 该耳机**只通过蓝牙 AVRCP → MediaRemote** 传递按键；HID / `NX_SYSDEFINED` / NSEvent 通道
  **完全没有信号**（同一时间键盘事件能被 CGEventTap 正常捕获，排除权限问题）。
* 逐一手势对应关系（**已用 HUD 逐条确认，2026-10-21**）：

| 手势 | Mac 收到的命令 | 结果 |
| --- | --- | --- |
| 左耳单击 | **无任何事件** | ❌ 固件不发 |
| 左耳双击 | `pause` / `play` | ✅ |
| 左耳三击 | **无任何事件** | ❌ |
| 右耳单击 | **无任何事件** | ❌ 固件不发 |
| 右耳双击 | `pause` / `play` | ✅ |
| 右耳三击 | `nextTrack` | ✅ |

* 修正记录：最初按时间戳推断时把"单击"误当成了 `play/pause`；实际是**单击完全不发**，
  `play/pause` 来自**双击**（左右耳双击都发 `play/pause`，无法区分左右）。
  上一轮 24 个手势共 12 条事件的正确分解是：8 个双击 → 8 条 play/pause，
  4 个右耳三击 → 4 条 nextTrack，8 个单击 + 4 个左耳三击 → 0 条。
* 因此：**这只耳机的可用手势是"双击"（开始录音）和"右耳三击"（退出到 Idle）**。
  单击永远不会有反应，不是 App 的 bug。
* **右耳三击 = 退出到 Idle**（`handleTriplePress`）：
  * **Idle**：撤销上一轮对话（删除最后一条 user 消息及其后的 assistant 回复，并清掉 opencode
    会话，确保模型上下文里也不再包含被撤销的那轮）；仍停在 Idle。
  * **录音 / 等静默**：丢弃这段音频，直接 Idle。
  * **识别中**：丢弃识别结果，直接 Idle。
  * **生成中 / 生成未结束但 TTS 已开口**：立即停止朗读，但**让 LLM 继续生成完**，把完整
    assistant 文本写入历史后再 Idle；期间的 token 不再朗读。
  * **生成已完成、正在朗读**：停止朗读，保留已写入历史的文本，Idle。
* **TTS 语速固定为高速**（`config.json` 的 `tts.fastRate`，当前 1.3x），三击不再切语速。
  句子队列（`ttsQueue` + `currentlySpeakingText`）仍保留，用于一次只喂一句给
  `AVSpeechSynthesizer`、停止时不丢队列。
* **完成 = 自动进入下一轮**：正常回答播放完后，`finishTurn()` 置 `.inactive`，1.5s 后自动
  `startListening()`，接着听下一轮。
* **打断/撤销/三击退出 = 停在 Idle**：双击硬打断、右耳三击退出、Idle 下三击撤销后，
  都不自动重开录音；用户用双击手动开始下一轮。
* App 必须始终是 Now Playing App，这是该耳机按键唯一的投递路径；丢掉 Now Playing 就等于
  按键全灭。旧代码里"录音引擎 = 伪装播放引擎"导致麦克风常开、蓝牙在 A2DP/HFP 间切换、
  keep-alive 引擎挂掉 —— 这是"有时候双击也没反应"的真正原因。
* 右耳三击 = `nextTrack`，已改为与双击相同的会话开关（否则它会静默切换 TTS 语速，
  看起来就像"没反应"）。
* 左耳三击、左右单击在 Mac 侧收不到任何事件，**软件无法修复**；需在 EDIFIER Connect
  之类的厂商 App 里改手势分配，或接受该限制。

### 关键设计决策

* **generation 令牌**：`ViewModel.generation: UInt64` 单调递增。所有异步续体（延迟重启、VAD 回调、
  TTS 完成、LLM 完成、ASR 结果）捕获自己的 generation，不匹配即丢弃。这是"随时可打断"的核心机制。
* **取消上移到 MediaKeyController**：`fire(_:source:)` 统一收口 NSEvent(global/local) / MPRemote / Space，
  按 action 去抖 0.5s（沿用原实现的经验值）；ViewModel 不再去抖。
* **ASR 串行后台队列**：`ViewModel.asrQueue`，`Qwen3ASRModel` 非线程安全，必须串行。
* **打断语义**：`.transcribing/.generating/.speaking` → `interruptConversation()` →
  停止 TTS / 取消 LLM / 删除本轮未完成对话 → **停在 Idle**（不再自动重开录音）。
* **完成语义**：正常回答结束后 `finishTurn()` 置 `.inactive` 并 `scheduleStartListening(1.5s)`
  自动进入下一轮（对话循环）。打断/撤销不走这条路，停在 Idle。
* **只删本轮**：`currentTurnUserMessageID` 记录本轮 user 消息，打断时只删这一轮；
  在 `.transcribing` 阶段（user 消息还没落库）打断不会误删上一轮。
* **TTS 句子队列**：`ttsQueue` + `currentlySpeakingText`，一次只喂一句给
  `AVSpeechSynthesizer`；停止/退出时直接清空，不会卡在 `.speaking`。语速固定为 fastRate。
* **录音 engine 必须 input-only**：一旦在录音 engine 上连接静音 output player，AVAudioEngine
  会把 I/O 绑到输出设备（A2DP 44.1k），`inputNode.inputFormat` 变成 44.1k，tap 永不触发
  （即使 defaultInput 是 EDIFIER 16k）。现在录音 engine 不接 output。
* **capture stall watchdog**：录音中每 0.5s 检查 tap 回调是否有增长；0 回调 >1.0s 或
  已有回调但 >1.2s 无新回调 → teardown + 新 engine 重试（最多 3 次）。解决"第二轮只收到
  一个 buffer 就静默停止、界面卡 listening"。
* **录音期间不跑 output 引擎**：实践表明在输入引擎运行后再启动 output-only
  keep-alive 会导致不稳定（第二轮回调中断/主线程卡住）。现在录音期间只跑 input-only
  engine；`pingNowPlaying` 仍每 0.5s 重新断言 `nowPlayingInfo/playbackState`，但不重建
  output engine。停止录音后再 stop+restart output（回到 A2DP，TTS 可听）。
  待验证：录音期间右耳三击是否还能到达 App；若不行，需要另想退出方式。
* **不要再停 keep-alive 给 TTS 让路**：实测停掉静音 keep-alive 后 TTS 会完全听不到
  （只剩一下噪音）。TTS 与 keep-alive 共存时可听；第一句保留 `preUtteranceDelay=0.15` 以缓解
  开头吞字。
* **强制 HFP**：`AudioRoute.preferHFPForInput()` 在录音前把默认蓝牙输出的 nominal rate
  设成 16000，促使耳机重新协商 HFP；录音结束 `restoreOutputRate()` 恢复原采样率。
  这是针对"多轮后 16k 输入全 0、重试退到 44.1k"的最后软件手段。
* **耳机掉线/默认设备被抢**：`HeadsetManager`（IOBluetooth + CoreAudio）在启动、每次录音前、
  TTS 前、停止录音后把 EDIFIER 的输入/输出 pin 成系统默认；音频设备不在时用
  `openConnection()` 重连并等待；capture 失败自动 reconnect + 重试（最多 2 次）。
  这解决了"默认输入变成 Virtual Desktop Mic（静音）/ 默认输出变成 Mac 扬声器（TTS 听不到）/
  双击变 Siri"的一整类问题。
* **不要自动 close/open 蓝牙**：只在链路真断开时 `openConnection`；音频设备暂时缺失只等待。
  `pinDefaults` 仅在默认设备不同时 set。capture 失败做软重试（等待+重 pin+重试一次），
  不再拆连接，避免"反复断开重连"的提示音和更糟的设备状态。
* **持久 HFP 会话**：整个对话期间保持同一个 input-only engine（HFP），说完只
  `finishCapture()` 保留 engine/tap，下一轮 `resumeCapture()`；不再每轮 A2DP↔HFP 切换。
  TTS 在 HFP 里播放（通话音质）。只有 idle/打断/撤销才拆 engine 回 A2DP。
* **TTS 结束直接进 listening**：持久 HFP/AVCapture 会话已不需要重置蓝牙，`finishTurn()`
  不再经过 1.5s idle，直接 `startListening()`；三段回放验证 speaking → listening 无 inactive 间隔。
* **三击状态映射（最终）**：只有 **idle（A2DP）** 能收到 nextTrack → 撤销最近一轮；
  listening / waitingSilence / transcribing / generating / speaking 都是持久 HFP，
  耳机固件不发 AVRCP，事件到不了 App；已删除这些状态的三击分支（只保留 ignore 日志）。
  录音超时默认 **30s**。
* **录音时的三击不可行**：实测即使把静音 keep-alive 放内置扬声器、App 保持 Now Playing，
  录音（HFP）期间也收不到任何 AVRCP 事件 → 耳机固件在 HFP 下不发媒体键。该方案已回退
  （还会让 TTS 路由变噪音）。录音中退出只能用界面按钮。
* **VPIO 已回退**：`setVoiceProcessingEnabled(true)` 会把麦克风电平压到 0.000x，导致只识别
  一半/幻觉；不要再用。判断静音用整段 RMS（<0.003）而不是 peak。
* **等待期间继续采集**：VAD end 不再立刻 finishCapture；`onSpeechStarted` 取消发送并继续
  收集，避免一句话只识别前半段。
* **最终采集方案：AVCaptureSession**：AVAudioEngine 在这只耳机上无解（input-only 全 0、
  duplex 0 回调、VPIO 压电平）。AVCaptureSession（视频通话同款路径）实测 5 秒 250 buffer、
  peak 0.37。`AudioRecorder` 已重写为 AVCaptureSession，16k mono Float32，会话跨轮保持。
  不要再回到 AVAudioEngine/VPIO/duplex。
* **HFP 16k 全 0 → duplex**：input-only 不激活 SCO。现在在录音 engine 上再 attach 一个
  16k 单声道静音 player（volume 0，loop），让耳机看到双向流（等价通话）。日志打印
  duplex player/outputNode 格式；若 outputNode=44.1k 且 peak 仍 0，下一步强制 HFP 16k。
* **HFP 16k 全 0**：input-only engine 可能不激活 SCO；在 beginCapture 里先
  `inputNode.setVoiceProcessingEnabled(true)`（VPIO 通话路径）。日志确认
  `voice processing enabled`；若仍全 0，下一步加 16k 静音 player 做 duplex。
* **沉默≠麦克风故障**：已删除 `periodPeak==0` 的静音重试；只有 0 回调才重试。录音超时
  （可配置，设置面板）时若无语音（peak<0.003）直接回 idle；有语音才进 ASR。
* **设置面板**：TTS 语速 slider（tts.fastRate）和录音超时（vad.maxRecordingDuration）
  可在齿轮设置里改，Apply 持久化。
* **静音幻觉**：送 ASR 前要求 RMS ≥0.005 + ≥16 个 20ms 有声帧 + VAD 段 ≥0.15s；
  不满足直接 idle。实测语音 RMS 0.011–0.016/150+ 帧通过，白噪声（RMS≤0.0039/0 帧）拒绝。提示音：开始 Pop / 等待 Tink / 转写 Morse /
  超时 Basso，各一次，取消每秒倒计时音。
* **失败提示音**：capture 失败播 Basso、软重试进入 listening 播 Glass，避免用户干等。
* **驱动不可行**：macOS kext 已废弃/需关 SIP，DriverKit 不提供通用蓝牙音频/HFP 驱动；
  蓝牙音频由闭源 bluetoothd + coreaudiod 管理。HAL 虚拟声卡仍走同一蓝牙栈，无法绕过
  A2DP↔HFP 切换。要彻底消除切换只能换硬件形态（USB/2.4G 耳机或独立 mic/扬声器）。
* **TTS 诊断**：日志新增 `TTS-QUEUE` / `TTS-SPEAK` / `TTS-DONE`，用于确认是否有句子被丢弃
  或提前进入 Idle。
* **capture 重试**：每次尝试用新的 `AVAudioEngine`；0.9s 没有 tap 回调就 teardown、
  等 0.5s 重试（最多 3 次），并记录 `defaultInput`（设备/采样率）。全部失败走
  `onCaptureFailed` 显示错误。原因是蓝牙在 A2DP↔HFP 切换时可能绑定到 44.1k 的错误输入端点。
  见 PITFALL.md 第 12 节。
* **settle 延迟**：停掉 keep-alive 后立刻 start 录音引擎会挂起或 0 回调；`startListening`
  现在 `pauseKeepAliveForRecording()` → `Task.sleep(0.6s)` → 校验 generation/state → `startRecording()`。
* **配置持久化**：`applyBackendSettings()` 调用 `AppConfig.save()` 写回
  `~/.config/my-llama-speech-assistant/config.json`。此前 UI 里的 backend 切换只在内存生效，
  重启后又会回到 `~/.config` 的 `opencode`（而该机器上 opencode 服务没起），于是"切到 llamacpp
  后还是没反应"。用户机器上的 `~/.config` 已改为 `"backend": "llamacpp"`。
* **失败可见**：ContentView 增加 `statusBanner`（errorMessage > loadingStatus > debugInfo）；
  opencode 服务不可用时直接报错停在 Idle；llama.cpp/opencode 空回复也报错。
* **诊断入日志**：`[AudioRecorder]`（输入格式/首帧/样本数/peak）、`[VAD]`、`ASR:`、
  `PIPELINE:`、`[LlamaCpp]`/`[Opencode]`（URL/HTTP/错误体）都写入会话日志。

### 改动文件

* `Sources/MediaKeyController.swift` — 去抖收口、空格键、Now Playing 状态、命令开关
* `Sources/ViewModel.swift` — generation 状态机、可取消重启、ASR 后台化、回调校验
* `Sources/AudioRecorder.swift` — tap 生命周期幂等 + 线程安全
* `Sources/OpencodeClient.swift` — 新增 `cancelPending()`，修掉一个 Sendable 警告

### 验证

```bash
swift build --disable-sandbox --build-system native \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Sources/Info.plist
codesign --entitlements Sources/LlamaStreamingDemo.entitlements --force -s - .build/debug/MyLlamaSpeechAssistant
otool -s __TEXT __info_plist .build/debug/MyLlamaSpeechAssistant   # 必须能看到 section 内容
```

注意：
- 默认 `swift build` 会因 mlx-swift 的 Metal kernel 编译失败，见 `PITFALL.md` 第 1 节。
- **`-sectcreate` 参数不能省**：它把 `Sources/Info.plist`（含 `NSMicrophoneUsageDescription`）
  嵌进二进制；省掉后 `AVAudioEngine` 照常启动但 input tap 永远没有回调，界面会卡在
  `listening`。见 `PITFALL.md` 第 10 节。

### 待用户确认 / 后续可做

- [ ] 真机回归：双击开始/停止/打断；正常回答结束后自动进入下一轮；打断后停在 Idle；
      Idle 时右耳三击撤销上一轮；进行中右耳三击切语速。
- [ ] 多段语音：VAD 第一次 `speechEnded` 就停止录音并启动静默计时，句中停顿会提前结束录音，
      属于既有设计，如需连续采集需另行改造。
- [ ] `sendToOpencode` 里 `ensureOpencodeServer()` 最长会等 3s，这期间打断已可生效（generation 校验），
      但 UI 状态仍显示 `transcribing`。
- [ ] 撤销上一轮时会 `opencodeClient.reset()`：因为 opencode 的服务端会话无法只删最后一轮，
      这等于把服务端上下文整体丢弃（本地更早的消息仍保留在界面上）。如需保留更早上下文，
      需要 opencode 提供按消息删除/回滚的 API。

## 自动化三轮语音测试（已通过）

测试模式（生产代码内，env 开关）：

```bash
TEST_AUDIO_DIR="$PWD/audios" TEST_AUTO_START=1 ./.build/debug/MyLlamaSpeechAssistant
```

* `AudioRecorder.testAudioFiles` 非空时，用 `AVAudioFile` 读取每个 m4a，转成 16k mono，
  按实时 64ms/1024 sample 送入同一个 VAD/pipeline；文件尾追加 0.8s 静音触发 speechEnded。
* 第一轮后保持会话；自动 listening 时喂下一个文件；第 4 次 start 时文件耗尽 →
  `onTestFinished` 打印 transcript 并退出。
* 2026-10-22 实测三段测试音频文件，三轮全过：
  1. 姓名记忆
  2. 指代/回忆姓名
  3. 复述上一轮问题并统计消息数
* 日志：`~/source/ai_talk_ideas/conversation_*.log`；stdout 里有 `[TEST] files/feeding/transcript`。

注意：文件模式绕过物理麦克风，验证的是 VAD/ASR/LLM/TTS/状态机；物理麦克风路径已由
`scripts/avcapture_probe.swift`（AVCaptureSession，250 buffers/5s，peak 0.366）验证。
