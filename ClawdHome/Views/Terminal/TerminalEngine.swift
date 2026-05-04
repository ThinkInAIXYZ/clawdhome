// ClawdHome/Views/Terminal/TerminalEngine.swift
// 终端引擎抽象：默认 shell + 模板列表
// 让 ShrimpTerminalTabManager / ShrimpTerminalConsole 在不同 runtime（hermes / openclaw）下展示对应的快捷命令。

import Foundation

enum TerminalEngine {
    case openclaw
    case hermes

    /// `+` 主按钮（或空状态"打开终端"按钮）默认开的命令。
    var defaultShell: [String] {
        switch self {
        case .openclaw: return ["zsh", "-l"]
        case .hermes:   return ["hermes-shell", "-l"]
        }
    }

    /// `+` 旁边 `▾` 下拉菜单展示的引擎特化模板。
    /// 第一项约定为"默认 shell"，与 `defaultShell` 对应，方便用户在菜单里也能直接选默认。
    var templates: [TerminalTemplate] {
        switch self {
        case .openclaw:
            return [
                TerminalTemplate(
                    id: "openclaw.shell",
                    title: L10n.k("terminal.template.zsh", fallback: "Shell (zsh)"),
                    icon: "terminal",
                    command: ["zsh", "-l"]
                ),
                TerminalTemplate(
                    id: "openclaw.setup",
                    title: L10n.k("terminal.template.openclaw_setup", fallback: "OpenClaw 配置"),
                    icon: "wrench.and.screwdriver",
                    command: ["openclaw", "setup"]
                ),
                TerminalTemplate(
                    id: "openclaw.doctor",
                    title: L10n.k("terminal.template.openclaw_doctor", fallback: "OpenClaw 诊断"),
                    icon: "stethoscope",
                    command: ["openclaw", "doctor"]
                ),
            ]
        case .hermes:
            return [
                TerminalTemplate(
                    id: "hermes.shell",
                    title: L10n.k("terminal.template.hermes_shell", fallback: "Hermes Shell"),
                    icon: "terminal",
                    command: ["hermes-shell", "-l"]
                ),
                TerminalTemplate(
                    id: "hermes.setup",
                    title: L10n.k("terminal.template.hermes_setup", fallback: "Hermes Setup"),
                    icon: "wrench.and.screwdriver",
                    command: ["hermes", "setup"]
                ),
                TerminalTemplate(
                    id: "hermes.profile_list",
                    title: L10n.k("terminal.template.hermes_profile_list", fallback: "Hermes Profile 列表"),
                    icon: "person.2",
                    command: ["hermes", "profile", "list"]
                ),
            ]
        }
    }
}

struct TerminalTemplate: Identifiable {
    let id: String
    let title: String
    let icon: String
    let command: [String]
}

// MARK: - 快捷命令（"🦞openclaw 指令" / "🪽hermes 指令" 菜单数据源）

struct TerminalQuickCommand: Identifiable {
    let id = UUID()
    let label: String
    let command: String
}

struct TerminalQuickCommandSection: Identifiable {
    let id: String              // 用 title 作为稳定 id，避免 ForEach 闪烁
    let title: String
    let commands: [TerminalQuickCommand]

    init(title: String, commands: [TerminalQuickCommand]) {
        self.id = title
        self.title = title
        self.commands = commands
    }
}

extension TerminalEngine {
    /// 顶栏快捷指令菜单的 label（带 emoji）
    var quickCommandMenuTitle: String {
        switch self {
        case .openclaw: return L10n.k("app.maintenance.quick.menu_title", fallback: "🦞openclaw 指令")
        case .hermes:   return L10n.k("app.maintenance.quick.hermes.menu_title", fallback: "🪽hermes 指令")
        }
    }

    /// 引擎特化的多段快捷命令，逐项通过 `sendLine` 注入活跃 tab。
    var quickCommandSections: [TerminalQuickCommandSection] {
        switch self {
        case .openclaw:
            return [
                TerminalQuickCommandSection(
                    title: L10n.k("app.maintenance.quick.section.query_diagnose", fallback: "查询 / 诊断"),
                    commands: [
                        TerminalQuickCommand(label: L10n.k("app.maintenance.quick.command.version", fallback: "版本查询"), command: "openclaw --version"),
                        TerminalQuickCommand(label: L10n.k("app.maintenance.quick.command.status_overview", fallback: "状态概览"), command: "openclaw status"),
                        TerminalQuickCommand(label: L10n.k("app.maintenance.quick.command.model_status", fallback: "模型状态"), command: "openclaw models status --probe"),
                        TerminalQuickCommand(label: L10n.k("app.maintenance.quick.command.connected_devices", fallback: "已连设备"), command: "openclaw devices list"),
                        TerminalQuickCommand(label: L10n.k("app.maintenance.quick.command.system_check", fallback: "系统体检"), command: "openclaw doctor"),
                        TerminalQuickCommand(label: L10n.k("app.maintenance.quick.command.security_audit", fallback: "安全审计"), command: "openclaw security audit"),
                        TerminalQuickCommand(label: L10n.k("app.maintenance.quick.command.live_logs", fallback: "实时日志"), command: "openclaw logs --follow"),
                    ]
                ),
                TerminalQuickCommandSection(
                    title: L10n.k("app.maintenance.quick.section.config_control", fallback: "配置 / 控制"),
                    commands: [
                        TerminalQuickCommand(label: L10n.k("app.maintenance.quick.command.configure", fallback: "交互配置"), command: "openclaw configure"),
                        TerminalQuickCommand(label: L10n.k("app.maintenance.quick.command.auto_fix", fallback: "自动修复"), command: "openclaw doctor --fix"),
                        TerminalQuickCommand(label: L10n.k("app.maintenance.quick.command.channel_login", fallback: "频道登录"), command: "openclaw channels login"),
                        TerminalQuickCommand(label: L10n.k("app.maintenance.quick.command.restart_service", fallback: "重启服务"), command: "openclaw gateway restart"),
                    ]
                ),
                TerminalQuickCommandSection(
                    title: L10n.k("app.maintenance.quick.section.upgrade_maintenance", fallback: "升级 / 维护"),
                    commands: [
                        TerminalQuickCommand(
                            label: L10n.k("app.maintenance.quick.command.upgrade_latest", fallback: "升级到最新"),
                            command: "openclaw --version; npm install -g openclaw@latest; openclaw --version"
                        ),
                    ]
                ),
            ]
        case .hermes:
            return [
                TerminalQuickCommandSection(
                    title: L10n.k("app.maintenance.quick.section.query_diagnose", fallback: "查询 / 诊断"),
                    commands: [
                        TerminalQuickCommand(label: L10n.k("app.maintenance.quick.hermes.version", fallback: "版本查询"), command: "hermes --version"),
                        TerminalQuickCommand(label: L10n.k("app.maintenance.quick.hermes.status", fallback: "状态概览"), command: "hermes status"),
                        TerminalQuickCommand(label: L10n.k("app.maintenance.quick.hermes.profile_list", fallback: "角色列表"), command: "hermes profile list"),
                        TerminalQuickCommand(label: L10n.k("app.maintenance.quick.hermes.gateway_status", fallback: "网关状态"), command: "hermes gateway status"),
                        TerminalQuickCommand(label: L10n.k("app.maintenance.quick.hermes.doctor", fallback: "系统体检"), command: "hermes doctor"),
                        TerminalQuickCommand(label: L10n.k("app.maintenance.quick.hermes.logs", fallback: "实时日志"), command: "hermes logs --follow"),
                    ]
                ),
                TerminalQuickCommandSection(
                    title: L10n.k("app.maintenance.quick.section.config_control", fallback: "配置 / 控制"),
                    commands: [
                        TerminalQuickCommand(label: L10n.k("app.maintenance.quick.hermes.setup", fallback: "交互配置"), command: "hermes setup"),
                        TerminalQuickCommand(label: L10n.k("app.maintenance.quick.hermes.gateway_restart", fallback: "重启网关"), command: "hermes gateway restart"),
                        TerminalQuickCommand(label: L10n.k("app.maintenance.quick.hermes.channels_list", fallback: "频道列表"), command: "hermes channels list"),
                    ]
                ),
                TerminalQuickCommandSection(
                    title: L10n.k("app.maintenance.quick.section.upgrade_maintenance", fallback: "升级 / 维护"),
                    commands: [
                        TerminalQuickCommand(
                            label: L10n.k("app.maintenance.quick.hermes.upgrade_latest", fallback: "升级到最新"),
                            command: "hermes --version; npm install -g @nousresearch/hermes-agent@latest; hermes --version"
                        ),
                    ]
                ),
            ]
        }
    }
}
