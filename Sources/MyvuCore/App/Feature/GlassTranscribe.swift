import Foundation

/// Transcription on the glasses, served by the glasses Translation app
/// (`com.upuphone.ar.translation.glasses`) in `transType` 1 ("transcribe").
///
/// Device evidence (build 4): with Transcribe opened on XGA010C, the only
/// sender was `com.upuphone.ar.translation.glasses`; it exited after ~6 s
/// when the phone answered nothing. The official phone module registers as
/// `com.upuphone.ar.translation.phone` (`InterConnectHelper.v`).
///
/// This is a separate command domain from the assistant's `code + payload`
/// messages: every JSON is `{"msgCmd":Int,"data":String?}`, where `data` is
/// itself a serialized JSON string (Gson `InterConnectMessage`).
///
/// Provenance (static, official China Android app 2.49.24): the msgCmd values,
/// the `StartTrans` / `PreTranslationEntity` / `RecordStateEntity` field names
/// and the `open_app` scene launch are recovered from the transcribe and
/// translation modules. The SEND routine (`TransInterConnectManager`) is a
/// protected stub, so the StMessage package pair, the order of the handshake
/// and the audio payload format are NOT recovered. Everything here that
/// depends on those is a best guess and is labelled so; capture code must
/// treat the inbound side as the source of truth.
public enum GlassTranscribe {
    public static let glassPackage = "com.upuphone.ar.translation.glasses"
    /// The phone-side identity the glasses app talks to.
    public static let phonePackage = "com.upuphone.ar.translation.phone"
    /// A separate Transcribe package exists in the launcher's app list, but
    /// on XGA010C it did not answer; kept for matching only.
    public static let transcribeGlassPackage = "com.upuphone.ar.transcribe.glasses"
    public static let defaultAppName = "Translation"

    /// Glasses → phone.
    public enum Glass2Phone {
        public static let clickStart = 1
        public static let proximalAudio = 3
        public static let remoteAudio = 4
        public static let exit = 7
        public static let serverStartComplete = 11
        public static let dialogDismiss = 12
        public static let assistantOpen = 14
        public static let assistantExit = 15
        public static let wechatReply = 16
        public static let wechatReplyEnd = 17
        public static let phoneOffhook = 18
        public static let phoneIdle = 19
        public static let phoneRinging = 20
        public static let screenState = 21

        public static func name(_ cmd: Int) -> String {
            switch cmd {
            case clickStart: return "TRANS_CLICK_START"
            case proximalAudio: return "TRANS_PROXIMAL_AUDIO"
            case remoteAudio: return "TRANS_REMOTE_AUDIO"
            case exit: return "TRANS_EXIT"
            case serverStartComplete: return "GLASS_SERVER_START_COMPLETE"
            case dialogDismiss: return "DIALOG_DISMISS"
            case assistantOpen: return "ASSISTANT_OPEN"
            case assistantExit: return "ASSISTANT_EXIT"
            case wechatReply: return "WECHAT_REPLY"
            case wechatReplyEnd: return "WECHAT_REPLY_END"
            case phoneOffhook: return "PHONE_STATE_OFFHOOK"
            case phoneIdle: return "PHONE_STATE_IDLE"
            case phoneRinging: return "PHONE_STATE_RINGING"
            case screenState: return "SCREEN_STATE"
            case BaseState.connect: return "CONNECT_STATE"
            case BaseState.disconnect: return "DISCONNECT_STATE"
            case BaseState.glassServiceExit: return "GLASS_SERVICE_EXIT"
            case BaseState.phoneServiceExit: return "PHONE_SERVICE_EXIT"
            default: return "msgCmd \(cmd)"
            }
        }
    }

    /// Phone → glasses.
    public enum Phone2Glass {
        public static let recordState = 51
        public static let transState = 52
        public static let remoteResult = 53
        public static let proximalResult = 54
        public static let serverRunningState = 55
        public static let subtitleSizeType = 57
        public static let subtitleSetType = 58
        public static let languageSet = 60
        public static let start = 61
        public static let dialogDismiss = 63
        public static let phoneServerExit = 65
        public static let saveSuccess = 66
        public static let exitAck = 68
        public static let screenTypeChange = 69
    }

    public enum BaseState {
        public static let connect = 101
        public static let disconnect = 102
        public static let glassServiceExit = 103
        public static let phoneServiceExit = 104
    }

    public enum RecordState {
        public static let initialized = 1
        public static let start = 2
        public static let stop = 3
        public static let release = 4
    }

    /// `TranslationStateAnno`, sent in TRANS_STATE (52).
    public enum TransState {
        public static let notStarted = 1
        public static let end = 2
        public static let preparing = 3
        public static let running = 4
        public static let listening = 5
        public static let stopping = 6
    }

    /// `TranslationExtCode`. Only `none` is sent here: the official phone app
    /// also reports mute (14/19/15) after 2 s / 5 s / 5 min of silence, which
    /// is a phone-side policy this app deliberately does not reproduce.
    public enum ExtCode {
        public static let none = -1
        public static let muteTwoSeconds = 14
        public static let muteFiveMinutes = 15
        public static let muteFiveSeconds = 19
    }

    public enum TranscribeType {
        public static let transcribe = 1
        public static let dialogTranscribe = 4
    }

    /// `TranslationVersionCode`: which service region the phone app runs.
    public enum ServiceVersion {
        public static let domestic = 1
        public static let international = 2
    }

    /// The `ext` of the scene launch: the translation module's
    /// `InitPhone2GlassInfo`. Field names are recovered; values are defaults
    /// chosen here, not observed traffic.
    public struct LaunchOptions: Sendable, Equatable {
        public var transType = TranscribeType.transcribe
        public var source = "en"
        public var destination = "en"
        public var subtitleSetType = 2      // MY_SUBTITLE_ORIGINAL_SHOW
        public var saveResult = 2           // NO_SYNC_RESULT
        public var serviceVersion = ServiceVersion.domestic
        public var versionCode = 0
        public init() {}
    }

    // MARK: - Builders

    /// `{"msgCmd":N,"data":"…"}`. Gson drops a null `data`, so it is omitted.
    public static func message(_ cmd: Int, data: String? = nil) -> String {
        var out = JsonObject()
        out.put("msgCmd", cmd)
        out.putIfPresent("data", data)
        return out.serialized()
    }

    /// The `open_app` scene launch, same envelope as the teleprompter and the
    /// official translation module (`startLauncherScene`). `ext` is a STRING.
    public static func buildOpenScene(_ options: LaunchOptions = LaunchOptions(),
                                      appName: String = defaultAppName) -> String {
        var ext = JsonObject()
        ext.put("dst", options.destination)
        ext.put("saveResult", options.saveResult)
        ext.put("src", options.source)
        ext.put("subtitleSetType", options.subtitleSetType)
        ext.put("transType", options.transType)
        ext.put("transVersionCode", options.serviceVersion)
        ext.put("versionCode", options.versionCode)

        var data = JsonObject()
        data.put("launchMode", "scene")
        data.put("action", "open_app")
        data.put("pkg", glassPackage)
        data.put("app_name", appName)
        data.put("ext", ext.serialized())

        var out = JsonObject()
        out.put("action", "app")
        out.put("data", data)
        return out.serialized()
    }

    /// TRANS_START (61) with a transcribe `StartTrans`.
    public static func buildStart(_ options: LaunchOptions = LaunchOptions(),
                                  phoneInitFinish: Bool = true,
                                  newSession: Bool = true) -> String {
        var start = JsonObject()
        start.put("callState", 0)
        start.put("dst", options.destination)
        start.put("isNewSession", newSession)
        start.put("phoneInitFinish", phoneInitFinish)
        start.put("src", options.source)
        start.put("transType", options.transType)
        start.put("wechatReply", false)
        return message(Phone2Glass.start, data: start.serialized())
    }

    /// TRANS_STATE (52): the phone's translation state machine, which the
    /// glasses app waits for after it starts.
    public static func buildTransState(_ state: Int, extCode: Int = ExtCode.none) -> String {
        var body = JsonObject()
        body.put("extCode", extCode)
        body.put("transState", state)
        return message(Phone2Glass.transState, data: body.serialized())
    }

    /// RECORD_STATE (51): the phone's recording state as the glasses see it.
    public static func buildRecordState(_ state: Int) -> String {
        var body = JsonObject()
        body.put("recordState", state)
        return message(Phone2Glass.recordState, data: body.serialized())
    }

    /// Longest `content` the glasses' text view takes from one message: its
    /// decoder stops after 0x580 (1,408) characters. Kept well under that.
    public static let subtitleCharacterLimit = 1_000

    /// One recognized line for the glasses' own Transcribe view
    /// (TRANS_REMOTE_RESULT, 53).
    ///
    /// Shape from the glasses firmware (`Pages/Translation/message/phone/
    /// PResultMsg.cpp`, intl 1.0.11.53): the parser reads `dst` then `src`, each
    /// an object with a string `content` and a number `type`; `type == 0`
    /// commits the line, anything else is a partial that is still changing. When
    /// `dst` is present `src` is ignored, so a transcript sends `src` only. In
    /// TRANSCRIBE mode the text goes to the main text view.
    /// - Parameters:
    ///   - text: the whole current sentence so far (partials are cumulative).
    ///   - committed: true for a final sentence.
    ///
    /// The text view appends each committed line straight after the previous
    /// one with no separator, so a committed line ends with one space; the next
    /// partial is drawn after it.
    public static func buildSubtitle(_ text: String, committed: Bool) -> String {
        var body = text
        if committed {
            while body.last?.isWhitespace == true { body.removeLast() }
            if !body.isEmpty { body += " " }
        }
        let content = body.count > subtitleCharacterLimit ? String(body.suffix(subtitleCharacterLimit)) : body
        var line = JsonObject()
        line.put("content", content)
        line.put("type", committed ? 0 : 1)
        var data = JsonObject()
        data.put("src", line)
        return message(Phone2Glass.remoteResult, data: data.serialized())
    }

    /// TRANS_EXIT (68), no data. The firmware's `PStopMsg` calls `stopTrans`
    /// while the view is running, so this both acks a glasses-side exit and
    /// stops Transcribe from the phone.
    public static func buildExitAck() -> String { message(Phone2Glass.exitAck) }
    /// PHONE_TRANS_SERVER_EXIT (65). Intl firmware 1.0.11.53 treats 65 as an
    /// invalid command and ignores it; kept after 68 for other firmware.
    public static func buildPhoneServerExit() -> String { message(Phone2Glass.phoneServerExit) }
}

/// One decoded StMessage envelope: `{2:src, 3:dst, 4:json, 5:bytes, 6:id}`.
public struct AppChannelMessage: Sendable {
    public let sourcePackage: String
    public let targetPackage: String
    public let json: String
    /// Field 5. Audio rides here (the assistant's code 109 does the same).
    public let binary: Data

    public init(sourcePackage: String, targetPackage: String, json: String, binary: Data) {
        self.sourcePackage = sourcePackage
        self.targetPackage = targetPackage
        self.json = json
        self.binary = binary
    }

    public static func parse(_ body: Data) -> AppChannelMessage? {
        let fields = Pb.parse(body)
        guard !fields.isEmpty else { return nil }
        let source = Pb.firstString(fields, 2)
        let target = Pb.firstString(fields, 3)
        guard !source.isEmpty || !target.isEmpty else { return nil }
        return AppChannelMessage(sourcePackage: source, targetPackage: target,
                                 json: Pb.firstString(fields, 4),
                                 binary: Pb.firstBytes(fields, 5))
    }

    public func involves(_ fragment: String) -> Bool {
        sourcePackage.contains(fragment) || targetPackage.contains(fragment)
    }

    /// `msgCmd`, or nil when the JSON is not an InterConnectMessage.
    public var msgCmd: Int? {
        guard let reader = JsonReader(parsing: json), reader.opt("msgCmd") != nil else { return nil }
        let value = reader.optInt("msgCmd", Int.min)
        return value == Int.min ? nil : value
    }

    public var dataString: String? {
        guard let reader = JsonReader(parsing: json), let value = reader.opt("data") else { return nil }
        return value as? String
    }
}
