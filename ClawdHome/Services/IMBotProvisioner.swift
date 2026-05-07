// ClawdHome/Services/IMBotProvisioner.swift
// IM Bot 绑定协议 + 标准通道登录实现 + 飞书 device flow 实现 + Factory
//
// 架构分工：
// - PluginManager（Helper 侧）只安装 openclaw plugin，不绑定 bot
// - IMBotProvisioner（App 侧）负责 bot 绑定，操作 IM 账号凭证
//
// 两个实现：
// 1. StandardChannelLoginProvisioner —— 微信/WhatsApp/Tlon
//    通过 `openclaw channels login --channel X --account Y` 完成扫码绑定
//    由 Helper.runChannelLogin() 代理执行，支持 --account 参数，多次执行不覆盖
// 2. FeishuDeviceFlowProvisioner —— 飞书 PersonalAgent device flow
//    直接调用 accounts.feishu.cn OAuth RFC 8628 接口，获取 client_id/client_secret
//    由 App 层 URLSession 完成，结果写入 OpenclawConfigSerializerV2.upsertIMAccount()

import Foundation

// MARK: - Result Model

/// 绑定成功后返回的 IM 账号凭证（写入 openclaw.json 所需字段）
public struct IMBotCredential: Sendable {
    /// platform-specific appId / client_id
    public let appId: String
    /// Keychain item 名；调用方负责写入 Keychain
    public let secretsPayload: String   // JSON {"appSecret":"...","encryptKey":"?","botToken":"?"}
    /// 平台
    public let platform: IMPlatform
    /// 机器人展示名（可选）
    public let botName: String?

    public init(appId: String, secretsPayload: String, platform: IMPlatform, botName: String? = nil) {
        self.appId = appId
        self.secretsPayload = secretsPayload
        self.platform = platform
        self.botName = botName
    }
}

// MARK: - Protocol

/// IM Bot 绑定抽象协议
/// 每个平台账号对应一次绑定流程，完成后返回 IMBotCredential
public protocol IMBotProvisioner: AnyObject {
    /// 当前绑定平台
    var platform: IMPlatform { get }

    /// 启动绑定流程（异步，可长时间运行）
    /// - Parameter progress: 过程中回调文本进度（如二维码 ASCII、提示语）
    /// - Returns: 绑定凭证
    func provision(
        username: String,
        accountKey: String,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> IMBotCredential

    /// 取消正在进行中的绑定流程（幂等）
    func cancel()
}

// MARK: - Errors

public enum IMBotProvisionerError: LocalizedError {
    case cancelled
    case noQRCodeFound
    case pollTimeout
    case apiError(String)
    case helperError(String)
    case unsupportedPlatform(IMPlatform)

    public var errorDescription: String? {
        switch self {
        case .cancelled:              return "已取消"
        case .noQRCodeFound:          return "未能获取二维码"
        case .pollTimeout:            return "等待扫码超时"
        case .apiError(let msg):      return "API 错误：\(msg)"
        case .helperError(let msg):   return "Helper 错误：\(msg)"
        case .unsupportedPlatform(let p): return "暂不支持 \(p.displayName) 的自动绑定"
        }
    }
}

// MARK: - StandardChannelLoginProvisioner

/// 标准通道登录：微信 / WhatsApp / Tlon
/// 通过 `openclaw channels login --channel X --account Y` 完成
/// 依赖 Helper.runChannelLogin()，整个命令在 Helper 侧以目标用户运行
public final class StandardChannelLoginProvisioner: IMBotProvisioner {

    public let platform: IMPlatform
    private let helperClient: HelperClient
    private var _cancelled = false
    private let lock = NSLock()

    init(platform: IMPlatform, helperClient: HelperClient) {
        precondition(platform.supportsStandardChannelLogin,
                     "StandardChannelLoginProvisioner 只支持 supportsStandardChannelLogin=true 的平台")
        self.platform = platform
        self.helperClient = helperClient
    }

    public func provision(
        username: String,
        accountKey: String,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> IMBotCredential {
        lock.lock(); let c = _cancelled; lock.unlock()
        if c { throw IMBotProvisionerError.cancelled }

        let channelId = platform.openclawChannelId
        // openclaw channels login --channel <channelId> --account <accountKey>
        let args = ["--channel", channelId, "--account", accountKey]
        progress("正在启动 \(platform.displayName) 登录…")

        let (ok, output) = await helperClient.runChannelLogin(username: username, args: args)

        lock.lock(); let c2 = _cancelled; lock.unlock()
        if c2 { throw IMBotProvisionerError.cancelled }

        guard ok else {
            throw IMBotProvisionerError.helperError(output)
        }

        progress(output)

        // channels login 成功后，凭证已由 openclaw 写入 openclaw.json channels.<platform>
        // 我们读取最新配置取出 appId 等，构造 IMBotCredential（secretsPayload 为空，凭证已在 json 中）
        // 对微信来说固定 accountKey = platform key，不需要额外 appId
        return IMBotCredential(
            appId: accountKey,
            secretsPayload: "{}",   // openclaw 自行管理，不需要 App 写 Keychain
            platform: platform,
            botName: nil
        )
    }

    public func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }
}

// MARK: - FeishuDeviceFlowProvisioner

/// 飞书 PersonalAgent device flow
/// 直接调用 accounts.feishu.cn OAuth 2.0 device flow + archetype=PersonalAgent
/// RFC 8628 标准，不依赖 lark-tools
///
/// 流程：
/// 1. POST /oauth/v1/app/registration { action: "begin", archetype: "PersonalAgent" }
///    → { device_code, user_code, verification_uri_complete, expires_in, interval }
/// 2. 展示 verification_uri_complete（服务器返回完整 URL）给用户（二维码 / 链接）
/// 3. 轮询 POST /oauth/v1/app/registration { action: "poll", device_code }
///    直到 status=success → 返回 { client_id, client_secret }
/// 4. 写入 openclaw.json channels.feishu.accounts[accountKey]
///
/// 注意：verification_uri_complete 是服务器返回的，不在客户端拼接
public final class FeishuDeviceFlowProvisioner: IMBotProvisioner {

    public let platform: IMPlatform = .feishu

    /// 飞书账号中心 base URL（国内版；Lark 版使用 accounts.larksuite.com）
    private let baseURL: URL
    private let urlSession: URLSession
    private var _cancelled = false
    private let lock = NSLock()

    // 轮询参数上限
    private let maxPollAttempts = 120    // 最多轮询 120 次
    private var pollIntervalSeconds: Int = 5

    public init(larkBrand: FeishuBrand = .feishu, urlSession: URLSession = .shared) {
        switch larkBrand {
        case .feishu:
            baseURL = URL(string: "https://accounts.feishu.cn")!
        case .lark:
            baseURL = URL(string: "https://accounts.larksuite.com")!
        }
        self.urlSession = urlSession
    }

    public func provision(
        username: String,
        accountKey: String,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> IMBotCredential {
        lock.lock(); let c = _cancelled; lock.unlock()
        if c { throw IMBotProvisionerError.cancelled }

        // Step 1: begin
        let beginResult = try await beginRegistration()
        pollIntervalSeconds = max(beginResult.interval, 3)

        // Step 2: 通知调用方展示二维码 / 链接
        let verificationURL = beginResult.verificationUriComplete
        progress("[feishu-device-flow] 请用飞书扫描或点击链接完成授权：\n\(verificationURL)")

        // Step 3: 轮询
        let cred = try await pollForCredential(
            deviceCode: beginResult.deviceCode,
            maxAttempts: maxPollAttempts,
            progress: progress
        )

        progress("飞书 Bot 绑定成功，client_id=\(cred.appId)")
        return cred
    }

    public func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }

    // MARK: - Step 1: begin

    private struct BeginResponse: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationUri: String
        let verificationUriComplete: String
        let expiresIn: Int
        let interval: Int

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationUri = "verification_uri"
            case verificationUriComplete = "verification_uri_complete"
            case expiresIn = "expires_in"
            case interval
        }
    }

    private func beginRegistration() async throws -> BeginResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("/oauth/v1/app/registration"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["action": "begin", "archetype": "PersonalAgent"]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)
        try assertHTTPSuccess(response: response, data: data)

        do {
            return try JSONDecoder().decode(BeginResponse.self, from: data)
        } catch {
            throw IMBotProvisionerError.apiError("begin 响应解析失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Step 3: poll

    private struct PollResponse: Decodable {
        let status: String      // "authorization_pending" | "slow_down" | "success" | "expired_token"
        let clientId: String?
        let clientSecret: String?
        let appName: String?

        enum CodingKeys: String, CodingKey {
            case status
            case clientId = "client_id"
            case clientSecret = "client_secret"
            case appName = "app_name"
        }
    }

    private func pollForCredential(
        deviceCode: String,
        maxAttempts: Int,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> IMBotCredential {
        var url = baseURL.appendingPathComponent("/oauth/v1/app/registration")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let pollBody: [String: String] = ["action": "poll", "device_code": deviceCode]
        request.httpBody = try JSONEncoder().encode(pollBody)

        for attempt in 1...maxAttempts {
            lock.lock(); let c = _cancelled; lock.unlock()
            if c { throw IMBotProvisionerError.cancelled }

            try await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds) * 1_000_000_000)

            lock.lock(); let c2 = _cancelled; lock.unlock()
            if c2 { throw IMBotProvisionerError.cancelled }

            let (data, response) = try await urlSession.data(for: request)
            try assertHTTPSuccess(response: response, data: data)

            let pollResult: PollResponse
            do {
                pollResult = try JSONDecoder().decode(PollResponse.self, from: data)
            } catch {
                throw IMBotProvisionerError.apiError("poll 响应解析失败: \(error.localizedDescription)")
            }

            switch pollResult.status {
            case "success":
                guard let clientId = pollResult.clientId,
                      let clientSecret = pollResult.clientSecret else {
                    throw IMBotProvisionerError.apiError("success 响应缺少 client_id/client_secret")
                }
                let secretsJSON = buildSecretsPayload(appSecret: clientSecret)
                return IMBotCredential(
                    appId: clientId,
                    secretsPayload: secretsJSON,
                    platform: .feishu,
                    botName: pollResult.appName
                )
            case "slow_down":
                pollIntervalSeconds += 5
                progress("服务器要求降速轮询，间隔调整为 \(pollIntervalSeconds)s")
            case "authorization_pending":
                progress("等待飞书授权中…（第 \(attempt)/\(maxAttempts) 次）")
            case "expired_token":
                throw IMBotProvisionerError.apiError("device_code 已过期，请重新扫码")
            default:
                throw IMBotProvisionerError.apiError("未知 poll 状态：\(pollResult.status)")
            }
        }
        throw IMBotProvisionerError.pollTimeout
    }

    // MARK: - Helpers

    private func assertHTTPSuccess(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            throw IMBotProvisionerError.apiError("HTTP \(http.statusCode): \(body)")
        }
    }

    private func buildSecretsPayload(appSecret: String) -> String {
        let dict: [String: String] = ["appSecret": appSecret]
        let data = (try? JSONEncoder().encode(dict)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - Factory

/// 根据平台和品牌创建对应的 provisioner
public enum ProvisionerFactory {

    /// 创建 provisioner
    /// - Parameters:
    ///   - platform: IM 平台
    ///   - larkBrand: 仅飞书有效，区分国内版/Lark
    ///   - helperClient: App 侧 XPC 客户端（标准通道登录使用）
    static func make(
        platform: IMPlatform,
        larkBrand: FeishuBrand = .feishu,
        helperClient: HelperClient
    ) -> any IMBotProvisioner {
        switch platform {
        case .feishu:
            return FeishuDeviceFlowProvisioner(larkBrand: larkBrand)
        case .wechat, .whatsapp, .tlon:
            return StandardChannelLoginProvisioner(platform: platform, helperClient: helperClient)
        case .slack, .discord, .telegram:
            // 这些平台需手动配置 token，暂不支持自动绑定
            // 调用方应检查 platform.supportsStandardChannelLogin 后再调用 Factory
            return StandardChannelLoginProvisioner(platform: platform, helperClient: helperClient)
        }
    }
}
