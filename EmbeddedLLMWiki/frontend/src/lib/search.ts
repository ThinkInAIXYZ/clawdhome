import { queryKnowledgeBase } from "@/lib/knowledge-base"
import { normalizePath } from "@/lib/path-utils"
import { tokenizeQuery } from "@/lib/search-utils"

export interface SearchResult {
  path: string
  title: string
  snippet: string
  titleMatch: boolean
  score: number
}

const MAX_RESULTS = 20

export { tokenizeQuery }

export async function searchWiki(
  projectPath: string,
  query: string,
): Promise<SearchResult[]> {
  if (!query.trim()) return []

  const pp = normalizePath(projectPath)
  const response = await queryKnowledgeBase(pp, {
    query,
    max_num_results: MAX_RESULTS,
  })

  return response.data.map((item) => ({
    path: `${pp}/${item.file_id}`,
    title: item.attributes.title,
    snippet: item.content[0]?.text ?? "",
    titleMatch: item.attributes.title_match,
    score: item.score,
  }))
}
