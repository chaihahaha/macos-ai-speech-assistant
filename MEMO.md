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
* 因此：**这只耳机的可用手势是"双击"（主操作/会话开关）和"右耳三击"（`nextTrack`）**。
  单击永远不会有反应，不是 App 的 bug。
* 右耳三击是**上下文相关**的（`handleTriplePress`）：
  * **Idle**：撤销上一轮对话（删除最后一条 user 消息及其后的 assistant 回复，并清掉 opencode
    会话，确保模型上下文里也不再包含被撤销的那轮）；仍停在 Idle。
  * **录音/识别/生成/朗读等任何进行中的状态**：切换 TTS 语速（0.5x ↔ 1.5x）。
    为避免切速时把整段朗读弄丢/卡死，TTS 改为显式句子队列：`ttsQueue` + `currentlySpeakingText`，
    一次只喂一句给 `AVSpeechSynthesizer`；切速时把当前句放回队首、用新语速重播，队列其余句子保留。
    未在朗读时用独立 `speedAnnouncer` 播"快/慢"作为反馈，界面底部也会显示当前倍速。
* **全程手动开始录音**：一轮回答结束、或被双击打断后，App 都停在 Idle，不再自动重新录音；
  用户用双击手动进入录音状态。
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
* **完成语义**：一轮回答结束后 `finishTurn()` 直接置 `.inactive` 并**停在 Idle**。
  用户用双击手动开始下一轮。这样"Idle 时右耳三击撤销上一轮"才随时可用。
* **只删本轮**：`currentTurnUserMessageID` 记录本轮 user 消息，打断时只删这一轮；
  在 `.transcribing` 阶段（user 消息还没落库）打断不会误删上一轮。
* **TTS 句子队列**：`ttsQueue` + `currentlySpeakingText`，一次只喂一句给
  `AVSpeechSynthesizer`。`toggleTTSSpeed()` 只把当前句放回队首并用新语速重播，保留其余队列；
  不再像旧实现那样 stop 后重播 `pendingSentence`（会丢句子、卡在 `.speaking`）。

### 改动文件

* `Sources/MediaKeyController.swift` — 去抖收口、空格键、Now Playing 状态、命令开关
* `Sources/ViewModel.swift` — generation 状态机、可取消重启、ASR 后台化、回调校验
* `Sources/AudioRecorder.swift` — tap 生命周期幂等 + 线程安全
* `Sources/OpencodeClient.swift` — 新增 `cancelPending()`，修掉一个 Sendable 警告

### 验证

```bash
swift build --disable-sandbox --build-system native   # exit 0，无 warning
```

注意：默认 `swift build` 会因 mlx-swift 的 Metal kernel 编译失败，见 `PITFALL.md` 第 1 节。

### 待用户确认 / 后续可做

- [ ] 真机回归：双击开始/停止/打断；回答结束后停在 Idle；Idle 时右耳三击撤销上一轮；
      进行中右耳三击切语速。
- [ ] 多段语音：VAD 第一次 `speechEnded` 就停止录音并启动静默计时，句中停顿会提前结束录音，
      属于既有设计，如需连续采集需另行改造。
- [ ] `sendToOpencode` 里 `ensureOpencodeServer()` 最长会等 3s，这期间打断已可生效（generation 校验），
      但 UI 状态仍显示 `transcribing`。
- [ ] 撤销上一轮时会 `opencodeClient.reset()`：因为 opencode 的服务端会话无法只删最后一轮，
      这等于把服务端上下文整体丢弃（本地更早的消息仍保留在界面上）。如需保留更早上下文，
      需要 opencode 提供按消息删除/回滚的 API。
