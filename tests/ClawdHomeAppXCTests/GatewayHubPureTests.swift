// tests/ClawdHomeAppXCTests/GatewayHubPureTests.swift
// 核心主流程测试 — 单元测试：GatewayHub 静态纯函数与连接错误分类判定

import XCTest
@testable import ClawdHome

final class GatewayHubPureTests: XCTestCase {

    /// 测试 Gateway URL 的解析逻辑，包括端口与 Token 的提取及安全约束
    func testGatewayURLParsing() {
        // 1. 正常包含 token fragment 的 URL
        if let (port, token) = GatewayHub.parse(gatewayURL: "http://127.0.0.1:18501/#token=my-secure-token") {
            XCTAssertEqual(port, 18501)
            XCTAssertEqual(token, "my-secure-token")
        } else {
            XCTFail("无法解析带有 Token 的正常 URL")
        }

        // 2. 正常无 token 的 URL
        if let (port, token) = GatewayHub.parse(gatewayURL: "http://127.0.0.1:18502/") {
            XCTAssertEqual(port, 18502)
            XCTAssertEqual(token, "")
        } else {
            XCTFail("无法解析无 Token 的正常 URL")
        }

        // 3. 安全约束：主机名非 127.0.0.1 应该拒绝，防止 SSRF/DNS rebinding
        XCTAssertNil(GatewayHub.parse(gatewayURL: "http://localhost:18501/#token=abc"))
        XCTAssertNil(GatewayHub.parse(gatewayURL: "http://192.168.1.50:18501/#token=abc"))
        XCTAssertNil(GatewayHub.parse(gatewayURL: "http://google.com:18501/"))

        // 4. 边界/异常输入
        XCTAssertNil(GatewayHub.parse(gatewayURL: "invalid_url"))
    }

    /// 测试端口分配计算及边界条件
    func testGatewayPortAllocation() {
        // 501 用户对应端口 18501
        XCTAssertEqual(GatewayHub.gatewayPort(for: 501), 18501)
        XCTAssertEqual(GatewayHub.gatewayPort(for: 1000), 19000)

        // 边界条件：端口必须 > 1024 且 < 65536
        // uid 为负数导致 port <= 1024 应当返回 nil
        XCTAssertNil(GatewayHub.gatewayPort(for: -17000)) // 18000 - 17000 = 1000 <= 1024
        XCTAssertNil(GatewayHub.gatewayPort(for: 50000)) // 18000 + 50000 = 68000 >= 65536
    }

    /// 测试将 dot-path 路径转换为嵌套 Dictionary 的功能
    func testBuildNestedDict() {
        let path = "channels.feishu.streaming"
        let dict = GatewayHub.buildNestedDict(path: path, value: true)

        guard let channels = dict["channels"] as? [String: Any],
              let feishu = channels["feishu"] as? [String: Any],
              let streaming = feishu["streaming"] as? Bool else {
            XCTFail("嵌套字典构建失败")
            return
        }

        XCTAssertTrue(streaming)
        XCTAssertNil(dict["streaming"])
    }

    /// 测试多层嵌套 Dictionary 的深度合并
    func testDeepMerge() {
        let base: [String: Any] = [
            "channels": [
                "feishu": [
                    "enabled": true,
                    "streaming": false
                ],
                "wecom": [
                    "enabled": false
                ]
            ],
            "debug": true
        ]

        let overlay: [String: Any] = [
            "channels": [
                "feishu": [
                    "streaming": true
                ],
                "slack": [
                    "enabled": true
                ]
            ],
            "debug": false
        ]

        let merged = GatewayHub.deepMerge(base, overlay)

        // 验证 debug 字段已被覆盖
        XCTAssertEqual(merged["debug"] as? Bool, false)

        // 验证 channels.feishu.streaming 被覆盖，但 enabled 保持
        guard let channels = merged["channels"] as? [String: Any],
              let feishu = channels["feishu"] as? [String: Any],
              let wecom = channels["wecom"] as? [String: Any],
              let slack = channels["slack"] as? [String: Any] else {
            XCTFail("合并后的结构解析错误")
            return
        }

        XCTAssertEqual(feishu["streaming"] as? Bool, true)
        XCTAssertEqual(feishu["enabled"] as? Bool, true)
        XCTAssertEqual(wecom["enabled"] as? Bool, false)
        XCTAssertEqual(slack["enabled"] as? Bool, true)
    }

    /// 测试网关连接错误判定函数 isGatewayConnectivityError() 对各类错误的识别情况
    func testIsGatewayConnectivityError() {
        // 1. Gateway 自身的客户端错误
        XCTAssertTrue(isGatewayConnectivityError(GatewayClientError.notConnected))
        XCTAssertTrue(isGatewayConnectivityError(GatewayClientError.connectFailed("无法连接")))
        XCTAssertFalse(isGatewayConnectivityError(GatewayClientError.requestFailed(code: "invalid_params", message: "参数错误")))
        XCTAssertFalse(isGatewayConnectivityError(GatewayClientError.encodingError(NSError(domain: "test", code: 1))))

        // 2. POSIX 网络层错误
        let connRefused = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED), userInfo: nil)
        let connReset = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET), userInfo: nil)
        let permissionDenied = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: nil)
        XCTAssertTrue(isGatewayConnectivityError(connRefused))
        XCTAssertTrue(isGatewayConnectivityError(connReset))
        XCTAssertFalse(isGatewayConnectivityError(permissionDenied))

        // 3. URLError 网络库错误
        XCTAssertTrue(isGatewayConnectivityError(URLError(.timedOut)))
        XCTAssertTrue(isGatewayConnectivityError(URLError(.cannotConnectToHost)))
        XCTAssertTrue(isGatewayConnectivityError(URLError(.networkConnectionLost)))
        XCTAssertFalse(isGatewayConnectivityError(URLError(.badURL)))

        // 4. 文字/语言兜底
        let customError1 = NSError(domain: "custom", code: 99, userInfo: [NSLocalizedDescriptionKey: "与 Socket 握手失败"])
        let customError2 = NSError(domain: "custom", code: 99, userInfo: [NSLocalizedDescriptionKey: "Gateway 未连接，请重试"])
        let customError3 = NSError(domain: "custom", code: 99, userInfo: [NSLocalizedDescriptionKey: "socket is not connected"])
        let unrelatedError = NSError(domain: "custom", code: 99, userInfo: [NSLocalizedDescriptionKey: "数据库读写失败"])

        XCTAssertTrue(isGatewayConnectivityError(customError1))
        XCTAssertTrue(isGatewayConnectivityError(customError2))
        XCTAssertTrue(isGatewayConnectivityError(customError3))
        XCTAssertFalse(isGatewayConnectivityError(unrelatedError))
    }
}
