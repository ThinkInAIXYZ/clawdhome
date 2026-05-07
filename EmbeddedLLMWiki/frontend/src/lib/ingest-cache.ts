import { readFile, writeFile } from "@/commands/fs"
import { normalizePath } from "@/lib/path-utils"

/**
 * SHA256-based ingest cache.
 * Stores hash of source file content → skips re-ingest if unchanged.
 * Cache file: .llm-wiki/ingest-cache.json
 */

interface CacheEntry {
  hash: string
  timestamp: number
  filesWritten: string[]
}

interface CacheData {
  entries: Record<string, CacheEntry> // keyed by source filename
}

async function sha256(content: string): Promise<string> {
  const encoder = new TextEncoder()
  const data = encoder.encode(content)
  const hashBuffer = await crypto.subtle.digest("SHA-256", data)
  const hashArray = Array.from(new Uint8Array(hashBuffer))
  return hashArray.map((b) => b.toString(16).padStart(2, "0")).join("")
}

function cachePath(projectPath: string): string {
  return `${normalizePath(projectPath)}/.llm-wiki/ingest-cache.json`
}

async function loadCache(projectPath: string): Promise<CacheData> {
  try {
    const raw = await readFile(cachePath(projectPath))
    return JSON.parse(raw) as CacheData
  } catch {
    return { entries: {} }
  }
}

async function saveCache(projectPath: string, cache: CacheData): Promise<void> {
  try {
    await writeFile(cachePath(projectPath), JSON.stringify(cache, null, 2))
  } catch {
    // non-critical
  }
}

/**
 * Check if a source file has already been ingested with the same content.
 * Returns the list of previously written files if cached, or null if ingest is needed.
 */
export async function checkIngestCache(
  projectPath: string,
  sourceFileName: string,
  sourceContent: string,
): Promise<string[] | null> {
  const cache = await loadCache(projectPath)
  const entry = cache.entries[sourceFileName]
  if (!entry) return null

  const currentHash = await sha256(sourceContent)
  if (entry.hash === currentHash) {
    return entry.filesWritten
  }
  return null
}

/**
 * Save ingest result to cache after successful ingest.
 */
export async function saveIngestCache(
  projectPath: string,
  sourceFileName: string,
  sourceContent: string,
  filesWritten: string[],
): Promise<void> {
  const cache = await loadCache(projectPath)
  const hash = await sha256(sourceContent)
  const newEntries = { ...cache.entries }
  newEntries[sourceFileName] = {
    hash,
    timestamp: Date.now(),
    filesWritten,
  }
  await saveCache(projectPath, { entries: newEntries })
}

/**
 * Remove a source file entry from cache (e.g., when source is deleted).
 */
export async function removeFromIngestCache(
  projectPath: string,
  sourceFileName: string,
): Promise<void> {
  const cache = await loadCache(projectPath)
  const newEntries = { ...cache.entries }
  delete newEntries[sourceFileName]
  await saveCache(projectPath, { entries: newEntries })
}
