import { useEffect, useCallback, useRef } from "react"
import { X } from "lucide-react"
import { useWikiStore } from "@/stores/wiki-store"
import { readFile, writeFile } from "@/commands/fs"
import { getFileCategory, isBinary } from "@/lib/file-types"
import { WikiEditor } from "@/components/editor/wiki-editor"
import { FilePreview } from "@/components/editor/file-preview"
import { getFileName } from "@/lib/path-utils"

export function PreviewPanel() {
  const selectedFile = useWikiStore((s) => s.selectedFile)
  const fileContent = useWikiStore((s) => s.fileContent)
  const setFileContent = useWikiStore((s) => s.setFileContent)
  const setSelectedFile = useWikiStore((s) => s.setSelectedFile)
  const saveTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => {
    if (!selectedFile) {
      setFileContent("")
      return
    }

    const category = getFileCategory(selectedFile)

    if (isBinary(category)) {
      setFileContent("")
      return
    }

    readFile(selectedFile)
      .then(setFileContent)
      .catch((err) => setFileContent(`Error loading file: ${err}`))
  }, [selectedFile, setFileContent])

  const handleSave = useCallback(
    (markdown: string) => {
      if (!selectedFile) return
      if (saveTimerRef.current) clearTimeout(saveTimerRef.current)
      saveTimerRef.current = setTimeout(() => {
        writeFile(selectedFile, markdown).catch((err) =>
          console.error("Failed to save:", err)
        )
      }, 1000)
    },
    [selectedFile]
  )

  useEffect(() => {
    return () => {
      if (saveTimerRef.current) clearTimeout(saveTimerRef.current)
    }
  }, [])

  if (!selectedFile) {
    return (
      <div className="flex h-full items-center justify-center text-sm text-muted-foreground">
        Select a file to preview
      </div>
    )
  }

  const category = getFileCategory(selectedFile)
  const fileName = getFileName(selectedFile)

  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center justify-between border-b px-3 py-1.5">
        <span className="truncate text-xs text-muted-foreground" title={selectedFile}>
          {fileName}
        </span>
        <button
          onClick={() => setSelectedFile(null)}
          className="shrink-0 rounded p-1 text-muted-foreground hover:bg-accent"
        >
          <X className="h-3.5 w-3.5" />
        </button>
      </div>
      <div className="flex-1 min-w-0 overflow-auto">
        {category === "markdown" ? (
          <WikiEditor
            key={selectedFile}
            content={fileContent}
            onSave={handleSave}
          />
        ) : (
          <FilePreview
            key={selectedFile}
            filePath={selectedFile}
            textContent={fileContent}
          />
        )}
      </div>
    </div>
  )
}
