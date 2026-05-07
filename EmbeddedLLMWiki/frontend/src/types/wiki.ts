export interface WikiProject {
  name: string
  path: string
}

export interface FileNode {
  name: string
  path: string
  is_dir: boolean
  children?: FileNode[]
}

export interface WikiPage {
  path: string
  content: string
  frontmatter: Record<string, unknown>
}

export interface SourceDocumentState {
  path: string
  relativePath: string
  modifiedMs: number
  size: number
}

export interface PendingIngestRequest {
  projectPath: string
  sourcePath: string
  debounceMs: number
  reason?: string
}
