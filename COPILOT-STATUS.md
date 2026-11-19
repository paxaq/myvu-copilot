# Copilot 原型进度

2026-11-17，分支 `main`。当前交付 P0 录音诊断及本地转写原型，不是已完成的会议 Copilot。默认音频来源已改为眼镜 Transcribe 功能入口（实验）。

## 提示改为固定 30 秒节奏（build 12）

用户要求：提示保持固定节奏，每 30 秒一次。build 12 已签名构建并安装到 iPhone，未实测。

- **轮次：**会话开始 30 秒后第一轮，之后每 30 秒一轮，固定网格，不随时钟抖动漂移。轮次到了即消耗，不顺延。
- **跳过条件：**这 30 秒里新增不足 3 个识别词（静音）或眼镜音频断流超过 8 秒时，这一轮不出提示；静音不结束会话。
- **生成：**Apple Intelligence 每轮必须给出一句追问（去掉了“不值得问”的选项）。模型出错、没给出或被过滤（重复、过长等）时，用离线规则补上：先找关键词缺口，再按顺序用 8 条通用追问，每条一场会话只用一次。
- **显示：**优先等 1.5 秒停顿，最多等 4 秒就显示；卡片 10 秒后消失；两张卡至少隔 20 秒；没在本轮显示的提示在下一轮开始时作废。
- 手机界面去掉了“Check every”选项，改为显示“Hint every 30 s”。
- 测试：`CopilotLogicTests` 等 54 项通过，日志 `test-hint-cadence.log`；构建日志 `build-hint-cadence.log`。

## 停止命令和句子分隔（build 11）

依据国际版 1.0.11.53 固件逆向，build 11 改了两处，均未上机实测：

- 手机主动停止时，在 52 END 之后先发 68（TRANS_EXIT，无 data），再发 65。固件里 68 进入 `PStopMsg`，在转写运行中调用 `stopTrans`；65 在这个固件里是无效命令，保留只为兼容其他固件。
- 定稿字幕（type 0）去掉末尾空白后补一个空格，避免固件把前后两句直接拼在一起。中间结果不加。空句仍发空字符串。
- 测试：`TranscribeChannelTests` 10 项通过（含新增的分隔符和 68 停止用例）；iPhone 签名 build 11 构建成功并已安装，待眼镜实测。

## 字幕回显改用眼镜固件格式（build 10）

**build 9 实测（2026-11-18，6 次）**：
- 格式 A 发出 25 + 4 条，格式 B 发出 4 条，眼镜都没有回错误，界面也不显示文字；只有镜片卡片能显示。
- 音频稳定：0 解码错误，最长断流 0.15 秒。
- Apple Intelligence 显示可用，但 6 次都没有出提示卡；报告当时没记录检查结果，无法判断原因。

**固件逆向（只读静态分析，未刷写）**：
- 样本：国际版 `intl-1.0.11.53-platform_tester.bin`，位于仓库外的 `diagnostics/official-app/firmware-research/`。眼镜不是 Android，转写界面是编进这个固件的 LVGL C++ 程序。
- 字符串的运行地址 = 文件偏移 + `0x3BFD7CB0`：147 个源码路径字符串全部对上。代码通过 PC 相对字面量池引用字符串；整个镜像没有 MOVW/MOVT 取址。
- 53 号消息的解析器 `Pages/Translation/message/phone/PResultMsg.cpp`，文件偏移约 `0x54FBAC`：
  1. 解析 `data`，先取 `dst` 再取 `src`。
  2. 每个都是对象：`content` 是字符串，`type` 是数字，`type == 0` 表示定稿（日志里的 `commit`），非 0 是仍在变化的中间结果。
  3. **有 `dst` 时忽略 `src`**；字段缺失或类型不对时静默丢弃。
  4. 文字交给 `updateView`（`0x54B930`）。
- `updateView`：
  - 只在两种视图状态下绘制，推测是 Listening/Running，我们发的 RUNNING 应当满足。
  - 配置字节 0 是 `transType`。TRANSCRIBE（1）时文字进主文本区。
  - 文本控件一次最多解码 0x580（1,408）个字符。
- 结论：格式 A、B 的 `src`/`dst` 是字符串或用了别的键名，所以被丢弃。

**build 10 改动**：
- 只保留固件格式：`{"src":{"content":"<当前整句>","type":1}}` 表示中间结果，`type:0` 表示定稿。不带 `dst`；单条 `content` 上限 1,000 字符，超长时保留最新部分。
- Copilot 页的字幕选项改为「Transcribe view (streaming)」（默认）、Lens card、Off。
- 诊断报告新增 `hintChecks`：每次提示检查的结果，只记状态，不记转写或提示文字。
- 未验证：
  - 眼镜已改刷国际版固件（版本号未核对）；格式来自国际版 1.0.11.53，要以实测为准。
  - 固件文本控件（`lv_textview`）：中间结果写在已定稿文字之后、替换上一条中间结果并加 "..."；定稿推进且保留，最多 1,408 字符滚动。没看到固件在句子之间插入分隔符，定稿句子可能粘连，待实测。
  - 固件里 msgCmd 65（停止时发的 PHONE_TRANS_SERVER_EXIT）是无效命令，被忽略；68 会让眼镜调用 `stopTrans`。手机主动停止时可能需要补发 68，待实测。
  - 中间结果是替换当前行还是追加，按「整句替换、定稿后换行」实现，仍待实测确认。

## Copilot 提示与字幕回显（build 9，未实测）

**字幕回显**：识别文字通过 TRANS_REMOTE_RESULT（53）发回眼镜的转写界面。
- 中间结果每秒最多约 3 次，最终结果全部发送，每句最终结果递增 segId。
- 官方手机端转发的是 ASR 服务原始 JSON（`AsrTtsResult.asrJson`），眼镜端解析器尚未恢复，所以提供两种已恢复的格式供实测选择（build 10 已证实两者都不对，见上节）：
  - 格式 A：`TranslationData`，即 `bg / ed / segId / src / dst / isEnd / type / biz`。
  - 格式 B：讯飞实时转写 `TranscribedData`，即 `cn.st.rt[].ws[].cw[].w`、`type "0"/"1"`、`seg_id`。
- 另有「镜片卡片」兜底，与提示卡片共用通知显示。
- 诊断报告只记字幕条数，不保存文字。

**Copilot 提示**：
- `MyvuAI/Copilot`（纯逻辑，有单元测试）：
  - `ConversationMemory`：最近 3 分钟原文，加上更早内容的结构化摘要（主题、事实、决定、未决问题、行动项）。
  - `HintScheduler`（build 12 起改为固定 30 秒节奏，见顶部；以下为旧规则）：检查周期 30 / 60 / 120 秒，至少 30 秒的讲话后才首次检查。每个周期最多出 1 张卡，需要至少 12 个新词；在自然停顿 1.5 秒后显示，连续讲话超过一个周期也允许显示；待显示的提示 90 秒后作废。问句限 4–18 个词；与已出过的提示去重；音频断流超过 8 秒时不检查、不出卡。**静音只是不产生新词，不会结束会话，也不会出卡。**
  - `RuleBasedHintEngine`：离线兜底，覆盖缺期限、缺预算范围、缺成功标准、缺负责人四类缺口。
- `AppleIntelligenceCopilot`（App，iOS 26+）：
  - 使用 Foundation Models 端侧模型，以 `@Generable` 结构化输出生成「是否值得问、问题、理由、依据、优先级」和会议笔记。
  - 每次请求新开 `LanguageModelSession`，控制上下文长度；指令中声明转写内容只是数据，不是给模型的指令。
  - 模型不可用或请求失败时，改用规则兜底。
  - 数据不离开 iPhone。
- 提示用固定 id 的镜片卡片显示 10 秒，新卡替换旧卡，不堆叠，不播报。
- Copilot 页可以填写会话目标、开关提示、选择引擎和检查周期，查看引擎状态、最近一次检查结果、已显示的提示（含理由和依据）和会议笔记。
- 诊断报告只记录提示数量和引擎状态。

测试：
- MyvuAI 52 项（新增 9 项 Copilot 逻辑测试）、MyvuAudio 16 项（新增字幕格式测试）均通过。
- build 9 已签名并安装。眼镜字幕格式是否被接受、Apple Intelligence 在本机的可用性和提示质量，都还没有实测。

## 转写通道（build 8）：iPhone 已收到眼镜转写音频

**build 8 实测（报告 `D25E45DD…`，2026-11-17）**
- **握手**：
  1. 手机发 `open_app`。
  2. 0.98 秒：眼镜请求启动 TranslationService。
  3. 1.60 秒：手机发 52 PREPARING / RUNNING 和 61。
  4. 2.03 秒：手机再次发 `open_app`。
  5. 2.14 秒：眼镜回 TRANS_CLICK_START。
  6. 手机回 52 PREPARING，2.46 秒回 RUNNING 和 **RECORD_STATE start（51）**。
  7. 2.78 秒：首个音频到达。

  build 7 少了 51，眼镜进入了转写但不送音频，所以 51 START 是开麦条件。
- **音频**：
  - 只有 TRANS_REMOTE_AUDIO（msgCmd 4），StMessage 从 `com.upuphone.ar.translation.glasses` 发往 `com.upuphone.ar.translation.phone`，走 BLE external relay（category 3、msgType 3、appUniteCode 1）。
  - 每条消息的 binary 字段是 **一个 240 字节的 Opus 包**，解码后为 960 样本，即 16 kHz 单声道 60 ms（32 kbps）。
  - 2.7–43.9 秒共收到 688 条，解码 41.28 秒音频，与墙上时间一致。最长收包间隔 0.12 秒，损坏和解码错误均为 0。
  - 最高帧 RMS −18.8 dBFS。
  - 近端音频（msgCmd 3）没有出现，与官方 App 只在通话翻译中使用它一致。
- **端侧转写**：Apple 转写返回 6 次结果、2 段最终结果。准确率尚未人工核对。
- **与 Copilot 的关系**：
  - 讲话期间显示和清除测试卡片，音频没有中断。
  - 本次没有保存 WAV。
  - 自带能量 VAD 记录的讲话段数为 0，与实际有语音不符，需要用保存的 WAV 核查阈值。
- **尚未验证**：静音 2 分钟后是否继续送音（官方手机端在静音 5 分钟时可能主动停止，眼镜端是否另有超时未知）、10 分钟以上的长时运行、锁屏和后台。


**build 7 实测：眼镜成功进入转写，但没有音频。**
- 时序（报告 `2B4CDE89…`）：0.33 秒眼镜请求启动 TranslationService → 0.94 秒手机发 52 PREPARING / RUNNING 和 61 → 1.36 秒再次 `open_app` → 1.47 秒收到 TRANS_CLICK_START → 手机回 52 PREPARING / RUNNING。
- 用户确认眼镜进入了转写界面。这是 iPhone 首次让眼镜转写场景启动成功。
- 在 68 秒内，转写包名下没有收到任何 msgCmd 3 / 4 音频消息，其他控制消息也没有。

**build 8**（排查音频去向）：
- `MyvuClient` 新增不含内容的入站探针，记录每个 BLE 载荷的通道、种类、category、msgType、appUniteCode、包名、命令号和大小。报告和界面里按类别汇总显示（「Inbound traffic」）。
- RUNNING 之后补发 RECORD_STATE START（51），检验眼镜是否在等手机录音状态才开麦。
- 已安装，尚未实测。


**build 6 实测**：
- 眼镜在 1.71 秒请求启动 TranslationService，手机在 2.35 秒自动发出 61。此后约 100 秒，眼镜没有再发任何消息，未进入转写，也没有音频。
- 由此判断，单发 61 不能触发开始。build 5 唯一一次得到 TRANS_CLICK_START，是在「52 PREPARING / RUNNING、61」之后又发了一次 `open_app`，眼镜在 0.08 秒后回应。

**build 7**：
- 收到启动请求 0.6 秒后，自动重放上述顺序：52 PREPARING、52 RUNNING、61，0.4 秒后再发一次带 `InitPhone2GlassInfo` 的 `open_app`。
- 眼镜没回应时，每 3.5 秒重试一次，最多 3 次。
- 已安装，尚未实测。


**build 5 实测**：
- 手机发 `open_app`（`com.upuphone.ar.translation.glasses`）后 0.3 秒，眼镜通过 RunAsOne type 11 请求启动 `com.upuphone.star.launcher@com.upuphone.ar.translation.phone.TranslationService`，SDK 已应答。之后眼镜停在「进入 Transcribe」，等手机服务回应。
- 手动从 `translation.phone` 发出 TRANS_START（61）后约 0.1 秒内，眼镜回了 TRANS_CLICK_START（1），带 `{"transType":1,"dst":"en","src":"en","callState":0,"wechatReply":false}`。
- build 5 的 2 秒重试节流把这次 1 跳过了，没有回 RUNNING，眼镜仍卡在进入状态。全程没有收到音频。

**build 6**：
- 看到眼镜请求启动 TranslationService 后 0.6 秒，自动发 61。
- 每次收到 1 / 11 都回 52 PREPARING，0.3 秒后回 RUNNING，只合并 250 毫秒内的重复请求。
- 已安装，尚未实测。


**build 4 实测（2026-11-17）**：眼镜进不了转写。报告显示，响应的是 `com.upuphone.ar.translation.glasses`（翻译应用，`transType` 1 即转写），不是 `com.upuphone.ar.transcribe.glasses`。翻译应用在约 5.8 秒时发出 TRANS_EXIT（7），之前没有发过别的消息。build 4 发出的 `open_app` 和 61 / 51 包名都错了，手机也没有回任何状态，两路都没有收到音频。

**build 5 修正**（依据官方翻译模块的 `InterConnectHelper`、`BleAudioHelper`、`TranslationManager` 及状态常量）：
- 包名对改为手机端 `com.upuphone.ar.translation.phone` → 眼镜端 `com.upuphone.ar.translation.glasses`。
- `open_app` 打开翻译应用，扩展参数用 `InitPhone2GlassInfo`。
- 收到 1 / 11 后，回 TRANS_STATE（52）PREPARING（3），再回 RUNNING（4），不再自动发 61 / 51。
- Stop 时发 52 END（2）和 65（build 11 起在 65 前补发 68）。
- 自动选择音频流时优先远端（4）：官方 App 把这一路送进降噪和识别；近端（3）只用于通话翻译。
- 官方手机端在静音 2 秒、5 秒、5 分钟时上报 mute，并可能在 5 分钟时停止。这些属于手机端策略，本 App 不发送。

build 5 已签名并安装，尚未实测。

以下为 build 4 的原始设计说明（包名部分已被上面的修正取代）。


按用户要求，Copilot 默认改走眼镜自带的 Transcribe（转写）功能入口，而不是助手 code 110 / 109。助手通道保留为对照选项。

- `GlassTranscribe`（MyvuCore）：转写模块独立的 `{"msgCmd":Int,"data":String}` 消息。命令号、`StartTrans` / `PreTranslationEntity` / `RecordStateEntity` 字段名，以及 `open_app` 场景启动方式，均取自官方中国区 Android 2.49.24 的转写和翻译模块（翻译模块的 `InterConnectHelper` 方法体基本可读）。
- `MyvuClient.subscribeToAppMessages`：按包名订阅 StMessage（`2:src, 3:dst, 4:json, 5:bytes`）。带二进制字段的匹配消息不进文本日志和 JSON 扫描。
- `TranscribeChannelCapture`（MyvuAudio）：
  - 可选从手机发送 `open_app`（`com.upuphone.ar.transcribe.glasses`），也可由佩戴者在眼镜菜单里打开 Transcribe。
  - 收到 GLASS_SERVER_START_COMPLETE（11）或 TRANS_CLICK_START（1）后，发送 TRANS_START（61，transType 1，en→en）和 RECORD_STATE start（51）。
  - 解码 TRANS_PROXIMAL_AUDIO（3）/ TRANS_REMOTE_AUDIO（4）。
  - 收到 TRANS_EXIT（7）时回 68 并结束。
  - 静音不结束会话，也不自动重开；超过 3 秒无音频只标记 stall。会话上限 30 分钟。
- `TranscribeAudioDecoder`：音频封装未从静态代码恢复。依次尝试 2 字节大端长度分帧 Opus、每条消息单个 Opus 包（需连续 3 次成功才认定）；都不行就报告 `undecodable`，不猜测为 PCM。打开 WAV 保存时，同时保存原始二进制载荷（`*.transcribe.bin`，上限 8 MB），供离线分析。
- 诊断：报告记录双向控制消息（不含音频、识别结果或回复文本，单条最多 160 字符）、眼镜实际使用的包名、两路音频的格式/包数/时长/音量、最长间隙和讲话段数。

**未恢复、需实机确认的部分**：`TransInterConnectManager` 的发送方法仍是受保护空桩，所以 StMessage 包名对（目前默认双向都用 `com.upuphone.ar.transcribe.glasses`；一旦眼镜发来消息，就改用其反向包名）、握手顺序、51 / 55 的必要性、音频编码，以及 `open_app` 能否在缺少经典蓝牙音频链路的 iOS 上打开转写场景，都还没有设备证据。眼镜若在没有识别结果（53 / 54）回传时自动退出，也需要实测判断。

测试：新增 7 项 `TranscribeChannelTests`，与原有 7 项音频测试、43 项相关回归测试一同通过；MyvuCore 230 项测试通过（跳过既有截图测试 1 项）。iPhone arm64 签名 build 4 编译成功，**尚未安装、未实机测试**。

## 已实现

- Connect 页和 Settings 页新增 Conversation Copilot 入口。
- 手动开始/停止，最长 10 分钟的诊断会话；开始时发送手机唤起助手的 `code:110`，等待眼镜触发/音频响应。没有自动发送未经验证的持续监听延长命令。
- 独立音频订阅，音频在专用队列处理，不阻塞 BLE；不替换原助手回调。开始测试前先关闭原助手，测试中禁止启动原助手。
- 使用官方 libopus 1.6.1 解码 16 kHz 单声道音频；按 2 字节大端长度拆包，损坏消息不进行部分解码。
- 不积累完整音频帧数组；计数不受旧版 2,000 帧缓存上限影响。
- 显示会话时长、解码音频时长、帧数、收包数、音量、末次收包间隔、损坏消息及解码错误。断流超过 3 秒明确提示，不伪装为持续收音。
- WAV 保存可选且默认关闭；启用时流式写本地文件，停止后补写文件头，可导出。诊断报告不包含转写正文或录音内容。
- Apple SpeechAnalyzer / SpeechTranscriber 本地英语转写；可预备/下载语言模型。只接收解码后的眼镜音频，不启用手机麦克风，也不回退到云端语音识别。
- 单独的固定英文测试卡片，10 秒后清除，用于人工检查显示是否打断音频。
- 新增不含内容的有界时间线：麦克风请求、助手触发/释放、首次音频、VAD、断流/恢复、卡片显示/清除请求；报告最长音频间隙及转写结果次数。仅在实际发过卡片后清除，避免停止时发送无关清除请求。
- 不调用 TTS；停止时恢复原先的助手偏好。卡片是否触发固件音效尚待佩戴实测。
- 修正开始时强制关闭 Continuous Conversation 的行为，改为保留用户选择；诊断页及报告记录本次请求值（不代表眼镜确认）。仍关闭助手文字、播报输出。用户后续反馈打开后仍约 30 秒停止；具体原因继续核查。

## 验证结果

- iPhone arm64 签名构建成功，并更新安装到用户的 iPhone 16 Pro Max，Bundle ID `dev.jasonpan.myvudemo`。
- 7 项音频/唤起/时序/偏好测试通过：真实 Opus 编解码/复位、多帧和截断消息、2,501 帧持续处理、WAV 文件头与容量边界、手机唤起消息格式、显示标记与尾部断流及日志容量边界，以及连续对话开/关均保留且不启用播报。
- 43 项相关已有 AI 流程、麦克风拆包、VAD 和 WAV 回归测试通过。完整旧套件存在既有的单行截图 PNG 测试失败；本轮未修改该测试或实现。
- iPhone 实机自测通过：将约 8.92 秒的本地生成英语 Opus 样本解码后交给 Apple SpeechAnalyzer，识别为：

  > The project deadline is next Friday. The budget is $20,000. Please clarify who owns implementation and ongoing support.

  该自测不访问真实麦克风、不播放音频、不上传录音。它验证解码和端侧识别，不证明眼镜麦克风或持续 BLE 收音通过。

- 构建日志、设备诊断和录音留在本地，不在公开仓库中。
- 时间线及连续对话偏好修正已通过签名构建并安装到 iPhone（测试构建 3）；早期两份报告来自增强前版本，不含逐事件时间线。
- 后续眼镜实测已收到真实 code 109 音频。两份本地报告分别为 531 / 494 帧、31.86 / 29.64 秒解码音频，损坏消息和解码错误均为 0；停止时已断流约 38 秒。此证据证明接收和解码，不证明语音可懂度或转写正确。
- 用户反馈：卡片约 10 秒消失后眼镜回到主界面，帧数不再增长，也未见英语转写。关闭本地转写、全程不显示卡片的对照测试同样在约 30 秒停止增长。因此卡片清除不是断流的唯一原因，仍不能认定同步显示通过。
- 早期约 30 秒测试期间，Copilot 开始时会强制发送连续对话关闭。因此早期结果只覆盖该配置，不能推广为所有助手模式的固定时限。
- 构建 3 的后续报告确认连续对话请求为 On：收到 488 帧、29.28 秒解码音频，解码/损坏错误均为 0；末次音频在开始后 30.020 秒，紧接着收到 `control:0` 助手释放事件，约 33.251 秒标记断流，用户在约 64.619 秒 Stop。该轮没有 `speechDetected`，最高帧 RMS 仅约 −51.7 dBFS，转写结果次数为 0。报告同时记录本地转写打开及卡片显示/清除（约 4.418 / 14.501 秒），所以不是无转写、无卡片的完全对照，也不能据此认定固定录音上限或卡片导致退出。
- 随后约 10 秒样本已隔离转写和显示：连续对话请求 On、转写 Off、无卡片；收到 151 帧、9.06 秒音频，WAV 为 16 kHz / 单声道 / 16-bit PCM，无解码和损坏错误；约 2.009 秒触发 `speechDetected`，至用户约 9.788 秒 Stop 前仍有音频，最长收包间隔约 89 ms。该样本整体 RMS 约 −33.1 dBFS，最高帧 RMS 约 −22.5 dBFS，证明此前的低音量/未检出语音不是每次发生。它尚不能验证长时收音或真实英语转写。
- 将上述真实 9.06 秒录音用相同 `AppleSpeechTranscriber` 实现在 Mac 上离线回放（60 ms 块，按音频时长投递），得到 20 次识别更新、3 段最终结果、共 11 个最终词；未人工评估准确率。这补充验证真实眼镜音频可以被 Apple 端侧模型处理，但运行主机为 Mac，不替代 iPhone 实时识别验证。录音、文字及独立检查工具均留本地，不提交公开仓库。
- 生成样本：`scripts/make-copilot-fixture.py`；libopus 可重复构建及校验：`scripts/build-opus.sh`、`Vendor/README.md`。

## 仍须验证

用户明确要求无人讲话时仍保持 Copilot 运行：保留会话和上下文，恢复讲话后自动继续，不依赖持续发声或用户再次唤醒。当前助手通道尚未通过此要求；后续先研究退出机制和专用转写通道，再安排「讲话—静音—再讲话」验收，不以持续朗读作为产品保活方案。

用户首轮实测指出眼镜上没有助手菜单或按钮。检查发现初版只等待触发，还关闭了语音唤醒。已改为开始时发送官方手机端唤起助手的 code 110，并保留原唤醒设置；增加重试按钮和请求/响应状态。后续已接通音频，但尚未区分是手机请求单独生效，还是实体键回退生效。

1. 真实眼镜音频是否可听懂，以及为何未见英语转写；生成样本通过不能替代此项。
2. 单次收音能否超过原问答时限，并持续 10 分钟；统计中的音频时长应和墙上时长分别看，不能只凭计数增长认定没有断流。
3. 显示卡片时是否继续收音、是否有音效，以及远端谈话者的录音清晰度。
4. 锁屏/后台、断线恢复、耗电。原型不承诺这些已通过。

设备验证通过后，进入会话记忆、信息缺口分析、定时追问及完整静默提示；当前没有自动分析谈话内容。

## 手动测试

1. 退出官方 App，让 Android 断开眼镜，在 MyvuDemos 的 Connect 页连到 Ready。
2. 打开 Conversation Copilot，先关闭本地转写、启用保存 WAV；点 Start microphone test。
3. Start 会请求唤起眼镜麦克风。若没有响应，可按住右侧镜腿下方实体电源键约 1 秒再松开（不是触控区长按），出现语音动画后读英语约 20 秒。观察帧数和音量，点 Stop。
4. 如音频正常，再开启本地转写重复测试；测试中点 Show a test hint for 10 seconds，观察音频是否连续。
5. 文件在 Files → On My iPhone → MyvuDemos → CopilotDiagnostics，可从页面直接导出。WAV 不填充断流时的静音，需配合诊断时长比较。

开发自测：用 `--copilot-self-test` 启动 Debug App；仅此显式参数会运行生成样本，结果写入 `Documents/CopilotDiagnostics/self-test.json`。正常启动没有自动录音。

## 手机端唤起指令的依据

此前恢复的官方中国区 Android 2.49.24 DEX 中，`AppComponent` 广播接收器处理 `LAUNCH_AI_ASSISTANT_ACTION` 时，调用公共通讯层发送 code 110、payload null；命令常量名为 `CODE_LAUNCH_GLASS_ASSISTANT`。本轮用 REA 再次对该方法完成静态反编译核对。该证据证明官方手机代码有这一入口，不证明眼镜当前固件一定执行成功。

原始 APK、恢复的 DEX 及完整 REA 证据留在本地，未发布到本仓库。手机端实现仅复用该已观察到的协议消息，不把 code 3（眼镜启动请求）或 code 4（手机确认）当作启动命令。

## 持续收音的下一条路径

官方 Android 翻译/转写模块使用独立的 `msgCmd + data` 协议。已观察到 `InterConnectMsgCmd.Phone2Glass` 中的 `TRANS_START=61`、`RECORD_STATE=51`、`TRANS_STATE=52`、`TRANS_SERVER_RUNNING_STATE=55`；眼镜侧声明近端/远端音频消息，`StartTrans` 包含语言、模式及初始化状态。它与助手 `code + payload` 的录音流程不同。现阶段只有静态声明，不能从中断言某一命令已可直接在 iPhone 启动长时录音。

本轮 REA 声明证据：`ev_ac75616dfec22b83b20df8a7a3d63818ddf3b9484c324b0782dfb2adc7a409d7`。另核对 `ResetVrListeningTimeCmdHandler.handle`，发现 code 124 是手机接收后重置手机计时器的处理器，不能按名称把它当作手机发给眼镜的保活命令：`ev_c8497c2ff1ccc71d622e28583bc2137ac812802316887c843725dade0db819ef`。

这些证据来自分析用恢复 DEX 容器，属于静态派生证据，不是原始 APK 签名或运行验证；部分转写方法恢复为桩，完整握手、音频封装和 iOS 兼容性仍未恢复。优先研究专用转写通道，并记录精确断流时间；不自动循环唤醒助手，不把重启间隙描述为连续录音。
