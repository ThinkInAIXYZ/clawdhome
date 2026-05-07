import { useState, useEffect } from "react"
import i18n from "@/i18n"
import { useWikiStore } from "@/stores/wiki-store"
import { useReviewStore } from "@/stores/review-store"
import { useChatStore } from "@/stores/chat-store"
import { listDirectory, openProject } from "@/commands/fs"
import { getLastProject, getRecentProjects, saveLastProject, loadLlmConfig, loadLanguage, loadSearchApiConfig, loadEmbeddingConfig, saveLanguage } from "@/lib/project-store"
import { loadReviewItems, loadChatHistory } from "@/lib/persist"
import { setupAutoSave } from "@/lib/auto-save"
import { startClipWatcher } from "@/lib/clip-watcher"
import { startSourceIngestWatcher, stopSourceIngestWatcher } from "@/lib/source-ingest-watcher"
import { AppLayout } from "@/components/layout/app-layout"
import type { WikiProject } from "@/types/wiki"
import { Button } from "@/components/ui/button"
import { getBootstrap, getHost } from "@/platform/host"

function App() {
  const project = useWikiStore((s) => s.project)
  const setProject = useWikiStore((s) => s.setProject)
  const setFileTree = useWikiStore((s) => s.setFileTree)
  const setSelectedFile = useWikiStore((s) => s.setSelectedFile)
  const setActiveView = useWikiStore((s) => s.setActiveView)
  const [loading, setLoading] = useState(true)
  const [startupError, setStartupError] = useState<string | null>(null)

  // Set up auto-save and clip watcher once on mount
  useEffect(() => {
    setupAutoSave()
    startClipWatcher()
  }, [])

  useEffect(() => {
    if (!project?.path) {
      stopSourceIngestWatcher()
      return
    }

    startSourceIngestWatcher(project.path)
    return () => {
      stopSourceIngestWatcher()
    }
  }, [project?.path])

  // Auto-open last project on startup
  useEffect(() => {
    async function init() {
      try {
        const bootstrap = getBootstrap()
        console.log("[WikiApp] bootstrap loaded", bootstrap)
        const savedConfig = await loadLlmConfig()
        console.log("[WikiApp] llm config loaded", !!savedConfig)
        if (savedConfig) {
          useWikiStore.getState().setLlmConfig(savedConfig)
        }
        const savedSearchConfig = await loadSearchApiConfig()
        console.log("[WikiApp] search config loaded", !!savedSearchConfig)
        if (savedSearchConfig) {
          useWikiStore.getState().setSearchApiConfig(savedSearchConfig)
        }
        const savedEmbeddingConfig = await loadEmbeddingConfig()
        console.log("[WikiApp] embedding config loaded", !!savedEmbeddingConfig)
        if (savedEmbeddingConfig) {
          useWikiStore.getState().setEmbeddingConfig(savedEmbeddingConfig)
        }
        const savedLang = await loadLanguage()
        console.log("[WikiApp] language loaded", savedLang ?? "<none>")
        if (savedLang) {
          await i18n.changeLanguage(savedLang)
        } else {
          await i18n.changeLanguage("zh")
          await saveLanguage("zh")
        }
        const lastProject = await getLastProject()
        console.log("[WikiApp] last project loaded", lastProject?.path ?? "<none>")
        const targetPath = lastProject?.path === bootstrap.projectPath
          ? lastProject.path
          : bootstrap.projectPath
        console.log("[WikiApp] opening project", targetPath)
        const proj = await openProject(targetPath)
        console.log("[WikiApp] project opened", proj.path)
        await handleProjectOpened(proj)
        console.log("[WikiApp] project initialization complete", proj.path)
      } catch (error) {
        console.error("[WikiApp] startup failed", error)
        setStartupError(error instanceof Error ? error.message : String(error))
      } finally {
        console.log("[WikiApp] startup finished")
        setLoading(false)
      }
    }
    init()
  }, [])

  async function handleProjectOpened(proj: WikiProject) {
    console.log("[WikiApp] handleProjectOpened start", proj.path)
    setProject(proj)
    setSelectedFile(null)
    setActiveView("wiki")
    await saveLastProject(proj)
    console.log("[WikiApp] last project saved", proj.path)

    // Restore ingest queue (resume interrupted tasks)
    import("@/lib/ingest-queue").then(({ restoreQueue }) => {
      restoreQueue(proj.path).catch((err) =>
        console.error("Failed to restore ingest queue:", err)
      )
    })
    // Notify local clip server of the current project + all recent projects
    fetch("http://127.0.0.1:19827/project", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ path: proj.path }),
    }).catch(() => {})

    // Send all recent projects to clip server for extension project picker
    getRecentProjects().then((recents) => {
      const projects = recents.map((p) => ({ name: p.name, path: p.path }))
      fetch("http://127.0.0.1:19827/projects", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ projects }),
      }).catch(() => {})
    }).catch(() => {})
    try {
      const tree = await listDirectory(proj.path)
      setFileTree(tree)
      console.log("[WikiApp] file tree loaded", tree.length)
    } catch (err) {
      console.error("Failed to load file tree:", err)
    }
    // Load persisted review items
    try {
      const savedReview = await loadReviewItems(proj.path)
      if (savedReview.length > 0) {
        useReviewStore.getState().setItems(savedReview)
      }
      console.log("[WikiApp] review items restored", savedReview.length)
    } catch {
      // ignore, start fresh
    }
    // Load persisted chat history
    try {
      const savedChat = await loadChatHistory(proj.path)
      if (savedChat.conversations.length > 0) {
        useChatStore.getState().setConversations(savedChat.conversations)
        useChatStore.getState().setMessages(savedChat.messages)
        // Set most recent conversation as active
        const sorted = [...savedChat.conversations].sort((a, b) => b.updatedAt - a.updatedAt)
        if (sorted[0]) {
          useChatStore.getState().setActiveConversation(sorted[0].id)
        }
      }
      console.log("[WikiApp] chat history restored", savedChat.conversations.length)
    } catch {
      // ignore, start fresh
    }
  }

  if (loading) {
    return (
      <div className="flex h-screen items-center justify-center bg-background text-muted-foreground">
        Loading...
      </div>
    )
  }

  if (!project) {
    return (
      <div className="flex h-screen items-center justify-center bg-background p-6">
        <div className="w-full max-w-lg rounded-xl border bg-card p-6 shadow-sm">
          <h1 className="text-xl font-semibold">Wiki unavailable</h1>
          <p className="mt-2 text-sm text-muted-foreground">
            {startupError ?? "The shared ClawdHome Wiki project could not be opened."}
          </p>
          <div className="mt-4 flex gap-3">
            <Button onClick={() => window.location.reload()}>
              Retry
            </Button>
            <Button
              variant="outline"
              onClick={() => {
                getHost().openWikiSupport().catch((error) => {
                  window.alert(`Failed to open Wiki Support: ${error}`)
                })
              }}
            >
              Open Wiki Support
            </Button>
          </div>
        </div>
      </div>
    )
  }

  return <AppLayout />
}

export default App
