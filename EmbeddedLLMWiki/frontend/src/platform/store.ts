import { getHost } from "./host"

interface LoadOptions {
  autoSave?: boolean
}

interface HostStore {
  get<T>(key: string): Promise<T | null>
  set(key: string, value: unknown): Promise<void>
}

export async function load(name: string, _options?: LoadOptions): Promise<HostStore> {
  const host = getHost()
  await host.storeLoad(name)

  return {
    async get<T>(key: string) {
      return host.storeGet<T>(key)
    },
    async set(key: string, value: unknown) {
      await host.storeSet(key, value)
    },
  }
}
