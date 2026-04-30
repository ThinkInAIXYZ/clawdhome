import { readFile, writeFile } from "@/commands/fs"
import { streamChat } from "./llm-client"
import { useWikiStore, type LlmConfig } from "@/stores/wiki-store"
import { LANGUAGE_RULE } from "./ingest"
import { normalizePath } from "@/lib/path-utils"

/**
 * Lightweight post-save enrichment: ask LLM to add [[wikilinks]] to a saved wiki page.
 * Much cheaper than full auto-ingest — no new pages created, just cross-references added.
 */
export async function enrichWithWikilinks(
  projectPath: string,
  filePath: string,
  llmConfig: LlmConfig,
): Promise<void> {
  const pp = normalizePath(projectPath)
  const fp = normalizePath(filePath)
  const [content, index] = await Promise.all([
    readFile(fp),
    readFile(`${pp}/wiki/index.md`).catch(() => ""),
  ])

  if (!content || !index) return

  // Quick LLM call: just add wikilinks, don't change content
  let enriched = ""

  await streamChat(
    llmConfig,
    [
      {
        role: "system",
        content: [
          "You are a wiki cross-referencing assistant.",
          "Your ONLY job: add [[wikilinks]] to the text where entities or concepts from the wiki index are mentioned.",
          "",
          LANGUAGE_RULE,
          "",
          "Rules:",
          "- Return the COMPLETE text with [[wikilinks]] added.",
          "- Do NOT change any content, only add [[ and ]] around existing words that match wiki pages.",
          "- Do NOT add new text, summaries, or explanations.",
          "- Do NOT remove or modify any existing text.",
          "- Preserve all YAML frontmatter exactly as-is.",
          "- Only link to pages that exist in the wiki index below.",
          "- Each page should be linked only on first mention.",
          "",
          `## Wiki Index (link to these pages)\n${index}`,
        ].join("\n"),
      },
      {
        role: "user",
        content: `Add [[wikilinks]] to this wiki page:\n\n${content}`,
      },
    ],
    {
      onToken: (token) => { enriched += token },
      onDone: () => {},
      onError: () => {},
    },
  )

  if (!enriched || enriched.length < content.length * 0.5) {
    // LLM returned something too short — probably an error, don't overwrite
    return
  }

  // Write the enriched version back
  await writeFile(fp, enriched)

  // Refresh graph
  useWikiStore.getState().bumpDataVersion()
}
