# Copilot 原型进度

2026-11-17，分支 `main`。当前交付 P0 录音诊断及本地转写原型，不是已完成的会议 Copilot。

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
- 不调用 TTS；停止时恢复原先的助手偏好。卡片是否触发固件音效尚待佩戴实测。

## 验证结果

- iPhone arm64 签名构建成功，并更新安装到用户的 iPhone 16 Pro Max，Bundle ID `dev.jasonpan.myvudemo`。
- 5 项音频/唤起测试通过：真实 Opus 编解码/复位、多帧和截断消息、2,501 帧持续处理、WAV 文件头与容量边界，以及手机唤起命令的消息格式。
- 43 项相关已有 AI 流程、麦克风拆包、VAD 和 WAV 回归测试通过。完整旧套件存在既有的单行截图 PNG 测试失败；本轮未修改该测试或实现。
- iPhone 实机自测通过：将约 8.92 秒的本地生成英语 Opus 样本解码后交给 Apple SpeechAnalyzer，识别为：

  > The project deadline is next Friday. The budget is $20,000. Please clarify who owns implementation and ongoing support.

  该自测不访问真实麦克风、不播放音频、不上传录音。它验证解码和端侧识别，不证明眼镜麦克风或持续 BLE 收音通过。

- 构建日志、设备诊断和录音留在本地，不在公开仓库中。
- 生成样本：`scripts/make-copilot-fixture.py`；libopus 可重复构建及校验：`scripts/build-opus.sh`、`Vendor/README.md`。

## 仍须验证

用户首轮实测指出眼镜上没有助手菜单或按钮。检查发现初版只等待触发，还关闭了语音唤醒。已改为开始时发送官方手机端唤起助手的 code 110，并保留原唤醒设置；增加重试按钮和请求/响应状态。此协议入口在本台眼镜上的效果尚待验证，不能记为眼镜实机测试通过。

1. XGA010C 实际麦克风音频能否通过 code 109 到达并正确解码。
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
