# Ralph

Autonomous AI agent loop that drives coding tasks to completion using any AI CLI backend. Define your work as user stories in a PRD, point Ralph at your repo, and let it iterate autonomously until every story passes.

Inspired by [Geoffrey Huntley's Ralph pattern](https://ghuntley.com/ralph/).

## How It Works

```
┌─────────────────────────────────────────┐
│              Ralph Loop                 │
│                                         │
│  1. Load prd.json                       │
│  2. Find next story (passes: false)     │
│  3. Build prompt (prompt.md + story     │
│     + guardrails + dynamic context)     │
│  4. Run AI agent (codex/claude/cursor/  │
│     gemini) in autonomous mode          │
│  5. Agent implements the story,         │
│     runs tests, marks it as passed      │
│  6. Ralph checks result:               │
│     - Story passed? → next story        │
│     - Failed? → record failure,         │
│       add guardrail, retry              │
│     - Rate limited? → smart backoff     │
│     - Stalled? → kill & retry           │
│  7. Repeat until all stories pass       │
│     or max iterations reached           │
└─────────────────────────────────────────┘
```

Ralph comes in two forms:

- **Shell scripts** (`scripts/`) — Battle-tested bash scripts, one per provider. Drop into any project and run immediately.
- **Rust binary** (`src/`) — Unified binary with all providers, structured detection (loop, stall, failure memory), and async health checks.
- **Agent skills** (`skills/`) — Ready-to-use skills for Claude Code and Cursor that teach them how to operate Ralph.

## Quick Start

### Using Shell Scripts

```bash
# 1. Clone this repo
git clone https://github.com/taberoajorge/ralph.git
cd ralph

# 2. Copy scripts to your project
cp scripts/ralph-*.sh /path/to/your-project/ralph/

# 3. Create the three required files in ralph/
#    (see examples/ for templates)
cp examples/prd.json   /path/to/your-project/ralph/prd.json
cp examples/prompt.md  /path/to/your-project/ralph/prompt.md
cp examples/guardrails.md /path/to/your-project/ralph/guardrails.md

# 4. Edit prd.json with YOUR project details and stories

# 5. Run with your preferred AI backend
cd /path/to/your-project/ralph
./ralph-codex.sh              # OpenAI Codex
./ralph-claude.sh             # Claude Code
./ralph-cursor.sh             # Cursor Agent
./ralph-gemini.sh             # Google Gemini
```

### Using the Rust Binary

```bash
# Build
cd ralph
cargo build --release

# Run
./target/release/ralph --provider codex --model gpt-5.4 --config ralph.toml
./target/release/ralph --provider claude --model claude-sonnet-4-6
./target/release/ralph --provider cursor --model claude-4.6-opus-max-thinking
```

## Required Files

Ralph needs three files to operate. All paths are relative to the directory where you run the script (or configurable via `ralph.toml`).

### prd.json — The Product Requirements Document

This is the brain of Ralph. It defines what the AI agent should do, story by story.

```json
{
  "project": "my-project",
  "feature": "What this loop is working on",
  "workingDirectory": "/absolute/path/to/your/repo",
  "branchName": "your-feature-branch",
  "userStories": [
    {
      "id": "story-001",
      "title": "Short description of what to do",
      "description": "Detailed explanation of the task",
      "acceptanceCriteria": [
        "First condition that must be true",
        "Second condition that must be true",
        "Tests must pass: npm test"
      ],
      "passes": false,
      "blocked": false,
      "notes": null,
      "priority": 1
    }
  ]
}
```

**Field Reference:**

| Field | Type | Required | Description |
|---|---|---|---|
| `project` | string | yes | Project identifier |
| `feature` | string | yes | What this Ralph session is working on |
| `workingDirectory` | string | yes | Absolute path to the git repository |
| `branchName` | string | no | Target branch name |
| `userStories` | array | yes | List of stories to implement |
| `userStories[].id` | string | yes | Unique story identifier |
| `userStories[].title` | string | yes | Short description |
| `userStories[].description` | string | no | Detailed task description |
| `userStories[].acceptanceCriteria` | string[] | no | Conditions for passing |
| `userStories[].passes` | boolean | yes | Whether this story is done |
| `userStories[].blocked` | boolean | no | Whether to skip this story |
| `userStories[].notes` | string | no | Agent notes from previous attempts |
| `userStories[].priority` | number | no | Execution order hint |

**How it works:** Ralph iterates through `userStories` in order, finds the first one where `passes: false` and `blocked: false`, and sends it to the AI agent. The agent is expected to set `passes: true` when it completes the story.

### prompt.md — Agent Instructions

This file contains the instructions the AI agent receives at the start of each iteration. Ralph appends dynamic context (current story, guardrails, iteration number, paths) automatically.

**Structure a good prompt.md:**

```markdown
# [Feature Name] - Execution Prompt

You are an expert [role] working on [context].

## Context
[Brief description of the project and tech stack]

## Execution Flow
For each story:
1. Read the story and acceptance criteria
2. Read relevant files before making changes
3. Implement the changes
4. Run verification: `[test command]`
5. If tests pass, update prd.json: set "passes": true
6. Commit with a descriptive message

## Absolute Rules
- [Rule 1: never do X]
- [Rule 2: always do Y]
- [Rule 3: constraints]
```

**Tips for effective prompts:**
- Be specific about the tech stack and project structure
- List exact commands for testing
- Include absolute rules the agent should never break
- Reference file paths the agent will need
- Keep it focused — the story provides the task details

### guardrails.md — Learned Constraints

Guardrails are lessons learned from previous failures. Ralph creates this file automatically if it doesn't exist, and adds new guardrails when a story fails repeatedly.

```markdown
# Guardrails (Signs)

Lessons learned from previous iterations. The agent MUST read this FIRST.

## Active Guardrails

### Sign: Database migrations must be idempotent
- **Trigger**: When creating or modifying migrations
- **Instruction**: Always use IF NOT EXISTS / IF EXISTS checks
- **Added after**: Iteration 5 - migration failed on re-run

### Sign: Don't modify the auth middleware
- **Trigger**: When working on API endpoints
- **Instruction**: The auth middleware is shared across services, changes break other apps
- **Added after**: Iteration 12 - broke the admin panel
```

The gutter detection system automatically adds guardrails when a story fails 3+ times (configurable via `GUTTER_THRESHOLD`).

## Configuration

### ralph.toml (Optional)

For projects with services that need to be running (databases, APIs, Docker containers), create a `ralph.toml`:

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

[services.legacy]
name = "database"
health = "http://localhost:5432"
port = 5432
optional = false
maxStartWait = 15

[services.new]
name = "api-server"
health = "http://localhost:3000/health"
port = 3000
start = "npm run dev"
stop = "kill $(lsof -ti :3000) 2>/dev/null"
workingDirectory = "/path/to/project"
type = "process"
maxStartWait = 30
```

**Service types:** `process` (local) or `docker` (with `buildCommand`, `containerName`, `imageName`).

Use it with: `./ralph-codex.sh --config ralph.toml` or `ralph --config ralph.toml`.

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `MAX_ITERATIONS` | `9999` | Maximum iterations before stopping |
| `POLL_INTERVAL` | `300` | Seconds between polling for changes |
| `MAX_RETRIES` | `5` | Retries per failed AI agent invocation |
| `INITIAL_BACKOFF` | `30` | Initial retry backoff in seconds |
| `MAX_BACKOFF` | `600` | Maximum retry backoff in seconds |
| `RATE_LIMIT_WAIT` | `120` | Seconds to wait on rate limit |
| `GUTTER_THRESHOLD` | `3` | Failures before a story is auto-blocked |
| `CODEX_STALL_TIMEOUT` | `300` | Seconds before killing a stalled agent |

**Provider-specific:**

| Variable | Script | Default |
|---|---|---|
| `CODEX_MODEL` | ralph-codex.sh | `gpt-5.4` |
| `CODEX_REASONING` | ralph-codex.sh | `high` |
| `CLAUDE_MODEL` | ralph-claude.sh | `claude-sonnet-4-6` |
| `CLAUDE_FALLBACK_MODEL` | ralph-claude.sh | `sonnet` |
| `MAX_TURNS` | ralph-claude.sh | `200` |
| `MAX_BUDGET_USD` | ralph-claude.sh | (none) |
| `CURSOR_MODEL` | ralph-cursor.sh | `claude-4.6-opus-max-thinking` |
| `CURSOR_FALLBACK_MODEL` | ralph-cursor.sh | `claude-4.6-sonnet-medium-thinking` |
| `GEMINI_MODEL` | ralph-gemini.sh | `gemini-2.5-pro` |

## Commands

All scripts support the same subcommands:

| Command | Description |
|---|---|
| `./ralph-{provider}.sh` | Start the autonomous loop |
| `./ralph-{provider}.sh status` | Show progress, model, errors |
| `./ralph-{provider}.sh watch` | Tail logs in real time |
| `./ralph-{provider}.sh reset` | Clear state files |
| `./ralph-{provider}.sh 5` | Run max 5 iterations |
| `./ralph-{provider}.sh --model <model>` | Override the model |
| `./ralph-{provider}.sh --config ralph.toml` | Use TOML configuration |

For the Rust binary:

```bash
ralph --provider codex --model gpt-5.4
ralph --provider claude --model claude-sonnet-4-6
ralph --provider cursor --model claude-4.6-opus-max-thinking
ralph status
ralph watch
ralph reset
ralph --max-iterations 10
ralph --config ralph.toml
```

## Monitoring & Control

### Pause / Resume

```bash
touch .ralph-pause    # Pauses after current iteration
rm .ralph-pause       # Resumes the loop
```

### Stop Gracefully

```bash
touch .ralph-done     # Exits after current iteration completes
```

### Log Files

| File | Content |
|---|---|
| `activity.log` | Timestamped session events |
| `error.log` | All errors with type classification |
| `codex_output.log` | Raw AI agent output |
| `progress.txt` | Cumulative iteration reports |
| `guardrails.md` | Accumulated lessons learned |
| `failure_memory.json` | Structured failure tracking (Rust only) |

## Providers

### OpenAI Codex (`ralph-codex.sh` / `--provider codex`)

| Default model | `gpt-5.4` |
|---|---|
| CLI version | 0.118.0+ |

```bash
codex exec \
    --dangerously-bypass-approvals-and-sandbox \
    --model "gpt-5.4" \
    -c model_reasoning_effort="high" \
    --json \
    -C "$WORK_DIR" \
    -o "$LAST_MESSAGE_FILE" \
    "$PROMPT"
```

Requires: `codex` CLI installed (`npm i -g @openai/codex`), `codex login` or `OPENAI_API_KEY` set.

### Claude Code (`ralph-claude.sh` / `--provider claude`)

| Default model | `claude-sonnet-4-6` |
|---|---|
| Fallback model | `sonnet` |
| CLI version | 2.1.0+ |

```bash
claude -p "$PROMPT" \
    --model "claude-sonnet-4-6" \
    --fallback-model "sonnet" \
    --output-format text \
    --max-turns 200 \
    --dangerously-skip-permissions
```

Requires: `claude` CLI installed (`npm i -g @anthropic-ai/claude-code`), authenticated.

### Cursor Agent (`ralph-cursor.sh` / `--provider cursor`)

| Default model | `claude-4.6-opus-max-thinking` |
|---|---|
| Fallback model | `claude-4.6-sonnet-medium-thinking` |
| CLI version | 2026.03+ |

```bash
agent -p --force \
    --model "claude-4.6-opus-max-thinking" \
    --output-format stream-json \
    --workspace "$WORK_DIR" \
    --sandbox disabled \
    --approve-mcps \
    "$PROMPT"
```

Requires: `agent` CLI installed (bundled with Cursor), authenticated. Run `agent --list-models` to see available models.

### Google Gemini (`ralph-gemini.sh`)

| Default model | `gemini-2.5-pro` |
|---|---|
| Fallback model | `gemini-2.5-flash` |
| CLI version | 0.28.0+ |

```bash
gemini -p "$PROMPT" \
    --yolo \
    --model "gemini-2.5-pro"
```

Requires: `gemini` CLI installed (`npm i -g @anthropic-ai/gemini-cli`), `gemini auth login` or `GEMINI_API_KEY` set.

## Architecture (Rust)

```
src/
├── main.rs              CLI entry point (clap)
├── config.rs            TOML config + env var loading
├── loop_engine.rs       Main iteration loop
├── prd.rs               PRD JSON parsing and management
├── prompt.rs            Prompt builder (base + guardrails + story + context)
├── git.rs               Git operations (fetch, hash, diff, branch)
├── guardrails.rs        Guardrail file management
├── logger.rs            Colored terminal output + file logging
├── signals.rs           Ctrl+C graceful shutdown
├── state.rs             Pause/resume/done state files
├── providers/
│   ├── mod.rs           Provider trait + AgentResult + rate limit detection
│   ├── codex.rs         OpenAI Codex provider
│   ├── claude.rs        Claude Code provider
│   └── cursor.rs        Cursor Agent provider
├── detection/
│   ├── failure_memory.rs  Per-story failure tracking with diversity enforcement
│   ├── loop_detector.rs   Output repetition detection
│   ├── progress.rs        Diff-based progress analysis
│   └── stall.rs           Stall detection with graceful kill
└── health/
    ├── mod.rs             Parallel service health checking
    ├── service.rs         HTTP health check + wait-for-healthy
    └── manager.rs         Shell command execution + process management
```

### Key Concepts

**Failure Memory** — The Rust binary tracks every failed attempt per story. When consecutive attempts use the same approach, it triggers "diversity enforcement": the prompt tells the agent to try a fundamentally different strategy and lists banned approaches.

**Gutter Detection** — When a story fails more than `gutter_threshold` times, it's automatically blocked and a guardrail is added. This prevents infinite loops on impossible tasks.

**Stall Detection** — Monitors agent stdout. If no output is produced for `stall_timeout_secs`, the process is killed (SIGINT → SIGTERM → SIGKILL) and the iteration is retried.

**Loop Detection** — Analyzes the last 50 lines of agent output for repeating patterns (windows of 1-3 lines repeated 3+ times). Logs a warning when detected.

## Planning a Ralph Session

### Step 1: Define the PRD

Break your work into small, testable stories. Each story should:
- Have clear acceptance criteria the agent can verify
- Be small enough to complete in a single agent session
- Have a verification command (test, typecheck, lint)
- Be ordered by dependency (stories are executed in array order)

### Step 2: Write the Prompt

Your prompt should:
- Describe the project context and tech stack
- Define the exact execution flow (read → implement → test → mark passed → commit)
- Set absolute rules the agent must follow
- Reference specific paths and commands

### Step 3: Choose Your Provider

| Provider | Best For | Cost |
|---|---|---|
| Codex | Complex multi-file changes | $$ |
| Claude | Reasoning-heavy tasks | $$ |
| Cursor | IDE-integrated workflows | Subscription |
| Gemini | Quick iterations, large context | $ |

### Step 4: Run and Monitor

```bash
# Start in background
nohup ./ralph-codex.sh > /dev/null 2>&1 &

# Monitor progress
./ralph-codex.sh watch

# Check status
./ralph-codex.sh status
```

## Skills

Ralph includes ready-to-use agent skills for Claude Code and Cursor. These teach the AI assistants how to set up, run, and troubleshoot Ralph sessions when you ask them to.

```
skills/
├── claude/SKILL.md    # For Claude Code / Codex CLI
└── cursor/SKILL.md    # For Cursor Agent
```

### Installation

Symlink or copy the skill into your agent's skills directory:

```bash
ln -s ~/personal/ralph/skills/claude/SKILL.md ~/.codex/skills/ralph/SKILL.md
ln -s ~/personal/ralph/skills/cursor/SKILL.md ~/.cursor/skills/ralph/SKILL.md
```

Once installed, you can ask your AI assistant things like "plan a ralph session for my project", "create a PRD for ralph", or "run ralph with codex" and it will know exactly what to do.

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `AUTH_ERROR` | Not authenticated | Run provider login command |
| `QUOTA_EXHAUSTED` | API usage limit reached | Check billing/subscription |
| `MODEL_ERROR` | Invalid model name | Check provider documentation |
| `RATE_LIMIT` | Too many requests | Auto-retries with backoff |
| `CONTEXT_LENGTH` | Prompt too large | Trim prompt.md or guardrails.md |
| `TERMINATED` | Process killed externally | Check system resources |
| `SERVER_ERROR` | Provider API outage | Auto-retries with backoff |
| PRD corrupted | Agent broke prd.json | Auto-restores from backup |
| GUTTER detected | Story failed 3+ times | Review errors, fix manually, then `reset` |

## License

MIT
