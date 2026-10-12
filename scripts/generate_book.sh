#!/bin/bash
# generate_book.sh — Master book generation orchestrator
#
# Chains the full pipeline: outline → chapters → appendices → references → compile
# All AI calls route through multi_provider_ai_simple.sh (Gemini → Ollama → Groq).
#
# Usage: ./scripts/generate_book.sh --topic "My Topic" [OPTIONS]
# Run:   ./scripts/generate_book.sh --help  for full documentation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Defaults ─────────────────────────────────────────────────────────────────
TOPIC=""
GENRE="non-fiction"
CHAPTERS=12
WORDS_PER_CHAPTER=3000
OUTPUT_DIR="$REPO_ROOT/v3"
PEN_NAME="${AUTHOR_PEN_NAME:-}"
PROVIDER=""
STYLE="engaging and informative"
TONE="accessible and professional"
TARGET_AUDIENCE="general audience"
SKIP_APPENDICES=false
SKIP_REFERENCES=false
SKIP_COMPILE=false
QUIET=false

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") --topic TOPIC [OPTIONS]

Generate a complete book manuscript using AI (Gemini, Ollama, or Groq).

Required:
  --topic TEXT            Book subject / title concept

Options:
  --genre TEXT            Genre (default: non-fiction)
  --chapters N            Number of chapters (default: 12)
  --words-per-chapter N   Target words per chapter (default: 3000)
  --output-dir DIR        Parent output directory (default: ./v3)
  --pen-name NAME         Author name — overrides AUTHOR_PEN_NAME env var
  --provider NAME         Force AI provider: gemini | ollama | groq (default: auto)
  --style TEXT            Writing style (default: "engaging and informative")
  --tone TEXT             Writing tone  (default: "accessible and professional")
  --audience TEXT         Target audience (default: "general audience")
  --skip-appendices       Skip appendix generation step
  --skip-references       Skip bibliography generation step
  --skip-compile          Skip final PDF/EPUB compilation
  --quiet                 Suppress progress output (errors still shown)
  --help                  Show this message and exit

Environment variables:
  GEMINI_API_KEY          Gemini API key   (preferred provider)
  GROQ_API_KEY            Groq API key     (fallback)
  OPENAI_API_KEY          OpenAI API key   (cover generation only)
  AUTHOR_PEN_NAME         Default pen name for all books

Example:
  ./scripts/generate_book.sh \\
    --topic "Personal Finance for Millennials" \\
    --chapters 10 --words-per-chapter 4000 \\
    --pen-name "Jordan Wells"
EOF
}

# ── Helpers ───────────────────────────────────────────────────────────────────
log() {
    if [ "$QUIET" = false ]; then
        echo "$@" >&2
    fi
}

die() {
    echo "❌ Error: $*" >&2
    exit 1
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --topic)             TOPIC="$2";              shift 2 ;;
        --genre)             GENRE="$2";              shift 2 ;;
        --chapters)          CHAPTERS="$2";           shift 2 ;;
        --words-per-chapter) WORDS_PER_CHAPTER="$2";  shift 2 ;;
        --output-dir)        OUTPUT_DIR="$2";         shift 2 ;;
        --pen-name)          PEN_NAME="$2";           shift 2 ;;
        --provider)          PROVIDER="$2";           shift 2 ;;
        --style)             STYLE="$2";              shift 2 ;;
        --tone)              TONE="$2";               shift 2 ;;
        --audience)          TARGET_AUDIENCE="$2";    shift 2 ;;
        --skip-appendices)   SKIP_APPENDICES=true;    shift ;;
        --skip-references)   SKIP_REFERENCES=true;    shift ;;
        --skip-compile)      SKIP_COMPILE=true;       shift ;;
        --quiet)             QUIET=true;              shift ;;
        --help|-h)           usage; exit 0 ;;
        *)                   die "Unknown option: $1  (run --help for usage)" ;;
    esac
done

# ── Validation ────────────────────────────────────────────────────────────────
[[ -z "$TOPIC" ]] && die "--topic is required  (run --help for usage)"
[[ "$CHAPTERS" =~ ^[0-9]+$ ]] || die "--chapters must be a positive integer"
[[ "$WORDS_PER_CHAPTER" =~ ^[0-9]+$ ]] || die "--words-per-chapter must be a positive integer"
[[ "$CHAPTERS" -gt 0 ]] || die "--chapters must be greater than 0"
[[ "$WORDS_PER_CHAPTER" -gt 0 ]] || die "--words-per-chapter must be greater than 0"

# Propagate optional overrides into environment
[[ -n "$PEN_NAME" ]] && export AUTHOR_PEN_NAME="$PEN_NAME"
[[ -n "$PROVIDER" ]] && export SMART_API_PROVIDER="$PROVIDER"

# ── Source AI layer ───────────────────────────────────────────────────────────
source "$SCRIPT_DIR/multi_provider_ai_simple.sh" \
    || die "Cannot source multi_provider_ai_simple.sh — check scripts directory"

# ── Create output directory ───────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SAFE_TOPIC=$(echo "$TOPIC" \
    | tr '[:upper:]' '[:lower:]' \
    | tr ' ' '_' \
    | tr -dc '[:alnum:]_' \
    | cut -c1-40)
BOOK_DIR="$OUTPUT_DIR/${TIMESTAMP}_${SAFE_TOPIC}"
mkdir -p "$BOOK_DIR"

log "📚 Book Generation Pipeline"
log "   Topic:       $TOPIC"
log "   Genre:       $GENRE"
log "   Chapters:    $CHAPTERS"
log "   Words/ch:    $WORDS_PER_CHAPTER"
log "   Output:      $BOOK_DIR"
log ""

# ── [1/6] Outline ─────────────────────────────────────────────────────────────
log "📋 [1/6] Generating outline..."
OUTLINE_FILE="$BOOK_DIR/outline.md"

OUTLINE_CONTENT=$(generate_outline_with_smart_api \
    "$TOPIC" "$GENRE" "$TARGET_AUDIENCE" "$STYLE" "$TONE")

if [[ -z "$OUTLINE_CONTENT" ]]; then
    die "Outline generation returned empty content. Verify API keys and network."
fi

echo "$OUTLINE_CONTENT" > "$OUTLINE_FILE"
log "        Saved: outline.md"

# Parse "Chapter N: Title" or "Chapter N - Title" headings
mapfile -t CHAPTER_LINES < <(grep -iE "^Chapter [0-9]+[:\-]" "$OUTLINE_FILE" | head -"$CHAPTERS")

if [[ ${#CHAPTER_LINES[@]} -eq 0 ]]; then
    log "   ⚠️  No 'Chapter N:' headings found in outline; using $CHAPTERS placeholder titles."
    for i in $(seq 1 "$CHAPTERS"); do
        CHAPTER_LINES+=("Chapter $i: Chapter $i")
    done
fi

ACTUAL_CHAPTERS=${#CHAPTER_LINES[@]}
log "        Parsed $ACTUAL_CHAPTERS chapters"

# ── [2/6] Chapters ────────────────────────────────────────────────────────────
log "✍️  [2/6] Writing $ACTUAL_CHAPTERS chapters..."
EXISTING_CHAPTERS=""
MIN_WORDS=$WORDS_PER_CHAPTER
MAX_WORDS=$((WORDS_PER_CHAPTER + 1000))

for i in "${!CHAPTER_LINES[@]}"; do
    CHAPTER_NUM=$((i + 1))
    CHAPTER_LINE="${CHAPTER_LINES[$i]}"
    # "Chapter N: Title" or "Chapter N - Title" → extract title part
    CHAPTER_TITLE=$(echo "$CHAPTER_LINE" | sed -E 's/^Chapter [0-9]+[:\-][[:space:]]*//')
    PADDED=$(printf "%02d" "$CHAPTER_NUM")
    CHAPTER_FILE="$BOOK_DIR/chapter_${PADDED}.md"

    log "        [$CHAPTER_NUM/$ACTUAL_CHAPTERS] $CHAPTER_TITLE"

    CHAPTER_CONTENT=$(generate_chapter_with_smart_api \
        "$CHAPTER_NUM" \
        "$CHAPTER_TITLE" \
        "$EXISTING_CHAPTERS" \
        "$OUTLINE_CONTENT" \
        "$MIN_WORDS" \
        "$MAX_WORDS" \
        "$STYLE" \
        "$TONE") || true  # never bail on a single chapter failure

    if [[ -z "$CHAPTER_CONTENT" ]]; then
        log "        ⚠️  Chapter $CHAPTER_NUM failed — writing placeholder"
        CHAPTER_CONTENT="# $CHAPTER_TITLE

*[Chapter $CHAPTER_NUM generation failed. Re-run with:]*

\`\`\`bash
./scripts/generate_book.sh --topic \"${TOPIC}\" --skip-compile
\`\`\`"
    fi

    echo "$CHAPTER_CONTENT" > "$CHAPTER_FILE"
    # Accumulate brief summary for continuity context (capped to avoid token bloat)
    EXISTING_CHAPTERS="${EXISTING_CHAPTERS}Chapter ${CHAPTER_NUM}: ${CHAPTER_TITLE} (complete). "
done

log "        All $ACTUAL_CHAPTERS chapters written"

# ── [3/6] Appendices ──────────────────────────────────────────────────────────
if [[ "$SKIP_APPENDICES" = false && -n "${GEMINI_API_KEY:-}" ]]; then
    log "📑 [3/6] Generating appendices..."
    if bash "$SCRIPT_DIR/generate_appendices.sh" "$BOOK_DIR"; then
        log "        ✓ Appendices complete"
    else
        log "        ⚠️  Appendix generation failed — continuing without appendices"
    fi
else
    log "⏭️  [3/6] Appendices skipped"
fi

# ── [4/6] References ──────────────────────────────────────────────────────────
if [[ "$SKIP_REFERENCES" = false && -n "${GEMINI_API_KEY:-}" ]]; then
    log "📚 [4/6] Generating bibliography..."
    if bash "$SCRIPT_DIR/generate_references.sh" "$BOOK_DIR"; then
        log "        ✓ Bibliography complete"
    else
        log "        ⚠️  Bibliography generation failed — continuing without references"
    fi
else
    log "⏭️  [4/6] Bibliography skipped"
fi

# ── [5/6] Originality check ───────────────────────────────────────────────────
log "🔍 [5/6] Originality checks..."
flagged=0
for chapter_file in "$BOOK_DIR"/chapter_*.md; do
    [[ -f "$chapter_file" ]] || continue
    result=0
    check_plagiarism_with_smart_api "$chapter_file" || result=$?
    if [[ $result -eq 1 ]]; then
        log "        ⚠️  Medium originality: $(basename "$chapter_file")"
        flagged=$((flagged + 1))
    elif [[ $result -ge 2 ]]; then
        log "        ❌ Low originality:    $(basename "$chapter_file") — review before publishing"
        flagged=$((flagged + 1))
    fi
done

if [[ $flagged -eq 0 ]]; then
    log "        ✓ All chapters passed originality check"
else
    log "        ⚠️  $flagged chapter(s) flagged for review"
fi

# ── [6/6] Compile ─────────────────────────────────────────────────────────────
if [[ "$SKIP_COMPILE" = false ]]; then
    log "📦 [6/6] Compiling book..."
    COMPILE_OPTS=()
    [[ -n "$PEN_NAME" ]] && COMPILE_OPTS+=(--author "$PEN_NAME")

    if bash "$SCRIPT_DIR/compile_book.sh" \
            "$BOOK_DIR" "all" "1" \
            ${COMPILE_OPTS[@]+"${COMPILE_OPTS[@]}"}; then
        log "        ✓ Compilation complete"
    else
        log "        ⚠️  Compilation failed — raw chapters are available in $BOOK_DIR"
    fi
else
    log "⏭️  [6/6] Compilation skipped"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
log "✅ Done!"
log "   📁 $BOOK_DIR"
log "   📋 outline.md  ($ACTUAL_CHAPTERS chapters)"
log ""
log "To compile manually:"
log "   ./scripts/compile_book.sh \"$BOOK_DIR\" all 1"
exit 0
