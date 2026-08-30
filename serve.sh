#!/bin/bash
# serve.sh — launch one llama.cpp WebUI server from a Hugging Face GGUF repo.
#
# Usage: serve.sh <hf-repo-id> [llama-server flags...]
#   serve.sh ggml-org/gemma-4-E2B-it-GGUF --jinja -c 0 --host 127.0.0.1 --port 8033
#
# Downloads in the FOREGROUND when the model is not cached, so progress is
# visible. Otherwise launches in the BACKGROUND and reports PID, URL and log.

set -u

LLAMA_DIR="$HOME/llama.cpp"
LOG="$LLAMA_DIR/server.log"
# Same override models.sh honours, so both scripts read the same cache.
CACHE="${HF_HUB_CACHE:-$HOME/.cache/huggingface/hub}"

MODEL="${1:-}"
[ -z "$MODEL" ] && { echo "Usage: serve.sh <hf-repo-id> [llama-server flags...]"; exit 1; }
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

# Do we already have the exact file this command needs? Only a tagged id makes
# that answerable: with a bare repo id llama.cpp picks the repo's own default
# quant, and we cannot know which one that is without asking Hugging Face. So an
# untagged id is always treated as a download.
#
# Match the '-<QUANT>.gguf' suffix, not a substring, or ':Q4_0' would be
# satisfied by a cached '…-Q4_0_XL.gguf'. Sidecars are excluded: a cached mmproj
# is not a cached model.
CACHED=""
if [ -n "$QUANT" ]; then
    CACHED=$(find "$CACHE/" -maxdepth 1 -type d -name "$CACHE_GLOB" \
        -exec find {} -path '*/snapshots/*' -not -name 'mmproj*' \
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
    cd "$LLAMA_DIR" && exec ./llama-server -hf "$MODEL" "$@"
fi

cd "$LLAMA_DIR" || exit 1
./llama-server -hf "$MODEL" "$@" > "$LOG" 2>&1 &
PID=$!

# A live process proves nothing — it may still be loading. Wait for the port to
# actually answer, and only then claim the server is up. 0.0.0.0 is a bind
# address, not a destination, so probe loopback.
PROBE_HOST=$HOST
[ "$PROBE_HOST" = "0.0.0.0" ] && PROBE_HOST=127.0.0.1

# A big model on CPU can take well over a minute to load, so wait minutes, not
# seconds — with a heartbeat, so a slow load does not look like a hung cell.
WAIT=180
echo "⏳ Starting server (PID $PID)... waiting up to ${WAIT}s for http://$HOST:$PORT"
UP=""
for i in $(seq 1 "$WAIT"); do
    ps -p "$PID" > /dev/null || break
    if (exec 3<>"/dev/tcp/$PROBE_HOST/$PORT") 2>/dev/null; then UP=1; break; fi
    [ $((i % 15)) -eq 0 ] && echo "   ...still loading (${i}s)"
    sleep 1
done

if [ -n "$UP" ]; then
    echo "✅ SUCCESS: Serving on http://$HOST:$PORT"
    echo "   - PID: $PID"
    echo "   - Logs: $LOG"
    echo "💡 Monitor usage with 'btop'. Stop via 'Stop All Services'."
elif ps -p "$PID" > /dev/null; then
    echo "⏳ Still starting (PID $PID) — not listening yet after ${WAIT}s."
    echo "   The model is most likely still loading."
    echo "   - Logs: $LOG"
    echo "💡 Watch it with 'Follow Server Log' (Column A)."
else
    echo "❌ FAILURE: Server process died."
    echo "🔍 Last 10 lines of $LOG:"
    tail -n 10 "$LOG"
fi
