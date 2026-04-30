import type { FileNode } from "@/types/wiki"

const STOP_WORDS = new Set([
  "的", "是", "了", "什么", "在", "有", "和", "与", "对", "从",
  "the", "is", "a", "an", "what", "how", "are", "was", "were",
  "do", "does", "did", "be", "been", "being", "have", "has", "had",
  "it", "its", "in", "on", "at", "to", "for", "of", "with", "by",
  "this", "that", "these", "those",
])

const SNIPPET_CONTEXT = 80
const SUMMARY_SECTION_KEYWORDS = ["概述", "定义", "摘要", "简介", "总结", "overview", "summary", "definition", "introduction"]
const RAG_RELATED_KEYWORDS = [
  "rag",
  "检索增强生成",
  "检索增强",
  "retrieval",
  "vector",
  "embedding",
  "嵌入",
  "向量",
  "权限",
  "脱敏",
  "加密",
  "graphRAG".toLowerCase(),
  "知识图谱",
  "知识库污染",
  "知识杀毒",
  "安全围栏",
  "提示词注入",
  "敏感数据",
  "rbac",
  "审计",
  "hybrid",
  "rerank",
  "重排",
  "bm25",
]
const MAX_RAG_HIGHLIGHTS = 12

interface MarkdownSection {
  heading: string
  lines: string[]
}

export interface ParsedFrontmatter {
  title?: string
  type?: string
  tags: string[]
  sources: string[]
}

export function tokenizeQuery(query: string): string[] {
  const rawTokens = query
    .toLowerCase()
    .split(/[\s,，。！？、；：""''（）()\-_/\\·~～…]+/)
    .filter((token) => token.length > 1)
    .filter((token) => !STOP_WORDS.has(token))

  const tokens: string[] = []

  for (const token of rawTokens) {
    const hasCjk = /[\u4e00-\u9fff\u3400-\u4dbf]/.test(token)

    if (hasCjk && token.length > 2) {
      const chars = [...token]
      for (let i = 0; i < chars.length - 1; i++) {
        tokens.push(chars[i] + chars[i + 1])
      }
      for (const ch of chars) {
        if (!STOP_WORDS.has(ch)) {
          tokens.push(ch)
        }
      }
      tokens.push(token)
    } else {
      tokens.push(token)
    }
  }

  return [...new Set(tokens)]
}

export function flattenMdFiles(nodes: readonly FileNode[]): FileNode[] {
  const files: FileNode[] = []
  for (const node of nodes) {
    if (node.is_dir && node.children) {
      files.push(...flattenMdFiles(node.children))
    } else if (!node.is_dir && node.name.endsWith(".md")) {
      files.push(node)
    }
  }
  return files
}

export function flattenAllFiles(nodes: readonly FileNode[]): FileNode[] {
  const files: FileNode[] = []
  for (const node of nodes) {
    if (node.is_dir && node.children) {
      files.push(...flattenAllFiles(node.children))
    } else if (!node.is_dir) {
      files.push(node)
    }
  }
  return files
}

export function extractTitle(content: string, fileName: string): string {
  const frontmatterTitle = parseFrontmatter(content).title
  if (frontmatterTitle) return frontmatterTitle

  const headingMatch = content.match(/^#\s+(.+)$/m)
  if (headingMatch) return headingMatch[1].trim()

  return fileName.replace(/\.md$/, "").replace(/-/g, " ")
}

export function buildSnippet(content: string, query: string): string {
  const lower = content.toLowerCase()
  const lowerQuery = query.toLowerCase()
  const index = lower.indexOf(lowerQuery)

  if (index === -1) {
    return content.slice(0, SNIPPET_CONTEXT * 2).replace(/\n/g, " ")
  }

  const start = Math.max(0, index - SNIPPET_CONTEXT)
  const end = Math.min(content.length, index + query.length + SNIPPET_CONTEXT)
  let snippet = content.slice(start, end).replace(/\n/g, " ")

  if (start > 0) snippet = "..." + snippet
  if (end < content.length) snippet += "..."

  return snippet
}

export function parseFrontmatter(content: string): ParsedFrontmatter {
  const frontmatter = extractFrontmatterBlock(content)

  return {
    title: matchScalar(frontmatter, "title"),
    type: matchScalar(frontmatter, "type")?.toLowerCase(),
    tags: matchArray(frontmatter, "tags"),
    sources: matchArray(frontmatter, "sources"),
  }
}

export function extractDocumentSummary(content: string, title?: string): string {
  const sections = splitMarkdownSections(content)
  const preferred = sections.find((section) =>
    SUMMARY_SECTION_KEYWORDS.some((keyword) =>
      section.heading.toLowerCase().includes(keyword.toLowerCase()),
    ),
  )

  const candidate = findSectionSummary(preferred)
    || sections.map(findSectionSummary).find(Boolean)
    || firstMeaningfulLine(stripFrontmatterContent(content).split(/\r?\n/))

  return truncateText(candidate || title || "", 220)
}

export function extractRagRelatedInfo(content: string, title: string): string[] {
  const sections = splitMarkdownSections(content)
  const firstLines = stripFrontmatterContent(content).split(/\r?\n/).slice(0, 24).join("\n")
  const docLevelRelevant = isRagRelatedText(title) || isRagRelatedText(firstLines)
  const highlights: string[] = []
  const seen = new Set<string>()

  for (const section of sections) {
    const joined = section.lines.join("\n")
    const sectionRelevant = docLevelRelevant
      || isRagRelatedText(section.heading)
      || isRagRelatedText(joined)

    if (!sectionRelevant) continue

    for (const line of section.lines) {
      if (highlights.length >= MAX_RAG_HIGHLIGHTS) return highlights

      const cleaned = cleanMarkdownLine(line)
      if (!cleaned || cleaned.length < 8) continue
      if (section.heading && cleaned === section.heading) continue

      if (!docLevelRelevant && !isRagRelatedText(cleaned)) continue

      const value = truncateText(
        section.heading ? `${section.heading}: ${cleaned}` : cleaned,
        220,
      )

      if (!seen.has(value)) {
        seen.add(value)
        highlights.push(value)
      }
    }
  }

  return highlights
}

export function buildKnowledgeBaseSummary(items: ReadonlyArray<{
  attributes: { title: string }
  summary?: string
}>): string {
  const parts = items
    .slice(0, 3)
    .map((item) => item.summary ? `${item.attributes.title}：${item.summary}` : item.attributes.title)

  if (parts.length === 0) return ""
  return `当前返回 ${items.length} 条相关知识。${parts.join("；")}`
}

export function collectKnowledgeBaseRagInfo(items: ReadonlyArray<{
  rag_related_info?: string[]
}>): string[] {
  const values: string[] = []
  const seen = new Set<string>()

  for (const item of items) {
    for (const entry of item.rag_related_info ?? []) {
      if (!seen.has(entry)) {
        seen.add(entry)
        values.push(entry)
      }
      if (values.length >= MAX_RAG_HIGHLIGHTS * 2) {
        return values
      }
    }
  }

  return values
}

function extractFrontmatterBlock(content: string): string {
  const lines = content.split(/\r?\n/)
  const startIndex = lines[0] === "---"
    ? 1
    : lines[0]?.trimStart().startsWith("```") && lines[1] === "---"
      ? 2
      : -1

  if (startIndex === -1) return ""

  for (let index = startIndex; index < lines.length; index++) {
    if (lines[index] === "---") {
      return lines.slice(startIndex, index).join("\n")
    }
  }

  return ""
}

function matchScalar(frontmatter: string, key: string): string | undefined {
  const escapedKey = escapeRegex(key)
  const match = frontmatter.match(new RegExp(`^${escapedKey}:\\s*["']?(.+?)["']?\\s*$`, "m"))
  return match?.[1]?.trim() || undefined
}

function matchArray(frontmatter: string, key: string): string[] {
  const escapedKey = escapeRegex(key)
  const blockMatch = frontmatter.match(new RegExp(`^${escapedKey}:\\s*\\n((?:\\s+-\\s+.+\\n?)*)`, "m"))
  if (blockMatch) {
    return blockMatch[1]
      .split("\n")
      .map((line) => line.match(/^\s+-\s+["']?(.+?)["']?\s*$/)?.[1]?.trim())
      .filter((value): value is string => Boolean(value))
  }

  const inlineMatch = frontmatter.match(new RegExp(`^${escapedKey}:\\s*\\[([^\\]]*)\\]`, "m"))
  if (!inlineMatch) return []

  return inlineMatch[1]
    .split(",")
    .map((item) => item.trim().replace(/^["']|["']$/g, ""))
    .filter(Boolean)
}

function escapeRegex(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

function stripFrontmatterContent(content: string): string {
  const lines = content.split(/\r?\n/)
  const startIndex = lines[0] === "---"
    ? 1
    : lines[0]?.trimStart().startsWith("```") && lines[1] === "---"
      ? 2
      : -1

  if (startIndex === -1) return content

  for (let index = startIndex; index < lines.length; index++) {
    if (lines[index] === "---") {
      let bodyStart = index + 1
      if (lines[bodyStart]?.trimStart().startsWith("```")) {
        bodyStart += 1
      }
      return lines.slice(bodyStart).join("\n")
    }
  }

  return content
}

function splitMarkdownSections(content: string): MarkdownSection[] {
  const body = stripFrontmatterContent(content)
  const sections: MarkdownSection[] = []
  let current: MarkdownSection = { heading: "", lines: [] }
  let inCodeBlock = false

  for (const line of body.split(/\r?\n/)) {
    const trimmed = line.trim()

    if (trimmed.startsWith("```")) {
      inCodeBlock = !inCodeBlock
      continue
    }

    if (!inCodeBlock && /^#{1,6}\s+/.test(trimmed)) {
      if (current.heading || current.lines.length > 0) {
        sections.push(current)
      }
      current = {
        heading: trimmed.replace(/^#{1,6}\s+/, "").trim(),
        lines: [],
      }
      continue
    }

    current.lines.push(line)
  }

  if (current.heading || current.lines.length > 0) {
    sections.push(current)
  }

  return sections
}

function findSectionSummary(section: MarkdownSection | undefined): string | undefined {
  if (!section) return undefined
  return firstMeaningfulLine(section.lines)
}

function firstMeaningfulLine(lines: readonly string[]): string | undefined {
  for (const line of lines) {
    const cleaned = cleanMarkdownLine(line)
    if (cleaned && cleaned.length >= 16) return cleaned
  }
  return undefined
}

function cleanMarkdownLine(line: string): string | undefined {
  const trimmed = line.trim()
  if (!trimmed) return undefined
  if (/^[-:| ]+$/.test(trimmed)) return undefined

  let normalized = trimmed

  if (normalized.startsWith("|")) {
    const cells = normalized
      .split("|")
      .map((cell) => cell.trim())
      .filter(Boolean)
      .filter((cell) => !/^[-: ]+$/.test(cell))
    if (cells.length === 0) return undefined
    normalized = cells.join(" | ")
  } else {
    normalized = normalized
      .replace(/^>\s*/, "")
      .replace(/^[-*+]\s+/, "")
      .replace(/^\d+\.\s+/, "")
  }

  normalized = normalized
    .replace(/\[\[([^\]]+)\]\]/g, "$1")
    .replace(/`+/g, "")
    .replace(/\*\*(.*?)\*\*/g, "$1")
    .replace(/\*(.*?)\*/g, "$1")
    .replace(/__(.*?)__/g, "$1")
    .replace(/\s+/g, " ")
    .trim()

  return normalized || undefined
}

function isRagRelatedText(value: string): boolean {
  const lower = value.toLowerCase()
  return RAG_RELATED_KEYWORDS.some((keyword) => lower.includes(keyword))
}

function truncateText(value: string, maxLength: number): string {
  if (value.length <= maxLength) return value
  return `${value.slice(0, maxLength - 3)}...`
}
