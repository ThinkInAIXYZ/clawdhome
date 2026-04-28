import { getHost, type HostDialogOptions } from "./host"

export async function open(options: HostDialogOptions): Promise<string | string[] | null> {
  return getHost().openDialog(options)
}
