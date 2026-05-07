// ClawdHome/Utils/PortAllocator.swift
import Foundation

/// 在 18800–18850 端口段扫描并分配可用端口
/// 用于 mlx-lm、F5-TTS 等本地服务（避开虾 Gateway 的 18000+uid 区段）
enum PortAllocator {

    static let localServiceRange = 18800...18850

    /// 检查端口是否可用（尝试 bind，不阻塞实际监听）
    static func isPortAvailable(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        var opt: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// 从 preferred 开始（或从 18800 开始）扫描，返回第一个可用端口
    static func allocate(preferred: Int? = nil) -> Int? {
        if let p = preferred, localServiceRange.contains(p), isPortAvailable(p) {
            return p
        }
        return localServiceRange.first(where: { isPortAvailable($0) })
    }
}
