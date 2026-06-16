#!/bin/bash
# claude-code-notification-hook — a Claude Code notification hook for macOS.

# Config: defaults below; override in ~/.config/claude-notify.conf
CONFIG="${CLAUDE_NOTIFY_CONFIG:-$HOME/.config/claude-notify.conf}"
[ -f "$CONFIG" ] && . "$CONFIG"
context_aware="${context_aware:-false}"
summarize_model="${summarize_model:-claude-haiku-4-5-20251001}"
icon="${icon:-}"                          # empty -> alerter's default app icon
action_app="${action_app:-}"              # empty -> clicking does nothing
alerter_timeout="${alerter_timeout:-}"    # empty -> notification persists until clicked
debug="${debug:-false}"

echo $context_aware

# Recursion guard
[ -n "$NOTIFY_HOOK_GUARD" ] && exit 0

# Arguments. Two styles, both supported:
#   named:      --title T --message M --sound S --context true   (flags may be omitted/reordered)
#   positional: T M S CONTEXT                                    (legacy; title message sound context)
# Named style is used if any argument starts with "--"; otherwise positional.
title="" message="" sound="" context_arg=""
if printf '%s\n' "$@" | grep -q '^--'; then
  while [ $# -gt 0 ]; do
    case "$1" in
      --title)                       title="$2";       shift 2 ;;
      --message)                     message="$2";     shift 2 ;;
      --sound)                       sound="$2";       shift 2 ;;
      --context|--context-aware|--context_aware)   context_arg="$2"; shift 2 ;;
      --title=*)                     title="${1#*=}";       shift ;;
      --message=*)                   message="${1#*=}";     shift ;;
      --sound=*)                     sound="${1#*=}";       shift ;;
      --context=*|--context-aware=*|--context_aware=*)   context_arg="${1#*=}"; shift ;;
      *)                             shift ;;
    esac
  done
else
  title="$1"; message="$2"; sound="$3"; context_arg="$4"
fi

title="${title:-Claude Code}"
sound="${sound:-Glass}"
# --context / 4th positional overrides the context_aware config value when non-empty.
# Accepts true/1/yes/on (case-insensitive) for enabled, anything else for disabled.
if [ -n "$context_arg" ]; then
  case "$(printf '%s' "$context_arg" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) context_aware=true ;;
    *) context_aware=false ;;
  esac
fi

# Pull the plain text out of a JSON transcript line (stdin -> stdout).
# Handles a string content (user prompts) and an array of blocks (assistant).
extract_text() {
  python3 -c '
import sys, json
try:
    c = json.loads(sys.stdin.read()).get("message", {}).get("content")
except Exception:
    sys.exit(0)
if isinstance(c, str):
    print(c)
elif isinstance(c, list):
    print("\n".join(b.get("text", "") for b in c
        if isinstance(b, dict) and b.get("type") == "text"))
'
}

# Context-aware summary
if [ "$context_aware" = true ]; then
  last=""
  request=""

  # Only Stop/StopFailure summarize; other events keep the static message.
  case "$NOTIFY_PAYLOAD" in
  *'"hook_event_name":"Stop'*)   # matches both Stop and StopFailure
    tp=$(printf '%s' "$NOTIFY_PAYLOAD" \
         | grep -o '"transcript_path":"[^"]*"' | head -1 | sed 's/.*:"//; s/"$//')
    if [ -n "$tp" ] && [ -f "$tp" ]; then
      # Last spoken assistant reply, and last real user prompt (skip tool_result).
      last=$(grep '"type":"assistant"' "$tp" | grep '"type":"text"' | tail -1 | extract_text)
      request=$(grep '"type":"user"' "$tp" | grep -v 'tool_result' | tail -1 | extract_text)
    fi
    ;;
  esac

  # Summarize context.
  if [ -n "$last" ]; then
    tmo=""
    command -v timeout  >/dev/null 2>&1 && tmo="timeout 20"
    command -v gtimeout >/dev/null 2>&1 && tmo="gtimeout 20"
    summary=$(printf 'USER REQUEST:\n%s\n\nASSISTANT REPLY:\n%s' "$request" "$last" \
      | NOTIFY_HOOK_GUARD=1 $tmo claude \
        --strict-mcp-config -p \
        "Below are a user's request and the assistant's reply. Summarize the PRIMARY thing the assistant accomplished in response to the request. Report the main change or outcome, NOT trailing steps like syntax checks, verification, or cleanup. Phone notification format: max 8 words, imperative mood, plain text, no markdown, no quotes." \
        --model "$summarize_model" 2>/dev/null | head -c 140)
    [ -n "$summary" ] && message="$summary"
  fi
fi

# Notify
args=(--title "$title" --message "$message" --sound "$sound")
[ -n "$icon" ] && args+=(--app-icon "$icon")
[ -n "$alerter_timeout" ] && args+=(--timeout "$alerter_timeout")
alerter "${args[@]}" | grep -q "CONTENTCLICKED" && [ -n "$action_app" ] && open -a "$action_app"
