#!/bin/bash
# serve.sh — launch one llama.cpp WebUI server from a Hugging Face GGUF repo.
#
# Usage: serve.sh [--fg] <hf-repo-id> [llama-server flags...]
#   serve.sh ggml-org/gemma-4-E2B-it-GGUF --jinja -c 0 --host 127.0.0.1 --port 8033
#
# Three launch shapes:
#   BACKGROUND  the default for a cached model — reports PID, URL and log.
#   FOREGROUND  --fg, when you want to watch the load happen.
#   FOREGROUND  also when the model is not cached, so the download stays visible.

set -u

LLAMA_DIR="$HOME/llama.cpp"
LOG="$LLAMA_DIR/server.log"
# Same override models.sh honours, so both scripts read the same cache.
CACHE="${HF_HUB_CACHE:-$HOME/.cache/huggingface/hub}"

FG=""
[ "${1:-}" = "--fg" ] && { FG=1; shift; }

MODEL="${1:-}"
[ -z "$MODEL" ] && { echo "Usage: serve.sh [--fg] <hf-repo-id> [llama-server flags...]"; exit 1; }
shift

[ -x "$LLAMA_DIR/llama-server" ] || {
    echo "❌ Not found: $LLAMA_DIR/llama-server"
    echo "💡 Run '🔍 Inspect Folder Setup' in Column A."
    exit 1
}

# -hf takes <user>/<model>[:quant]; the cache dir is named per repo:
#   ggml-org/gpt-oss-20b-GGUF:Q8_0 -> models--*gpt-oss-20b-GGUF
REPO=${MODEL%%:*}
CACHE_GLOB="models--*${REPO##*/}"
QUANT=""
[[ $MODEL == *:* ]] && QUANT=${MODEL#*:}

# Read --host/--port back out of the passthrough flags, for the URL echo only.
HOST=127.0.0.1
PORT=8033
prev=""
for arg in "$@"; do
    case "$prev" in
        --host) HOST="$arg" ;;
        --port) PORT="$arg" ;;
    esac
    prev="$arg"
done

# 0.0.0.0 is a bind address, not a destination, so probe loopback.
PROBE_HOST=$HOST
[ "$PROBE_HOST" = "0.0.0.0" ] && PROBE_HOST=127.0.0.1

# A second server cannot have the port, and the one that loses it dies seconds
# after this script would have called it up — the old server answers every probe
# on its behalf. So refuse before launching, and say who holds it. Nothing here
# kills anything: that is what 'Stop All Servers' is for.
HOLDER=""
if command -v ss > /dev/null; then
    HOLDER=$(ss -ltnpH "sport = :$PORT" 2>/dev/null)
elif (exec 3<>"/dev/tcp/$PROBE_HOST/$PORT") 2>/dev/null; then
    HOLDER="something is listening on $PORT (install 'ss' to see what)"
fi
if [ -n "$HOLDER" ]; then
    echo "❌ Port $PORT is already in use:"
    # ss prints one row per address family, so indent every line, not just one.
    printf '%s\n' "$HOLDER" | sed 's/^/   /'
    echo "💡 '📊 Server Status' (Column A) says what it is."
    echo "   'Stop All Servers' (Column A) frees the port."
    exit 1
fi

# The foreground shapes, in one place. 'set -m … & fg … stty sane' is the deck's
# TUI idiom: a cell runs under 'bash -lc', which has job control off, so the
# server needs its own process group for Ctrl-C to reach it — and the terminal
# needs repairing once it exits. tee keeps 'View / Follow Server Log' useful for
# a foreground run; it truncates the log exactly as a background launch does.
run_foreground() {
    # Echo the expanded command: job control prints the job's source text, so
    # without this the only line shown still reads '-hf "$MODEL"'.
    echo "▶️  llama-server -hf $MODEL $*"
    echo "   Foreground — Ctrl-C stops the server. Output also goes to $LOG."
    cd "$LLAMA_DIR" || exit 1
    set -m
    ./llama-server -hf "$MODEL" "$@" 2>&1 | tee "$LOG" &
    fg
    stty sane 2>/dev/null   # no-op when there is no terminal to repair
    exit 0
}

# Do we already have the exact file this command needs? Only a tagged id makes
# that answerable: with a bare repo id llama.cpp picks the repo's own default
# quant, and we cannot know which one that is without asking Hugging Face. So an
# untagged id is always treated as a download.
#
# Match the '-<QUANT>.gguf' suffix, not a substring, or ':Q4_0' would be
# satisfied by a cached '…-Q4_0_XL.gguf'. Sidecars are excluded: a cached mmproj
# is not a cached model — and 'mmproj' has to be matched anywhere in the name,
# since a projector shipped as '<model>-mmproj-Q8_0.gguf' otherwise satisfies
# the ':Q8_0' match itself, and the model's real download then runs invisibly in
# the background.
CACHED=""
if [ -n "$QUANT" ]; then
    CACHED=$(find "$CACHE/" -maxdepth 1 -type d -name "$CACHE_GLOB" \
        -exec find {} -path '*/snapshots/*' -not -iname '*mmproj*' \
             \( -iname "*-${QUANT}.gguf" \
                -o -iname "*-${QUANT}-[0-9][0-9][0-9][0-9][0-9]-of-[0-9][0-9][0-9][0-9][0-9].gguf" \) \
             -print -quit \; 2>/dev/null)
fi

if [ -z "$CACHED" ]; then
    if [ -n "$QUANT" ]; then
        echo "⚠️  $MODEL is not cached. Downloading and running in FOREGROUND..."
    else
        echo "⚠️  No :QUANT given, so the quant llama.cpp picks is unknown here."
        echo "    Running in FOREGROUND so any download stays visible."
    fi
    run_foreground "$@"
fi

[ -n "$FG" ] && run_foreground "$@"

cd "$LLAMA_DIR" || exit 1
./llama-server -hf "$MODEL" "$@" > "$LOG" 2>&1 &
PID=$!

# An open port proves nothing: llama-server binds and starts answering BEFORE it
# reads the weights, replying 503 'Loading model' to /health meanwhile. A plain
# TCP probe therefore succeeds about a second in — long before a load can fail
# on a bad flag, on VRAM, or on a quant that does not fit — and success would be
# claimed for a server that is about to die. Ask /health instead: with -f, curl
# fails on the 503, so only a 200 counts as loaded.
CURL=""
command -v curl > /dev/null && CURL=1
[ -z "$CURL" ] && echo "⚠️  No curl — falling back to a port probe, which reports 'up' while still loading."

ready() {
    if [ -n "$CURL" ]; then
        curl -fsS -m 2 "http://$PROBE_HOST:$PORT/health" > /dev/null 2>&1
    else
        (exec 3<>"/dev/tcp/$PROBE_HOST/$PORT") 2>/dev/null
    fi
}

# A big model on CPU can take well over a minute to load, so wait minutes, not
# seconds — with a heartbeat, so a slow load does not look like a hung cell.
WAIT=180
echo "⏳ Starting server (PID $PID)... waiting up to ${WAIT}s for http://$HOST:$PORT"
UP=""
for i in $(seq 1 "$WAIT"); do
    ps -p "$PID" > /dev/null || break
    if ready; then UP=1; break; fi
    [ $((i % 15)) -eq 0 ] && echo "   ...still loading (${i}s)"
    sleep 1
done

# /health can turn 200 on the last stretch of a load that still aborts. Give it
# a moment and make sure the process we started is the one still there.
if [ -n "$UP" ]; then
    sleep 2
    ps -p "$PID" > /dev/null || UP=""
fi

if [ -n "$UP" ]; then
    echo "✅ SUCCESS: Serving on http://$HOST:$PORT"
    echo "   - PID: $PID"
    echo "   - Logs: $LOG"
    echo "💡 Monitor usage with 'btop'. Stop via 'Stop All Servers' (Column A)."
elif ps -p "$PID" > /dev/null; then
    echo "⏳ Still starting (PID $PID) — not ready yet after ${WAIT}s."
    echo "   The model is most likely still loading."
    echo "   - Logs: $LOG"
    echo "💡 Watch it with 'Follow Server Log' (Column A)."
else
    echo "❌ FAILURE: Server process died."
    # 20, not 10: a rejected flag prints its whole usage block after the error,
    # which pushes the line you need out of a short tail.
    echo "🔍 Last 20 lines of $LOG:"
    tail -n 20 "$LOG"
fi
