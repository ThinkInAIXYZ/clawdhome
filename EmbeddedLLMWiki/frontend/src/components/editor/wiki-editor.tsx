import { useMemo } from "react"
import { Editor, rootCtx, defaultValueCtx } from "@milkdown/kit/core"
import { commonmark } from "@milkdown/kit/preset/commonmark"
import { gfm } from "@milkdown/kit/preset/gfm"
import { history } from "@milkdown/kit/plugin/history"
import { listener, listenerCtx } from "@milkdown/kit/plugin/listener"
import { math } from "@milkdown/plugin-math"
import { nord } from "@milkdown/theme-nord"
import { Milkdown, MilkdownProvider, useEditor } from "@milkdown/react"
import "@milkdown/theme-nord/style.css"
import "katex/dist/katex.min.css"
import { convertLatexToUnicode } from "@/lib/latex-to-unicode"

interface WikiEditorInnerProps {
  content: string
  onSave: (markdown: string) => void
}

function WikiEditorInner({ content, onSave }: WikiEditorInnerProps) {
  useEditor(
    (root) =>
      Editor.make()
        .config(nord)
        .config((ctx) => {
          ctx.set(rootCtx, root)
          ctx.set(defaultValueCtx, content)
          ctx.get(listenerCtx).markdownUpdated((_ctx, markdown) => {
            onSave(markdown)
          })
        })
        .use(commonmark)
        .use(gfm)
        .use(math)
        .use(history)
        .use(listener),
    [content],
  )

  return <Milkdown />
}

interface WikiEditorProps {
  content: string
  onSave: (markdown: string) => void
}

function wrapBareMathBlocks(text: string): string {
  return text.replace(
    /(?<!\$\$\s*)(\\begin\{[^}]+\}[\s\S]*?\\end\{[^}]+\})(?!\s*\$\$)/g,
    (_match, block: string) => `$$\n${block}\n$$`,
  )
}

export function WikiEditor({ content, onSave }: WikiEditorProps) {
  const processedContent = useMemo(() => wrapBareMathBlocks(content), [content])

  return (
    <MilkdownProvider>
      <div className="prose prose-invert min-w-0 max-w-none overflow-hidden p-6">
        <WikiEditorInner content={processedContent} onSave={onSave} />
      </div>
    </MilkdownProvider>
  )
}
