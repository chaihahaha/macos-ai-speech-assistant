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
