# duet

Autonomous pair programming for AI coding agents. Two agents work side-by-side in tmux — one implements, the other reviews — iterating until they reach consensus. One shell script, zero dependencies.



```
./duet.sh -a -t -e "implement a streaming anomaly detector in Python"
```

## What it does

1. Spins up two Claude Code (or Codex) instances in a tmux session
2. Agent A implements your task
3. Agent B reviews, critiques, and improves the code
4. They go back and forth until both agree the work is done (`VERDICT: CONSENSUS`)
5. In explore mode, agents propose follow-up tasks and self-direct through the backlog
6. Bridge prompts you for a follow-up task — agents keep full context

The idle agent watches the working agent in real-time and can interject if it spots a serious bug mid-implementation.

## Quick start

```bash
# Prerequisites
brew install tmux        # or: apt install tmux
# Claude Code CLI: https://docs.anthropic.com/en/docs/claude-code
# Codex CLI (optional): npm install -g @openai/codex

# Basic run
./duet.sh "implement a markdown-to-HTML converter with tests"

# With auto-approve + token tracking
./duet.sh -a -t "build a B-tree key-value store in Python"

# With explore mode (agents propose and self-direct follow-up tasks)
./duet.sh -a -t -e "build a marketplace framework"

# Named session (run multiple in parallel)
./duet.sh -a -t -s api-work "add rate limiting to the API"

# Watch the agents work (read-only so keystrokes don't interfere)
tmux attach -t pair -r     # or: tmux attach -t api-work -r
```

## Options

| Flag | Description |
|---|---|
| `-s NAME`, `--session NAME` | Session name (default: `pair`). Run multiple sessions in parallel. |
| `-t`, `--tokens` | Track and report estimated token usage at each turn and end of task. |
| `-a`, `--auto-approve` | Auto-approve safe bash commands, file edits, and re-runs of previously approved scripts. `rm` is always blocked. |
| `-e`, `--explore` | Agents propose follow-up tasks as they work. After consensus, they self-direct through the backlog, alternating who picks. |
| `--secure` | Hardened auto-approve. Blocks pipes/semicolons/subshells, sensitive file edits (`~/.ssh`, `.env`, etc.), removes `python -c` and `find` from safe list. Use with `-a`. |
| `--turn-timeout SECS` | Max seconds per agent turn (default: 3600 / 1hr). |
| `--stall-timeout SECS` | Seconds before declaring agent stuck (default: 600). Set to 0 to disable. |
| `--clear` | Remove the `.bridge/` directory and exit. Use to start fresh. |

## How it works

```
┌─────────────┐     .bridge/      ┌─────────────┐
│   Agent A    │◄────────────────►│   Agent B    │
│  (implement) │   a_to_b.md      │   (review)   │
│              │   b_to_a.md      │              │
└──────┬───────┘   feedback_*.md  └──────┬───────┘
       │           proposals.md          │
       └──────────┐  ┌───────────────────┘
                  ▼  ▼
            ┌──────────────┐
            │    Bridge     │
            │ (pair-program │
            │    .sh)       │
            └──────────────┘
            Monitors both agents,
            detects errors & stalls,
            orchestrates turn-taking,
            auto-approves commands
```

- **Communication**: Agents read/write markdown files in `.bridge/<session>/`. The bridge monitors tmux panes for idle detection, error classification, and permission prompts.
- **Live scrutiny**: While Agent A works, the bridge periodically asks Agent B to glance at Agent A's screen and file diffs. Agent B responds with `STATUS: OK`, `STATUS: NOTE` (queued for later), or `INTERJECT:` (interrupts immediately for serious issues). The bridge includes the task context on first observation and existing notes to prevent duplicates.
- **Error patience**: Transient errors (missing import, typo) get 1 retry cycle. Serious errors (segfault, bus error) trigger immediate interjection. If the observer dismisses an error as a false positive, transient detection is suppressed for the rest of the turn.
- **Diff gating**: Observations only fire when project files have actually changed since the last observation (tracked via checksums), saving tokens when the agent is thinking or the screen is static.
- **Consensus**: Agent B ends each review with `VERDICT: APPROVED` or `VERDICT: NEEDS_WORK`. On approval, Agent A confirms with `VERDICT: CONSENSUS`.

## Explore mode

With `-e`, agents propose follow-up tasks as they work:

```
PROPOSAL: Add persistent state (SQLite)
REASON: All state is in-memory. Need persistence across sessions.
PRIORITY: HIGH
```

After consensus on the current task, the bridge presents accumulated proposals and the agents self-direct:

1. Agent A picks the highest priority proposal → implements it
2. Agent B reviews → they iterate to consensus
3. Agent B picks the next proposal → implements it (roles alternate)
4. New proposals can be added at any time — the backlog is self-sustaining
5. Agents remove completed proposals from the file as they go

Proposals persist across tasks within a session. Each agent is told to read existing proposals before adding new ones to avoid duplicates, and can refine or reprioritize existing proposals.

## Interactive REPL

After a task completes (or when proposals run out in explore mode), the bridge keeps the session alive and prompts for follow-up tasks:

```
[pair] ▸ now add comprehensive error handling
[pair] ▸ refactor the parser into separate modules
[pair] ▸ exit
```

Agents retain full context from previous tasks. `exit`, `quit`, or Ctrl+C to stop.

## Auto-approve

With `-a`, the bridge detects permission prompts in the tmux pane and approves them automatically. Supports both Claude Code and Codex prompt formats.

- **File edits**: Approved with "allow all edits" / "don't ask again" when available (checks for 2 vs 3 option menus to avoid selecting "No")
- **Safe bash commands**: `ls`, `mkdir`, `grep`, `cat`, `python`, `pytest`, `node`, `cargo`, `docker run/exec/build`, `git status/log/diff`, `pip install`, `npm run/test`, and more
- **Env var prefixes**: `PYTHONDONTWRITEBYTECODE=1 python -m pytest` correctly strips the prefix and matches `python`
- **Learned scripts**: Manually approve `python train.py --lr 0.01` once, and future runs of `python train.py` with any args are auto-approved
- **Always blocked**: `rm`, `rmdir`, `sudo`, `git push`, `git reset`
- **Retry on failure**: If a keystroke doesn't register, the bridge retries after 5 seconds instead of getting stuck

With `--secure`, additional protections apply:
- Rejects commands with pipes, semicolons, subshells, backticks
- Blocks edits to `~/.ssh/*`, `.env`, `.bashrc`, `/etc/*`, etc.
- Removes `python -c`, `find`, `chmod` from safe list

**Tip**: Attach with `tmux attach -t <session> -r` (read-only) to watch without accidentally sending keystrokes.

## Cross-model pairing

To pair Claude with Codex (or any other CLI), edit the agent commands near the top of the script:

```bash
AGENT_A_CMD="claude"
AGENT_B_CMD="codex"      # or any CLI that accepts text prompts
```

Each agent automatically gets its own project config file:

| CLI | Config file |
|---|---|
| `claude` | `CLAUDE.md` |
| `codex` | `AGENTS.md` |
| `aider` | `.aider.conf.yml` |
| other | `PROJECT_NOTES.md` |

## Configuration

Tunable constants at the top of `duet.sh` (or via CLI flags):

| Variable | Default | CLI flag | Description |
|---|---|---|---|
| `POLL_INTERVAL` | `1` | — | Seconds between idle/approval checks |
| `IDLE_CHECKS` | `3` | — | Consecutive unchanged checks = agent is done |
| `TURN_TIMEOUT` | `3600` | `--turn-timeout` | Max seconds per agent turn (1 hour) |
| `STALL_TIMEOUT` | `600` | `--stall-timeout` | Seconds before declaring agent stuck (0 to disable) |
| `OBSERVE_INTERVAL` | `45` | — | Seconds between live-scrutiny snapshots |
| `FIRST_OBSERVE_DELAY` | `60` | — | Seconds before first observation (allows extended thinking) |
| `ERROR_PATIENCE` | `1` | — | Transient error cycles to tolerate before interjecting |

## Session management

- **Session locking**: Only one bridge can use a session name at a time. A second `./duet.sh -s economy` will error with the PID of the existing bridge.
- **Clean start**: `./duet.sh --clear` removes all `.bridge/` data (including proposals).
- **Proposals persist**: Within a session, `proposals.md` survives across tasks. Only `--clear` removes it.

## Tips

- **Read-only attach**: `tmux attach -t <session> -r` to watch without interfering
- **Multiple sessions**: `-s frontend` and `-s backend` run independent pairs in parallel
- **Long jobs**: Use `--stall-timeout 0` for training runs so the bridge doesn't interrupt. The observer can vouch for long-running jobs (STATUS: OK prevents nudging).
- **Works on macOS and Linux**: bash 3.2+ compatible, no GNU-specific dependencies
- **Anti-sycophancy**: Both agents are instructed to be direct and critical — Agent B won't rubber-stamp, Agent A won't agree just to be polite
