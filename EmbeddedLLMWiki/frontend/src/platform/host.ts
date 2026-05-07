export interface HostBootstrap {
  projectPath: string
  projectName: string
  appStatePath: string
  locale?: string
}

export interface HostDialogOptions {
  directory?: boolean
  multiple?: boolean
  title?: string
  filters?: Array<{
    name: string
    extensions: string[]
  }>
}

export interface ClawdHomeWikiHost {
  invoke<T>(command: string, payload?: unknown): Promise<T>
  openDialog(options: HostDialogOptions): Promise<string | string[] | null>
  storeLoad(name: string): Promise<void>
  storeGet<T>(key: string): Promise<T | null>
  storeSet(key: string, value: unknown): Promise<void>
  convertFileSrc(path: string): string
  openWikiSupport(): Promise<void>
}

declare global {
  interface Window {
    ClawdHomeWiki?: ClawdHomeWikiHost
    __CLAWDHOME_WIKI_BOOTSTRAP__?: HostBootstrap
  }
}

export function getHost(): ClawdHomeWikiHost {
  if (!window.ClawdHomeWiki) {
    throw new Error("ClawdHome Wiki host bridge unavailable")
  }
  return window.ClawdHomeWiki
}

export function getBootstrap(): HostBootstrap {
  const bootstrap = window.__CLAWDHOME_WIKI_BOOTSTRAP__
  if (!bootstrap?.projectPath || !bootstrap.projectName) {
    throw new Error("ClawdHome Wiki bootstrap data unavailable")
  }
  return bootstrap
}
