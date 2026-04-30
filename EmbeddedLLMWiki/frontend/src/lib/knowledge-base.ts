import { invoke } from "@tauri-apps/api/core"
import { normalizePath } from "@/lib/path-utils"
import {
  clampMaxNumResults,
  clampMaxRelatedItems,
  normalizeSearchQueries,
  type KnowledgeBaseDocumentRequest,
  type KnowledgeBaseDocumentResponse,
  type KnowledgeBaseEmbeddingConfig,
  type KnowledgeBaseQueryRequest,
  type KnowledgeBaseQueryResponse,
} from "@/lib/knowledge-base-schema"
import { useWikiStore, type EmbeddingConfig } from "@/stores/wiki-store"

const DEFAULT_MAX_RESULTS = 10
const DEFAULT_MAX_RELATED_ITEMS = 5

interface QueryKnowledgeBaseOptions {
  embeddingConfig?: EmbeddingConfig
  retrievalMode?: "keyword" | "vector" | "hybrid"
}

export async function queryKnowledgeBase(
  projectPath: string,
  request: KnowledgeBaseQueryRequest,
  options: QueryKnowledgeBaseOptions = {},
): Promise<KnowledgeBaseQueryResponse> {
  const queries = normalizeSearchQueries(request.query)
  if (queries.length === 0) {
    return emptyQueryResponse()
  }

  const embeddingConfig = resolveEmbeddingConfig(options.embeddingConfig)
  const normalizedRequest: KnowledgeBaseQueryRequest = {
    ...request,
    query: queries.length === 1 ? queries[0] : queries,
    max_num_results: clampMaxNumResults(request.max_num_results, DEFAULT_MAX_RESULTS),
    extensions: {
      ...(request.extensions ?? {}),
      ...(options.retrievalMode ? { retrieval_mode: options.retrievalMode } : {}),
      ...(embeddingConfig ? { embedding_config: embeddingConfig } : {}),
    },
  }

  if (!Object.keys(normalizedRequest.extensions ?? {}).length) {
    delete normalizedRequest.extensions
  }

  return invoke<KnowledgeBaseQueryResponse>("knowledge_base_query", {
    projectPath: normalizePath(projectPath),
    request: normalizedRequest,
  })
}

export async function getKnowledgeBaseDocument(
  projectPath: string,
  request: KnowledgeBaseDocumentRequest,
): Promise<KnowledgeBaseDocumentResponse> {
  return invoke<KnowledgeBaseDocumentResponse>("knowledge_base_document", {
    projectPath: normalizePath(projectPath),
    request: {
      ...request,
      max_related_items: clampMaxRelatedItems(request.max_related_items, DEFAULT_MAX_RELATED_ITEMS),
    },
  })
}

function emptyQueryResponse(): KnowledgeBaseQueryResponse {
  return {
    object: "vector_store.search_results.page",
    search_query: [],
    data: [],
    has_more: false,
    next_page: null,
    summary: "",
    rag_related_info: [],
  }
}

function resolveEmbeddingConfig(
  override?: EmbeddingConfig,
): KnowledgeBaseEmbeddingConfig | undefined {
  const config = override ?? useWikiStore.getState().embeddingConfig
  if (!config.enabled || !config.endpoint.trim() || !config.model.trim()) {
    return undefined
  }

  return {
    enabled: true,
    endpoint: config.endpoint.trim(),
    apiKey: config.apiKey,
    model: config.model.trim(),
  }
}
