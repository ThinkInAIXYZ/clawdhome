import Foundation
import SystemConfiguration

enum LlmWikiManager {
    private static let projectRoot = LLMWikiPaths.projectRoot
    private static let runtimeRoot = LLMWikiPaths.runtimeRoot
    private static let socketPath = LLMWikiPaths.socketPath
    private static let heartbeatSocketPath = LLMWikiPaths.heartbeatSocketPath
    private static let metadataPath = LLMWikiPaths.metadataPath

    static func setupLlmWikiNotes(username: String) throws {
        try VaultManager.setupVault(username: username)
        let notesPath = LLMWikiPaths.notesPath(for: username)
        let group = perShrimpGroup(username)
        let adminUsers = resolveAdminUsers()

        try createGroupIfNeeded(group)
        for admin in adminUsers {
            try addMemberIfNeeded(admin, to: group)
        }
        try addMemberIfNeeded(username, to: group)

        try ensureDirectory(notesPath)
        try FilePermissionHelper.chown(notesPath, owner: username, group: group)
        try FilePermissionHelper.chmod(notesPath, mode: "2770")
        try FilePermissionHelper.grantDirectoryWriteACL(notesPath, username: username)
        for admin in adminUsers {
            try? FilePermissionHelper.grantDirectoryWriteACL(notesPath, username: admin)
        }
    }

    static func repairProject() throws {
        try ensureSharedGroup()
        try ensureProjectSkeleton()
        for managed in DashboardCollector.fetchManagedUsers() {
            try setupLlmWikiNotes(username: managed.username)
            try repairMapping(username: managed.username)
            try installBundledSkill(username: managed.username)
        }
    }

    static func repairMapping(username: String) throws {
        try ensureProjectSkeleton()
        try setupLlmWikiNotes(username: username)
        let linkPath = LLMWikiPaths.projectSymlinkPath(for: username)
        let targetPath = LLMWikiPaths.notesPath(for: username)
        try replaceSymlink(at: linkPath, target: targetPath)
    }

    static func repairRuntimePermissions() throws {
        try ensureSharedGroup()
        let runtimeOwner = resolvePrimaryAdminUser()
        try ensureDirectory(runtimeRoot)
        try FilePermissionHelper.chown(runtimeRoot, owner: runtimeOwner, group: LLMWikiPaths.sharedGroup)
        try FilePermissionHelper.chmod(runtimeRoot, mode: "0770")
        for path in [socketPath, heartbeatSocketPath, metadataPath] where FileManager.default.fileExists(atPath: path) {
            try? FilePermissionHelper.chown(path, owner: runtimeOwner, group: LLMWikiPaths.sharedGroup)
            try? FilePermissionHelper.chmod(path, mode: "0660")
        }
    }

    static func installBundledSkill(username: String) throws {
        let skillPath = LLMWikiPaths.workspaceSkillPath(for: username)
        let workspaceRoot = "/Users/\(username)/.openclaw/workspace"
        let skillRoot = URL(fileURLWithPath: skillPath)
        let scriptsDir = skillRoot.appendingPathComponent("scripts")
        let referencesDir = skillRoot.appendingPathComponent("references")

        try ensureDirectory(skillRoot.deletingLastPathComponent().path)
        try ensureDirectory(skillPath)
        try ensureDirectory(scriptsDir.path)
        try ensureDirectory(referencesDir.path)

        for file in skillSpec() {
            let destination = skillRoot.appendingPathComponent(file.relativePath)
            try ensureDirectory(destination.deletingLastPathComponent().path)
            guard let data = file.content.data(using: .utf8) else { continue }
            try data.write(to: destination, options: .atomic)
            if file.executable {
                try FilePermissionHelper.chmod(destination.path, mode: "755")
            }
        }

        try FilePermissionHelper.chownRecursive(skillPath, owner: username)
        if FileManager.default.fileExists(atPath: workspaceRoot) {
            try? FilePermissionHelper.chownRecursive(workspaceRoot, owner: username)
        }
        try ensureWorkspaceToolsGuidance(username: username)
    }

    static func auditGlobalState() -> LLMWikiGlobalAudit {
        let projectExists = FileManager.default.fileExists(atPath: projectRoot)
        let wikiExists = FileManager.default.fileExists(atPath: "\(projectRoot)/wiki")
        let rawSourcesExists = FileManager.default.fileExists(atPath: "\(projectRoot)/raw/sources")
        let shrimpsSourcesExists = FileManager.default.fileExists(atPath: LLMWikiPaths.shrimpsSourcesRoot)
        let runtimeExists = FileManager.default.fileExists(atPath: runtimeRoot)
        let socketExists = FileManager.default.fileExists(atPath: socketPath)
        let heartbeatExists = FileManager.default.fileExists(atPath: heartbeatSocketPath)
        let metadataExists = FileManager.default.fileExists(atPath: metadataPath)
        let attrs = try? FileManager.default.attributesOfItem(atPath: runtimeRoot)
        let runtimeOwner = attrs?[.ownerAccountName] as? String
        let runtimeGroup = attrs?[.groupOwnerAccountName] as? String
        let runtimeMode = permissionString(attrs?[.posixPermissions])
        let metadataSecurity = metadataSecurityInfo()

        return LLMWikiGlobalAudit(
            projectPath: projectRoot,
            runtimePath: runtimeRoot,
            socketPath: socketPath,
            heartbeatSocketPath: heartbeatSocketPath,
            metadataPath: metadataPath,
            projectExists: projectExists,
            projectStructureComplete: projectExists && wikiExists && rawSourcesExists && shrimpsSourcesExists,
            wikiExists: wikiExists,
            rawSourcesExists: rawSourcesExists,
            shrimpsSourcesExists: shrimpsSourcesExists,
            runtimeExists: runtimeExists,
            socketExists: socketExists,
            heartbeatExists: heartbeatExists,
            metadataExists: metadataExists,
            runtimeOwner: runtimeOwner,
            runtimeGroup: runtimeGroup,
            runtimeMode: runtimeMode,
            metadataSecurityMode: metadataSecurity.mode,
            metadataSecurityGroup: metadataSecurity.group
        )
    }

    static func auditUserState(username: String) -> LLMWikiUserAudit {
        let notesPath = LLMWikiPaths.notesPath(for: username)
        let notesEntryPath = LLMWikiPaths.notesEntryPath(for: username)
        let symlinkPath = LLMWikiPaths.projectSymlinkPath(for: username)
        let skillPath = LLMWikiPaths.workspaceSkillPath(for: username)

        let notesAttrs = try? FileManager.default.attributesOfItem(atPath: notesPath)
        let notesExists = FileManager.default.fileExists(atPath: notesPath)
        let symlinkExists = (try? FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath)) != nil
        let symlinkValid = (try? FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath)) == notesPath
        let skillExists = FileManager.default.fileExists(atPath: skillPath)

        return LLMWikiUserAudit(
            username: username,
            notesPath: notesPath,
            notesEntryPath: notesEntryPath,
            projectSymlinkPath: symlinkPath,
            workspaceSkillPath: skillPath,
            notesExists: notesExists,
            notesOwner: notesAttrs?[.ownerAccountName] as? String,
            notesGroup: notesAttrs?[.groupOwnerAccountName] as? String,
            notesMode: permissionString(notesAttrs?[.posixPermissions]),
            projectSymlinkExists: symlinkExists,
            projectSymlinkValid: symlinkValid,
            workspaceSkillExists: skillExists
        )
    }

    private static func ensureProjectSkeleton() throws {
        let runtimeOwner = resolvePrimaryAdminUser()
        let directories = [
            projectRoot,
            "\(projectRoot)/.llm-wiki",
            "\(projectRoot)/.llm-wiki/chats",
            "\(projectRoot)/wiki",
            "\(projectRoot)/wiki/entities",
            "\(projectRoot)/wiki/concepts",
            "\(projectRoot)/wiki/sources",
            "\(projectRoot)/wiki/queries",
            "\(projectRoot)/wiki/comparisons",
            "\(projectRoot)/wiki/synthesis",
            "\(projectRoot)/raw",
            "\(projectRoot)/raw/assets",
            "\(projectRoot)/raw/sources",
            LLMWikiPaths.shrimpsSourcesRoot,
        ]
        for directory in directories {
            try ensureDirectory(directory)
            try? FilePermissionHelper.chown(directory, owner: runtimeOwner, group: LLMWikiPaths.sharedGroup)
            try? FilePermissionHelper.chmod(directory, mode: "2775")
        }

        let files = [
            ("\(projectRoot)/schema.md", schemaContent()),
            ("\(projectRoot)/purpose.md", purposeContent()),
            ("\(projectRoot)/wiki/index.md", indexContent()),
            ("\(projectRoot)/wiki/log.md", logContent()),
            ("\(projectRoot)/wiki/overview.md", overviewContent()),
            ("\(projectRoot)/.llm-wiki/conversations.json", "[]\n"),
            ("\(projectRoot)/.llm-wiki/ingest-cache.json", "{}\n"),
            ("\(projectRoot)/.llm-wiki/ingest-queue.json", "[]\n"),
            ("\(projectRoot)/.llm-wiki/review.json", "{}\n"),
        ]
        for (path, content) in files {
            try writeIfMissing(path: path, content: content)
            if FileManager.default.fileExists(atPath: path) {
                try? FilePermissionHelper.chown(path, owner: runtimeOwner, group: LLMWikiPaths.sharedGroup)
                try? FilePermissionHelper.chmod(path, mode: "664")
            }
        }
    }

    private static func ensureSharedGroup() throws {
        try createGroupIfNeeded(LLMWikiPaths.sharedGroup)
        for admin in resolveAdminUsers() {
            try addMemberIfNeeded(admin, to: LLMWikiPaths.sharedGroup)
        }
    }

    private static func replaceSymlink(at linkPath: String, target: String) throws {
        let fm = FileManager.default
        if let existing = try? fm.destinationOfSymbolicLink(atPath: linkPath), existing == target {
            return
        }
        if fm.fileExists(atPath: linkPath) || (try? fm.destinationOfSymbolicLink(atPath: linkPath)) != nil {
            try fm.removeItem(atPath: linkPath)
        }
        try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
    }

    private static func ensureDirectory(_ path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        }
    }

    private static func ensureWorkspaceToolsGuidance(username: String) throws {
        let workspaceRoot = "/Users/\(username)/.openclaw/workspace"
        let toolsPath = "\(workspaceRoot)/TOOLS.md"

        try ensureDirectory(workspaceRoot)

        let existingData = FileManager.default.contents(atPath: toolsPath) ?? Data()
        let existingContent = String(data: existingData, encoding: .utf8) ?? ""
        guard let mergedToolsContent = LLMWikiWorkspaceGuidance.mergedToolsContent(existing: existingContent) else {
            return
        }

        guard let data = mergedToolsContent.data(using: .utf8) else { return }
        try data.write(to: URL(fileURLWithPath: toolsPath), options: .atomic)
        try? FilePermissionHelper.chown(toolsPath, owner: username, group: perShrimpGroup(username))
        try? FilePermissionHelper.chmod(toolsPath, mode: "664")
    }

    private static func writeIfMissing(path: String, content: String) throws {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        guard let data = content.data(using: .utf8) else { return }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func resolvePrimaryAdminUser() -> String {
        let console = resolveConsoleAdmin()
        if !console.isEmpty { return console }
        return resolveAdminUsers().first ?? "root"
    }

    private static func resolveConsoleAdmin() -> String {
        var uid: uid_t = 0
        guard let console = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?,
              !console.isEmpty,
              console != "loginwindow"
        else { return "" }
        return console
    }

    private static func resolveAdminUsers() -> [String] {
        var users = Set<String>()
        let console = resolveConsoleAdmin()
        if !console.isEmpty {
            users.insert(console)
        }
        if let output = try? run("/usr/bin/dscl", args: ["/Local/Default", "-read", "/Groups/admin", "GroupMembership"]) {
            output
                .components(separatedBy: ":")
                .dropFirst()
                .joined(separator: ":")
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != "root" && !$0.hasPrefix("_") }
                .forEach { users.insert($0) }
        }
        return users.sorted()
    }

    private static func perShrimpGroup(_ username: String) -> String {
        "clawdhome-\(username)"
    }

    private static func createGroupIfNeeded(_ groupName: String) throws {
        do {
            try run("/usr/sbin/dseditgroup", args: ["-o", "create", groupName])
        } catch {
            if groupExists(groupName) {
                return
            }
            throw error
        }
    }

    private static func addMemberIfNeeded(_ user: String, to group: String) throws {
        do {
            try run("/usr/sbin/dseditgroup", args: ["-o", "edit", "-a", user, "-t", "user", group])
        } catch {
            if isUser(user, memberOf: group) {
                return
            }
            throw error
        }
    }

    private static func groupExists(_ groupName: String) -> Bool {
        (try? run("/usr/bin/dscl", args: ["/Local/Default", "-read", "/Groups/\(groupName)", "RecordName"])) != nil
    }

    private static func isUser(_ user: String, memberOf group: String) -> Bool {
        guard let output = try? run("/usr/sbin/dseditgroup", args: ["-o", "checkmember", "-m", user, group]) else {
            return false
        }
        return output.lowercased().contains("yes")
    }

    private static func permissionString(_ raw: Any?) -> String? {
        guard let number = raw as? NSNumber else { return nil }
        return String(format: "%04o", number.intValue & 0o7777)
    }

    private static func metadataSecurityInfo() -> (mode: String?, group: String?) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: metadataPath)),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let security = payload["security"] as? [String: Any]
        else {
            return (nil, nil)
        }
        return (
            security["runtimeMode"] as? String,
            security["runtimeGroup"] as? String
        )
    }

    private struct SkillFile {
        let relativePath: String
        let content: String
        let executable: Bool
    }

    private static func skillSpec() -> [SkillFile] {
        [
            SkillFile(relativePath: "SKILL.md", content: skillMarkdown(), executable: false),
            SkillFile(relativePath: "scripts/search_knowledge_base.mjs", content: searchScript(), executable: true),
            SkillFile(relativePath: "scripts/get_knowledge_document.mjs", content: documentScript(), executable: true),
            SkillFile(relativePath: "scripts/save_note_to_kb.mjs", content: saveNoteScript(), executable: true),
            SkillFile(relativePath: "references/note_writing_guide.md", content: noteWritingGuide(), executable: false),
        ]
    }

    private static func skillMarkdown() -> String {
        """
        ---
        name: \(LLMWikiPaths.skillName)
        version: 1.0.0
        description: This skill should be used when the shrimp needs to save notes, summaries, knowledge snippets, or memories into its LLM Wiki notes directory, query the shared LLM Wiki knowledge base, fetch a document with related content, or get guidance on writing high-quality knowledge notes.
        ---

        # ClawdHome LLM Wiki

        这个 skill 连接到 ClawdHome 管理的单实例 LLM Wiki，通过 Unix socket 直接查询知识库接口。

        ## 固定约束

        - 正式笔记优先写入 `~/clawdhome_shared/private/llmwiki-notes/`
        - 只有写入这个目录的 Markdown，才会被 LLM Wiki 的 Sources 直接看到
        - 所有知识库查询都通过 ClawdHome 管理的 LLM Wiki socket 发送

        ## 默认触发规则

        当用户提到以下意图时，优先使用这个 skill，而不是只把内容留在当前对话里：

        - 写笔记
        - 写总结
        - 写知识库
        - 存文本
        - 记住这段内容
        - 帮我保存
        - 沉淀一下
        - 写成纪要 / 复盘 / 经验记录

        默认动作：

        1. 先把内容整理成清晰的 Markdown
        2. 再写入 `~/clawdhome_shared/private/llmwiki-notes/`
        3. 保存后把文件路径返回给用户

        如果用户没有给标题，可以根据内容自动拟一个明确标题。

        ## 何时使用

        ### 1. 搜索知识库

        当用户问“我之前记过什么”“帮我查笔记”“搜索知识库”时，运行：

        ```bash
        node scripts/search_knowledge_base.mjs "查询词"
        ```

        可选第二个参数是返回条数，例如：

        ```bash
        node scripts/search_knowledge_base.mjs "GraphRAG" 8
        ```

        ### 2. 拉取某个文件的正文和相关内容

        先通过搜索拿到 `file_id`，再运行：

        ```bash
        node scripts/get_knowledge_document.mjs "raw/sources/shrimps/<username>/xxx.md"
        ```

        或直接用搜索结果里的 `file_id`：

        ```bash
        node scripts/get_knowledge_document.mjs "wiki/concepts/某个文件.md"
        ```

        ### 3. 教用户如何写好知识笔记

        当用户问“怎么写笔记更适合知识库”“给我一个知识笔记模板”时，先阅读：

        - `references/note_writing_guide.md`

        再按其中的结构给出具体建议或模板。

        ### 4. 把内容直接写进知识库笔记目录

        当用户要求“写笔记”“写总结”“存起来”“记住这段话”“写进知识库”时，使用：

        ```bash
        cat <<'EOF' | node scripts/save_note_to_kb.mjs --title "标题" --type summary
        这里是整理后的 Markdown 正文
        EOF
        ```

        如果标题缺失，也可以省略 `--title`，脚本会从正文自动提取一个标题：

        ```bash
        cat <<'EOF' | node scripts/save_note_to_kb.mjs --type note
        # 临时标题

        这里是正文
        EOF
        ```

        可选参数：

        - `--type note|summary|knowledge|memory`
        - `--tags tag1,tag2,tag3`
        """
    }

    private static func sharedNodeHttpClient() -> String {
        """
        import http from "node:http";
        import os from "node:os";

        function request(path, method, payload) {
          return new Promise((resolve, reject) => {
            const body = payload ? Buffer.from(JSON.stringify(payload), "utf8") : Buffer.alloc(0);
            const req = http.request({
              socketPath: "\(LLMWikiPaths.socketPath)",
              path,
              method,
              headers: {
                "Content-Type": "application/json",
                "Content-Length": String(body.length),
              },
            }, (res) => {
              const chunks = [];
              res.on("data", (chunk) => chunks.push(chunk));
              res.on("end", () => {
                const raw = Buffer.concat(chunks).toString("utf8");
                if (!raw) {
                  reject(new Error(`LLM Wiki returned empty response for ${path}`));
                  return;
                }
                let parsed;
                try {
                  parsed = JSON.parse(raw);
                } catch (error) {
                  reject(new Error(`Failed to parse JSON response: ${error.message}`));
                  return;
                }
                if (res.statusCode && res.statusCode >= 400) {
                  const message = parsed?.error || parsed?.message || `HTTP ${res.statusCode}`;
                  reject(new Error(String(message)));
                  return;
                }
                resolve(parsed);
              });
            });
            req.on("error", reject);
            if (body.length > 0) req.write(body);
            req.end();
          });
        }

        """
    }

    private static func searchScript() -> String {
        """
        #!/usr/bin/env node
        \(sharedNodeHttpClient())

        const query = process.argv[2]?.trim();
        const limitArg = process.argv[3];
        if (!query) {
          console.error("Usage: node scripts/search_knowledge_base.mjs <query> [maxResults]");
          process.exit(1);
        }
        const maxNumResults = Number.parseInt(limitArg || "5", 10);

        const payload = {
          projectPath: "\(LLMWikiPaths.projectRoot)",
          query,
          max_num_results: Number.isFinite(maxNumResults) ? maxNumResults : 5,
        };

        request("/vector_stores/search", "POST", payload)
          .then((result) => {
            process.stdout.write(JSON.stringify(result, null, 2));
          })
          .catch((error) => {
            console.error(error.message || String(error));
            process.exit(1);
          });
        """
    }

    private static func documentScript() -> String {
        """
        #!/usr/bin/env node
        \(sharedNodeHttpClient())

        const target = process.argv[2]?.trim();
        if (!target) {
          console.error("Usage: node scripts/get_knowledge_document.mjs <fileIdOrPath>");
          process.exit(1);
        }

        const payload = {
          projectPath: "\(LLMWikiPaths.projectRoot)",
          fileId: target,
          max_related_items: 5,
          include_related_content: false,
        };

        request("/knowledge-base/document", "POST", payload)
          .then((result) => {
            process.stdout.write(JSON.stringify(result, null, 2));
          })
          .catch((error) => {
            console.error(error.message || String(error));
            process.exit(1);
          });
        """
    }

    private static func saveNoteScript() -> String {
        """
        #!/usr/bin/env node
        import fs from "node:fs/promises";
        import http from "node:http";
        import os from "node:os";
        import path from "node:path";

        function parseArgs(argv) {
          const result = { title: "", type: "note", tags: "", content: "" };
          for (let i = 0; i < argv.length; i += 1) {
            const arg = argv[i];
            if (arg === "--title") {
              result.title = argv[i + 1] || "";
              i += 1;
            } else if (arg === "--type") {
              result.type = argv[i + 1] || "note";
              i += 1;
            } else if (arg === "--tags") {
              result.tags = argv[i + 1] || "";
              i += 1;
            } else if (arg === "--content") {
              result.content = argv[i + 1] || "";
              i += 1;
            }
          }
          return result;
        }

        function readStdin() {
          return new Promise((resolve) => {
            if (process.stdin.isTTY) {
              resolve("");
              return;
            }
            const chunks = [];
            process.stdin.on("data", (chunk) => chunks.push(chunk));
            process.stdin.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
          });
        }

        function normalizeType(type) {
          const normalized = String(type || "note").trim().toLowerCase();
          return ["note", "summary", "knowledge", "memory"].includes(normalized) ? normalized : "note";
        }

        function inferTitle(content) {
          const lines = content
            .split(/\\r?\\n/)
            .map((line) => line.trim())
            .filter(Boolean);
          if (lines.length === 0) return "untitled-note";

          const heading = lines.find((line) => line.startsWith("#"));
          const candidate = (heading || lines[0])
            .replace(/^#+\\s*/, "")
            .replace(/^[-*]\\s*/, "")
            .replace(/[`*_>#]/g, "")
            .trim();
          return candidate.slice(0, 60) || "untitled-note";
        }

        function slugify(input) {
          return input
            .toLowerCase()
            .normalize("NFKD")
            .replace(/[^a-z0-9\\u4e00-\\u9fff]+/g, "-")
            .replace(/^-+|-+$/g, "")
            .slice(0, 80) || "note";
        }

        function timestamp(now) {
          const pad = (n) => String(n).padStart(2, "0");
          return `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
        }

        function formatTags(rawTags) {
          return String(rawTags || "")
            .split(",")
            .map((tag) => tag.trim())
            .filter(Boolean);
        }

        function buildFrontmatter({ title, type, tags, createdAt }) {
          const lines = [
            "---",
            `title: ${JSON.stringify(title)}`,
            `type: ${JSON.stringify(type)}`,
            `created_at: ${JSON.stringify(createdAt)}`,
            `updated_at: ${JSON.stringify(createdAt)}`,
          ];
          if (tags.length > 0) {
            lines.push("tags:");
            for (const tag of tags) {
              lines.push(`  - ${JSON.stringify(tag)}`);
            }
          }
          lines.push("---", "");
          return lines.join("\\n");
        }

        function request(pathname, method, payload) {
          return new Promise((resolve, reject) => {
            const body = payload ? Buffer.from(JSON.stringify(payload), "utf8") : Buffer.alloc(0);
            const req = http.request({
              socketPath: "\(LLMWikiPaths.socketPath)",
              path: pathname,
              method,
              headers: {
                "Content-Type": "application/json",
                "Content-Length": String(body.length),
              },
            }, (res) => {
              const chunks = [];
              res.on("data", (chunk) => chunks.push(chunk));
              res.on("end", () => {
                const raw = Buffer.concat(chunks).toString("utf8");
                if (!raw) {
                  resolve({ ok: false, status: res.statusCode || 0, error: "empty response" });
                  return;
                }
                try {
                  const parsed = JSON.parse(raw);
                  if (res.statusCode && res.statusCode >= 400) {
                    resolve({
                      ok: false,
                      status: res.statusCode,
                      error: parsed?.error || `HTTP ${res.statusCode}`,
                    });
                    return;
                  }
                  resolve({
                    ok: true,
                    status: res.statusCode || 200,
                    payload: parsed,
                  });
                } catch (error) {
                  resolve({
                    ok: false,
                    status: res.statusCode || 0,
                    error: `invalid json response: ${error.message}`,
                  });
                }
              });
            });
            req.on("error", (error) => resolve({
              ok: false,
              status: 0,
              error: error.message,
            }));
            if (body.length > 0) req.write(body);
            req.end();
          });
        }

        const args = parseArgs(process.argv.slice(2));
        const stdin = await readStdin();
        const rawContent = (args.content || stdin || "").trim();
        if (!rawContent) {
          console.error('Usage: cat note.md | node scripts/save_note_to_kb.mjs [--title "标题"] [--type note|summary|knowledge|memory] [--tags a,b,c]');
          process.exit(1);
        }

        const type = normalizeType(args.type);
        const title = (args.title || inferTitle(rawContent)).trim();
        const tags = formatTags(args.tags);
        const noteDir = path.join(os.homedir(), "clawdhome_shared", "private", "llmwiki-notes");
        const username = process.env.USER || os.userInfo().username;
        const now = new Date();
        const createdAt = now.toISOString();
        const filename = `${timestamp(now)}--${slugify(title)}.md`;
        const filePath = path.join(noteDir, filename);
        const projectSourcePath = path.join(
          "\(LLMWikiPaths.projectRoot)",
          "raw",
          "sources",
          "shrimps",
          username,
          filename,
        );

        await fs.mkdir(noteDir, { recursive: true });
        const frontmatter = buildFrontmatter({ title, type, tags, createdAt });
        const trimmedBody = rawContent.trim();
        const firstLine = trimmedBody.split(/\\r?\\n/).find((line) => line.trim().length > 0) || "";
        const body = firstLine.trim().startsWith("#")
          ? trimmedBody
          : `# ${title}\\n\\n${trimmedBody}`;
        const content = `${frontmatter}${body}\\n`;
        await fs.writeFile(filePath, content, "utf8");
        await fs.mkdir(path.dirname(projectSourcePath), { recursive: true });
        try {
          await fs.access(projectSourcePath);
        } catch {
          if (path.resolve(filePath) !== path.resolve(projectSourcePath)) {
            await fs.copyFile(filePath, projectSourcePath);
          }
        }
        const ingestTrigger = await request("/knowledge-base/ingest", "POST", {
          projectPath: "\(LLMWikiPaths.projectRoot)",
          sourcePath: projectSourcePath,
          debounceMs: 1500,
          reason: "save_note_to_kb",
        });

        process.stdout.write(JSON.stringify({
          ok: true,
          title,
          type,
          tags,
          filename,
          path: filePath,
          noteDirectory: noteDir,
          bytes: Buffer.byteLength(content, "utf8"),
          ingestTrigger,
        }, null, 2));
        """
    }

    private static func noteWritingGuide() -> String {
        """
        # 如何写适合 LLM Wiki 的知识笔记

        ## 目标

        让笔记既适合人看，也适合后续知识库检索、引用和再加工。

        ## 推荐结构

        1. 标题明确
        - 直接写主题，不要只写“随记”“想法”

        2. 开头先给结论
        - 第一段用 3 到 5 句话说明这篇笔记的核心结论

        3. 分段使用小标题
        - 用二级或三级标题拆分背景、问题、方案、结论、待办

        4. 写出关键术语和别名
        - 例如同时写 `GraphRAG`、`知识图谱增强检索`、`知识图谱`，方便检索命中

        5. 保留原始出处
        - 记录链接、作者、时间、会议、产品名或文件名

        6. 标注你的判断
        - 区分“原文事实”“我的结论”“待验证点”

        ## 一个最小模板

        ```markdown
        # 主题名

        ## 结论
        这篇笔记的核心观点是什么？

        ## 背景
        问题来自哪里，为什么重要？

        ## 关键事实
        - 事实 1
        - 事实 2
        - 事实 3

        ## 我的判断
        - 判断 1
        - 判断 2

        ## 相关术语
        - 术语 A
        - 术语 B

        ## 来源
        - 链接 / 文件名 / 作者 / 时间
        ```

        ## 不建议的写法

        - 只有截图，没有文字摘要
        - 标题过于模糊
        - 整篇只有一大段流水账
        - 没有来源和时间
        - 结论藏在很后面
        """
    }

    private static func schemaContent() -> String {
        """
        # ClawdHome LLM Wiki Schema

        这个项目由 ClawdHome 管理，单实例共享给所有虾和管理员使用。

        - `raw/sources/shrimps/<username>`：每只虾的原始笔记目录映射
        - `wiki/`：LLM Wiki 派生或整理后的知识页面
        - v1 不要求自动 ingest；重点是让原始笔记在 Sources 中直接可见，并可通过本地知识库接口检索
        """
    }

    private static func purposeContent() -> String {
        """
        # Purpose

        这个知识库项目用于汇聚 ClawdHome 管理下各只虾的原始笔记文件，并通过本地 Unix socket 接口提供查询和文档读取能力。

        当前阶段的目标：
        - 让每只虾写入 `~/clawdhome_shared/private/llmwiki-notes/` 的笔记能在 LLM Wiki 中直接看到
        - 让管理员可统一查看和维护这些来源文件
        - 让每只虾通过内置 skill 直接查询共享 LLM Wiki 搜索接口
        """
    }

    private static func indexContent() -> String {
        """
        # ClawdHome Notes Index

        这个共享项目收录了所有虾的原始笔记映射。

        - 原始笔记入口：`raw/sources/shrimps/<username>`
        - 共享运行目录：`/Users/Shared/ClawdHome/llmwiki/run`
        - 本项目由 ClawdHome 负责修复目录、权限、软链和 runtime 配置
        """
    }

    private static func logContent() -> String {
        """
        # Project Log

        - 由 ClawdHome 创建和维护
        - v1 使用共享项目 + 每虾专用 `llmwiki-notes` 目录映射
        - 不创建公共笔记目录，不做自动 ingest watcher
        """
    }

    private static func overviewContent() -> String {
        """
        # Overview

        共享项目结构：

        - `wiki/`：知识页目录
        - `raw/sources/shrimps/`：各只虾的笔记软链映射
        - `raw/assets/`：原始附件目录

        访问语义：

        - 管理员和 LLM Wiki 进程可访问全部虾目录
        - 每只虾通过自己的 skill 只允许检索 `raw/sources/shrimps/<username>` 前缀
        """
    }
}
