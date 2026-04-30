export type KnowledgeBaseAttributeScalar = string | number | boolean
export type KnowledgeBaseAttributeValue = KnowledgeBaseAttributeScalar | Array<string | number>
export type KnowledgeBaseFilterAttributes = Record<string, KnowledgeBaseAttributeValue | undefined>

export interface KnowledgeBaseComparisonFilter {
  key: string
  type: "eq" | "ne" | "gt" | "gte" | "lt" | "lte" | "in" | "nin"
  value: KnowledgeBaseAttributeValue
}

export interface KnowledgeBaseCompoundFilter {
  type: "and" | "or"
  filters: KnowledgeBaseFilter[]
}

export type KnowledgeBaseFilter = KnowledgeBaseComparisonFilter | KnowledgeBaseCompoundFilter

export interface KnowledgeBaseEmbeddingConfig {
  enabled: boolean
  endpoint: string
  apiKey: string
  model: string
}

export interface KnowledgeBaseQueryExtensions {
  retrieval_mode?: "keyword" | "vector" | "hybrid"
  embedding_config?: KnowledgeBaseEmbeddingConfig
  allowed_path_prefixes?: string[]
}

export interface KnowledgeBaseQueryRequest {
  query: string | string[]
  filters?: KnowledgeBaseFilter
  max_num_results?: number
  ranking_options?: {
    ranker?: "none" | "auto" | "default-2024-11-15"
    score_threshold?: number
  }
  rewrite_query?: boolean
  extensions?: KnowledgeBaseQueryExtensions
}

export interface KnowledgeBaseContentChunk {
  type: "text"
  text: string
}

export interface KnowledgeBaseQueryResultAttributes {
  path: string
  title: string
  source: "wiki" | "raw"
  directory: string
  type: string
  title_match: boolean
  retrieval_mode: "keyword" | "vector" | "hybrid"
}

export interface KnowledgeBaseQueryResultItem {
  file_id: string
  filename: string
  score: number
  attributes: KnowledgeBaseQueryResultAttributes
  content: KnowledgeBaseContentChunk[]
  summary?: string
  rag_related_info?: string[]
}

export interface KnowledgeBaseQueryResponse {
  object: "vector_store.search_results.page"
  search_query: string[]
  data: KnowledgeBaseQueryResultItem[]
  has_more: boolean
  next_page: string | null
  summary?: string
  rag_related_info?: string[]
}

export interface KnowledgeBaseDocumentRequest {
  fileId?: string
  path?: string
  filename?: string
  directory?: string
  source?: "wiki" | "raw" | string
  max_related_items?: number
  include_related_content?: boolean
  extensions?: {
    allowed_path_prefixes?: string[]
  }
}

export interface KnowledgeBaseDocumentAttributes {
  path: string
  title: string
  source: string
  directory: string
  type: string
  tags: string[]
  sources: string[]
  related: string[]
}

export interface KnowledgeBaseDocumentItem {
  file_id: string
  filename: string
  attributes: KnowledgeBaseDocumentAttributes
  content_text: string
  summary: string
  rag_related_info: string[]
  outbound_wikilinks: string[]
}

export interface KnowledgeBaseRelatedDocumentItem {
  file_id: string
  filename: string
  score: number
  relation_reasons: string[]
  attributes: KnowledgeBaseDocumentAttributes
  content_preview: string
  content_text?: string
  summary: string
  rag_related_info: string[]
}

export interface KnowledgeBaseDocumentResponse {
  object: "vector_store.document"
  document: KnowledgeBaseDocumentItem
  related: KnowledgeBaseRelatedDocumentItem[]
}

export function normalizeSearchQueries(query: string | string[]): string[] {
  const queries = Array.isArray(query) ? query : [query]
  return queries.map((item) => item.trim()).filter(Boolean)
}

export function clampMaxNumResults(value: number | undefined, fallback: number = 10): number {
  const normalized = Number.isFinite(value) ? Number(value) : fallback
  return Math.min(50, Math.max(1, Math.trunc(normalized)))
}

export function normalizeScore(value: number): number {
  if (!Number.isFinite(value)) return 0
  return Math.max(0, Math.min(1, value))
}

export function clampMaxRelatedItems(value: number | undefined, fallback: number = 5): number {
  const normalized = Number.isFinite(value) ? Number(value) : fallback
  return Math.min(10, Math.max(1, Math.trunc(normalized)))
}

export function matchesKnowledgeBaseFilter(
  attributes: KnowledgeBaseFilterAttributes,
  filter?: KnowledgeBaseFilter,
): boolean {
  if (!filter) return true

  if (isCompoundFilter(filter)) {
    if (filter.filters.length === 0) return true
    return filter.type === "and"
      ? filter.filters.every((item) => matchesKnowledgeBaseFilter(attributes, item))
      : filter.filters.some((item) => matchesKnowledgeBaseFilter(attributes, item))
  }

  const actual = attributes[filter.key]
  if (actual === undefined) return false

  return compareAttribute(actual, filter.type, filter.value)
}

function isCompoundFilter(filter: KnowledgeBaseFilter): filter is KnowledgeBaseCompoundFilter {
  return "filters" in filter
}

function compareAttribute(
  actual: KnowledgeBaseAttributeValue,
  operator: KnowledgeBaseComparisonFilter["type"],
  expected: KnowledgeBaseAttributeValue,
): boolean {
  if (Array.isArray(actual)) {
    return compareArray(actual, operator, expected)
  }

  switch (operator) {
    case "eq":
      return actual === expected
    case "ne":
      return actual !== expected
    case "gt":
      return compareComparable(actual, expected, (left, right) => left > right)
    case "gte":
      return compareComparable(actual, expected, (left, right) => left >= right)
    case "lt":
      return compareComparable(actual, expected, (left, right) => left < right)
    case "lte":
      return compareComparable(actual, expected, (left, right) => left <= right)
    case "in":
      return Array.isArray(expected) ? expected.includes(actual) : actual === expected
    case "nin":
      return Array.isArray(expected) ? !expected.includes(actual) : actual !== expected
  }
}

function compareArray(
  actual: Array<string | number>,
  operator: KnowledgeBaseComparisonFilter["type"],
  expected: KnowledgeBaseAttributeValue,
): boolean {
  switch (operator) {
    case "eq":
      return Array.isArray(expected)
        ? expected.length === actual.length && expected.every((item, index) => item === actual[index])
        : actual.includes(expected)
    case "ne":
      return !compareArray(actual, "eq", expected)
    case "in":
      return Array.isArray(expected)
        ? actual.some((item) => expected.includes(item))
        : actual.includes(expected)
    case "nin":
      return !compareArray(actual, "in", expected)
    case "gt":
    case "gte":
    case "lt":
    case "lte":
      return false
  }
}

function compareComparable(
  actual: KnowledgeBaseAttributeScalar,
  expected: KnowledgeBaseAttributeValue,
  comparator: (left: string | number, right: string | number) => boolean,
): boolean {
  if (Array.isArray(expected) || typeof actual === "boolean" || typeof expected === "boolean") {
    return false
  }
  return comparator(actual, expected)
}
