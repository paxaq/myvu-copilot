# Copilot 专用 App：开发准备小结

日期：2026-11-19。依据：build 12 实机测试（XGA010C，国际版固件；用户确认功能正常）、两份新诊断报告、眼镜固件静态逆向。本文是从 MyvuDemo 原型转向独立 Copilot App 的起点；过程记录见 `COPILOT-STATUS.md`，交接见 `HANDOFF.md`。

## 1. 已在真机上跑通的能力

8 分 8 秒的一次完整会话（build 12）：

| 环节 | 结果 |
| --- | --- |
| 收音 | 从眼镜「转写」入口取音频。眼镜送来 remote 流 Opus，iPhone 解码；第 3.7 秒出第一帧音频，全程最长间隔 0.30 秒。 |
| 本地识别 | Apple SpeechAnalyzer 英语识别；49 段语音、55 句定稿，全部在手机本地。 |
| 眼镜实时字幕 | 识别文字流式显示在眼镜自带的转写画面，共发 139 条字幕消息。半句带「...」实时刷新，定稿后保留，句间补空格。 |
| Copilot 提示 | 每 30 秒一轮，共显示 14 张提示卡（镜片卡片，叠加在转写画面上可见），10 秒后消失。 |
| 静音 | 无人说话的轮次跳过，不结束会话（另一份 75 秒报告：两轮均记为「no new speech」）。 |
| 停止 | 手机停止：发 52 END → 68 → 65，眼镜退出转写。眼镜端退出：收到 7 后回 68，手机结束。 |
| 隐私 | 不录音（WAV 默认关闭），识别和提示都在手机端，不上传；报告只记统计和状态，不记正文。 |

## 2. 测试中暴露的问题（专用 App 要先解决）

1. **Apple Intelligence 的提示大量重复。** 报告保留了最后 14 轮：模型的建议只有 4 轮被采用，10 轮因与已显示的问题相似被过滤；其中 8 轮由内置规则补上，最后 2 轮（07:30、08:00）连规则问题也用完，没有提示。
   - 原因推测：同样的近期转写反复喂给模型，温度 0.2，只要一个答案。
   - 方向：一次生成 3 个候选再挑第一个不重复的；把已显示问题的约束写得更强；可在每轮只给「上一轮之后的新内容 + 摘要」；规则问题池扩充或允许长会话后循环。
2. **报告里的 `hintChecks` 只保留最后 40 条状态**，长会话的开头看不到。专用 App 应记录完整的每轮结果（只记状态，不记正文）。
3. **会话中途眼镜又发了一次 `TRANS_CLICK_START`**（可能是眼镜上暂停/继续），手机重新上报了运行状态，没有出错，但含义还没确认。
4. **锁屏/后台运行没验证。** 目前 App 只声明了 `bluetooth-central` 后台模式；手机锁屏或切到别的 App 时，语音识别和 Apple Intelligence 是否还能继续，必须实测。这决定了专用 App 的使用方式。
5. **单次会话上限 30 分钟**（`TranscribeChannelCapture` 的 `maximumDuration`），长会议需要实测后再定。
6. **电量和发热**：8 分钟测试未记录，长会话需要测。

## 3. 可以直接复用的代码

| 模块 | 内容 | 状态 |
| --- | --- | --- |
| `MyvuCore` | BLE 连接、配对、`MyvuClient`、应用消息通道、`GlassTranscribe`（转写协议构造与常量）、`LensCards`（镜片卡片） | Swift Package，可直接依赖 |
| `MyvuAudio` | `TranscribeChannelCapture`（转写入口收音、握手、字幕、停止）、Opus 解码（`COpus.xcframework`，保留 libopus 许可证）、`GlassesMicCapture`（助手通道，约 30 秒退出，仅作对照） | Swift Package |
| `MyvuAI/Copilot` | `ConversationMemory`（近期转写 + 摘要）、`HintScheduler`（30 秒固定节奏、过滤、停顿显示）、`RuleBasedHintEngine`（离线规则） | 纯逻辑，单元测试覆盖 |
| Demo 里的 Copilot | `AppleSpeechTranscriber`（SpeechAnalyzer）、`AppleIntelligenceCopilot`（Foundation Models，`@Generable`）、`CopilotAssistant`（提示编排）、`CopilotModel`（会话编排、字幕节流、报告）、`CopilotView`、`CopilotSelfTest` | 在 Demo 工程里，需要搬出 |
| Demo 的连接管理 | `GlassesModel` 的连接、配对、重连部分 | 和导航、天气、Spotify 等功能混在一起，要抽出精简版 |

建议：新增一个 package target（例如 `MyvuCopilot`，标注 iOS 26 可用性），把 Demo 里与 Copilot 有关的 6 个文件移进去，Demo 和专用 App 共用，避免两份代码分叉。

## 4. 协议要点（专用 App 需要的部分）

转写入口（眼镜端 `com.upuphone.ar.translation.glasses`，手机以 `com.upuphone.ar.translation.phone` 的身份应答）：

- **打开：** 向 Launcher 发 `open_app` 场景（`ext` 为字符串，含 `transType=1` 等）；iOS 上可能被忽略，用户也可以直接在眼镜菜单打开转写。
- **握手：** 眼镜请求启动手机端服务（type 11）→ 手机发 61 TRANS_START → 眼镜回 `TRANS_CLICK_START`/服务就绪 → 手机发 52 PREPARING、52 RUNNING、51 RECORD start。
- **音频：** 眼镜发 msgCmd 3（proximal）/ 4（remote），Opus 在消息二进制字段；实测用 remote 流。
- **字幕：** 53，`{"src":{"content":…,"type":…}}`；`type 0` 定稿、非 0 为半句；不要带 `dst`（带了会忽略 `src`）。固件文本最多约 1,408 字符滚动，App 侧单条上限 1,000。
- **停止：** 手机端 52 END → 68 → 65（国际版只认 68，65 为兼容保留）；眼镜端发 7 时手机回 68。
- **镜片卡片：** 固定 id 的 show/dismiss，新提示替换旧卡，不堆叠；在转写画面上可见。
- **备用显示方式（固件已确认，未实测）：** Toast（纯文字）、Dialog（标题/正文/提示语）、提词器分页、通知设置（显示时长、播报开关、亮屏）。
- **显示约束：** 640×480 面板；英文字体只有 32/36 号，卡片文字要短。

完整的固件协议表和函数位置在本地逆向报告里（不在仓库）。

## 5. 必须保留的产品规则

- 只给佩戴者看，不 TTS、不发提示音、不替用户说话；全部英文。
- 用户点 Start 才收音；正常启动不自动开麦。
- 静音必须保持会话，不能因安静而结束；只是不出新提示。
- 眼镜麦克风是默认来源；手机麦克风只能作为明确选择的备用，不得悄悄替换。
- 默认不保存原始音频；诊断报告不含转写正文和提示原文；真实录音、报告、签名和个人构建配置不提交。
- 音频断流超过 8 秒时不出提示，避免基于过时内容。

## 6. 专用 App 的建议结构

- **工程：** 同一仓库新增 App 工程（例如 `Apps/MyvuCopilot`），依赖本地 Swift Package；最低 iOS 26（SpeechAnalyzer 与 Foundation Models 需要），规则引擎作为不可用时的后备。
- **页面：**
  1. 连接：扫描、配对引导、连接状态、自动重连。
  2. 会话准备：目标、可选背景/议程/专有名词。
  3. 会话中：连接与音频健康、实时转写、提示历史、Pause/Resume/End。
  4. 会后：摘要（事实、决定、未决问题、行动项，`MemorySummary` 已有雏形），可复制或分享。
  5. 设置与诊断：字幕开关、提示开关、诊断报告导出。
- **去掉：** Demo 里的导航、天气、健康、Spotify、Uniden、联系人、OTA 等无关功能和对应权限说明。

## 7. 下一步优先级

1. **提交现有工作。** 自上次提交（`26b367f`）以来，build 9–12 的代码、测试和文档都还没提交。建议先提交，再开新工程。
2. 抽出 `MyvuCopilot` package target，Demo 改为依赖它，测试保持通过。
3. 建专用 App 骨架：连接 + 会话 + 提示 + 字幕，先达到 build 12 的同等功能。
4. 解决提示重复（第 2 节第 1 条），并把每轮结果完整写入报告。
5. 实测锁屏/后台、30 分钟以上长会话、电量。
6. 会后摘要、Pause/Resume。

## 8. 需要你决定的事

- 专用 App 放在本仓库，还是新建仓库。
- App 名称和 Bundle ID（当前 Demo 用的是开发用 ID）。
- 计划书里允许云端处理；目前全部在手机本地完成。专用 App 是否保持纯本地，还是给提示/摘要加可选的云端模型。
