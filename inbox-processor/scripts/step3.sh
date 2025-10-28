#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
INBOX_DIRS="/data/inbox"
REPORTS_DIR="/data/reports"
OLLAMA_HOST="http://192.168.1.94:11434"
OLLAMA_MODEL="llama3.1:8b"
AI_TIMEOUT=60

mkdir -p "$REPORTS_DIR"
DATE_TAG=$(date +%Y-%m-%d)
REPORT_FILE="$REPORTS_DIR/step3_text_${DATE_TAG}.json"

echo "============================================================"
echo "🤖 [step3] Starting AI file analysis at $(date)"
echo "Ollama host: $OLLAMA_HOST"
echo "Model: $OLLAMA_MODEL"
echo "============================================================"

# --- Check Ollama connection ---
if ! curl -s --connect-timeout 5 "$OLLAMA_HOST/api/tags" > /dev/null; then
    echo "❌ ERROR: Cannot connect to Ollama at $OLLAMA_HOST"
    exit 1
fi
echo "✅ Ollama connection successful"

# --- Collect text files ---
mapfile -t files < <(find "$INBOX_DIRS" -maxdepth 1 -type f -name "*.txt")
if [[ ${#files[@]} -eq 0 ]]; then
    echo "❌ No .txt files found in $INBOX_DIRS"
    exit 0
fi
echo "📝 Found ${#files[@]} text files to process"

# --- Start JSON output file ---
echo "[" > "$REPORT_FILE"
first=true

# --- Analyze each file ---
for file in "${files[@]}"; do
    echo "🔍 Analyzing: $file"

    prompt=$(cat <<EOF
You are LibrAIry, a precise JSON-only assistant.
Given the file path below, return ONLY a single JSON object — no markdown, no explanation, no text — matching this schema:
{
  "original_path": "<full path>",
  "proposed_name": "clean_name.txt",
  "category": "Note|Document|Config|Other",
  "confidence": "High|Medium|Low"
}

File: $file
EOF
)

    # Escape newlines safely
    safe_prompt=$(jq -Rs . <<< "$prompt")

    response=$(curl -s --connect-timeout "$AI_TIMEOUT" \
      -H "Content-Type: application/json" \
      -d "{
          \"model\": \"$OLLAMA_MODEL\",
          \"prompt\": $safe_prompt,
          \"stream\": false
      }" \
      "$OLLAMA_HOST/api/generate")

    # Check for error from Ollama
    if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
        echo "❌ Ollama error: $(echo "$response" | jq -r '.error')"
        continue
    fi

    # Extract model response text
    raw_text=$(echo "$response" | jq -r '.response' 2>/dev/null || echo "")
    if [[ -z "$raw_text" || "$raw_text" == "null" ]]; then
        echo "⚠️ No response for $file"
        continue
    fi

    echo "💬 Raw model text (truncated):"
    echo "$raw_text" | head -n 5
    echo "------------------------------------"

    # --- Extract the JSON content ---
    # 1. Try to find ```json ... ``` block
    clean_json=$(echo "$raw_text" | sed -n '/```json/,/```/p' | sed 's/```json//;s/```//')
    # 2. If no code block found, try to grab text between first { and last }
    if [[ -z "$clean_json" ]]; then
        clean_json=$(echo "$raw_text" | sed -n '/{/,/}/p')
    fi
    # 3. Trim and clean
    clean_json=$(echo "$clean_json" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r')

    # --- Validate JSON ---
    if echo "$clean_json" | jq empty >/dev/null 2>&1; then
        echo "✅ Extracted valid JSON for: $file"
        if [[ "$first" == true ]]; then
            first=false
        else
            echo "," >> "$REPORT_FILE"
        fi
        echo "$clean_json" >> "$REPORT_FILE"
    else
        echo "⚠️ Could not extract valid JSON for: $file"
        echo "🪶 Raw text (first 10 lines):"
        echo "$raw_text" | head -n 10
    fi

    echo "------------------------------------"
    sleep 1
done

echo "]" >> "$REPORT_FILE"

echo "✅ Analysis finished"
echo "📄 Report saved to: $REPORT_FILE"
echo "============================================================"

