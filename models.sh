#!/bin/bash
# models.sh — inspect the Hugging Face GGUF cache, and launch what is in it.
#
# Usage:
#   models.sh list      One row per cached quant, as pasteable -hf ids.
#   models.sh launch    Pick a cached model and start it as a server or a TUI.
#
# Server launches are handed to serve.sh, which owns the cache check, the
# foreground download and the background PID/log report.

CACHE="$HOME/.cache/huggingface/hub"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Cache enumeration ────────────────────────────────────────────────────────
# Populates: ROWS[]       "bytes<TAB>display<TAB>launch_id"  (launch_id empty
#                         for mmproj sidecars and unrecognised filenames)
#            INCOMPLETE[] "size<TAB>id"
#            TOTAL, REPO_COUNT
scan_cache() {
    ROWS=()
    INCOMPLETE=()
    TOTAL=0
    REPO_COUNT=0

    shopt -s nullglob nocasematch

    local repo base id files f name stem b
    for repo in "$CACHE"/models--*; do
        [ -d "$repo" ] || continue
        # models--unsloth--Qwen3.8-27B-GGUF -> unsloth/Qwen3.8-27B-GGUF
        base=${repo##*/}
        id=${base#models--}
        id=${id//--//}

        # A repo with no .gguf under snapshots/ is an abandoned download.
        files=("$repo"/snapshots/*/*.gguf)
        if [ ${#files[@]} -eq 0 ]; then
            INCOMPLETE+=("$(du -sh "$repo" 2>/dev/null | cut -f1)	$id")
            continue
        fi

        # Sum multi-part files (-00001-of-00003) into a single entry per stem.
        declare -A part_bytes=()
        for f in "${files[@]}"; do
            [ -e "$f" ] || continue          # skip broken symlinks
            name=${f##*/}
            stem=${name%.gguf}
            stem=$(sed -E 's/-[0-9]{5}-of-[0-9]{5}$//' <<<"$stem")
            b=$(du -sbL "$f" 2>/dev/null | cut -f1)
            [ -n "$b" ] || continue
            part_bytes["$stem"]=$(( ${part_bytes["$stem"]:-0} + b ))
        done
        [ ${#part_bytes[@]} -eq 0 ] && continue

        REPO_COUNT=$((REPO_COUNT + 1))
        for stem in "${!part_bytes[@]}"; do
            b=${part_bytes["$stem"]}
            TOTAL=$((TOTAL + b))
            if [[ $stem == mmproj* ]]; then
                ROWS+=("$b	$id  [mmproj]	")
            elif [[ $stem =~ -((IQ|Q)[0-9]+[A-Za-z0-9_]*|BF16|F16|F32|MXFP4)$ ]]; then
                ROWS+=("$b	${id}:${BASH_REMATCH[1]^^}	${id}:${BASH_REMATCH[1]^^}")
            else
                # No recognisable quant token: the bare repo id is still a
                # valid -hf argument, so it stays launchable.
                ROWS+=("$b	$id  ($stem.gguf)	$id")
            fi
        done
        unset part_bytes
    done
}

# ── list ─────────────────────────────────────────────────────────────────────
cmd_list() {
    echo "📂 $CACHE"
    echo "---------------------------------------------------"
    [ -d "$CACHE" ] || { echo "Cache dir not found."; exit 0; }

    scan_cache

    if [ ${#ROWS[@]} -gt 0 ]; then
        printf '%s\n' "${ROWS[@]}" | sort -rn | while IFS=$'\t' read -r b l _; do
            printf '%8s  %s\n' "$(numfmt --to=iec <<<"$b")" "$l"
        done
    else
        echo "  No usable models cached."
    fi

    echo "---------------------------------------------------"
    printf '  total %s in %d repo(s)\n' "$(numfmt --to=iec <<<"$TOTAL")" "$REPO_COUNT"

    if [ ${#INCOMPLETE[@]} -gt 0 ]; then
        echo
        echo "  ⚠ incomplete downloads (not usable, delete via 'Remove Model'):"
        printf '%s\n' "${INCOMPLETE[@]}" | while IFS=$'\t' read -r sz id; do
            printf '%8s  %s\n' "$sz" "$id"
        done
    fi
}

# ── launch ───────────────────────────────────────────────────────────────────
cmd_launch() {
    [ -d "$CACHE" ] || { echo "Cache dir not found."; exit 0; }
    scan_cache

    # Menu of launchable ids, largest first.
    local menu=() ids=() line b label lid
    while IFS=$'\t' read -r b label lid; do
        [ -n "$lid" ] || continue
        menu+=("$lid  ($(numfmt --to=iec <<<"$b"))")
        ids+=("$lid")
    done < <(printf '%s\n' "${ROWS[@]}" | sort -rn)

    local TYPE_ENTRY="[ type a repo id ]" CANCEL_ENTRY="[ cancel ]"
    local MODEL=""

    echo "🚀 Launch a model"
    echo "---------------------------------------------------"
    [ ${#ids[@]} -eq 0 ] && echo "  (no cached models — use '$TYPE_ENTRY')"

    PS3="#? "
    select choice in "${menu[@]}" "$TYPE_ENTRY" "$CANCEL_ENTRY"; do
        case "$choice" in
            "$CANCEL_ENTRY") echo "❌ Cancelled."; exit 0 ;;
            "$TYPE_ENTRY")
                while :; do
                    read -e -p "Hugging Face repo id (e.g. ggml-org/Qwen3-0.6B-GGUF:Q8_0): " MODEL
                    [ -z "$MODEL" ] && { echo "❌ Cancelled."; exit 0; }
                    [[ $MODEL == */* ]] && break
                    echo "⚠️  Needs the form <user>/<model>[:quant]."
                done
                break ;;
            "") echo "Invalid selection." ;;
            *)  MODEL="${ids[$((REPLY - 1))]}"; break ;;
        esac
    done
    [ -z "$MODEL" ] && { echo "❌ Cancelled."; exit 0; }

    echo
    echo "Model: $MODEL"
    local MODE=""
    select MODE in "Server (WebUI, background)" "TUI (llama-cli, foreground)"; do
        [ -n "$MODE" ] && break
        echo "Invalid selection."
    done
    [ -z "$MODE" ] && { echo "❌ Cancelled."; exit 0; }

    if [[ $MODE == TUI* ]]; then
        echo
        echo "▶️  llama-cli -hf $MODEL -c 0"
        set -m
        cd "$HOME/llama.cpp" || { echo "❌ Not found: $HOME/llama.cpp"; exit 1; }
        ./llama-cli -hf "$MODEL" -c 0 &
        fg
        stty sane
        exit 0
    fi

    local HOST=""
    select HOST in "127.0.0.1" "0.0.0.0"; do
        [ -n "$HOST" ] && break
        echo "Invalid selection."
    done
    [ -z "$HOST" ] && { echo "❌ Cancelled."; exit 0; }

    echo
    exec "$SCRIPT_DIR/serve.sh" "$MODEL" --jinja -c 0 --host "$HOST" --port 8033
}

case "${1:-list}" in
    list)   cmd_list ;;
    launch) cmd_launch ;;
    *)      echo "Usage: models.sh [list|launch]"; exit 1 ;;
esac
