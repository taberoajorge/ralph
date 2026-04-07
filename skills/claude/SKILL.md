---
name: ralph
description: |
  Autonomous AI agent loop that drives coding tasks to completion. Supports Codex, Claude, Cursor, and Gemini as backends. Define work as user stories in a PRD, write a prompt, and Ralph iterates until every story passes.

  Use when user says:
  - "run ralph", "start ralph", "launch ralph loop"
  - "ralph status", "check ralph", "ralph watch"
  - "plan ralph session", "create PRD for ralph", "setup ralph"
  - "create prd.json", "write prompt.md", "define stories"
  - "ralph is stuck", "ralph error", "troubleshoot ralph"
  - "pause ralph", "stop ralph", "resume ralph"
  - "autonomous loop", "agent loop", "PRD-driven loop"
  - "switch provider", "use codex", "use claude", "use gemini", "use cursor"

  Executes: scripts/ralph-{codex,claude,cursor,gemini}.sh, cargo run
  Source: ~/personal/ralph (https://github.com/taberoajorge/ralph)
---

# Ralph

Autonomous AI agent loop. Source code and scripts live at `~/personal/ralph` (GitHub: `taberoajorge/ralph`).

Ralph iterates through user stories defined in a `prd.json`, sends each one to an AI agent (Codex, Claude, Cursor, or Gemini), and loops until every story is marked as passed.

## Repository Layout

```
~/personal/ralph/
├── Cargo.toml              # Rust binary
├── src/                    # Rust source (unified engine, all providers)
├── scripts/                # Shell scripts (one per provider)
│   ├── ralph-codex.sh      # OpenAI Codex CLI
│   ├── ralph-claude.sh     # Claude Code CLI
│   ├── ralph-cursor.sh     # Cursor Agent CLI
│   ├── ralph-gemini.sh     # Google Gemini CLI
│   └── ralph-config.sh     # Shared TOML config loader
└── examples/               # Templates
    ├── prd.json
    ├── prompt.md
    ├── guardrails.md
    └── ralph.toml
```

## Setting Up a New Ralph Session

When the user wants to run Ralph on a project, follow these steps:

### Step 1: Create the ralph directory in the target project

```bash
mkdir -p /path/to/project/ralph
cp ~/personal/ralph/scripts/ralph-*.sh /path/to/project/ralph/
```

### Step 2: Create prd.json

```json
{
  "project": "project-name",
  "feature": "What this session will accomplish",
  "workingDirectory": "/absolute/path/to/project",
  "branchName": "feature-branch-name",
  "userStories": [
    {
      "id": "story-001",
      "title": "Short description",
      "description": "Detailed task description",
      "acceptanceCriteria": [
        "Condition 1",
        "Condition 2",
        "Tests pass: npm test"
      ],
      "passes": false,
      "blocked": false,
      "notes": null,
      "priority": 1
    }
  ]
}
```

Key rules for good stories:
- Each story must be small enough for one agent session
- Acceptance criteria must be verifiable (test commands, grep checks)
- Order stories by dependency (executed in array order)
- `workingDirectory` must be an absolute path to a git repo

### Step 3: Create prompt.md

```markdown
# [Feature] - Execution Prompt

You are an expert [role] working on [context].

## Context
[Project description, tech stack, file structure]

## Execution Flow
1. Read the story and acceptance criteria
2. Read relevant files before making changes
3. Implement the changes
4. Run verification: `[test command]`
5. If tests pass, update prd.json: set "passes": true
6. Commit with a descriptive message

## Absolute Rules
- Never modify unrelated files
- Always run tests before marking passed
- Read existing code before writing replacements
```

### Step 4: Create guardrails.md

```markdown
# Guardrails (Signs)

Lessons learned from previous iterations. The agent MUST read this FIRST.

## Active Guardrails

(None yet - will be added as errors are encountered)
```

### Step 5: Run

```bash
cd /path/to/project/ralph

./ralph-codex.sh                           # OpenAI Codex
./ralph-claude.sh                          # Claude Code
./ralph-cursor.sh                          # Cursor Agent
./ralph-gemini.sh                          # Google Gemini

./ralph-codex.sh --config ralph.toml       # With service config
./ralph-codex.sh --model o4-mini           # Override model
./ralph-codex.sh 10                        # Max 10 iterations
```

## Running with the Rust Binary

```bash
cd ~/personal/ralph
cargo build --release

./target/release/ralph --provider codex --model o4-mini --config /path/to/ralph.toml
./target/release/ralph --provider claude --model claude-sonnet-4-6
./target/release/ralph --provider cursor --model claude-sonnet-4-6
```

## Commands (All Providers)

| Command | Description |
|---|---|
| `./ralph-{provider}.sh` | Start the loop |
| `./ralph-{provider}.sh status` | Show progress, model, errors |
| `./ralph-{provider}.sh watch` | Tail logs in real time |
| `./ralph-{provider}.sh reset` | Clear state files |
| `./ralph-{provider}.sh N` | Run max N iterations |
| `./ralph-{provider}.sh --model X` | Override model |
| `./ralph-{provider}.sh --config F` | Use TOML config |

## Monitoring & Control

```bash
touch .ralph-pause    # Pause after current iteration
rm .ralph-pause       # Resume

touch .ralph-done     # Stop after current iteration
```

## Log Files

| File | Content |
|---|---|
| `activity.log` | Session events |
| `error.log` | Classified errors |
| `{provider}_output.log` | Raw agent output |
| `progress.txt` | Iteration reports |
| `guardrails.md` | Auto-accumulated lessons |
| `failure_memory.json` | Failure tracking (Rust only) |

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `MAX_ITERATIONS` | `9999` | Max loop iterations |
| `MAX_RETRIES` | `5` | Retries per agent call |
| `RATE_LIMIT_WAIT` | `120` | Rate limit wait (seconds) |
| `GUTTER_THRESHOLD` | `3` | Failures before auto-block |
| `CODEX_MODEL` | `o4-mini` | Codex model |
| `CLAUDE_MODEL` | `claude-sonnet-4-6` | Claude model |
| `CURSOR_MODEL` | `claude-sonnet-4-6` | Cursor model |
| `GEMINI_MODEL` | `gemini-2.5-pro` | Gemini model |

## ralph.toml (Optional)

For projects that need services running:

```toml
[project]
workingDirectory = "/path/to/project"

[prd]
path = "prd.json"
backup = "prd.json.bak"
prompt = "prompt.md"
guardrails = "guardrails.md"
progress = "progress.txt"

[test]
command = "npm test"

[services.new]
name = "api"
health = "http://localhost:3000/health"
port = 3000
start = "npm run dev"
stop = "kill $(lsof -ti :3000) 2>/dev/null"
workingDirectory = "/path/to/project"
maxStartWait = 30
```

## Troubleshooting

| Error | Fix |
|---|---|
| `AUTH_ERROR` | Run provider login (`codex login`, `claude`, `agent login`, `gemini auth login`) |
| `QUOTA_EXHAUSTED` | Check billing for the provider |
| `RATE_LIMIT` | Auto-retries; increase `RATE_LIMIT_WAIT` if persistent |
| `GUTTER` | Story failed 3+ times; review `error.log`, fix manually, run `reset` |
| PRD corrupted | Auto-restores from backup; recreate if backup is also broken |
| Agent stalled | Auto-killed after stall timeout; retries automatically |

## Provider CLI Invocations

| Provider | Command |
|---|---|
| Codex | `codex exec --dangerously-bypass-approvals-and-sandbox --model $M --json -C $DIR "$PROMPT"` |
| Claude | `claude -p "$PROMPT" --model $M --output-format text --dangerously-skip-permissions` |
| Cursor | `agent -p --force --model $M --output-format stream-json --workspace $DIR --sandbox disabled --approve-mcps "$PROMPT"` |
| Gemini | `gemini --yolo --model $M "$PROMPT"` |

## Switching Providers

All scripts share `prd.json`, `prompt.md`, `guardrails.md`. Stop one (`touch .ralph-done`), start another. Progress carries over.
