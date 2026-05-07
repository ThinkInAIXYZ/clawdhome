import path from "path"
import { defineConfig } from "vite"
import react from "@vitejs/plugin-react"
import tailwindcss from "@tailwindcss/vite"

const host = process.env.TAURI_DEV_HOST

// https://vitejs.dev/config/
export default defineConfig(async () => ({
  plugins: [react(), tailwindcss()],
  base: "./",

  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
      "@tauri-apps/api/core": path.resolve(__dirname, "./src/platform/core.ts"),
      "@tauri-apps/plugin-dialog": path.resolve(__dirname, "./src/platform/dialog.ts"),
      "@tauri-apps/plugin-store": path.resolve(__dirname, "./src/platform/store.ts"),
    },
  },

  // Vite options tailored for the embedded ClawdHome webview.
  //
  // 1. prevent vite from obscuring rust errors
  clearScreen: false,
  // 2. tauri expects a fixed port, fail if that port is not available
  server: {
    port: 1420,
    strictPort: true,
    host: host || false,
    hmr: host
      ? {
          protocol: "ws",
          host,
          port: 1421,
        }
      : undefined,
    watch: {
      // 3. avoid watching Rust build outputs from the embedded runtime
      ignored: ["../runtime/target/**", "**/runtime/target/**"],
    },
  },

  test: {
    environment: "node",
  },
  build: {
    chunkSizeWarningLimit: 1600,
  },
}))
