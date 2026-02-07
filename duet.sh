#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# duet.sh
#
# Autonomous pair programming bridge: two Claude Code (or Codex) CLI instances
# running side-by-side in tmux, communicating through a shared .bridge/ dir.
#
# Features:
#   - Early termination when agents reach consensus (VERDICT: APPROVED)
#   - Error patience: tolerates 1 transient error cycle, but interjects
#     immediately on logic errors, security issues, or repeated failures
#   - Live scrutiny: the idle agent periodically reviews the working agent's
#     code and screen, and can interject with feedback mid-turn
#   - Stall detection: if an agent is stuck too long, the other helps
#   - Config learning: agents update their config file (CLAUDE.md / AGENTS.md)
#
# Usage:
#   ./duet.sh [OPTIONS] "task description"
#
# Options:
#   --session NAME, -s NAME   Session name (default: "pair"). Allows multiple
#                              independent sessions in the same directory.
#   --tokens, -t              Track and report estimated token usage
#   --auto-approve, -a        Auto-approve safe bash commands (ls, mkdir, etc.),
#                              file edits, and re-runs of previously approved
#                              scripts. rm is always blocked. Off by default.
#   --secure                   Hardened auto-approve: rejects commands with
#                              pipes/semicolons/subshells, blocks sensitive file
#                              edits (~/.ssh, .env, etc.), removes python -c
#                              and find from safe list. Use with -a.
#   --explore, -e              Agents can propose follow-up tasks when they spot
#                              gaps, missing features, or improvements. Proposals
#                              auto-queue after consensus. Off by default.
#   --turn-timeout SECS        Max seconds per agent turn (default: 3600 / 1hr).
#   --stall-timeout SECS       Seconds before declaring agent stuck (default: 600).
#                              For long jobs (training, batch), set high or 0.
#   --clear                    Remove the .bridge/ directory and exit. Use to
#                              start fresh (clears all sessions).
#
# After each task completes, the bridge prompts for a follow-up task.
# Agents keep full context across tasks. Ctrl+C or "exit" to quit.
#
# Examples:
#   ./duet.sh "implement a rate limiter in Go"
#   ./duet.sh -s cuda-opt -t "optimize the matrix profile kernel"
#   ./duet.sh -s review "review and fix bugs in src/"
#
# Prerequisites:
#   - tmux
#   - claude (Claude Code CLI) — or change AGENT_*_CMD below
#
# Permissions:
#   Both Claude Code instances may ask for tool-use approval. Either:
#     a) Attach to the tmux session (tmux attach -t pair) and approve manually
#     b) Run agents with appropriate permission settings
###############################################################################

# --- Args & Config -----------------------------------------------------------
TRACK_TOKENS=false
AUTO_APPROVE=false
SECURE_MODE=false
EXPLORE_MODE=false
SESSION="pair"

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --session|-s)       SESSION="$2"; shift 2 ;;
        --tokens|-t)        TRACK_TOKENS=true; shift ;;
        --auto-approve|-a)  AUTO_APPROVE=true; shift ;;
        --secure)           SECURE_MODE=true; shift ;;
        --turn-timeout)     TURN_TIMEOUT="$2"; shift 2 ;;
        --stall-timeout)    STALL_TIMEOUT="$2"; shift 2 ;;
        --explore|-e)       EXPLORE_MODE=true; shift ;;
        --clear)
            echo "Clearing .bridge/ directory..."
            rm -rf "$(pwd)/.bridge"
            echo "Done. .bridge/ removed."
            exit 0
            ;;
        -*)                 echo "Unknown option: $1" >&2; exit 1 ;;
        *)                  break ;;
    esac
done

TASK="${1:?Usage: ./duet.sh [-s name] [-t] [-a] 'task description'}"
MAX_ROUNDS=999999  # effectively unlimited — runs until consensus or Ctrl+C

BRIDGE_DIR="$(pwd)/.bridge/$SESSION"
BP=".bridge/$SESSION"              # relative path for agent-facing messages
AGENT_A_CMD="claude"
AGENT_B_CMD="codex"          # swap to "codex" for cross-model pairing

# Map agent CLI to its project config file
agent_config_file() {
    case "$1" in
        *claude*) echo "CLAUDE.md" ;;
        *codex*)  echo "AGENTS.md" ;;
        *aider*)  echo ".aider.conf.yml" ;;
        *)        echo "PROJECT_NOTES.md" ;;
    esac
}
AGENT_A_CONFIG=$(agent_config_file "$AGENT_A_CMD")
AGENT_B_CONFIG=$(agent_config_file "$AGENT_B_CMD")

POLL_INTERVAL=1               # seconds between idle-checks
IDLE_CHECKS=3                 # consecutive unchanged checks = done
TURN_TIMEOUT=3600             # max seconds per agent turn (1 hour)
STALL_TIMEOUT=600             # seconds before declaring an agent stuck (10 min)
OBSERVE_INTERVAL=45           # seconds between live-scrutiny snapshots
FIRST_OBSERVE_DELAY=60        # seconds before first observation (allow extended thinking)
ERROR_PATIENCE=1              # transient error cycles to tolerate before interject

# --- Colors ------------------------------------------------------------------
C_RESET='\033[0m'
C_BRIDGE='\033[0;36m'
C_A='\033[0;32m'
C_B='\033[0;33m'
C_ERR='\033[0;31m'
C_WARN='\033[0;35m'
C_OBS='\033[0;34m'
C_TOK='\033[0;37m'

stamp() { date +%H:%M:%S; }
log()   { echo -e "${C_BRIDGE}[$(stamp)] [bridge]${C_RESET} $*"; }
log_a() { echo -e "${C_A}[$(stamp)] [Agent A]${C_RESET} $*"; }
log_b() { echo -e "${C_B}[$(stamp)] [Agent B]${C_RESET} $*"; }
log_w() { echo -e "${C_WARN}[$(stamp)] [interject]${C_RESET} $*"; }
log_o() { echo -e "${C_OBS}[$(stamp)] [observe]${C_RESET} $*"; }
log_t() { echo -e "${C_TOK}[$(stamp)] [tokens]${C_RESET} $*"; }
err()   { echo -e "${C_ERR}[$(stamp)] [ERROR]${C_RESET} $*" >&2; }

# --- Platform helpers --------------------------------------------------------
file_mtime() {
    stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

pane_hash() {
    local content
    content=$(tmux capture-pane -t "$1" -p 2>/dev/null || true)
    if command -v md5 &>/dev/null; then
        echo "$content" | md5 -q
    else
        echo "$content" | md5sum | cut -d' ' -f1
    fi
}

now_epoch() { date +%s; }

# Lowercase a string (macOS bash 3.2 compatible — no ${var,,} support)
lc() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

# --- Token tracking ----------------------------------------------------------
# Tracks cumulative bytes flowing through .bridge/ as a proxy for token usage.
# ~4 chars ≈ 1 token for English text.
TOKENS_BRIDGE_BYTES=0
TOKENS_OBSERVATIONS=0
TOKENS_INTERJECTIONS=0
TOKENS_TURNS=0
TOKENS_START_TIME=""

tokens_init() {
    TOKENS_START_TIME=$(now_epoch)
    TOKENS_BRIDGE_BYTES=0
    TOKENS_OBSERVATIONS=0
    TOKENS_INTERJECTIONS=0
    TOKENS_TURNS=0
}

# Sum current bytes of all .bridge/ files
tokens_bridge_total() {
    local total=0
    local size
    for f in "$BRIDGE_DIR"/*.md "$BRIDGE_DIR"/*.txt; do
        if [[ -f "$f" ]]; then
            size=$(wc -c < "$f" 2>/dev/null || echo 0)
            total=$((total + size))
        fi
    done
    echo "$total"
}

tokens_record_turn() {
    if [[ "$TRACK_TOKENS" != "true" ]]; then return; fi
    (( TOKENS_TURNS++ )) || true
    TOKENS_BRIDGE_BYTES=$(tokens_bridge_total)
    local est_tokens=$((TOKENS_BRIDGE_BYTES / 4))
    log_t "Turn $TOKENS_TURNS complete | Bridge I/O: ~${TOKENS_BRIDGE_BYTES} bytes (~${est_tokens} tokens) | Observations: $TOKENS_OBSERVATIONS | Interjections: $TOKENS_INTERJECTIONS"
}

tokens_record_observation() {
    if [[ "$TRACK_TOKENS" != "true" ]]; then return; fi
    (( TOKENS_OBSERVATIONS++ )) || true
}

tokens_record_interjection() {
    if [[ "$TRACK_TOKENS" != "true" ]]; then return; fi
    (( TOKENS_INTERJECTIONS++ )) || true
}

tokens_report() {
    if [[ "$TRACK_TOKENS" != "true" ]]; then return; fi
    local end_time
    end_time=$(now_epoch)
    local elapsed=$((end_time - TOKENS_START_TIME))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))
    TOKENS_BRIDGE_BYTES=$(tokens_bridge_total)
    local est_tokens=$((TOKENS_BRIDGE_BYTES / 4))

    echo ""
    log_t "━━━━━━━━━━━━━━━━━ Token Usage Report ━━━━━━━━━━━━━━━━━━━━━━"
    log_t "Wall time:       ${mins}m ${secs}s"
    log_t "Turns:           $TOKENS_TURNS"
    log_t "Observations:    $TOKENS_OBSERVATIONS"
    log_t "Interjections:   $TOKENS_INTERJECTIONS"
    log_t "Bridge I/O:      ${TOKENS_BRIDGE_BYTES} bytes"
    log_t "Est. bridge tokens: ~${est_tokens} (bridge files only, excludes agent tool use)"
    log_t ""
    log_t "Note: This tracks bytes flowing through .bridge/ files."
    log_t "Actual API token usage is higher — each agent also reads/writes"
    log_t "project files, runs tools, and maintains conversation history."
    log_t "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# --- Auto-approve system -----------------------------------------------------
# Safe commands: non-destructive, read-only or benign operations
SAFE_CMD_PATTERN='^(ls|ll|la|dir|tree|pwd|du|df|cat|head|tail|wc|sort|uniq|diff|file|stat|mkdir|cd|chmod|chown|echo|printf|which|type|env|export|find|grep|rg|sleep|pytest|py\.test|node|ruby|perl|git[[:space:]]+(status|log|diff|branch|show|tag)|pip[[:space:]]+(list|show|install)|npm[[:space:]]+(list|ls|test|install|run)|yarn[[:space:]](list|test|install|run)|cargo[[:space:]]+(build|test|check|clippy|run)|docker[[:space:]]+(run|exec|build|ps|logs|images|compose)|docker-compose|python|python3)([[:space:]]|$)'

# --secure mode: tighter safe list (no bare python/node, no find, no chmod/chown)
SAFE_CMD_PATTERN_SECURE='^(ls|ll|la|dir|tree|pwd|du|df|cat|head|tail|wc|sort|uniq|diff|file|stat|mkdir|cd|echo|printf|which|type|env|export|grep|rg|sleep|pytest|py\.test|git[[:space:]]+(status|log|diff|branch|show|tag)|pip[[:space:]]+(list|show)|npm[[:space:]]+(list|ls|test)|yarn[[:space:]](list|test)|cargo[[:space:]]+(build|test|check|clippy)|python[[:space:]]+-m|python3[[:space:]]+-m)([[:space:]]|$)'

# Always blocked — never auto-approve these regardless of mode
BLOCKED_CMD_PATTERN='^(rm|rmdir|sudo|git[[:space:]]+(push|reset|clean|checkout[[:space:]]+\.))'

# --secure mode: expanded block list
BLOCKED_CMD_PATTERN_SECURE='^(rm|rmdir|sudo|dd|mv|chmod|chown|chattr|git[[:space:]]+(push|reset|clean|checkout[[:space:]]+\.))'

# --secure mode: reject commands with dangerous operators (pipes, semicolons, etc.)
DANGEROUS_OPERATORS='[;|`]|\$\(|&&'

# --secure mode: sensitive file paths — never auto-approve edits to these
BLOCKED_EDIT_PATTERN='(\.ssh|\.gnupg|\.bash|\.zsh|\.profile|\.git/hooks|/etc/|/root/|\.env|credentials|secrets|authorized_keys|known_hosts|id_rsa|\.pem|\.key)'

APPROVED_SCRIPTS_FILE=""  # set in setup()
LAST_PENDING_A=""         # tracks pending prompt per pane
LAST_PENDING_B=""
LAST_PENDING_TIME_A=0     # epoch when last approval was attempted
LAST_PENDING_TIME_B=0
APPROVAL_RETRY_AFTER=5    # seconds before retrying same prompt (keys may not register)

# Extract the script invocation pattern from a command.
# "python run.py --arg 1 --arg 2" → "python run.py"
# "cd /path && python run.py --foo" → "python run.py"
# "./test.sh arg1" → "./test.sh"
extract_script_pattern() {
    local cmd="$1"
    # Handle chained commands — check the last meaningful command
    local last_cmd
    last_cmd=$(echo "$cmd" | tr '&' '\n' | tr ';' '\n' | tail -1 | sed 's/^[[:space:]]*//')

    # Match: interpreter + script file
    local pattern
    pattern=$(echo "$last_cmd" | grep -oE '(python3?|node|ruby|perl|bash|sh|tsx?|npx)[[:space:]]+[^[:space:]]+\.(py|js|ts|rb|pl|sh|tsx)' | head -1)
    if [[ -n "$pattern" ]]; then
        echo "$pattern"
        return
    fi

    # Match: direct script execution (./script.sh, ./run.py)
    pattern=$(echo "$last_cmd" | grep -oE '\./[^[:space:]]+' | head -1)
    if [[ -n "$pattern" ]]; then
        echo "$pattern"
        return
    fi
}

# Get the base command (first word, or first word after cd ... &&)
get_base_command() {
    local cmd="$1"
    # Strip leading cd ... && if present
    local effective
    effective=$(echo "$cmd" | sed 's/^cd[[:space:]][^&]*&&[[:space:]]*//')
    echo "$effective" | awk '{print $1}'
}

# Check if a command should be auto-approved
should_auto_approve() {
    local cmd="$1"

    # Strip leading cd ... && (common pattern: cd /path && python script.py)
    local effective
    effective=$(echo "$cmd" | sed 's/^cd[[:space:]][^&]*&&[[:space:]]*//')

    # Strip leading env var assignments (e.g. PYTHONDONTWRITEBYTECODE=1 python -m pytest)
    while echo "$effective" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]'; do
        effective=$(echo "$effective" | sed 's/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]*//')
    done

    # --secure: reject commands with dangerous operators (pipes, semicolons, etc.)
    if [[ "$SECURE_MODE" == "true" ]]; then
        if echo "$effective" | grep -qE "$DANGEROUS_OPERATORS"; then
            return 1
        fi
    fi

    # BLOCKED: never auto-approve
    local block_pat="$BLOCKED_CMD_PATTERN"
    if [[ "$SECURE_MODE" == "true" ]]; then
        block_pat="$BLOCKED_CMD_PATTERN_SECURE"
    fi
    if echo "$effective" | grep -qE "$block_pat"; then
        return 1
    fi

    # SAFE: whitelisted non-destructive commands
    local safe_pat="$SAFE_CMD_PATTERN"
    if [[ "$SECURE_MODE" == "true" ]]; then
        safe_pat="$SAFE_CMD_PATTERN_SECURE"
    fi
    if echo "$effective" | grep -qE "$safe_pat"; then
        return 0
    fi

    # APPROVED SCRIPT: same script ran before (any args)
    local script_pattern
    script_pattern=$(extract_script_pattern "$effective")
    if [[ -n "$script_pattern" && -f "$APPROVED_SCRIPTS_FILE" ]]; then
        if grep -qF "$script_pattern" "$APPROVED_SCRIPTS_FILE" 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# Record a script as approved for future re-runs
record_script_approval() {
    local cmd="$1"
    local effective
    effective=$(echo "$cmd" | sed 's/^cd[[:space:]][^&]*&&[[:space:]]*//')

    # --secure: don't learn from commands with dangerous operators
    if [[ "$SECURE_MODE" == "true" ]]; then
        if echo "$effective" | grep -qE "$DANGEROUS_OPERATORS"; then
            return
        fi
    fi

    local script_pattern
    script_pattern=$(extract_script_pattern "$effective")
    if [[ -n "$script_pattern" ]]; then
        # Avoid duplicates
        if ! grep -qF "$script_pattern" "$APPROVED_SCRIPTS_FILE" 2>/dev/null; then
            echo "$script_pattern" >> "$APPROVED_SCRIPTS_FILE"
            log "Learned script approval: $script_pattern (future re-runs auto-approved)"
        fi
    fi
}

# Detect a permission prompt in the pane.
# Returns via stdout:
#   "bash:<command>"  — for Bash command approval
#   "edit:<filename>" — for file create/edit approval
#   ""                — no prompt detected
#
# Claude Code prompt formats (from tmux capture):
#
# Bash prompt:
#   Do you want to proceed?
#   ❯ 1. Yes  /  2. No
#
# File edit/create prompt:
#   Do you want to create <filename>?
#   ❯ 1. Yes
#     2. Yes, allow all edits during this session (shift+tab)
#     3. No
detect_permission_prompt() {
    local pane="$1"
    local lines
    lines=$(tmux capture-pane -t "$pane" -p -S -25 2>/dev/null || true)

    # --- File create/edit prompt (Claude Code) ---
    # "Do you want to create converter.py?"
    # "Do you want to edit converter.py?"
    # "Do you want to make this edit to economy.py?"  (v2.1.34+)
    local edit_file
    edit_file=$(echo "$lines" | grep -oE 'Do you want to (create|edit|make this edit to) [^ ?]+' | tail -1 | awk '{print $NF}')
    if [[ -n "$edit_file" ]]; then
        echo "edit:$edit_file"
        return
    fi

    # --- Bash command prompt (Claude Code) ---
    # Two known formats:
    #   v2.1.34+:  "Bash command\n  <cmd>\n  <desc>\n Permission rule..."
    #   older:     "Bash(<cmd>)\n ... Do you want to proceed?"
    if echo "$lines" | grep -qE '(Do you want to proceed|Permission rule)'; then
        local cmd=""

        # Format 1 (v2.1.34+): "Bash command" header, command on next indented line
        if [[ -z "$cmd" ]] && echo "$lines" | grep -q 'Bash command'; then
            local found_header=false
            while IFS= read -r line; do
                if echo "$line" | grep -q 'Bash command'; then
                    found_header=true
                    continue
                fi
                if [[ "$found_header" == "true" ]]; then
                    local trimmed
                    trimmed=$(echo "$line" | sed 's/^[[:space:]]*//')
                    # Skip blank lines; stop at Permission rule / Do you want
                    if [[ -z "$trimmed" ]]; then continue; fi
                    if echo "$trimmed" | grep -qE 'Permission rule|Do you want'; then break; fi
                    cmd="$trimmed"
                    break
                fi
            done <<< "$lines"
        fi

        # Format 2 (older): "Bash(command)" on one line
        if [[ -z "$cmd" ]]; then
            cmd=$(echo "$lines" | grep -oE 'Bash\((.+)\)' | tail -1 | sed 's/^Bash(//;s/)$//')
        fi

        # Format 2 fallback: Bash(...) spanning multiple lines
        if [[ -z "$cmd" ]]; then
            local bash_line
            bash_line=$(echo "$lines" | grep -n 'Bash(' | tail -1 | cut -d: -f1)
            if [[ -n "$bash_line" ]]; then
                cmd=$(echo "$lines" | tail -n +"$bash_line" | head -4 | tr '\n' ' ' | grep -oE 'Bash\((.+)\)' | sed 's/^Bash(//;s/)$//')
            fi
        fi

        if [[ -n "$cmd" ]]; then
            echo "bash:$cmd"
        fi
        return
    fi

    # --- File edit prompt (Codex) ---
    # Format:
    #   Would you like to make the following edits?
    #   agentic_capitalism/selection.py (+13 -2)
    #   ...diffs...
    #   › 1. Yes, proceed (y)
    #     2. Yes, and don't ask again for these files (a)
    #     3. No, and tell Codex what to do differently (esc)
    if echo "$lines" | grep -qE 'Would you like to make the following edits'; then
        local edit_file
        edit_file=$(echo "$lines" | grep -oE '[^[:space:]]+\.[a-zA-Z]+ \(\+[0-9]+ -[0-9]+\)' | tail -1 | awk '{print $1}')
        if [[ -n "$edit_file" ]]; then
            echo "edit:$edit_file"
        else
            # Fallback: can't extract filename but prompt is there
            echo "edit:(codex)"
        fi
        return
    fi

    # --- Bash command prompt (Codex) ---
    # Format:
    #   Would you like to run the following command?
    #   $ cat > file.md <<'EOF'
    #   ...
    #   › 1. Yes, proceed (y)
    #     2. Yes, and don't ask again for commands that start with `...` (p)
    #     3. No, and tell Codex what to do differently (esc)
    #
    # Returns "codex-bash:" so try_auto_approve can select option 2
    # ("don't ask again") via Down+Enter instead of plain Enter.
    if echo "$lines" | grep -qE 'Would you like to run the following command'; then
        local cmd
        cmd=$(echo "$lines" | grep -E '^[[:space:]]*[$] ' | tail -1 | sed 's/^[[:space:]]*[$] //')
        if [[ -n "$cmd" ]]; then
            echo "codex-bash:$cmd"
        fi
        return
    fi
}

# Check a pane for permission prompts and auto-approve if safe.
# File edits: always approve with "allow all edits" (shift+tab → Enter).
# Bash commands: approve only if on safe whitelist or learned script.
# Uses per-pane tracking to handle both agents concurrently.
try_auto_approve() {
    if [[ "$AUTO_APPROVE" != "true" ]]; then
        return
    fi

    local pane="$1"
    local label="$2"

    # Per-pane last-pending tracking (simple if/else, no eval)
    local last_pending=""
    case "$label" in
        A|a) last_pending="$LAST_PENDING_A" ;;
        B|b) last_pending="$LAST_PENDING_B" ;;
    esac

    local pending
    pending=$(detect_permission_prompt "$pane") || true

    if [[ -z "$pending" ]]; then
        # No pending prompt — check if a previously pending command resolved
        # (user manually approved it) → learn the script pattern
        if [[ -n "$last_pending" ]]; then
            record_script_approval "$last_pending"
            case "$label" in
                A|a) LAST_PENDING_A="" ;;
                B|b) LAST_PENDING_B="" ;;
            esac
        fi
        return
    fi

    # Skip if we already saw this exact prompt — but retry after
    # APPROVAL_RETRY_AFTER seconds in case the keystroke didn't register.
    if [[ "$pending" == "$last_pending" ]]; then
        local last_time=0
        case "$label" in
            A|a) last_time=$LAST_PENDING_TIME_A ;;
            B|b) last_time=$LAST_PENDING_TIME_B ;;
        esac
        local now_ap
        now_ap=$(now_epoch)
        if [[ $((now_ap - last_time)) -lt $APPROVAL_RETRY_AFTER ]]; then
            return
        fi
        # Enough time passed — retry
        log "Retrying auto-approve for Agent $label (previous attempt may not have registered)"
    fi
    case "$label" in
        A|a) LAST_PENDING_A="$pending"; LAST_PENDING_TIME_A=$(now_epoch) ;;
        B|b) LAST_PENDING_B="$pending"; LAST_PENDING_TIME_B=$(now_epoch) ;;
    esac

    local prompt_type="${pending%%:*}"
    local prompt_value="${pending#*:}"

    case "$prompt_type" in
        edit)
            # --secure: block edits to sensitive files (ssh keys, shell config, etc.)
            if [[ "$SECURE_MODE" == "true" ]]; then
                if echo "$prompt_value" | grep -qE "$BLOCKED_EDIT_PATTERN"; then
                    log "Blocking auto-approval for sensitive file: $prompt_value"
                    return
                fi
            fi
            # Both Claude Code and Codex have "allow all / don't ask again"
            # as option 2 — BUT only when 3+ options exist. With 2 options
            # (Yes/No), Down+Enter would select No.
            local pane_text
            pane_text=$(tmux capture-pane -t "$pane" -p -S -15 2>/dev/null || true)
            if echo "$pane_text" | grep -qiE "(allow all edits|don't ask again)"; then
                log "Auto-approving file edit for Agent $label: $prompt_value (allow all edits)"
                tmux send-keys -t "$pane" Down
                sleep 0.1
                tmux send-keys -t "$pane" Enter
            else
                log "Auto-approving file edit for Agent $label: $prompt_value"
                tmux send-keys -t "$pane" Enter
            fi
            sleep 0.2
            ;;
        bash)
            if should_auto_approve "$prompt_value"; then
                log "Auto-approving bash for Agent $label: $prompt_value"
                tmux send-keys -t "$pane" Enter
                sleep 0.2
                record_script_approval "$prompt_value"
            else
                log "Awaiting manual approval for Agent $label: $prompt_value"
            fi
            ;;
        codex-bash)
            # Codex bash prompts may have 2 or 3 options:
            #   2 options: 1. Yes, proceed / 2. No
            #   3 options: 1. Yes, proceed / 2. Don't ask again / 3. No
            # CRITICAL: Down+Enter on a 2-option prompt selects "No"!
            # Check the pane for "don't ask again" to decide.
            if should_auto_approve "$prompt_value"; then
                local pane_text
                pane_text=$(tmux capture-pane -t "$pane" -p -S -15 2>/dev/null || true)
                if echo "$pane_text" | grep -qi "don't ask again"; then
                    log "Auto-approving bash for Agent $label: $prompt_value (don't ask again)"
                    tmux send-keys -t "$pane" Down
                    sleep 0.1
                    tmux send-keys -t "$pane" Enter
                else
                    log "Auto-approving bash for Agent $label: $prompt_value"
                    tmux send-keys -t "$pane" Enter
                fi
                sleep 0.2
                record_script_approval "$prompt_value"
            else
                log "Awaiting manual approval for Agent $label: $prompt_value"
            fi
            ;;
    esac
}

# --- Core functions ----------------------------------------------------------

# Block until a tmux pane's visible content stops changing.
wait_for_idle() {
    local pane="$1"
    local label="${2:-agent}"
    local prev="" idle=0 elapsed=0

    while [[ $elapsed -lt $TURN_TIMEOUT ]]; do
        local h
        h=$(pane_hash "$pane")
        if [[ "$h" == "$prev" && -n "$h" ]]; then
            (( idle++ ))
            if [[ $idle -ge $IDLE_CHECKS ]]; then
                return 0
            fi
        else
            idle=0
        fi
        prev="$h"
        # Check for permission prompts during idle wait too
        try_auto_approve "$pane" "$label"
        sleep "$POLL_INTERVAL"
        (( elapsed += POLL_INTERVAL ))
    done

    err "Timeout waiting for $label to become idle"
    return 1
}

# Block until a file's mtime is newer than $after.
# Also auto-approves permission prompts on up to two panes while waiting.
wait_for_file_simple() {
    local file="$1" after="$2" timeout="${3:-$TURN_TIMEOUT}"
    local check_pane="${4:-}" check_label="${5:-}"
    local check_pane2="${6:-}" check_label2="${7:-}"
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        if [[ -f "$file" ]]; then
            local mt
            mt=$(file_mtime "$file")
            if [[ $mt -gt $after ]]; then
                return 0
            fi
        fi
        # Auto-approve prompts that may block either pane
        if [[ -n "$check_pane" ]]; then
            try_auto_approve "$check_pane" "$check_label"
        fi
        if [[ -n "$check_pane2" ]]; then
            try_auto_approve "$check_pane2" "$check_label2"
        fi
        sleep "$POLL_INTERVAL"
        (( elapsed += POLL_INTERVAL ))
    done
    return 1
}

# Capture a snapshot of the working agent's state with actual file diffs.
# Tracks file checksums between observations so the bridge can tell what's new.
# Returns (via exit code): 0 = files changed since last snapshot, 1 = no change.
capture_snapshot() {
    local worker_pane="$1"
    local worker_label="$2"
    local snapshot_file="$BRIDGE_DIR/live_$(lc "$worker_label").txt"
    local state_file="$BRIDGE_DIR/file_state_$(lc "$worker_label").txt"
    local prev_state_file="$BRIDGE_DIR/prev_file_state_$(lc "$worker_label").txt"

    # --- Find files modified since the task started ---
    local changed_files
    changed_files=$(find . -newer "$BRIDGE_DIR/task.md" \
        -not -path './.bridge/*' \
        -not -path './.git/*' \
        -not -path './__pycache__/*' \
        -not -path './node_modules/*' \
        -not -path './.pytest_cache/*' \
        -not -name '*.pyc' \
        -not -name 'duet.sh' -not -name 'pair-program.sh' \
        -not -name '*.log' \
        -type f 2>/dev/null | sort | head -30)

    # --- Build current file state (path + checksum) ---
    local current_state=""
    if [[ -n "$changed_files" ]]; then
        while IFS= read -r f; do
            if [[ -f "$f" ]]; then
                local cksum
                if command -v md5 &>/dev/null; then
                    cksum=$(md5 -q "$f" 2>/dev/null || echo "?")
                else
                    cksum=$(md5sum "$f" 2>/dev/null | cut -d' ' -f1 || echo "?")
                fi
                current_state="${current_state}${f}:${cksum}"$'\n'
            fi
        done <<< "$changed_files"
    fi

    # --- Compare to previous state to find newly changed files ---
    local files_changed=false
    local new_or_changed_files=""
    if [[ -f "$prev_state_file" ]]; then
        local prev_state
        prev_state=$(cat "$prev_state_file")
        if [[ "$current_state" != "$prev_state" ]]; then
            files_changed=true
            # Identify which files are new or have different checksums
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                if ! grep -qF "$line" "$prev_state_file" 2>/dev/null; then
                    local fpath="${line%%:*}"
                    new_or_changed_files="${new_or_changed_files}${fpath}"$'\n'
                fi
            done <<< "$current_state"
        fi
    else
        # First observation — everything is new
        files_changed=true
        new_or_changed_files="$changed_files"
    fi

    # Save current state for next comparison
    echo "$current_state" > "$state_file"

    # --- Write snapshot ---
    {
        echo "=== Agent $worker_label — Screen (last 40 lines) ==="
        tmux capture-pane -t "$worker_pane" -p -S -40 2>/dev/null || echo "(capture failed)"
        echo ""

        if [[ -n "$changed_files" ]]; then
            # If git is available, use git diff (best diffs)
            if git rev-parse --git-dir &>/dev/null 2>&1; then
                echo "=== File diffs (git) ==="
                git diff --stat HEAD 2>/dev/null || true
                echo ""
                # Show actual diff content for recently changed files (truncated)
                git diff HEAD 2>/dev/null | head -200 || true
            else
                # No git — show content of newly changed files (truncated)
                echo "=== All changed files ==="
                echo "$changed_files"
                echo ""
                if [[ -n "$new_or_changed_files" ]]; then
                    echo "=== New/modified since last observation ==="
                    while IFS= read -r f; do
                        [[ -z "$f" || ! -f "$f" ]] && continue
                        local lines
                        lines=$(wc -l < "$f" 2>/dev/null || echo 0)
                        echo "--- $f ($lines lines) ---"
                        head -40 "$f" 2>/dev/null || true
                        if [[ $lines -gt 40 ]]; then
                            echo "... (truncated, $((lines - 40)) more lines)"
                        fi
                        echo ""
                    done <<< "$new_or_changed_files"
                else
                    echo "(no new changes since last observation)"
                fi
            fi
        else
            echo "=== Changed files ==="
            echo "(none)"
        fi
        echo ""
        echo "=== Timestamp: $(date) ==="
    } > "$snapshot_file"

    # Promote state file for next comparison
    cp "$state_file" "$prev_state_file" 2>/dev/null || true

    if [[ "$files_changed" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# Classify errors found in pane content.
# Returns: "none", "transient", or "serious"
#
# IMPORTANT: patterns must be specific enough to avoid false positives from
# agent discussion text (e.g. "error handling", "race condition mitigation").
# Require colons, stack frames, or other structural indicators of real errors.
classify_errors() {
    local content="$1"

    # Serious errors — interject immediately
    # Only match unambiguous runtime crashes, not discussion about these topics
    if echo "$content" | grep -qE \
        'Segmentation fault|SIGSEGV|SIGBUS|Bus error|Aborted \(core dumped\)|Killed[[:space:]]*$' \
        2>/dev/null; then
        echo "serious"
        return
    fi

    # Transient errors — be patient, let agent self-correct
    # Require structural indicators: "Error:" with a type prefix, traceback frames,
    # or shell-specific error messages. Avoids bare "error" which matches discussion.
    if echo "$content" | grep -qE \
        'Traceback \(most recent|[A-Z][a-z]*Error:|[A-Z][a-z]*Exception:|FAILED|panic:|command not found|No such file or directory|Permission denied|exit code [1-9]|Cannot find module|Could not resolve' \
        2>/dev/null; then
        echo "transient"
        return
    fi

    echo "none"
}

# Type a message into a tmux pane and press Enter.
instruct() {
    local pane="$1"; shift
    local msg="$*"
    tmux send-keys -t "$pane" -l "$msg"
    sleep 0.3
    tmux send-keys -t "$pane" Enter
}

# Interrupt an agent (Esc twice, like the user pressing Esc in Claude Code).
interrupt_agent() {
    local pane="$1"
    tmux send-keys -t "$pane" Escape
    sleep 1
    tmux send-keys -t "$pane" Escape
    sleep 0.5
}

# Ask the observer to review and optionally interject.
# Non-blocking: writes feedback file if there's a concern.
# Returns 0 if observer flagged an issue, 1 otherwise.
request_observation() {
    local worker_pane="$1"
    local observer_pane="$2"
    local worker_label="$3"
    local observer_label="$4"
    local reason="${5:-periodic}"   # "periodic", "error", "stall"

    local snapshot_has_changes=true
    capture_snapshot "$worker_pane" "$worker_label" || snapshot_has_changes=false

    # For periodic observations, skip if no files changed since last snapshot.
    # Error/stall observations always proceed (screen content matters).
    if [[ "$reason" == "periodic" && "$snapshot_has_changes" == "false" ]]; then
        log_o "No file changes since last observation — skipping"
        return 1
    fi

    local feedback_file="$BRIDGE_DIR/feedback_for_$(lc "$worker_label").md"
    local fb_ts
    fb_ts=$(now_epoch)

    local prompt
    local fb_path="$BP/feedback_for_$(lc "$worker_label").md"
    local live_path="$BP/live_$(lc "$worker_label").txt"
    case "$reason" in
        error)
            prompt="Agent $worker_label is hitting errors. Read $live_path for their screen. Only read full code files if the screen alone isn't enough to diagnose. Write actionable advice to $fb_path. Start with INTERJECT: if this is a serious/logic error they can't self-correct, or STATUS: SUGGESTION if it's minor."
            ;;
        stall)
            prompt="Agent $worker_label has been working a while with no screen changes. Read $live_path for their screen. If they look stuck, write advice to $fb_path starting with INTERJECT:. If they're running a long job (training, tests, batch processing) and just need more time, write STATUS: OK — this will prevent the bridge from interrupting them."
            ;;
        *)
            local task_ctx=""
            if [[ "$TOKENS_OBSERVATIONS" -eq 0 ]]; then
                task_ctx="NEW TASK — read $BP/task.md for context on what Agent $worker_label is building. Then "
            fi
            # Tell the observer about existing queued notes so it doesn't repeat them
            local notes_ctx=""
            local queued_file="$BRIDGE_DIR/queued_notes_for_$(lc "$worker_label").md"
            if [[ -f "$queued_file" && -s "$queued_file" ]]; then
                notes_ctx=" You already noted these issues this turn (do NOT repeat them, only write a NEW issue): $(cat "$queued_file" | grep -v '^---$' | grep -v '^$' | tr '\n' ' ' | head -c 300)."
            fi
            prompt="${task_ctx}Glance at $live_path (screen + file diffs only). Verify the worker's approach aligns with the task requirements — flag if they're building the wrong thing or missing key requirements. Do NOT read full code files unless the diff looks suspicious.${notes_ctx} Write to $fb_path ONE of: STATUS: OK if progress looks on-track (or if the only issues are ones you already noted). STATUS: NOTE only for NEW specific actionable issues not already noted. INTERJECT: only for serious logic errors, security issues, or fundamentally wrong approaches that need immediate correction."
            ;;
    esac

    # Before sending instructions, clear any pending permission prompts.
    # If the observer is stuck on an un-approvable prompt, skip this
    # observation entirely — typing into an active permission dialog
    # garbles the agent's state.
    try_auto_approve "$observer_pane" "$observer_label"
    sleep 0.5
    local pending_prompt
    pending_prompt=$(detect_permission_prompt "$observer_pane") || true
    if [[ -n "$pending_prompt" ]]; then
        log_o "Observer $observer_label has a pending prompt ($pending_prompt) — skipping observation"
        return 1
    fi

    tokens_record_observation
    log_o "Asking Agent $observer_label to review ($reason)..."
    instruct "$observer_pane" "$prompt"

    # Give the observer time to review (up to 90s)
    # Auto-approve both panes: observer may need file-write approval,
    # worker may hit bash prompts while the bridge is waiting here.
    if wait_for_file_simple "$feedback_file" "$fb_ts" 90 \
        "$observer_pane" "$observer_label" "$worker_pane" "$worker_label"; then
        wait_for_idle "$observer_pane" "Agent $observer_label"

        if [[ ! -f "$feedback_file" ]]; then
            return 1
        fi

        # INTERJECT: → serious issue, interrupt the working agent NOW
        if grep -q 'INTERJECT:' "$feedback_file" 2>/dev/null; then
            log_o "Agent $observer_label flagged a serious issue — will interrupt"
            return 0
        fi

        # STATUS: NOTE → queue actionable observation for next turn boundary.
        if grep -q 'STATUS: NOTE' "$feedback_file" 2>/dev/null; then
            local queued="$BRIDGE_DIR/queued_notes_for_$(lc "$worker_label").md"
            cat "$feedback_file" >> "$queued"
            echo -e "\n---\n" >> "$queued"
            log_o "Agent $observer_label noted something — queued for next turn"
            rm -f "$feedback_file"
            return 1
        fi

        # STATUS: OK or STATUS: SUGGESTION → no interruption needed
        log_o "Agent $observer_label says OK"
        rm -f "$feedback_file"
        return 1
    else
        log_o "Observer didn't respond in time, continuing..."
        return 2  # distinct from 1 (OK) — caller can back off
    fi
}

# Deliver any queued observation notes to an agent (non-interruptive).
# Called at the START of an agent's formal turn, not mid-work.
deliver_queued_notes() {
    local agent_label="$1"
    local agent_pane="$2"
    local queued="$BRIDGE_DIR/queued_notes_for_$(lc "$agent_label").md"

    if [[ -f "$queued" && -s "$queued" ]]; then
        log_o "Delivering queued observation notes to Agent $agent_label"
        # Move to a delivery file the agent can read
        mv "$queued" "$BRIDGE_DIR/notes_for_$(lc "$agent_label").md"
        instruct "$agent_pane" \
            "FYI: your partner noted some observations during your last turn. Read $BP/notes_for_$(lc "$agent_label").md — address anything relevant as you work. These are non-urgent."
        sleep 2
    fi
}

# Forward observer feedback to the working agent (with interrupt).
forward_feedback() {
    local worker_pane="$1"
    local worker_label="$2"
    local observer_label="$3"
    local output_file_basename="$4"

    local feedback_file="$BRIDGE_DIR/feedback_for_$(lc "$worker_label").md"

    tokens_record_interjection
    log_w "Interrupting Agent $worker_label to forward Agent $observer_label's feedback..."
    interrupt_agent "$worker_pane"

    instruct "$worker_pane" \
        "Agent $observer_label reviewed your work-in-progress and found an issue. Read $BP/feedback_for_$(lc "$worker_label").md for their feedback. Address it and continue. Write your output to $BP/$output_file_basename when done."

    rm -f "$feedback_file"
}

# Main monitoring loop: wait for output file while providing error patience
# and live scrutiny.
monitor_turn() {
    local output_file="$1"
    local after="$2"
    local worker_pane="$3"
    local observer_pane="$4"
    local worker_label="$5"
    local observer_label="$6"

    local elapsed=0
    local transient_error_count=0
    local last_observe_time=0
    local last_content_hash=""
    local last_observe_hash=""       # screen hash at last observation — skip if unchanged
    local stall_interjected=false
    local last_error_interjection=0
    local ERROR_INTERJECTION_COOLDOWN=120  # seconds after error interjection before re-triggering
    local transient_errors_dismissed=false  # observer said "not a real error" — suppress until turn ends
    local output_basename
    output_basename=$(basename "$output_file")

    while [[ $elapsed -lt $TURN_TIMEOUT ]]; do
        # --- Check if output file was written --------------------------------
        if [[ -f "$output_file" ]]; then
            local mt
            mt=$(file_mtime "$output_file")
            if [[ $mt -gt $after ]]; then
                return 0
            fi
        fi

        # --- Capture current screen content ----------------------------------
        local current_content
        current_content=$(tmux capture-pane -t "$worker_pane" -p -S -50 2>/dev/null || true)
        local current_hash
        if command -v md5 &>/dev/null; then
            current_hash=$(echo "$current_content" | md5 -q)
        else
            current_hash=$(echo "$current_content" | md5sum | cut -d' ' -f1)
        fi

        local content_changed=false
        if [[ "$current_hash" != "$last_content_hash" ]]; then
            content_changed=true
        fi
        last_content_hash="$current_hash"

        # --- Error classification & patience ---------------------------------
        local error_class="none"
        local now_ts
        now_ts=$(now_epoch)

        # Skip error checks during cooldown after a recent interjection,
        # or if the observer already dismissed transient errors as false positives.
        # Serious errors (actual crashes) always get checked regardless.
        if [[ $((now_ts - last_error_interjection)) -ge $ERROR_INTERJECTION_COOLDOWN ]]; then
            error_class=$(classify_errors "$current_content")
            # Observer dismissed transient errors — downgrade to "none"
            if [[ "$transient_errors_dismissed" == "true" && "$error_class" == "transient" ]]; then
                error_class="none"
            fi
        fi

        case "$error_class" in
            serious)
                # Serious error: interject IMMEDIATELY (bypasses dismissed flag)
                log_w "SERIOUS error detected in Agent $worker_label's output!"
                if request_observation "$worker_pane" "$observer_pane" \
                    "$worker_label" "$observer_label" "error"; then
                    forward_feedback "$worker_pane" "$worker_label" \
                        "$observer_label" "$output_basename"
                else
                    # Observer said it's not actually serious — dismiss
                    log "Observer dismissed serious error as false positive"
                fi
                transient_error_count=0
                last_error_interjection=$(now_epoch)
                ;;
            transient)
                if [[ "$content_changed" == "true" ]]; then
                    (( transient_error_count++ )) || true
                    if [[ $transient_error_count -le $ERROR_PATIENCE ]]; then
                        log "Agent $worker_label hit a transient error (attempt $transient_error_count/$ERROR_PATIENCE) — being patient..."
                    else
                        # Patience exhausted — ask observer to verify
                        log_w "Agent $worker_label: transient errors persist after $ERROR_PATIENCE retries"
                        if request_observation "$worker_pane" "$observer_pane" \
                            "$worker_label" "$observer_label" "error"; then
                            forward_feedback "$worker_pane" "$worker_label" \
                                "$observer_label" "$output_basename"
                        else
                            # Observer says it's not a real error — suppress
                            # transient detection for the rest of this turn
                            log "Observer dismissed error as false positive — suppressing transient detection"
                            transient_errors_dismissed=true
                        fi
                        transient_error_count=0
                        last_error_interjection=$(now_epoch)
                    fi
                fi
                ;;
            none)
                transient_error_count=0
                ;;
        esac

        # --- Periodic live scrutiny (only when no errors active) -------------
        local now
        now=$(now_epoch)
        # First observation waits FIRST_OBSERVE_DELAY; subsequent ones use OBSERVE_INTERVAL
        local min_elapsed=$OBSERVE_INTERVAL
        if [[ "$TOKENS_OBSERVATIONS" -eq 0 ]]; then
            min_elapsed=$FIRST_OBSERVE_DELAY
        fi
        # Only observe if screen has changed since the LAST observation,
        # not just since the last 1-second poll. Saves tokens when the
        # worker is in extended thinking or the screen is mostly static.
        local screen_changed_since_observe=false
        if [[ "$current_hash" != "$last_observe_hash" ]]; then
            screen_changed_since_observe=true
        fi
        if [[ "$error_class" == "none" \
            && $((now - last_observe_time)) -ge $OBSERVE_INTERVAL \
            && "$screen_changed_since_observe" == "true" \
            && $elapsed -ge $min_elapsed ]]; then

            last_observe_time=$now
            last_observe_hash="$current_hash"

            local obs_rc=0
            request_observation "$worker_pane" "$observer_pane" \
                "$worker_label" "$observer_label" "periodic" || obs_rc=$?

            if [[ $obs_rc -eq 0 ]]; then
                # Observer flagged an issue — forward to worker
                forward_feedback "$worker_pane" "$worker_label" \
                    "$observer_label" "$output_basename"
            elif [[ $obs_rc -eq 2 ]]; then
                # Observer timed out or was stuck — back off to avoid
                # spamming a confused agent with repeated requests.
                log_o "Backing off observations for ${FIRST_OBSERVE_DELAY}s after timeout"
                last_observe_time=$((now + FIRST_OBSERVE_DELAY - OBSERVE_INTERVAL))
            fi
        fi

        # --- Stall detection (no output change for too long) -----------------
        if [[ $STALL_TIMEOUT -gt 0 \
            && $elapsed -ge $STALL_TIMEOUT \
            && "$stall_interjected" == "false" ]]; then
            log_w "Agent $worker_label appears stalled (${STALL_TIMEOUT}s)..."
            local stall_rc=0
            request_observation "$worker_pane" "$observer_pane" \
                "$worker_label" "$observer_label" "stall" || stall_rc=$?

            if [[ $stall_rc -eq 0 ]]; then
                # Observer says there's a real problem — interrupt worker
                forward_feedback "$worker_pane" "$worker_label" \
                    "$observer_label" "$output_basename"
            elif [[ $stall_rc -eq 1 ]]; then
                # Observer says OK (e.g. long-running job is expected) —
                # trust the observer, don't interrupt the worker.
                log "Observer confirmed agent is fine — no interruption"
            else
                # Observer timed out — send a gentle nudge as last resort
                interrupt_agent "$worker_pane"
                instruct "$worker_pane" \
                    "You've been working for a while. If you're stuck, try a different approach. Remember to write your output to $BP/$output_basename when done."
            fi
            stall_interjected=true
        fi

        # --- Auto-approve permission prompts if enabled -------------------------
        try_auto_approve "$worker_pane" "$worker_label"
        try_auto_approve "$observer_pane" "$observer_label"

        sleep "$POLL_INTERVAL"
        (( elapsed += POLL_INTERVAL ))
    done

    err "Timeout waiting for Agent $worker_label (file: $output_file)"
    return 1
}

# Check if a review file indicates consensus (task is done).
check_verdict() {
    local file="$1"
    if [[ -f "$file" ]]; then
        if grep -qiE 'VERDICT:\s*(APPROVED|COMPLETE|CONSENSUS|LGTM)' "$file" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# --- Setup -------------------------------------------------------------------
setup() {
    mkdir -p "$BRIDGE_DIR"

    # ---- Session lock — prevent two bridges on the same session ---------------
    local lockfile="$BRIDGE_DIR/bridge.pid"
    if [[ -f "$lockfile" ]]; then
        local old_pid
        old_pid=$(cat "$lockfile" 2>/dev/null)
        if kill -0 "$old_pid" 2>/dev/null; then
            err "Session '$SESSION' is already running (PID $old_pid)."
            err "Use a different session name (-s NAME) or kill the other bridge."
            exit 1
        else
            # Stale lock from a crashed bridge — clean it up
            rm -f "$lockfile"
        fi
    fi
    echo $$ > "$lockfile"

    # ---- Auto-approve script tracking ------------------------------------------
    APPROVED_SCRIPTS_FILE="$BRIDGE_DIR/approved_scripts.txt"
    touch "$APPROVED_SCRIPTS_FILE"
    if [[ "$AUTO_APPROVE" == "true" ]]; then
        if [[ "$SECURE_MODE" == "true" ]]; then
            log "Auto-approve enabled (SECURE). Hardened: no python -c, no find, no pipes/semicolons, sensitive files blocked."
        else
            log "Auto-approve enabled. Safe commands + learned scripts will be auto-approved."
        fi
    fi

    # ---- Agent A instructions -----------------------------------------------
    cat > "$BRIDGE_DIR/instructions_a.md" <<EOF
# Agent A — Pair Programming

You are **Agent A** in an autonomous pair programming session with **Agent B**.
A bridge script orchestrates communication between you.

## Workflow
1. Read \`$BP/task.md\` for the task.
2. Implement a solution using your full tools (Read, Write, Edit, Bash, etc.).
3. When DONE, write a concise summary to \`$BP/a_to_b.md\` covering:
   - What you implemented (files created/modified)
   - Key design decisions and tradeoffs
   - Open questions or areas you are unsure about
4. IMPORTANT: You MUST write \`$BP/a_to_b.md\` as the LAST thing you do
   so the bridge knows you are finished.

## Mid-turn feedback
The bridge may interrupt you with feedback from Agent B while you're working.
If this happens, read the feedback file mentioned, adjust your approach, and
continue working. This is normal pair programming — your partner is watching.

## Completion
- If Agent B's review says \`VERDICT: APPROVED\` and you agree the task is done,
  write a final \`$BP/a_to_b.md\` that includes \`VERDICT: CONSENSUS\` and
  a short summary of the final state. Do NOT continue iterating.

## Common issues & learning
- If you discover a common pitfall or project-specific pattern, add it to
  \`$AGENT_A_CONFIG\` in the project root so both agents benefit in future sessions.
- Read the file first — don't duplicate what's already noted.

## Guidelines
- Write real code to the project, not just to $BP/.
- Be specific — Agent B will read your code and critique it.
- If Agent B has sent you feedback (in \`$BP/b_to_a.md\`), address every point.
- If a command fails, try to self-correct once before giving up.
- Be **direct and critical** — don't agree with Agent B just to be polite. If you
  think their feedback is wrong or unnecessary, say so with reasoning.
EOF

    # ---- Explore mode instructions (Agent A) --------------------------------
    if [[ "$EXPLORE_MODE" == "true" ]]; then
        cat >> "$BRIDGE_DIR/instructions_a.md" <<EOF

## Proposing follow-up tasks (explore mode)
As you work, whenever you spot gaps, missing features, potential improvements,
or research needed, append a proposal to \`$BP/proposals.md\`. Do this any time
— don't wait until you're done. But stay focused on the CURRENT task first.
Read \`$BP/proposals.md\` first if it exists — don't duplicate existing proposals.
You can refine or reprioritize an existing one instead.

Format:
\`\`\`
PROPOSAL: <short title>
REASON: <why this matters — be specific about the gap or improvement>
PRIORITY: HIGH | MEDIUM | LOW
\`\`\`

After the current task reaches consensus, the bridge will ask both agents to
review proposals and agree on what to tackle next. Remove proposals from the
file as they get completed.

Be ambitious — propose features, refactors, tests, or research that would make
the project genuinely better. Don't hold back to be agreeable.
EOF
    fi

    # ---- Agent B instructions -----------------------------------------------
    cat > "$BRIDGE_DIR/instructions_b.md" <<EOF
# Agent B — Pair Programming

You are **Agent B** in an autonomous pair programming session with **Agent A**.
A bridge script orchestrates communication between you.

## Workflow
1. Read \`$BP/task.md\` for the original task.
2. Read \`$BP/a_to_b.md\` for Agent A's latest message.
3. Read the actual code files Agent A created/modified.
4. Review for: correctness, performance, security, edge cases, design.
5. Make direct improvements to the code using your full tools.
6. Write your critique + summary of changes to \`$BP/b_to_a.md\`:
   - Issues found (with severity)
   - Changes you made
   - Remaining concerns or suggestions
7. IMPORTANT: You MUST write \`$BP/b_to_a.md\` as the LAST thing you do
   so the bridge knows you are finished.

## Live observation
The bridge may ask you to glance at Agent A's progress mid-turn. When asked:
- Read the snapshot file (screen + file diffs). Do NOT read full code files
  unless a diff looks suspicious — keep observations lightweight.
- Be patient. Transient errors (typo, missing import, wrong path) are normal.
  Let the agent self-correct.
- Respond with one of:
  - \`STATUS: OK\` — everything looks fine, no action needed.
  - \`STATUS: NOTE\` + your observation — minor feedback to deliver later
    (will be queued and shown at the next turn boundary, NOT interrupt them).
  - \`INTERJECT:\` + urgent feedback — ONLY for serious logic errors, security
    issues, or fundamentally wrong approaches. This WILL interrupt the agent.

## Verdict (REQUIRED)
At the end of \`$BP/b_to_a.md\`, you MUST include exactly one of:
- \`VERDICT: NEEDS_WORK\` — if there are real issues that need fixing
- \`VERDICT: APPROVED\` — if the implementation is correct, secure, and complete

Only approve when the code genuinely meets the task requirements. Do NOT
rubber-stamp. But also do NOT nitpick style when the code is functionally solid.

## Common issues & learning
- If you find a common pitfall or project-specific pattern during review,
  add it to \`$AGENT_B_CONFIG\` in the project root so both agents learn from it.
- Read the file first — don't duplicate what's already noted.

## Guidelines
- Actually read and modify code files, don't just comment.
- Be constructive but thorough — catch real bugs, not style nits.
- Run tests if they exist. Write tests if they don't.
- Be **direct and critical** — don't approve just to be polite. If the code has
  real problems, say NEEDS_WORK even if Agent A put in effort. Quality matters
  more than feelings. Conversely, don't invent problems that aren't there.
EOF

    # ---- Explore mode instructions (Agent B) --------------------------------
    if [[ "$EXPLORE_MODE" == "true" ]]; then
        cat >> "$BRIDGE_DIR/instructions_b.md" <<EOF

## Proposing follow-up tasks (explore mode)
As you work, whenever you spot gaps, missing features, potential improvements,
or research needed, append a proposal to \`$BP/proposals.md\`. Do this any time
— don't wait until you're done. But stay focused on the CURRENT task first.
Read \`$BP/proposals.md\` first if it exists — don't duplicate existing proposals.
You can refine or reprioritize an existing one instead.

Format:
\`\`\`
PROPOSAL: <short title>
REASON: <why this matters — be specific about the gap or improvement>
PRIORITY: HIGH | MEDIUM | LOW
\`\`\`

After the current task reaches consensus, the bridge will ask both agents to
review proposals and agree on what to tackle next. Remove proposals from the
file as they get completed.

Be ambitious and critical — if the implementation works but the architecture is
wrong, propose a refactor. If tests are shallow, propose deeper coverage. If
there's a better algorithm, propose research. Don't settle for "good enough."
EOF
    fi

    # ---- tmux session -------------------------------------------------------
    if tmux has-session -t "$SESSION" 2>/dev/null; then
        log "Reusing existing session '$SESSION' — agents keep full context."
    else
        tmux new-session  -d -s "$SESSION" -x 220 -y 50
        tmux split-window -h -t "$SESSION"

        tmux select-pane -t "$SESSION:0.0" -T "Agent A ($SESSION)"
        tmux select-pane -t "$SESSION:0.1" -T "Agent B ($SESSION)"
        tmux set-option  -t "$SESSION" pane-border-status top
        tmux set-option  -t "$SESSION" pane-border-format " #{pane_title} "

        log "Starting Agent A ($AGENT_A_CMD) and Agent B ($AGENT_B_CMD)..."
        tmux send-keys -t "$SESSION:0.0" "$AGENT_A_CMD" Enter
        tmux send-keys -t "$SESSION:0.1" "$AGENT_B_CMD" Enter

        log "Waiting for CLIs to initialize..."
        sleep 5
    fi

    BRIDGE_OWNS_SESSION=true
    log "Setup complete. Attach with: tmux attach -t $SESSION"
}

# --- Cleanup -----------------------------------------------------------------
CLEANING_UP=false
BRIDGE_OWNS_SESSION=false   # only true after successful setup
cleanup() {
    if [[ "$CLEANING_UP" == "true" ]]; then return; fi
    CLEANING_UP=true
    echo ""
    if [[ "$BRIDGE_OWNS_SESSION" == "true" ]]; then
        tokens_report
        log "Exiting. Killing tmux session '$SESSION'..."
        rm -f "$BRIDGE_DIR/bridge.pid"
        tmux kill-session -t "$SESSION" 2>/dev/null || true
        # Kill any lingering child processes (stuck tmux send-keys, sleep, etc.)
        kill 0 2>/dev/null || true
    fi
    exit 0
}
# First Ctrl+C triggers cleanup. If cleanup hangs, second Ctrl+C
# resets to default handler and kills immediately.
trap 'trap - INT; cleanup' INT
trap 'trap - TERM; cleanup' TERM HUP
trap cleanup EXIT

# --- Clean bridge files between tasks ----------------------------------------
clean_bridge_files() {
    rm -f "$BRIDGE_DIR/a_to_b.md" "$BRIDGE_DIR/b_to_a.md"
    rm -f "$BRIDGE_DIR/stuck_"*.txt "$BRIDGE_DIR/help_for_"*.md
    rm -f "$BRIDGE_DIR/live_"*.txt "$BRIDGE_DIR/feedback_for_"*.md
    rm -f "$BRIDGE_DIR/queued_notes_for_"*.md "$BRIDGE_DIR/notes_for_"*.md
    rm -f "$BRIDGE_DIR/prev_live_"*.txt
    rm -f "$BRIDGE_DIR/file_state_"*.txt "$BRIDGE_DIR/prev_file_state_"*.txt
    # NOTE: proposals.md is NOT cleaned — it's a living document across tasks.
    # Agents remove completed proposals themselves.
}

# --- Run one task through the pair programming loop --------------------------
run_task() {
    local task_text="$1"
    local task_num="$2"

    clean_bridge_files

    # Write new task file
    cat > "$BRIDGE_DIR/task.md" <<EOF
# Task

$task_text
EOF

    local ts
    ts=$(now_epoch)

    # === Round 0: Agent A gets the task ======================================
    log_a "Sending task to Agent A..."
    if [[ "$task_num" -gt 1 ]]; then
        instruct "$SESSION:0.0" \
            "NEW TASK #$task_num (you have context from previous tasks). Read $BP/task.md for the new task. Build on prior work if relevant. Same protocol: write $BP/a_to_b.md when done."
    else
        instruct "$SESSION:0.0" \
            "Read $BP/instructions_a.md and $BP/task.md — then implement the task. When finished, write your summary to $BP/a_to_b.md."
    fi

    log_a "Working..."
    monitor_turn \
        "$BRIDGE_DIR/a_to_b.md" "$ts" \
        "$SESSION:0.0" "$SESSION:0.1" "A" "B"
    wait_for_idle "$SESSION:0.0" "Agent A"
    log_a "Round 0 complete"
    tokens_record_turn

    # === Rounds 1..N =========================================================
    for round in $(seq 1 "$MAX_ROUNDS"); do
        echo ""
        log "━━━━━━━━━━━━━━━━━ Round $round / $MAX_ROUNDS ━━━━━━━━━━━━━━━━━"

        # --- Agent B reviews Agent A's work ----------------------------------
        deliver_queued_notes "B" "$SESSION:0.1"
        ts=$(now_epoch)
        log_b "Reviewing Agent A's work..."
        instruct "$SESSION:0.1" \
            "Read $BP/instructions_b.md, $BP/task.md, and $BP/a_to_b.md. Review Agent A's code and respond. Write your review to $BP/b_to_a.md when done. Include a VERDICT."

        monitor_turn \
            "$BRIDGE_DIR/b_to_a.md" "$ts" \
            "$SESSION:0.1" "$SESSION:0.0" "B" "A"
        wait_for_idle "$SESSION:0.1" "Agent B"
        log_b "Round $round complete"
        tokens_record_turn

        # --- Check for consensus ---------------------------------------------
        if check_verdict "$BRIDGE_DIR/b_to_a.md"; then
            log "Agent B says APPROVED. Notifying Agent A for final confirmation..."

            ts=$(now_epoch)
            instruct "$SESSION:0.0" \
                "Read $BP/b_to_a.md — Agent B has approved your implementation. If you agree, write a final $BP/a_to_b.md with VERDICT: CONSENSUS and a brief summary. If you disagree, explain why."

            monitor_turn \
                "$BRIDGE_DIR/a_to_b.md" "$ts" \
                "$SESSION:0.0" "$SESSION:0.1" "A" "B"
            wait_for_idle "$SESSION:0.0" "Agent A"
            tokens_record_turn

            if check_verdict "$BRIDGE_DIR/a_to_b.md"; then
                log "Both agents reached consensus."
                break
            else
                log "Agent A disagrees. Continuing iteration..."
            fi
        fi

        # --- Agent A addresses feedback (only if not approved) ---------------
        if ! check_verdict "$BRIDGE_DIR/b_to_a.md"; then
            deliver_queued_notes "A" "$SESSION:0.0"
            ts=$(now_epoch)
            log_a "Addressing Agent B's feedback..."
            instruct "$SESSION:0.0" \
                "Read $BP/b_to_a.md for Agent B's review. Address every point, improve the code, and update $BP/a_to_b.md when done."

            monitor_turn \
                "$BRIDGE_DIR/a_to_b.md" "$ts" \
                "$SESSION:0.0" "$SESSION:0.1" "A" "B"
            wait_for_idle "$SESSION:0.0" "Agent A"
            log_a "Round $round complete"
            tokens_record_turn
        fi
    done

    # === Task summary ========================================================
    echo ""
    log "━━━━━━━━━━━━━━━━━ Task #$task_num complete ━━━━━━━━━━━━━━━━━━━"
    if check_verdict "$BRIDGE_DIR/b_to_a.md" && check_verdict "$BRIDGE_DIR/a_to_b.md"; then
        log "Result: CONSENSUS REACHED"
    elif check_verdict "$BRIDGE_DIR/b_to_a.md"; then
        log "Result: Agent B approved, Agent A did not confirm consensus"
    else
        log "Result: No consensus reached"
    fi
    log "  Agent A: $BRIDGE_DIR/a_to_b.md"
    log "  Agent B: $BRIDGE_DIR/b_to_a.md"
    if [[ -f "$AGENT_A_CONFIG" ]]; then
        log "  Learned: $AGENT_A_CONFIG (Agent A project notes)"
    fi
    if [[ "$AGENT_A_CONFIG" != "$AGENT_B_CONFIG" && -f "$AGENT_B_CONFIG" ]]; then
        log "  Learned: $AGENT_B_CONFIG (Agent B project notes)"
    fi
    tokens_report

    # === Explore mode: loop through proposals until exhausted ================
    local picker="A"  # alternate who picks: A, B, A, B...
    while [[ "$EXPLORE_MODE" == "true" \
        && -f "$BRIDGE_DIR/proposals.md" \
        && -s "$BRIDGE_DIR/proposals.md" ]]; do

        local proposal_count
        proposal_count=$(grep -c 'PROPOSAL:' "$BRIDGE_DIR/proposals.md" 2>/dev/null || echo 0)
        [[ $proposal_count -eq 0 ]] && break

        echo ""
        log "━━━━━━━━━━━━━━━━━ Explore: $proposal_count proposal(s) ━━━━━━━━━━━━━━━━━"
        cat "$BRIDGE_DIR/proposals.md"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        # Alternate who picks the next proposal
        local picker_pane reviewer_pane picker_label reviewer_label
        if [[ "$picker" == "A" ]]; then
            picker_pane="$SESSION:0.0"; reviewer_pane="$SESSION:0.1"
            picker_label="A"; reviewer_label="B"
            picker="B"  # next time B picks
        else
            picker_pane="$SESSION:0.1"; reviewer_pane="$SESSION:0.0"
            picker_label="B"; reviewer_label="A"
            picker="A"  # next time A picks
        fi

        local ts
        ts=$(now_epoch)
        log "Agent $picker_label picks the next proposal..."
        instruct "$picker_pane" \
            "Task complete. Read $BP/proposals.md — these are follow-up tasks both agents proposed. Pick the highest priority one to tackle next. Write the chosen task description to $BP/task.md (overwrite it). Remove that proposal from $BP/proposals.md. Then start implementing — same protocol, write $BP/$(lc "$picker_label")_to_$(lc "$reviewer_label").md when done. As you work, if you spot NEW gaps or improvements, add them to $BP/proposals.md (read it first to avoid duplicates)."

        (( task_num++ )) || true
        tokens_init

        # Wait for the picker to write the new task.md
        if ! wait_for_file_simple "$BRIDGE_DIR/task.md" "$ts" 120 \
            "$picker_pane" "$picker_label" "$reviewer_pane" "$reviewer_label"; then
            log "Agent $picker_label didn't select a proposal in time — returning to REPL"
            break
        fi

        log "Agent $picker_label selected a proposal — starting task #$task_num"
        # Clean handoff files but keep proposals.md (living document)
        rm -f "$BRIDGE_DIR/a_to_b.md" "$BRIDGE_DIR/b_to_a.md"
        rm -f "$BRIDGE_DIR/feedback_for_"*.md "$BRIDGE_DIR/queued_notes_for_"*.md
        rm -f "$BRIDGE_DIR/file_state_"*.txt "$BRIDGE_DIR/prev_file_state_"*.txt

        local picker_output="$BRIDGE_DIR/$(lc "$picker_label")_to_$(lc "$reviewer_label").md"
        local reviewer_output="$BRIDGE_DIR/$(lc "$reviewer_label")_to_$(lc "$picker_label").md"

        # Monitor the picker's implementation turn
        monitor_turn \
            "$picker_output" "$ts" \
            "$picker_pane" "$reviewer_pane" "$picker_label" "$reviewer_label"
        wait_for_idle "$picker_pane" "Agent $picker_label"
        log "Agent $picker_label: Round 0 complete (from proposal)"
        tokens_record_turn

        # Review rounds — reviewer critiques, picker addresses
        local consensus_reached=false
        for round in $(seq 1 "$MAX_ROUNDS"); do
            echo ""
            log "━━━━━━━━━━━━━━━━━ Round $round / $MAX_ROUNDS ━━━━━━━━━━━━━━━━━"

            deliver_queued_notes "$reviewer_label" "$reviewer_pane"
            ts=$(now_epoch)
            log "Agent $reviewer_label: Reviewing..."
            instruct "$reviewer_pane" \
                "Read $BP/instructions_$(lc "$reviewer_label").md, $BP/task.md, and $BP/$(basename "$picker_output"). Review the code and respond. Write your review to $BP/$(basename "$reviewer_output") when done. Include a VERDICT. If you spot NEW gaps or improvements during review, add them to $BP/proposals.md (read it first to avoid duplicates)."

            monitor_turn \
                "$reviewer_output" "$ts" \
                "$reviewer_pane" "$picker_pane" "$reviewer_label" "$picker_label"
            wait_for_idle "$reviewer_pane" "Agent $reviewer_label"
            log "Agent $reviewer_label: Round $round complete"
            tokens_record_turn

            if check_verdict "$reviewer_output"; then
                log "Agent $reviewer_label says APPROVED. Notifying Agent $picker_label..."
                ts=$(now_epoch)
                instruct "$picker_pane" \
                    "Read $BP/$(basename "$reviewer_output") — Agent $reviewer_label approved. If you agree, write $BP/$(basename "$picker_output") with VERDICT: CONSENSUS. If not, explain why."
                monitor_turn \
                    "$picker_output" "$ts" \
                    "$picker_pane" "$reviewer_pane" "$picker_label" "$reviewer_label"
                wait_for_idle "$picker_pane" "Agent $picker_label"
                tokens_record_turn
                if check_verdict "$picker_output"; then
                    log "Consensus on proposal task."
                    consensus_reached=true
                    break
                fi
            fi

            if ! check_verdict "$reviewer_output"; then
                deliver_queued_notes "$picker_label" "$picker_pane"
                ts=$(now_epoch)
                log "Agent $picker_label: Addressing feedback..."
                instruct "$picker_pane" \
                    "Read $BP/$(basename "$reviewer_output") for Agent $reviewer_label's review. Address every point, improve the code, and update $BP/$(basename "$picker_output") when done."
                monitor_turn \
                    "$picker_output" "$ts" \
                    "$picker_pane" "$reviewer_pane" "$picker_label" "$reviewer_label"
                wait_for_idle "$picker_pane" "Agent $picker_label"
                tokens_record_turn
            fi
        done

        echo ""
        log "━━━━━━━━━━━━━━━━━ Proposal task #$task_num complete ━━━━━━━━━━━━━━"
        tokens_report

        if [[ "$consensus_reached" != "true" ]]; then
            log "No consensus on proposal — returning to REPL"
            break
        fi
    done
}

# --- Interactive REPL --------------------------------------------------------
main() {
    setup
    tokens_init

    local task_number=1

    # Run the initial task from CLI args
    run_task "$TASK" "$task_number"

    # Prompt for follow-up tasks
    echo ""
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "Session '$SESSION' alive. Agents have full context."
    log "Enter a follow-up task, or 'exit' / Ctrl+C to quit."
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    while true; do
        echo ""
        echo -ne "${C_BRIDGE}[$SESSION] ▸${C_RESET} "
        local next_task
        if ! read -r next_task; then
            # EOF (Ctrl+D)
            break
        fi

        # Trim whitespace and handle exit commands
        next_task=$(echo "$next_task" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$(lc "$next_task")" in
            exit|quit|q|bye)
                break
                ;;
            "")
                continue
                ;;
        esac

        (( task_number++ )) || true
        tokens_init  # reset token counters per task
        run_task "$next_task" "$task_number"

        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "Session '$SESSION' alive. Enter next task, or 'exit' to quit."
    done
}

main
