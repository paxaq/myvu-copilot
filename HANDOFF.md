# MYVU Copilot 开发交接

更新：2026-11-17，America/Toronto。交接基线：`main` / `2ac8280`。

## 接手时先知道的事

当前处于 **P0 设备可行性验证**。真实眼镜音频已经能到达 iPhone 并解码；会议 Copilot 尚未实现完成。主要阻塞是眼镜助手收音在部分测试中约 30 秒退出，以及如何在无人讲话时保持收音待命。

用户最新要求是写交接文档。本轮没有新的 60 秒测试结果：上次邀请持续朗读时，用户明确补充了「没有声音也要保持 Copilot 运行」的产品要求。不要把这条回复记为测试完成，也不要把持续讲话作为产品保活方式。

先读 [AGENTS.md](AGENTS.md)、[README.md](README.md)、[开发计划](COPILOT-PLAN.md)、[实测进度](COPILOT-STATUS.md)。同一开发机的仓库父目录另有 `HANDOFF-LOCAL.md`，保存本机操作和私有证据位置，不提交公开仓库。

## 用户目标和边界

- 眼镜型号是 **XGA010C**，早期提到的 XGA010A 已由用户更正。
- 主要使用 iPhone；另有一台已做过官方 App 分析的 Android。
- 作为面对面谈话/会议助手：输入英语，提示全部为英语，优先发现遗漏信息和值得追问的问题。
- 只在镜片显示简短提示，不播报、不替用户发言。固件卡片音效是否存在仍需实测。
- 用户允许云端处理；当前优先 Apple 端侧英语转写，尚未实现云端服务或上下文推理。
- **静音时保留会话、上下文和收音待命；重新有人讲话后自动继续，无需再按键或唤醒。** 没有新信息时不重复提示，旧卡片按时清除。
- 手机页面计时继续、眼镜却停止送音，不算满足持续运行。自动反复重开助手及其录音空洞也不能伪装成通过。
- 原始音频默认不落盘，诊断 WAV 由用户显式开启；设备报告、真实录音/转写、凭据和签名配置不进入公开仓库。
- 当前开发不刷固件，不因本任务恢复此前的国际版固件/区域限制研究。

## 仓库和交付状态

- 当前仓库：[paxaq/myvu-copilot](https://github.com/paxaq/myvu-copilot)，分支 `main`，`origin` 为用户仓库。
- `upstream` 为 BimaPDev/SmartGlasses。初始代码是其提交 `01a374068fba8730b4b497a82bacfda730412428` 的源码快照，未保留完整上游历史。
- 相邻的旧 SmartGlasses 克隆保存早期原型；继续开发应使用本仓库。
- App 显示名称 **MyvuDemos**。最后安装到 iPhone 的签名测试版为 **build 3**；后续只有文档提交。
- UI：Connect → 连接到 Ready → Conversation Copilot；Settings 也有入口。
- Continuous Conversation 在 Settings → Voice Assistant。Copilot 使用开始测试时选定的值，诊断显示 `Continuous Conversation at start`；这是请求值，不是眼镜确认回执。

关键提交：

| 提交 | 内容 |
| --- | --- |
| `c17238a` | 手机发送 code 110 请求助手麦克风，保留唤醒设置及实体键回退说明 |
| `82216d5` | 有界时序诊断、断流统计，清除实际显示过的卡片 |
| `680775f` | 修正 Copilot 强制关闭 Continuous Conversation；50 项相关测试通过，安装 build 3 |
| `d6c6b54` | 记录连续对话打开后的测试，以及真实音频的 Mac 端侧转写结果 |
| `2ac8280` | 明确静音保持要求及验收条件 |

## 已验证和未验证

| 项目 | 证据与结论 | 限制 |
| --- | --- | --- |
| Opus 解码及 Apple 端侧识别 | iPhone 对内置 8.92 秒合成英语样本自测通过 | 不访问眼镜麦克风 |
| 真实眼镜音频 | 收到 code 109，能够拆包、解码并写 WAV | 帧数增长不等于语音清楚或持续收音通过 |
| build 3 短样本 | 151 帧 / 9.06 秒；16 kHz、单声道、16-bit PCM；约 2.009 秒触发语音检测；最长收包间隔约 89 ms；零损坏/解码错误 | 用户在约 9.788 秒主动 Stop；没有测试超过 30 秒 |
| 真实音频端侧转写 | 上述 WAV 在 **Mac** 用同一转写实现回放，得到 20 次更新、3 段最终结果、11 个最终词 | 未人工核对准确率，不能记为 iPhone 实时转写通过 |
| 显示 | 用户反馈测试卡片能显示，并在约 10 秒后消失 | 音效、长期显示与收音共存未通过 |
| 连续对话打开 | 用户反馈仍约 30 秒停止；新报告确认请求为 On | 该次未检出语音，且同时启用了转写和卡片，退出原因未隔离 |
| 静音保持、长期运行、后台 | 尚未通过 | 上下文记忆、定时 AI 追问尚未实现 |

### 约 30 秒退出：精确证据

早期连续对话被原型强制关闭，收到过 531 / 494 帧，即 31.86 / 29.64 秒音频。修复该设置后，另一次报告为：

- Continuous Conversation 请求 On，本地转写 On。
- 首音频约 0.801 秒；卡片显示/清除请求约 4.418 / 14.501 秒。
- 最后音频约 30.020 秒，累计 488 帧、29.28 秒解码音频；同一时刻附近收到 `control:0`。
- 约 33.251 秒记录断流，用户约 64.619 秒才 Stop。
- 没有 `speechDetected`，最高帧 RMS 约 −51.7 dBFS；转写结果次数为 0；零损坏/解码错误。

`control:0` 是 SDK 标记的助手释放/页面关闭信号，不包含已确定的退出原因。该次清除卡片后音频仍持续约 15 秒，不能只凭返回主界面的观感认定清卡直接关闭麦克风。也不能把约 30 秒泛化为硬件固定上限。

随后的短样本音量与语音检测正常（整体 RMS 约 −33.1 dBFS，最高帧 RMS 约 −22.5 dBFS）。低音量不是每次发生；在明确检测到讲话的长时场景、静音场景下为何退出，仍待定位。

## 当前实现地图

| 文件 | 接手关注点 |
| --- | --- |
| `Sources/MyvuAudio/GlassesMicCapture.swift` | 独立采集状态机、请求/确认、VAD 起点、断流、停止和偏好恢复 |
| `Sources/MyvuAudio/MicCaptureProcessor.swift` | protobuf field 5，2 字节大端长度分帧，流式解码/统计 |
| `Sources/MyvuAudio/LibOpusDecoder.swift` | libopus 1.6.1，16 kHz 单声道 PCM |
| `Sources/MyvuAudio/MicCaptureTimeline.swift` | 最多 128 个无内容事件，首次/末次音频与最长间隙 |
| `Sources/MyvuAudio/WaveFileWriter.swift` | 增量 WAV，停止时补文件头，默认容量对应 10 分钟 |
| `Sources/MyvuCore/MyvuClient.swift` | 独立队列音频订阅，保留原回调，避免争抢所有权 |
| `Sources/MyvuAI/AiProtocol.swift` | 助手命令及偏好消息 |
| `Sources/MyvuAI/VoiceActivity.swift` | 校准噪声的能量 VAD；不是官方原生 VAD |
| `Examples/MyvuDemo/MyvuDemo/Copilot/AppleSpeechTranscriber.swift` | iOS 26+ SpeechAnalyzer/SpeechTranscriber、格式转换、有限队列、最终结果处理 |
| `Examples/MyvuDemo/MyvuDemo/Copilot/CopilotModel.swift` | 采集/转写编排，报告及固定卡片；不是完整 CopilotEngine |
| `Examples/MyvuDemo/MyvuDemo/Copilot/CopilotView.swift` | 测试开关、统计、文字和导出入口 |
| `Examples/MyvuDemo/MyvuDemo/Copilot/CopilotSelfTest.swift` | 仅 Debug 显式启动参数运行合成样本自测 |
| `Examples/MyvuDemo/MyvuDemo/GlassesModel.swift` | `startCopilot` 先停止旧 AiSession，传入当前偏好 |
| `Tests/MyvuAudioTests/AudioCaptureTests.swift` | 7 项音频/时序/偏好测试 |

### 保留的状态机约束

1. Start 建立独立订阅，发送临时静默偏好，再发送 `{"code":110}` 请求助手。普通 App 启动不采集。
2. 收到真实 code 3/7 触发才创建 session ID 并发 code 4 确认；不伪造眼镜事件。
3. 真实语音起点发 code 104/type 1。Copilot 不因普通静音或 “stop/thanks” 等谈话内容结束会话，不发送 VAD end 来切断整场录音。
4. Continuous Conversation、唤醒等偏好现在保留用户选择；助手字幕、回复文字和播报在采集中关闭，停止时恢复原偏好。
5. 数据超过 3 秒未到会标记 stalled，不自动循环唤醒。600 秒上限是本原型诊断限制，不是已测得的固件能力。
6. Stop / 断开时取消订阅，发 106 close / 107 endTurn，结束 WAV 和转写；原 AiSession 与 Copilot 保持分离。

实际眼镜样本每个 Opus 包解码出 960 个样本（60 ms），不能沿用合成 fixture 的 20 ms 包时长估算。`frames` 只在解码成功后增长；`peakDB` 实际是最高帧 RMS dBFS，并非单个 PCM 样本峰值。

诊断 JSON 不保存正文或音频，记录事件、统计和转写结果次数。WAV 按收到的 PCM 拼接，不填补断流静音；判断覆盖率应同时看单调时钟时间线与解码时长。外层 startedAt 包含模型准备时间，精确收音比较使用 update 内 elapsed/wallDuration。

## 官方协议研究：可以复用什么

官方 Android App 的静态分析支持两套不同业务协议：

| 通道 | 已有证据 | 尚缺内容 |
| --- | --- | --- |
| 助手 `code + payload` | code 110 手机请求；3/7 眼镜触发；4 确认；109 音频 | 约 30 秒退出条件、长期/静音保持机制 |
| 翻译/转写 `msgCmd + data` | 61 启动、51 录音状态、52 翻译状态、55 服务状态；近端/远端音频声明；StartTrans 语言/模式/初始化字段 | 完整路由与启动握手、参数含义、音频封装、服务依赖、iOS 可用性 |

不要按数字名称猜方向：**code 124 已核对为手机侧接收处理后重置手机计时器，不能当作已验证的手机到眼镜保活命令。** 118 / 119 也没有被证实为可直接发送的持续录音方案。

本地 REA 证据已经导出并 reset；不要假定仍有活动 session。恢复 DEX 容器是分析产物，部分方法仍为桩；它不证明原 APK 签名真实性，也不等同运行观察。

关键证据 ID：

- 翻译/转写 Phone2Glass 常量：`ev_ac75616dfec22b83b20df8a7a3d63818ddf3b9484c324b0782dfb2adc7a409d7`。
- code 124 手机处理器：`ev_c8497c2ff1ccc71d622e28583bc2137ac812802316887c843725dade0db819ef`。
- code 110 官方 AppComponent 入口：`ev_086bc28162ea4c0df7e554658ad050b05ec72a2016d4baa986c28d71019ef5a4`。

原 APK、恢复源码、完整证据包、真实诊断和 WAV 均在公开仓库之外，位置见同机本地交接补充。

## 下一步建议与验收

1. 继续恢复官方转写/翻译专用会话：定位入口、目标/来源路由、初始化完成条件、录音状态、音频处理和停止闭环。必要时用 Android 官方 App 的受控运行 trace 对照；先检查设备是否仍连接，不复用旧 PID/地址。
2. 同时定位助手退出：将请求、确认、实际语音检测、`control:0`、末音频和手机停止操作分开。比较静音和实际讲话，避免直接认定固件硬时限或清卡原因。
3. 复用已保存音频确认 iPhone 端侧识别链路。Mac 离线检查已有结果，尚未有 App 内「回放转写保存录音」功能，勿把该本地工具误认作已交付功能。
4. 确定候选长会话通道后，安排一次有目的的「讲话 → 至少 2 分钟静音 → 再讲话」测试，再扩展到 10 分钟；无需用户重唤醒，量化空洞与识别延迟。2 分钟不是产品静音超时。
5. 验证显示/更新/清卡时收音继续且无声音；再测对面约 1–2 米讲话、锁屏/后台、断线、耗电。
6. P0 通过后进入 P1 持续转写，再做 P2 上下文记忆/缺口分析与提示调度。当前固定测试问题不是真实内容建议。

需要用户操作时，说明该次测试要排除的假设，尽量复用已有样本，不要求用户反复无目的朗读。手机麦克风只能作为明确选择的备用输入，不能默默替换后声称眼镜收音通过。

## 构建和验证

要求完整 Xcode。示例使用可替换环境变量，签名、设备 ID 和本机路径见本地补充，不提交个人配置。

```sh
export DEVELOPER_DIR="/path/to/Xcode.app/Contents/Developer"
export MYVU_BUILD_ROOT="/path/to/external/build-root"
bash build-myvu-ios.sh
swift test --filter 'AudioCaptureTests|GlassesMicStreamTests|VoiceActivityTests|AiSessionTests|WavTests' \
  --scratch-path "$MYVU_BUILD_ROOT/SwiftTests"
```

最近结果：7 项新测试 + 43 项相关上游回归测试通过，iPhone arm64 签名 build 3 成功且已安装。完整上游测试存在既有 `ShareAbilityTests.testPngFromOneBlankHudRow` 失败/崩溃；没有宣称全套通过。

设备自测参数 `--copilot-self-test` 仅使用内置合成 Opus 英语，结果写入 App 的 `Documents/CopilotDiagnostics/self-test.json`。正常启动不触发自测。

本次交接只新增文档，不修改或重新安装 App。继续改采集代码时，遵守 AGENTS.md 的目标测试和 iOS 构建要求，保留 MIT/libopus 许可证。
