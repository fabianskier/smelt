# Claude Code stream-json fixtures

Recorded with Claude Code CLI 2.1.322–2.1.323:

    claude -p "<prompt>" --output-format stream-json --verbose < /dev/null

| File | Origin |
|---|---|
| `success.jsonl` | Recorded: `Reply with exactly: ok` |
| `tool_use.jsonl` | Recorded: `Read the file hello.txt and reply with its contents only.` (`--allowedTools Read`) |
| `error_result.jsonl` | Derived from `success.jsonl`: result marked `is_error: true`, subtype `error_during_execution` |
| `no_result.jsonl` | Derived from `success.jsonl`: `result` line removed |
| `unknown_and_malformed.jsonl` | Derived from `success.jsonl`: an unknown event type and a non-JSON line before the result |

Sanitized: the `init` event keeps only `type`, `subtype`, `cwd`, `session_id`, `model`,
`permissionMode` and `claude_code_version` (tools and MCP servers emptied); local paths
are replaced with `/tmp/project`; `credential_expires_at` is removed.
