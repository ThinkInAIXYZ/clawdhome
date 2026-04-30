import Foundation

struct LLMWikiSocketStatus: Decodable {
    let ok: Bool
    let transport: String?
    let socketPath: String?
    let socketInfoPath: String?
    let heartbeatSocketPath: String?
    let healthEndpoint: String?
    let ready: Bool?
    let security: [String: String]?
}

struct LLMWikiHealthStatus: Decodable {
    let ok: Bool
    let ready: Bool
    let status: String?
    let reason: String?
    let kbSocketPath: String?
    let uptimeSeconds: Int?
}

struct LLMWikiSearchExtensions: Encodable {
    let allowed_path_prefixes: [String]?
    let retrieval_mode: String?
    let embedding_config: LLMWikiEmbeddingConfig?
}

struct LLMWikiEmbeddingConfig: Encodable {
    let enabled: Bool
    let endpoint: String
    let apiKey: String
    let model: String

    enum CodingKeys: String, CodingKey {
        case enabled
        case endpoint
        case apiKey = "api_key"
        case model
    }
}

struct LLMWikiSearchRankingOptions: Encodable {
    let score_threshold: Double?
    let ranker: String?
}

struct LLMWikiSearchRequest: Encodable {
    let projectPath: String
    let query: String
    let max_num_results: Int
    let ranking_options: LLMWikiSearchRankingOptions?
    let extensions: LLMWikiSearchExtensions?
    let rewrite_query: Bool?
}

struct LLMWikiDocumentExtensions: Encodable {
    let allowed_path_prefixes: [String]?
}

struct LLMWikiDocumentRequest: Encodable {
    let projectPath: String
    let fileId: String?
    let path: String?
    let filename: String?
    let max_related_items: Int?
    let include_related_content: Bool?
    let extensions: LLMWikiDocumentExtensions?

    enum CodingKeys: String, CodingKey {
        case projectPath
        case fileId
        case path
        case filename
        case max_related_items
        case include_related_content
        case extensions
    }
}

struct LLMWikiSearchContentBlock: Decodable {
    let type: String
    let text: String?
}

struct LLMWikiSearchResultAttributes: Decodable {
    let path: String?
    let title: String?
    let source: String?
    let directory: String?
    let type: String?
    let retrieval_mode: String?
}

struct LLMWikiSearchResultItem: Decodable, Identifiable {
    let file_id: String
    let filename: String?
    let score: Double?
    let summary: String?
    let rag_related_info: [String]?
    let attributes: LLMWikiSearchResultAttributes?
    let content: [LLMWikiSearchContentBlock]?

    var id: String { file_id }
}

struct LLMWikiSearchResponse: Decodable {
    let object: String
    let search_query: [String]?
    let data: [LLMWikiSearchResultItem]
    let has_more: Bool?
    let next_page: String?
    let summary: String?
    let rag_related_info: [String]?
}

struct LLMWikiDocumentNode: Decodable {
    let file_id: String
    let filename: String?
    let summary: String?
    let rag_related_info: [String]?
    let content_text: String?
    let outbound_wikilinks: [String]?
}

struct LLMWikiRelatedDocument: Decodable, Identifiable {
    let file_id: String
    let filename: String?
    let score: Double?
    let relation_reasons: [String]?
    let summary: String?
    let rag_related_info: [String]?
    let content_preview: String?
    let content_text: String?

    var id: String { file_id }
}

struct LLMWikiDocumentResponse: Decodable {
    let object: String
    let document: LLMWikiDocumentNode
    let related: [LLMWikiRelatedDocument]
}

struct LLMWikiProjectStatus: Decodable {
    let ok: Bool
    let path: String?
}

final class KnowledgeBaseSocketClient {
    private let httpClient: UnixHTTPClient
    private let socketPath: String
    private let heartbeatSocketPath: String

    init(
        socketPath: String = LLMWikiPaths.socketPath,
        heartbeatSocketPath: String = LLMWikiPaths.heartbeatSocketPath,
        httpClient: UnixHTTPClient = UnixHTTPClient()
    ) {
        self.socketPath = socketPath
        self.heartbeatSocketPath = heartbeatSocketPath
        self.httpClient = httpClient
    }

    func status() async throws -> LLMWikiSocketStatus {
        try await decode(request: .main(path: "/status", method: "GET", body: nil), as: LLMWikiSocketStatus.self)
    }

    func health() async throws -> LLMWikiHealthStatus {
        try await decode(request: .heartbeat(path: "/health", method: "GET", body: nil), as: LLMWikiHealthStatus.self)
    }

    func projectStatus() async throws -> LLMWikiProjectStatus {
        try await decode(request: .main(path: "/project", method: "GET", body: nil), as: LLMWikiProjectStatus.self)
    }

    func search(_ request: LLMWikiSearchRequest) async throws -> LLMWikiSearchResponse {
        let body = try JSONEncoder().encode(request)
        return try await decode(request: .main(path: "/vector_stores/search", method: "POST", body: body), as: LLMWikiSearchResponse.self)
    }

    func document(_ request: LLMWikiDocumentRequest) async throws -> LLMWikiDocumentResponse {
        let body = try JSONEncoder().encode(request)
        return try await decode(request: .main(path: "/knowledge-base/document", method: "POST", body: body), as: LLMWikiDocumentResponse.self)
    }

    private enum TargetRequest {
        case main(path: String, method: String, body: Data?)
        case heartbeat(path: String, method: String, body: Data?)

        var path: String {
            switch self {
            case .main(let path, _, _), .heartbeat(let path, _, _):
                return path
            }
        }

        var method: String {
            switch self {
            case .main(_, let method, _), .heartbeat(_, let method, _):
                return method
            }
        }

        var body: Data? {
            switch self {
            case .main(_, _, let body), .heartbeat(_, _, let body):
                return body
            }
        }
    }

    private func decode<T: Decodable>(request: TargetRequest, as type: T.Type) async throws -> T {
        let targetSocketPath: String
        switch request {
        case .main:
            targetSocketPath = socketPath
        case .heartbeat:
            targetSocketPath = heartbeatSocketPath
        }
        let response = try await httpClient.request(
            socketPath: targetSocketPath,
            method: request.method,
            path: request.path,
            headers: request.body == nil ? [:] : ["Content-Type": "application/json"],
            body: request.body
        )
        return try JSONDecoder().decode(type, from: response.body)
    }
}
