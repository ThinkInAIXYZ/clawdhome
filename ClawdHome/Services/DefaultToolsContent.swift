// Shared/DefaultToolsContent.swift
// 默认 TOOLS.md 内容 — 告知虾共享文件夹的存在和用途

import Foundation

/// 默认 TOOLS.md 内容，用于初始化虾的工作区
let defaultToolsContent: String = L10n.k("views.wizard.tools_md_content", fallback: "## Shared Folders\n\nYou have two file sharing spaces accessible at the following paths:\n\n### Private Folder\n- Path: `~/clawdhome_shared/private/`\n- Access: Only you and the admin can access; other Shrimps cannot see it\n- Purpose: All work outputs, generated files, and exported data should be stored here first\n\n### Public Folder\n- Path: `~/clawdhome_shared/public/`\n- Access: Shared by all Shrimps and the admin\n- Purpose: Read/write common resources, shared files, and public datasets\n\n### Usage Guidelines\n- When asked to save files, export results, or generate reports, write to `~/clawdhome_shared/private/`\n- When referencing public resources, read from `~/clawdhome_shared/public/`\n- Do not write sensitive data to the public folder")
