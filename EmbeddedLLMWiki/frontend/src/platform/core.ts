import { getHost } from "./host"

export async function invoke<T>(command: string, payload?: unknown): Promise<T> {
  return getHost().invoke<T>(command, payload ?? {})
}

export function convertFileSrc(path: string): string {
  return getHost().convertFileSrc(path)
}
