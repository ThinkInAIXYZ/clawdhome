import Darwin
import Foundation

struct UnixHTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

enum UnixHTTPClientError: LocalizedError {
    case socketCreateFailed
    case socketPathTooLong
    case connectFailed(String)
    case writeFailed(String)
    case readFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .socketCreateFailed:
            return "无法创建 Unix socket"
        case .socketPathTooLong:
            return "Unix socket 路径过长"
        case .connectFailed(let message):
            return "连接 Unix socket 失败：\(message)"
        case .writeFailed(let message):
            return "写入 Unix socket 失败：\(message)"
        case .readFailed(let message):
            return "读取 Unix socket 失败：\(message)"
        case .invalidResponse:
            return "HTTP over UDS 返回了无效响应"
        }
    }
}

final class UnixHTTPClient {
    func request(
        socketPath: String,
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 5
    ) async throws -> UnixHTTPResponse {
        try await Task.detached(priority: .userInitiated) {
            try Self.requestSync(
                socketPath: socketPath,
                method: method,
                path: path,
                headers: headers,
                body: body,
                timeout: timeout
            )
        }.value
    }

    private static func requestSync(
        socketPath: String,
        method: String,
        path: String,
        headers: [String: String],
        body: Data?,
        timeout: TimeInterval
    ) throws -> UnixHTTPResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixHTTPClientError.socketCreateFailed }
        defer { close(fd) }

        try configureTimeouts(fd: fd, timeout: timeout)
        try connect(fd: fd, socketPath: socketPath)

        let requestData = try buildRequestData(method: method, path: path, headers: headers, body: body)
        try writeAll(fd: fd, data: requestData)
        shutdown(fd, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw UnixHTTPClientError.readFailed(String(cString: strerror(errno)))
            }
            response.append(buffer, count: count)
        }

        return try parseResponse(response)
    }

    private static func configureTimeouts(fd: Int32, timeout: TimeInterval) throws {
        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: __darwin_suseconds_t((timeout - floor(timeout)) * 1_000_000)
        )
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size)
    }

    private static func connect(fd: Int32, socketPath: String) throws {
        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxPathLength else {
            throw UnixHTTPClientError.socketPathTooLong
        }

        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: CChar.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = UInt8(bitPattern: byte)
            }
        }

        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }
        guard result == 0 else {
            throw UnixHTTPClientError.connectFailed(String(cString: strerror(errno)))
        }
    }

    private static func buildRequestData(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) throws -> Data {
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        var lines = ["\(method) \(normalizedPath) HTTP/1.1", "Host: localhost", "Connection: close"]
        let requestBody = body ?? Data()
        if !requestBody.isEmpty {
            lines.append("Content-Length: \(requestBody.count)")
        }
        for key in headers.keys.sorted() {
            let value = headers[key] ?? ""
            lines.append("\(key): \(value)")
        }
        lines.append("")
        lines.append("")
        guard var data = lines.joined(separator: "\r\n").data(using: .utf8) else {
            throw UnixHTTPClientError.invalidResponse
        }
        data.append(requestBody)
        return data
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let count = write(fd, baseAddress.advanced(by: sent), data.count - sent)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw UnixHTTPClientError.writeFailed(String(cString: strerror(errno)))
                }
                sent += count
            }
        }
    }

    private static func parseResponse(_ data: Data) throws -> UnixHTTPResponse {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else {
            throw UnixHTTPClientError.invalidResponse
        }
        let headerData = data.subdata(in: 0..<headerRange.lowerBound)
        let rawBody = data.subdata(in: headerRange.upperBound..<data.endIndex)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw UnixHTTPClientError.invalidResponse
        }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw UnixHTTPClientError.invalidResponse
        }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let statusCode = Int(parts[1]) else {
            throw UnixHTTPClientError.invalidResponse
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key.lowercased()] = value
        }

        let body: Data
        if headers["transfer-encoding"]?.lowercased() == "chunked" {
            body = try decodeChunkedBody(rawBody)
        } else {
            body = rawBody
        }
        return UnixHTTPResponse(statusCode: statusCode, headers: headers, body: body)
    }

    private static func decodeChunkedBody(_ data: Data) throws -> Data {
        var cursor = data.startIndex
        var decoded = Data()
        while cursor < data.endIndex {
            guard let lineRange = data[cursor...].range(of: Data("\r\n".utf8)) else { break }
            let sizeData = data.subdata(in: cursor..<lineRange.lowerBound)
            guard let sizeString = String(data: sizeData, encoding: .utf8)?.split(separator: ";").first,
                  let size = Int(sizeString, radix: 16)
            else {
                throw UnixHTTPClientError.invalidResponse
            }
            cursor = lineRange.upperBound
            if size == 0 { break }
            let end = cursor + size
            guard end <= data.endIndex else { throw UnixHTTPClientError.invalidResponse }
            decoded.append(data.subdata(in: cursor..<end))
            cursor = min(end + 2, data.endIndex)
        }
        return decoded
    }
}
