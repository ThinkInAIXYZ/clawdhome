import { beforeEach, describe, expect, it, vi } from "vitest"

const { invokeMock } = vi.hoisted(() => ({
  invokeMock: vi.fn(),
}))

vi.mock("@tauri-apps/api/core", () => ({
  invoke: invokeMock,
}))

import {
  getKnowledgeBaseDocument,
  queryKnowledgeBase,
} from "@/lib/knowledge-base"
import { useWikiStore } from "@/stores/wiki-store"

describe("knowledge base tauri wrapper", () => {
  beforeEach(() => {
    invokeMock.mockReset()
    useWikiStore.setState({
      embeddingConfig: {
        enabled: false,
        endpoint: "",
        apiKey: "",
        model: "",
      },
    })
  })

  it("returns an empty response without invoking tauri when query is blank", async () => {
    const response = await queryKnowledgeBase("/tmp/project", {
      query: "   ",
    })

    expect(invokeMock).not.toHaveBeenCalled()
    expect(response).toEqual({
      object: "vector_store.search_results.page",
      search_query: [],
      data: [],
      has_more: false,
      next_page: null,
      summary: "",
      rag_related_info: [],
    })
  })

  it("normalizes and forwards search requests to the Rust command", async () => {
    invokeMock.mockImplementation(async (_command: string, args: any) => ({
      object: "vector_store.search_results.page",
      search_query: Array.isArray(args.request.query)
        ? args.request.query
        : [args.request.query],
      data: [],
      has_more: false,
      next_page: null,
      summary: "",
      rag_related_info: [],
    }))

    await queryKnowledgeBase(
      "/tmp/project",
      {
        query: [" 知识图谱 ", " ", "RAG"],
        max_num_results: 80,
        ranking_options: {
          ranker: "auto",
          score_threshold: 0.2,
        },
        rewrite_query: true,
        extensions: {
          allowed_path_prefixes: ["raw/sources/shrimps/demo-user"],
        },
      },
      {
        retrievalMode: "hybrid",
        embeddingConfig: {
          enabled: true,
          endpoint: "https://example.com/v1/embeddings",
          apiKey: "secret",
          model: "text-embedding-3-large",
        },
      },
    )

    expect(invokeMock).toHaveBeenCalledTimes(1)
    expect(invokeMock).toHaveBeenCalledWith("knowledge_base_query", {
      projectPath: "/tmp/project",
      request: {
        query: ["知识图谱", "RAG"],
        max_num_results: 50,
        ranking_options: {
          ranker: "auto",
          score_threshold: 0.2,
        },
        rewrite_query: true,
        extensions: {
          allowed_path_prefixes: ["raw/sources/shrimps/demo-user"],
          retrieval_mode: "hybrid",
          embedding_config: {
            enabled: true,
            endpoint: "https://example.com/v1/embeddings",
            apiKey: "secret",
            model: "text-embedding-3-large",
          },
        },
      },
    })
  })

  it("uses store embedding config when no override is provided", async () => {
    useWikiStore.setState({
      embeddingConfig: {
        enabled: true,
        endpoint: "http://127.0.0.1:1234/v1/embeddings",
        apiKey: "store-key",
        model: "text-embedding-qwen3-embedding-0.6b",
      },
    })

    invokeMock.mockResolvedValue({
      object: "vector_store.search_results.page",
      search_query: ["知识库安全"],
      data: [],
      has_more: false,
      next_page: null,
      summary: "",
      rag_related_info: [],
    })

    await queryKnowledgeBase("/tmp/project", {
      query: "知识库安全",
    })

    expect(invokeMock).toHaveBeenCalledWith("knowledge_base_query", {
      projectPath: "/tmp/project",
      request: {
        query: "知识库安全",
        max_num_results: 10,
        extensions: {
          embedding_config: {
            enabled: true,
            endpoint: "http://127.0.0.1:1234/v1/embeddings",
            apiKey: "store-key",
            model: "text-embedding-qwen3-embedding-0.6b",
          },
        },
      },
    })
  })

  it("clamps document related item requests before invoking Rust", async () => {
    invokeMock.mockResolvedValue({
      object: "vector_store.document",
      document: {
        file_id: "wiki/concepts/知识库安全.md",
        filename: "知识库安全.md",
        attributes: {
          path: "wiki/concepts/知识库安全.md",
          title: "知识库安全",
          source: "wiki",
          directory: "wiki/concepts",
          type: "concept",
          tags: [],
          sources: [],
          related: [],
        },
        content_text: "内容",
        summary: "摘要",
        rag_related_info: [],
        outbound_wikilinks: [],
      },
      related: [],
    })

    await getKnowledgeBaseDocument("/tmp/project", {
      fileId: "wiki/concepts/知识库安全.md",
      max_related_items: 50,
      include_related_content: true,
    })

    expect(invokeMock).toHaveBeenCalledWith("knowledge_base_document", {
      projectPath: "/tmp/project",
      request: {
        fileId: "wiki/concepts/知识库安全.md",
        max_related_items: 10,
        include_related_content: true,
      },
    })
  })
})
