import Foundation

@main
struct PromptMemorySearchTests {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let prompts = [
            PromptItem(
                title: "代码审查",
                body: "请从正确性、边界条件和测试覆盖角度审查下面的代码：{{input}}",
                summary: "代码审查模板",
                tags: ["review", "代码"],
                triggerKeywords: ["代码审查", "review"]
            ),
            PromptItem(
                title: "会议纪要整理",
                body: "把下面的会议记录整理成决议、风险和待办：{{input}}",
                summary: "会议记录整理",
                tags: ["meeting"],
                triggerKeywords: ["会议纪要", "待办"]
            )
        ]
        let indexes = Dictionary(uniqueKeysWithValues: prompts.map { ($0.id, PromptMemorySearch.makeIndex(for: $0)) })

        let review = PromptMemorySearch.search(query: "帮我 review 这段代码", items: prompts, indexes: indexes)
        expect(review.first?.item.title == "代码审查", "keyword/tag/title weighted search should rank code review first")
        expect((review.first?.score ?? 0) >= PromptMemorySearch.panelThreshold, "review query should pass panel threshold")

        let meeting = PromptMemorySearch.search(query: "会议纪要 待办", items: prompts, indexes: indexes)
        expect(meeting.first?.item.title == "会议纪要整理", "Chinese keyword search should rank meeting prompt first")

        let suggestion = PromptMemorySearch.bestSuggestion(query: "代码审查 review", items: prompts, indexes: indexes)
        expect(suggestion?.item.title == "代码审查", "strong title and keyword match should produce suggestion")

        let low = PromptMemorySearch.bestSuggestion(query: "天气怎么样", items: prompts, indexes: indexes)
        expect(low == nil, "unrelated query should not produce proactive suggestion")

        let hashA = PromptMemorySearch.queryHash("  代码 审查 ")
        let hashB = PromptMemorySearch.queryHash("代码   审查")
        expect(hashA == hashB, "query hash should be based on normalized text")

        print("Prompt memory search tests passed.")
    }
}
