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

MODEL="${1:-}"
[ -z "$MODEL" ] && { echo "Usage: serve.sh <hf-repo-id> [llama-server flags...]"; exit 1; }
shift

[ -x "$LLAMA_DIR/llama-server" ] || {
    echo "❌ Not found: $LLAMA_DIR/llama-server"
    echo "💡 Run '🔍 Inspect Folder Setup' in Column A."
    exit 1
}

# Cache dir derived from the repo basename, with any :quant suffix stripped —
# -hf takes <user>/<model>[:quant], but the cache dir is named per repo:
#   ggml-org/gpt-oss-20b-GGUF:Q8_0 -> models--*gpt-oss-20b-GGUF
# We look for an actual .gguf under snapshots/, not just the directory: a repo
# holding only .downloadInProgress blobs is an abandoned download, not a model.
REPO=${MODEL%%:*}
CACHE_GLOB="models--*${REPO##*/}"

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

if ! find "$HOME/.cache/huggingface/hub/" -maxdepth 1 -type d -name "$CACHE_GLOB" \
     -exec find {} -path '*/snapshots/*' -name '*.gguf' -print -quit \; 2>/dev/null | grep -q .; then
    echo "⚠️  Model not found. Downloading and running in FOREGROUND..."
    cd "$LLAMA_DIR" && exec ./llama-server -hf "$MODEL" "$@"
fi

cd "$LLAMA_DIR" || exit 1
./llama-server -hf "$MODEL" "$@" > "$LOG" 2>&1 &
PID=$!
echo "⏳ Starting server (PID $PID)... waiting 3s..."
sleep 3
if ps -p "$PID" > /dev/null; then
    echo "✅ SUCCESS: Server process started (Background)"
    echo "   - PID: $PID"
    echo "   - WebUI: http://$HOST:$PORT"
    echo "   - Logs: $LOG"
    echo "💡 Monitor usage with 'btop'. Stop via 'Stop All Services'."
else
    echo "❌ FAILURE: Server process died."
    echo "🔍 Last 10 lines of $LOG:"
    tail -n 10 "$LOG"
fi
