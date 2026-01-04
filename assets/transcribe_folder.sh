#!/bin/bash

# Arguments
SRC_DIR="$1"
DEST_DIR="$2"
SERVER_URL="${3:-http://127.0.0.1:8080}"

# Check arguments
if [ -z "$SRC_DIR" ] || [ -z "$DEST_DIR" ]; then
    echo "Usage: $0 <source_dir> <dest_dir> [server_url]"
    exit 1
fi

# Ensure output directory exists
mkdir -p "$DEST_DIR"

# Verify dependencies
if ! command -v ffmpeg &> /dev/null; then
    echo "Error: ffmpeg is not installed."
    exit 1
fi
if ! command -v curl &> /dev/null; then
    echo "Error: curl is not installed."
    exit 1
fi
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed (required for JSON parsing)."
    exit 1
fi

# Sanitize URL (remove trailing slash)
SERVER_URL=${SERVER_URL%/}

# Check connectivity
if ! curl -s --head "$SERVER_URL/health" &> /dev/null && ! curl -s --head "$SERVER_URL" &> /dev/null; then
    echo "⚠️  Warning: Cannot reach server at $SERVER_URL"
    echo "   Ensure 'whisper-server' is running."
    sleep 2
fi

echo "---------------------------------------------------"
echo "📂 Source: $SRC_DIR"
echo "📂 Dest:   $DEST_DIR"
echo "🌐 Server: $SERVER_URL"
echo "---------------------------------------------------"

# Iterate over audio files
find "$SRC_DIR" -maxdepth 1 -type f \( -iname "*.mp3" -o -iname "*.wav" -o -iname "*.m4a" -o -iname "*.ogg" -o -iname "*.flac" \) | while read -r FILE; do
    BASENAME=$(basename "$FILE")
    NAME="${BASENAME%.*}"
    
    # Output files
    OUT_TXT="$DEST_DIR/$NAME.txt"
    OUT_JSON="$DEST_DIR/$NAME.json"
    
    if [ -f "$OUT_TXT" ]; then
        echo "⏭️  Skipping (Exists): $BASENAME"
        continue
    fi
    
    echo "🎤 Processing: $BASENAME"
    
    # Temp Paths (PID based)
    TEMP_WAV="/tmp/whisper_client_$$.wav"
    trap "rm -f '$TEMP_WAV'" EXIT

    # 1. Convert to 16kHz mono WAV (Client side conversion saves server bandwidth/cpu usually)
    ffmpeg -y -i "$FILE" -ar 16000 -ac 1 -c:a pcm_s16le "$TEMP_WAV" -v error
    if [ $? -ne 0 ]; then
        echo "❌ Conversion failed for $BASENAME"
        continue
    fi
    
    # 2. Transcribe via API
    # Save full JSON response
    HTTP_CODE=$(curl -s -w "%{http_code}" -X POST "$SERVER_URL/inference" \
        -H "Content-Type: multipart/form-data" \
        -F file="@$TEMP_WAV" \
        -F temperature="0.0" \
        -F response_format="json" \
        -o "$OUT_JSON")
        
    # 3. Parse Response
    if [ "$HTTP_CODE" -eq 200 ] && [ -f "$OUT_JSON" ]; then
        TEXT=$(jq -r '.text // empty' "$OUT_JSON")
        
        if [ -n "$TEXT" ]; then
            echo "$TEXT" > "$OUT_TXT"
            echo "📝 Content:"
            echo "$TEXT"
            echo "✅ Saved: $NAME.json & $NAME.txt"
        else
            echo "❌ Parsing failed or empty text. See $OUT_JSON"
        fi
    else
        echo "❌ Server Error ($HTTP_CODE). Response saved to $OUT_JSON"
    fi
    
done

echo "---------------------------------------------------"
echo "🎉 Batch Transcription Complete."
