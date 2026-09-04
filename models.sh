#!/bin/bash
# models.sh — inspect the Hugging Face GGUF cache, and launch what is in it.
#
# Usage:
#   models.sh list      One row per cached quant, as pasteable -hf ids.
#   models.sh launch    Pick a cached model and start it as a background server,
#                       a foreground server, or a TUI.
#   models.sh remove    Delete one cached quant, or one abandoned download.
#
# Server launches are handed to serve.sh, which owns the cache check, the
# foreground download and the background PID/log report.

# HF_HUB_CACHE is Hugging Face's own override. Honouring it is what lets the
# destructive 'remove' path be tested against a fixture cache.
CACHE="${HF_HUB_CACHE:-$HOME/.cache/huggingface/hub}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Cache enumeration ────────────────────────────────────────────────────────
# Populates: ROWS[]       "bytes<TAB>display<TAB>repo_dir<TAB>stem<TAB>launch_id"
#                         (repo_dir + stem are what 'remove' deletes; launch_id
#                         is empty for mmproj sidecars, so it goes LAST — TAB is
#                         IFS whitespace, and an empty field in the middle would
#                         collapse and shift every later field left)
#            INCOMPLETE[] "size<TAB>id<TAB>repo_dir"
#            TOTAL, REPO_COUNT
#
# Readers must absorb the trailing fields (read -r a b c _), or the last
# variable silently swallows the rest of the line.
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
            INCOMPLETE+=("$(du -sh "$repo" 2>/dev/null | cut -f1)	$id	$repo")
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
                ROWS+=("$b	$id  [mmproj]	$repo	$stem	")
            elif [[ $stem =~ -((IQ|Q)[0-9]+[A-Za-z0-9_]*|BF16|F16|F32|MXFP4)$ ]]; then
                ROWS+=("$b	${id}:${BASH_REMATCH[1]^^}	$repo	$stem	${id}:${BASH_REMATCH[1]^^}")
            else
                # No recognisable quant token: the bare repo id is still a
                # valid -hf argument, so it stays launchable.
                ROWS+=("$b	$id  ($stem.gguf)	$repo	$stem	$id")
            fi
        done
        unset part_bytes
    done
}

# ── Deletion ─────────────────────────────────────────────────────────────────
# Delete one quant: every snapshot symlink carrying this stem, then the blobs
# they pointed at. Blobs live inside the repo and are content-addressed, so two
# different quants can never share one — once a stem's links are gone, its blobs
# are referenced by nothing. Read each link before unlinking it.
delete_stem() {
    local repo=$1 stem=$2 f left
    local blobs=()

    for f in "$repo"/snapshots/*/"$stem".gguf \
             "$repo"/snapshots/*/"$stem"-[0-9][0-9][0-9][0-9][0-9]-of-[0-9][0-9][0-9][0-9][0-9].gguf; do
        blobs+=("$(readlink -f "$f")")
        rm -f "$f"
    done
    [ ${#blobs[@]} -gt 0 ] && rm -f "${blobs[@]}"

    # That was the repo's last quant — nothing left but metadata.
    left=("$repo"/snapshots/*/*.gguf)
    [ ${#left[@]} -eq 0 ] && rm -rf "$repo"
    return 0
}

# ── remove ───────────────────────────────────────────────────────────────────
cmd_remove() {
    [ -d "$CACHE" ] || { echo "Cache dir not found."; exit 0; }
    scan_cache

    # One menu of deletable things. An empty stem means "the whole repo", which
    # is what an abandoned download is.
    local menu=() labels=() repos=() stems=() sizes=()
    local b label repo stem sz id line
    while IFS=$'\t' read -r b label repo stem _; do
        [ -n "$repo" ] || continue
        sz=$(numfmt --to=iec <<<"$b")
        menu+=("$(printf '%8s  %s' "$sz" "$label")")
        labels+=("$label"); repos+=("$repo"); stems+=("$stem"); sizes+=("$sz")
    done < <(printf '%s\n' "${ROWS[@]}" | sort -rn)

    for line in "${INCOMPLETE[@]}"; do
        IFS=$'\t' read -r sz id repo <<<"$line"
        menu+=("$(printf '%8s  [incomplete] %s' "$sz" "$id")")
        labels+=("$id (incomplete download)"); repos+=("$repo"); stems+=(""); sizes+=("$sz")
    done

    if [ ${#menu[@]} -eq 0 ]; then
        echo "No models found."
        exit 0
    fi

    echo "🗑️  Select what to DELETE:"
    echo "---------------------------------------------------"
    local CANCEL_ENTRY="[ cancel ]" choice i="" answer
    PS3="#? "
    select choice in "${menu[@]}" "$CANCEL_ENTRY"; do
        case "$choice" in
            "$CANCEL_ENTRY") echo "❌ Cancelled."; exit 0 ;;
            "") echo "Invalid selection." ;;
            *)  i=$((REPLY - 1)); break ;;
        esac
    done
    # select also ends on EOF (Ctrl-D) with nothing chosen — never fall through
    # to a confirm prompt for whatever happens to sit at index 0.
    [ -n "$i" ] || { echo "❌ Cancelled."; exit 0; }

    echo
    echo "⚠️  Delete '${labels[$i]}' (${sizes[$i]})?  (y/n)"
    read -r answer
    case "$answer" in
        [Yy]*) ;;
        *) echo "❌ Cancelled."; exit 0 ;;
    esac

    # Never rm -rf anything that is not a repo directory inside the cache.
    case "${repos[$i]}" in
        "$CACHE"/models--*) ;;
        *) echo "❌ Refusing to delete '${repos[$i]}' — not a repo under $CACHE."; exit 1 ;;
    esac

    if [ -n "${stems[$i]}" ]; then
        delete_stem "${repos[$i]}" "${stems[$i]}"
    else
        rm -rf "${repos[$i]}"
    fi
    echo "✅ Deleted. Reclaimed ${sizes[$i]}."
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
        printf '%s\n' "${INCOMPLETE[@]}" | while IFS=$'\t' read -r sz id _; do
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
    while IFS=$'\t' read -r b label _ _ lid; do
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
    echo
    echo "How should it run?"
    # 'foreground' appears in two of the three labels, so the branches below
    # match a label whole — never a substring.
    local BG_ENTRY="Server — WebUI, background" \
          FG_ENTRY="Server — WebUI, foreground (watch the load, Ctrl-C stops it)" \
          TUI_ENTRY="TUI (llama-cli, foreground)"
    local MODE=""
    select MODE in "$BG_ENTRY" "$FG_ENTRY" "$TUI_ENTRY"; do
        [ -n "$MODE" ] && break
        echo "Invalid selection."
    done
    [ -z "$MODE" ] && { echo "❌ Cancelled."; exit 0; }

    # MTP (multi-token prediction): speculative decoding off the model's own
    # heads, no draft model involved. Needs llama.cpp b9200+ and a model that
    # carries MTP weights — the flag is passed through as asked, unchecked.
    local MTP=() MTP_CHOICE=""
    echo
    echo "Enable MTP (multi-token prediction)?"
    select MTP_CHOICE in "No" "Yes — --spec-type draft-mtp --spec-draft-n-max 2"; do
        [ -n "$MTP_CHOICE" ] && break
        echo "Invalid selection."
    done
    [[ $MTP_CHOICE == Yes* ]] && MTP=(--spec-type draft-mtp --spec-draft-n-max 2)

    if [ "$MODE" = "$TUI_ENTRY" ]; then
        echo
        echo "▶️  llama-cli -hf $MODEL -c 0 ${MTP[*]}"
        set -m
        cd "$HOME/llama.cpp" || { echo "❌ Not found: $HOME/llama.cpp"; exit 1; }
        ./llama-cli -hf "$MODEL" -c 0 "${MTP[@]}" &
        fg
        stty sane
        exit 0
    fi

    local FG=()
    [ "$MODE" = "$FG_ENTRY" ] && FG=(--fg)

    local HOST=""
    select HOST in "127.0.0.1" "0.0.0.0"; do
        [ -n "$HOST" ] && break
        echo "Invalid selection."
    done
    [ -z "$HOST" ] && { echo "❌ Cancelled."; exit 0; }

    echo
    exec "$SCRIPT_DIR/serve.sh" "${FG[@]}" "$MODEL" --jinja -c 0 "${MTP[@]}" --host "$HOST" --port 8033
}

case "${1:-list}" in
    list)   cmd_list ;;
    launch) cmd_launch ;;
    remove) cmd_remove ;;
    *)      echo "Usage: models.sh [list|launch|remove]"; exit 1 ;;
esac
