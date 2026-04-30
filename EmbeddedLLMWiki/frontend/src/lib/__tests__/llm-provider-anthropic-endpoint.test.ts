import { describe, expect, it } from "vitest"

function normalizeBaseUrl(value: string): string {
  return value.trim().replace(/\/+$/, "")
}

function anthropicEndpoint(base: string): string {
  const normalized = normalizeBaseUrl(base)
  if (!normalized) return "https://api.anthropic.com/v1/messages"
  if (normalized.endsWith("/v1/messages")) return normalized
  if (normalized.endsWith("/v1")) return `${normalized}/messages`
  return `${normalized}/v1/messages`
}

describe("anthropicEndpoint", () => {
  it("falls back to Anthropic official endpoint when custom base is empty", () => {
    expect(anthropicEndpoint("")).toBe("https://api.anthropic.com/v1/messages")
  })

  it("appends /v1/messages for anthropic-compatible base urls", () => {
    expect(anthropicEndpoint("https://api.kimi.com/coding")).toBe(
      "https://api.kimi.com/coding/v1/messages"
    )
  })

  it("preserves urls that already end with /v1/messages", () => {
    expect(anthropicEndpoint("https://example.com/v1/messages")).toBe(
      "https://example.com/v1/messages"
    )
  })

  it("appends /messages when the base already ends with /v1", () => {
    expect(anthropicEndpoint("https://example.com/v1")).toBe(
      "https://example.com/v1/messages"
    )
  })
})
