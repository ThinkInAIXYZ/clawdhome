import { describe, expect, it } from "vitest"
import {
  clampMaxNumResults,
  matchesKnowledgeBaseFilter,
  normalizeSearchQueries,
} from "@/lib/knowledge-base-schema"

describe("knowledge base query schema", () => {
  it("normalizes a single query into an array", () => {
    expect(normalizeSearchQueries("  knowledge graph  ")).toEqual(["knowledge graph"])
  })

  it("drops empty query strings when multiple queries are provided", () => {
    expect(normalizeSearchQueries(["first", " ", "second"])).toEqual(["first", "second"])
  })

  it("clamps max_num_results to the standard vector search range", () => {
    expect(clampMaxNumResults(0)).toBe(1)
    expect(clampMaxNumResults(88)).toBe(50)
    expect(clampMaxNumResults(undefined, 12)).toBe(12)
  })

  it("supports scalar equality filters", () => {
    expect(matchesKnowledgeBaseFilter(
      { type: "concept", source: "wiki" },
      { key: "type", type: "eq", value: "concept" },
    )).toBe(true)
  })

  it("supports array membership filters", () => {
    expect(matchesKnowledgeBaseFilter(
      { tags: ["llm", "search"], source: "wiki" },
      { key: "tags", type: "in", value: ["vector", "search"] },
    )).toBe(true)
  })

  it("supports compound filters", () => {
    expect(matchesKnowledgeBaseFilter(
      { type: "concept", source: "wiki", directory: "wiki/concepts" },
      {
        type: "and",
        filters: [
          { key: "type", type: "eq", value: "concept" },
          { key: "source", type: "eq", value: "wiki" },
        ],
      },
    )).toBe(true)
  })
})
