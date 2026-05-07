# Release Notes

每个版本单独维护两份发布说明：

- `release-notes/vX.Y.Z.zh.md`
- `release-notes/vX.Y.Z.en.md`

`make release` 会读取这两份文件，并同步到：

- GitHub Release 正文（中文在前，英文在后）
- `CHANGELOG.zh.md` / `CHANGELOG.en.md`
- 网站 `api/version.json` 的 `release_notes` / `release_notes_en`

推荐做法：

1. 先运行 `make release-notes-draft` 自动生成中英文草稿并打开文件。
2. 检查并修改本次版本的中英文发布说明。
3. 运行 `make release-dry-run` 检查输出。
4. 确认后运行 `make release`。
