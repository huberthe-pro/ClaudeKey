# Claude Code Hooks 完整参考

ClaudeKey 可用的 Claude Code hook 事件和数据字段。

## statusLine (已接入)

每次状态更新时执行，通过 stdin 发送 JSON。

```json
{
  "session_id": "uuid",
  "transcript_path": "/path/to/transcript.jsonl",
  "cwd": "/current/dir",
  "model": {
    "id": "claude-opus-4-6[1m]",
    "display_name": "Opus 4.6 (1M context)"
  },
  "workspace": {
    "current_dir": "/Users/minbot/Dev/project",
    "project_dir": "/Users/minbot/Dev/project",
    "added_dirs": []
  },
  "version": "2.1.85",
  "cost": {
    "total_cost_usd": 0.177,
    "total_duration_ms": 96057,
    "total_api_duration_ms": 24213,
    "total_lines_added": 0,
    "total_lines_removed": 0
  },
  "context_window": {
    "total_input_tokens": 379,
    "total_output_tokens": 1945,
    "context_window_size": 1000000,
    "current_usage": {
      "input_tokens": 3,
      "output_tokens": 345,
      "cache_creation_input_tokens": 11406,
      "cache_read_input_tokens": 19403
    },
    "used_percentage": 3,
    "remaining_percentage": 97
  },
  "exceeds_200k_tokens": false,
  "rate_limits": {
    "five_hour": { "used_percentage": 1, "resets_at": 1774652400 },
    "seven_day": { "used_percentage": 29, "resets_at": 1774771200 }
  }
}
```

配置位置: `settings.json` → `statusLine`

## hooks 事件 (27 个)

配置位置: `settings.json` → `hooks`

每个 hook 通过 stdin 接收 JSON，通过 stdout/exit code 返回决策。

### 公共字段 (所有事件都有)

```json
{
  "session_id": "abc123",
  "transcript_path": "/path/to/transcript.jsonl",
  "cwd": "/current/working/directory",
  "permission_mode": "default|plan|acceptEdits|auto|dontAsk|bypassPermissions",
  "hook_event_name": "EventName"
}
```

---

## 会话生命周期

### SessionStart
会话开始/恢复时触发。
```json
{ "source": "startup|resume|clear|compact", "model": "claude-sonnet-4-6" }
```
可注入上下文: `hookSpecificOutput.additionalContext`
可设环境变量: 写入 `$CLAUDE_ENV_FILE`

### SessionEnd
会话结束时触发。
```json
{ "reason": "clear|resume|logout|prompt_input_exit|bypass_permissions_disabled|other" }
```
不可阻断。仅用于清理/日志。

---

## 用户输入

### UserPromptSubmit
用户提交 prompt 时触发。**可阻断。**
```json
{ "prompt": "用户输入的文字" }
```
决策: `block` (拒绝) / `omit` (静默忽略)
可注入上下文: `additionalContext`

---

## 工具执行

### PreToolUse ← ClaudeKey 已接入
工具执行前触发。**可阻断，可修改输入。**
```json
{
  "tool_name": "Bash|Write|Edit|Read|Glob|Grep|Agent|WebFetch|WebSearch|mcp__*",
  "tool_input": { ... },
  "tool_use_id": "toolu_01ABC..."
}
```

tool_input 按工具类型不同:

| 工具 | 关键字段 |
|------|---------|
| Bash | `command`, `description`, `timeout` |
| Write | `file_path`, `content` |
| Edit | `file_path`, `old_string`, `new_string` |
| Read | `file_path`, `offset`, `limit` |
| Glob | `pattern`, `path` |
| Grep | `pattern`, `path`, `glob`, `output_mode` |
| WebFetch | `url`, `prompt` |
| WebSearch | `query`, `allowed_domains`, `blocked_domains` |
| Agent | `prompt`, `description`, `subagent_type`, `model` |

决策:
- `permissionDecision`: `allow|deny|ask`
- `updatedInput`: 修改工具输入
- `additionalContext`: 注入上下文

Matcher: 支持正则匹配 tool_name，如 `"matcher": "Bash|Write"`

### PermissionRequest
权限确认弹窗时触发。**可自动批准/拒绝。**
```json
{
  "tool_name": "Bash",
  "tool_input": { "command": "rm -rf node_modules" },
  "permission_suggestions": [
    { "type": "addRules", "rules": [...], "behavior": "allow|deny", "destination": "session|localSettings" }
  ]
}
```
决策: `behavior: "allow|deny"`, `updatedInput`, `updatedPermissions`

### PostToolUse ← ClaudeKey 可接入
工具成功执行后触发。
```json
{
  "tool_name": "Write",
  "tool_input": { "file_path": "...", "content": "..." },
  "tool_response": { "filePath": "...", "success": true }
}
```
可注入上下文，可替换 MCP 工具输出。

### PostToolUseFailure
工具执行失败后触发。
```json
{
  "tool_name": "Bash",
  "tool_input": { "command": "npm test" },
  "error": "Command exited with non-zero status code 1",
  "is_interrupt": false
}
```

---

## 通知

### Notification ← ClaudeKey 已接入
通知发送时触发。
```json
{
  "message": "通知文字",
  "title": "通知标题",
  "notification_type": "permission_prompt|idle_prompt|auth_success|elicitation_dialog"
}
```

| type | 含义 | ClaudeKey 用途 |
|------|------|---------------|
| permission_prompt | Claude 等待用户批准 | 面板闪烁 Accept 按钮 |
| idle_prompt | Claude 完成，等待输入 | 显示 "等待输入" |
| auth_success | 认证成功 | 无 |
| elicitation_dialog | MCP 请求用户输入 | 可扩展 |

---

## Agent 活动

### SubagentStart
子 agent 启动时触发。
```json
{ "agent_id": "agent-abc123", "agent_type": "Bash|Explore|Plan|custom" }
```

### SubagentStop
子 agent 完成时触发。**可阻断。**
```json
{
  "agent_id": "agent-def456",
  "agent_type": "Explore",
  "agent_transcript_path": "/path/to/subagent-transcript.jsonl",
  "last_assistant_message": "子 agent 最后的回复"
}
```

---

## 停止

### Stop ← ClaudeKey 可接入
Claude 主 agent 完成时触发。**可阻断（让 Claude 继续）。**
```json
{
  "stop_hook_active": false,
  "last_assistant_message": "Claude 最后的回复"
}
```

### StopFailure
API 错误导致停止。
```json
{
  "error": "rate_limit|authentication_failed|billing_error|invalid_request|server_error|max_output_tokens|unknown",
  "error_details": "详细错误信息"
}
```

---

## Context 管理

### PreCompact / PostCompact
上下文压缩前/后触发。
```json
{ "source": "manual|auto" }
```

### InstructionsLoaded
CLAUDE.md 或规则文件加载时触发。
```json
{
  "file_path": "/path/to/CLAUDE.md",
  "memory_type": "User|Project|Local|Managed",
  "load_reason": "session_start|nested_traversal|path_glob_match|include|compact"
}
```

---

## 任务 (Team 功能)

### TaskCreated / TaskCompleted
任务创建/完成时触发。**可阻断。**
```json
{
  "task_id": "task-001",
  "task_subject": "任务标题",
  "task_description": "详细描述",
  "teammate_name": "name",
  "team_name": "team"
}
```

### TeammateIdle
队友空闲时触发。可通过 exit code 2 让队友继续。

---

## 文件/配置变化

### CwdChanged
工作目录改变时触发。可设环境变量。

### FileChanged
被监控文件改变时触发。Matcher 匹配文件名。
```json
{ "file_path": "/path/to/file.ext", "file_name": "file.ext" }
```

### ConfigChange
配置文件改变时触发。**可阻断。**
```json
{ "source": "user_settings|project_settings|local_settings|policy_settings|skills" }
```

---

## Worktree

### WorktreeCreate
创建 worktree 时触发。Hook 返回 worktree 路径。

### WorktreeRemove
删除 worktree 时触发。不可阻断。

---

## MCP Elicitation

### Elicitation
MCP server 请求用户输入时触发。**可自动填充。**
```json
{
  "mcp_server_name": "server-name",
  "form": { "fields": [{ "name": "field", "type": "text|checkbox|dropdown" }] }
}
```

### ElicitationResult
用户响应 elicitation 后触发。**可修改用户输入。**

---

## Hook 配置格式

```json
// ~/.claude/settings.json
{
  "hooks": {
    "EventName": [
      {
        "type": "command",
        "command": "/path/to/script",
        "matcher": "optional-regex"
      }
    ]
  }
}
```

同一事件可以有多个 hook，按顺序执行。

## Exit Codes

| Code | 含义 |
|------|------|
| 0 | 成功，解析 JSON 输出 |
| 2 | 阻断错误，stderr 显示给用户/Claude |
| 其他 | 非阻断错误，verbose 模式显示 stderr |

---

## ClaudeKey 接入状态

| Hook | 状态 | 文件 |
|------|------|------|
| statusLine | ✅ 已接入 | scripts/claude-status-hook |
| Notification | ✅ 已接入 | scripts/claude-notify-hook |
| PreToolUse | ✅ 已接入 | scripts/claude-tool-hook |
| Stop | 🔜 v0.2 | 可显示 "Claude 完成" |
| StopFailure | 🔜 v0.2 | 可显示 rate limit 警告 |
| SubagentStart/Stop | 🔜 v0.2 | 可显示并行 agent 数量 |
| PostToolUse | 🔜 v0.2 | 可显示工具结果 |
| PreCompact/PostCompact | 🔜 v0.2 | 可提醒 context 被压缩 |
