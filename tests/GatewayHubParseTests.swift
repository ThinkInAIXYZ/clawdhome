// tests/GatewayHubParseTests.swift
// 核心主流程测试 — 命令行参考测试：网关 URL 解析与端口计算核心算法

import Foundation

// 模拟 GatewayHub 内部的核心纯算法逻辑，供命令行独立运行
struct GatewayHubParser {
    /// 提取 port 和 token 的核心解析算法，包含 127.0.0.1 主机安全约束
    static func parse(gatewayURL: String) -> (port: Int, token: String)? {
        guard let url = URL(string: gatewayURL),
              let host = url.host, host == "127.0.0.1",
              let port = url.port
        else { return nil }

        let token: String
        if let fragment = url.fragment, fragment.hasPrefix("token=") {
            token = String(fragment.dropFirst(6))
        } else {
            token = ""
        }
        return (port, token)
    }

    /// 端口分配核心算法，范围约束：1024 < port < 65536
    static func gatewayPort(for uid: Int) -> Int? {
        let port = 18000 + uid
        guard port > 1024, port < 65536 else { return nil }
        return port
    }
}

struct GatewayHubParseTests {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        // 1. 测试正常 URL 带 Token 解析
        if let (port, token) = GatewayHubParser.parse(gatewayURL: "http://127.0.0.1:18501/#token=my-secure-token") {
            expect(port == 18501, "端口应为 18501")
            expect(token == "my-secure-token", "Token 应匹配")
        } else {
            expect(false, "无法解析正常带 Token 的 URL")
        }

        // 2. 测试正常 URL 无 Token 解析
        if let (port, token) = GatewayHubParser.parse(gatewayURL: "http://127.0.0.1:18502/") {
            expect(port == 18502, "端口应为 18502")
            expect(token == "", "Token 应为空")
        } else {
            expect(false, "无法解析正常无 Token 的 URL")
        }

        // 3. 测试安全约束：仅允许 127.0.0.1
        expect(GatewayHubParser.parse(gatewayURL: "http://localhost:18501/#token=abc") == nil, "应当拒绝 localhost")
        expect(GatewayHubParser.parse(gatewayURL: "http://192.168.1.1:18501/#token=abc") == nil, "应当拒绝局域网 IP")

        // 4. 测试非法 URL
        expect(GatewayHubParser.parse(gatewayURL: "invalid_url") == nil, "非法格式应当返回 nil")

        // 5. 测试 UID 端口分配
        expect(GatewayHubParser.gatewayPort(for: 501) == 18501, "UID 501 端口分配应当为 18501")

        // 6. 测试端口越界检查
        expect(GatewayHubParser.gatewayPort(for: -17500) == nil, "分配端口不应 <= 1024")
        expect(GatewayHubParser.gatewayPort(for: 50000) == nil, "分配端口不应 >= 65536")

        print("Gateway hub URL parsing reference tests passed.")
    }
}

GatewayHubParseTests.main()
