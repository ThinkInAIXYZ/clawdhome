import { listSourceDocuments, takePendingIngestRequests } from "@/commands/fs"
import { enqueueIngest } from "@/lib/ingest-queue"
import { normalizePath } from "@/lib/path-utils"
import { useWikiStore } from "@/stores/wiki-store"
import type { PendingIngestRequest, SourceDocumentState } from "@/types/wiki"

const POLL_INTERVAL_MS = 2000
const DEFAULT_DEBOUNCE_MS = 2500

let activeProjectPath = ""
let pollTimer: number | null = null
let polling = false
let initialized = false
let snapshot = new Map<string, string>()
let debounceTimers = new Map<string, number>()
let lastQueuedFingerprints = new Map<string, string>()

function fingerprint(document: SourceDocumentState): string {
  return `${document.modifiedMs}:${document.size}`
}

function llmConfigured(): boolean {
  const llmConfig = useWikiStore.getState().llmConfig
  return Boolean(
    llmConfig.apiKey ||
      llmConfig.provider === "ollama" ||
      llmConfig.provider === "custom"
  )
}

function clearDebounceTimers() {
  for (const timer of debounceTimers.values()) {
    window.clearTimeout(timer)
  }
  debounceTimers.clear()
}

async function scheduleDebouncedIngest(
  projectPath: string,
  sourcePath: string,
  debounceMs: number,
  reason: string,
  fileFingerprint?: string,
) {
  const normalizedProjectPath = normalizePath(projectPath)
  const normalizedSourcePath = normalizePath(sourcePath)
  const delay = Math.min(Math.max(debounceMs, 200), 30_000)

  const existingTimer = debounceTimers.get(normalizedSourcePath)
  if (existingTimer) {
    window.clearTimeout(existingTimer)
  }

  const timer = window.setTimeout(async () => {
    debounceTimers.delete(normalizedSourcePath)

    if (activeProjectPath !== normalizedProjectPath) {
      return
    }
    if (!llmConfigured()) {
      console.warn(`[Auto Ingest Watcher] Skip ${normalizedSourcePath} (${reason}): LLM not configured`)
      return
    }

    try {
      await enqueueIngest(normalizedProjectPath, normalizedSourcePath)
      if (fileFingerprint) {
        lastQueuedFingerprints.set(normalizedSourcePath, fileFingerprint)
      }
      console.log(`[Auto Ingest Watcher] Enqueued ${normalizedSourcePath} (${reason})`)
    } catch (error) {
      console.error(`[Auto Ingest Watcher] Failed to enqueue ${normalizedSourcePath}:`, error)
    }
  }, delay)

  debounceTimers.set(normalizedSourcePath, timer)
}

async function handlePendingRequests(requests: PendingIngestRequest[]) {
  for (const request of requests) {
    if (normalizePath(request.projectPath) !== activeProjectPath) {
      continue
    }
    await scheduleDebouncedIngest(
      request.projectPath,
      request.sourcePath,
      request.debounceMs || DEFAULT_DEBOUNCE_MS,
      request.reason || "manual_trigger",
    )
  }
}

async function handleScannedDocuments(documents: SourceDocumentState[]) {
  const nextSnapshot = new Map<string, string>()
  for (const document of documents) {
    const normalizedPath = normalizePath(document.path)
    const currentFingerprint = fingerprint(document)
    nextSnapshot.set(normalizedPath, currentFingerprint)

    if (!initialized) {
      continue
    }

    const previousFingerprint = snapshot.get(normalizedPath)
    if (previousFingerprint === currentFingerprint) {
      continue
    }
    if (lastQueuedFingerprints.get(normalizedPath) === currentFingerprint) {
      continue
    }

    const reason = previousFingerprint ? "source_updated" : "source_created"
    await scheduleDebouncedIngest(
      activeProjectPath,
      normalizedPath,
      DEFAULT_DEBOUNCE_MS,
      reason,
      currentFingerprint,
    )
  }

  snapshot = nextSnapshot
  initialized = true
}

async function poll() {
  if (!activeProjectPath || polling) {
    return
  }

  polling = true
  try {
    const [documents, pendingRequests] = await Promise.all([
      listSourceDocuments(activeProjectPath).catch((error) => {
        console.error("[Auto Ingest Watcher] Failed to scan source documents:", error)
        return [] as SourceDocumentState[]
      }),
      takePendingIngestRequests(activeProjectPath).catch((error) => {
        console.error("[Auto Ingest Watcher] Failed to read pending ingest requests:", error)
        return [] as PendingIngestRequest[]
      }),
    ])

    await handleScannedDocuments(documents)
    await handlePendingRequests(pendingRequests)
  } finally {
    polling = false
  }
}

export function startSourceIngestWatcher(projectPath: string) {
  const normalizedProjectPath = normalizePath(projectPath)
  if (!normalizedProjectPath) {
    stopSourceIngestWatcher()
    return
  }

  if (activeProjectPath === normalizedProjectPath && pollTimer !== null) {
    return
  }

  stopSourceIngestWatcher()
  activeProjectPath = normalizedProjectPath
  initialized = false
  snapshot = new Map()
  lastQueuedFingerprints = new Map()

  void poll()
  pollTimer = window.setInterval(() => {
    void poll()
  }, POLL_INTERVAL_MS)
}

export function stopSourceIngestWatcher() {
  if (pollTimer !== null) {
    window.clearInterval(pollTimer)
    pollTimer = null
  }

  activeProjectPath = ""
  initialized = false
  polling = false
  snapshot = new Map()
  lastQueuedFingerprints = new Map()
  clearDebounceTimers()
}
