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

# ── The picker ───────────────────────────────────────────────────────────────
# bash's own 'select' lays its options out in as many columns as the terminal
# fits, so '[ cancel ]' ends up beside option 1 and the list reads as a table
# nobody asked for. This prints one option per line inside a frame instead, and
# closes it on the prompt line — which is also why 'select' cannot be kept and
# merely re-styled: it prints its options and PS3 back to back, leaving nowhere
# to draw a bottom rule.
#
# Sets PICK to the 1-based choice. Returns 1 on EOF (Ctrl-D), which every caller
# treats as a cancel — never as a selection.
PICK=""
pick() {
    local title=$1; shift
    local n=$# i ans
    printf '┌─ %s\n' "$title"
    for ((i = 1; i <= n; i++)); do
        printf '│ %d) %s\n' "$i" "${!i}"
    done
    while :; do
        printf '└─ #? '
        read -r ans || { PICK=""; echo; return 1; }
        if [[ $ans =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "$n" ]; then
            PICK=$ans
            return 0
        fi
        echo "   Pick a number between 1 and $n."
    done
}

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

    local CANCEL_ENTRY="[ cancel ]" i answer
    # A cancel — chosen or by Ctrl-D — must never fall through to the confirm
    # prompt for whatever happens to sit at index 0.
    pick "🗑️  Select what to DELETE" "${menu[@]}" "$CANCEL_ENTRY" \
        || { echo "❌ Cancelled."; exit 0; }
    [ "$PICK" -gt ${#menu[@]} ] && { echo "❌ Cancelled."; exit 0; }
    i=$((PICK - 1))

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

    [ ${#ids[@]} -eq 0 ] && echo "  (no cached models — use '$TYPE_ENTRY')"

    pick "🚀 Launch a model" "${menu[@]}" "$TYPE_ENTRY" "$CANCEL_ENTRY" \
        || { echo "❌ Cancelled."; exit 0; }
    # The two entries past the cached ids are '[ type a repo id ]' and, last,
    # '[ cancel ]'.
    if [ "$PICK" -gt $(( ${#ids[@]} + 1 )) ]; then
        echo "❌ Cancelled."; exit 0
    elif [ "$PICK" -eq $(( ${#ids[@]} + 1 )) ]; then
        while :; do
            read -e -p "Hugging Face repo id (e.g. ggml-org/Qwen3-0.6B-GGUF:Q8_0): " MODEL
            [ -z "$MODEL" ] && { echo "❌ Cancelled."; exit 0; }
            [[ $MODEL == */* ]] && break
            echo "⚠️  Needs the form <user>/<model>[:quant]."
        done
    else
        MODEL="${ids[$((PICK - 1))]}"
    fi
    [ -z "$MODEL" ] && { echo "❌ Cancelled."; exit 0; }

    echo
    echo "Model: $MODEL"
    echo
    # MODE is the number picked here: 1 background, 2 foreground, 3 TUI. Two of
    # the three labels contain the word 'foreground', so the branches below test
    # the number rather than the text.
    local MODE=""
    pick "How should it run?" \
        "Server — WebUI, background" \
        "Server — WebUI, foreground (watch the load, Ctrl-C stops it)" \
        "TUI (llama-cli, foreground)" \
        || { echo "❌ Cancelled."; exit 0; }
    MODE=$PICK

    # MTP (multi-token prediction): speculative decoding off the model's own
    # heads, no draft model involved. Needs llama.cpp b9200+ and a model that
    # carries MTP weights — the flag is passed through as asked, unchecked.
    local MTP=()
    echo
    pick "Enable MTP (multi-token prediction)?" \
        "No" \
        "Yes — --spec-type draft-mtp --spec-draft-n-max 2" \
        || { echo "❌ Cancelled."; exit 0; }
    [ "$PICK" -eq 2 ] && MTP=(--spec-type draft-mtp --spec-draft-n-max 2)

    if [ "$MODE" -eq 3 ]; then
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
    [ "$MODE" -eq 2 ] && FG=(--fg)

    echo
    local HOST=""
    pick "Bind the server to" \
        "127.0.0.1  (this machine only)" \
        "0.0.0.0    (also reachable on your LAN)" \
        || { echo "❌ Cancelled."; exit 0; }
    [ "$PICK" -eq 1 ] && HOST=127.0.0.1 || HOST=0.0.0.0

    echo
    exec "$SCRIPT_DIR/serve.sh" "${FG[@]}" "$MODEL" --jinja -c 0 "${MTP[@]}" --host "$HOST" --port 8033
}

case "${1:-list}" in
    list)   cmd_list ;;
    launch) cmd_launch ;;
    remove) cmd_remove ;;
    *)      echo "Usage: models.sh [list|launch|remove]"; exit 1 ;;
esac
