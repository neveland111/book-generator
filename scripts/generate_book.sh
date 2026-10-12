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
  --provider NAME         Force one AI provider (default: auto):
                            gemini | ollama | groq | anthropic | openai | custom
                          "openai" and "custom" both use the OpenAI-compatible
                          endpoint configured through CUSTOM_API_BASE_URL /
                          CUSTOM_API_KEY / CUSTOM_MODEL (OPENAI_* also accepted).
                          A pinned provider is never silently replaced.
  --style TEXT            Writing style (default: "engaging and informative")
  --tone TEXT             Writing tone  (default: "accessible and professional")
  --audience TEXT         Target audience (default: "general audience")
  --skip-appendices       Skip appendix generation step
  --skip-references       Skip bibliography generation step
  --skip-compile          Skip final PDF/EPUB compilation
  --quiet                 Suppress progress output (errors still shown)
  --help                  Show this message and exit

Environment variables:
  GEMINI_API_KEY          Gemini API key        (preferred provider)
  GROQ_API_KEY            Groq API key          (fallback)
  ANTHROPIC_API_KEY       Anthropic (Claude) key — optional provider
  ANTHROPIC_MODEL         Claude model name     (default: claude-sonnet-4-5)
  CUSTOM_API_BASE_URL     Any OpenAI-compatible endpoint, e.g.
                          https://openrouter.ai/api/v1 or http://localhost:1234/v1
  CUSTOM_API_KEY          Key for that endpoint (local servers: any string)
  CUSTOM_MODEL            Model name to request (default: gpt-4o-mini)
  OPENAI_API_KEY          Alias for CUSTOM_API_KEY (plain OpenAI needs only this)
  OPENAI_BASE_URL         Alias for CUSTOM_API_BASE_URL (e.g. https://api.openai.com/v1)
  AUTHOR_PEN_NAME         Default pen name for all books
  SMART_API_PROVIDER      Same as --provider (auto|gemini|ollama|groq|anthropic|openai|custom)

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

if [[ -n "$PROVIDER" ]]; then
    case "$PROVIDER" in
        auto|gemini|ollama|groq|anthropic|openai|custom) : ;;
        *) die "Unknown --provider '$PROVIDER'. Valid values: auto | gemini | ollama | groq | anthropic | openai | custom" ;;
    esac
    export SMART_API_PROVIDER="$PROVIDER"
fi

# Warn early (instead of after a failed chapter) when the pinned provider has no
# usable configuration.
case "${SMART_API_PROVIDER:-auto}" in
    anthropic)
        [[ -z "${ANTHROPIC_API_KEY:-}" ]] && die "--provider anthropic requires ANTHROPIC_API_KEY"
        ;;
    openai|custom)
        if [[ -z "${CUSTOM_API_BASE_URL:-${OPENAI_BASE_URL:-}}" || -z "${CUSTOM_API_KEY:-${OPENAI_API_KEY:-}}" ]]; then
            die "--provider $SMART_API_PROVIDER requires CUSTOM_API_BASE_URL and CUSTOM_API_KEY (or OPENAI_BASE_URL and OPENAI_API_KEY)"
        fi
        ;;
esac

# ── Source AI layer ───────────────────────────────────────────────────────────
source "$SCRIPT_DIR/multi_provider_ai_simple.sh" \
    || die "Cannot source multi_provider_ai_simple.sh — check scripts directory"

# Pick up keys from .env in the repo root (existing environment wins)
load_dotenv_if_present

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
    "$TOPIC" "$GENRE" "$TARGET_AUDIENCE" "$STYLE" "$TONE" "$CHAPTERS" "$WORDS_PER_CHAPTER")

if [[ -z "$OUTLINE_CONTENT" ]]; then
    die "Outline generation returned empty content. Verify API keys and network."
fi

echo "$OUTLINE_CONTENT" > "$OUTLINE_FILE"
log "        Saved: outline.md"

# Chapter headings are extracted with extract_outline_chapters(), which comes
# from multi_provider_ai_simple.sh (sourced above) so both orchestrators share
# exactly one parser.
mapfile -t CHAPTER_LINES < <(extract_outline_chapters "$OUTLINE_FILE" "$CHAPTERS")

if [[ ${#CHAPTER_LINES[@]} -eq 0 ]]; then
    # A book of placeholder-titled chapters ("Chapter 1: Chapter 1") is worse
    # than no book: stop here with something actionable instead.
    die "The outline contains no 'Chapter N: Title' headings, so no chapters could be planned.
     Outline file: $OUTLINE_FILE
     First lines of the outline:
$(head -n 5 "$OUTLINE_FILE" | sed 's/^/       /')
     Edit that file so each chapter starts with a '### Chapter N: Title' line,
     or re-run with a topic that produces a parseable outline."
fi

ACTUAL_CHAPTERS=${#CHAPTER_LINES[@]}
log "        Parsed $ACTUAL_CHAPTERS chapters"

# ── [2/6] Chapters ────────────────────────────────────────────────────────────
log "✍️  [2/6] Writing $ACTUAL_CHAPTERS chapters..."
EXISTING_CHAPTERS=""
MIN_WORDS=$WORDS_PER_CHAPTER
MAX_WORDS=$((WORDS_PER_CHAPTER + 1000))

# Output-token budget for one chapter. English prose runs ~1.5-1.7 tokens per
# word, so a 4,000-word chapter needs far more than a small default cap; without
# this the model stops mid-sentence at the provider's limit.
MAX_TOKENS=$(( WORDS_PER_CHAPTER * 2 ))
[[ $MAX_TOKENS -lt 4096 ]] && MAX_TOKENS=4096
[[ $MAX_TOKENS -gt 8192 ]] && MAX_TOKENS=8192

FAILED_CHAPTERS=0
WRITTEN_CHAPTERS=0
LAST_TAIL=""

for i in "${!CHAPTER_LINES[@]}"; do
    CHAPTER_NUM=$((i + 1))
    CHAPTER_LINE="${CHAPTER_LINES[$i]}"
    # "Chapter N: Title" or "Chapter N - Title" → extract title part
    CHAPTER_TITLE=$(echo "$CHAPTER_LINE" | sed -E 's/^Chapter [0-9]+[:\-][[:space:]]*//')
    PADDED=$(printf "%02d" "$CHAPTER_NUM")
    CHAPTER_FILE="$BOOK_DIR/chapter_${PADDED}.md"

    log "        [$CHAPTER_NUM/$ACTUAL_CHAPTERS] $CHAPTER_TITLE"

    # Continuity context: the running list of chapters (compact) plus the tail
    # of the previous chapter so the model can match voice and pick the thread
    # up, without paying to resend every earlier chapter in full.
    PRIOR_CONTEXT="$EXISTING_CHAPTERS"
    if [[ -n "$LAST_TAIL" ]]; then
        PRIOR_CONTEXT="${PRIOR_CONTEXT}
End of the previous chapter, for voice and continuity: ...${LAST_TAIL}"
    fi

    CHAPTER_CONTENT=$(generate_chapter_with_smart_api \
        "$CHAPTER_NUM" \
        "$CHAPTER_TITLE" \
        "$PRIOR_CONTEXT" \
        "$OUTLINE_CONTENT" \
        "$MIN_WORDS" \
        "$MAX_WORDS" \
        "$STYLE" \
        "$TONE" \
        "$MAX_TOKENS") || true  # never bail on a single chapter failure

    if [[ -z "$CHAPTER_CONTENT" ]]; then
        log "        ⚠️  Chapter $CHAPTER_NUM failed — writing placeholder"
        FAILED_CHAPTERS=$((FAILED_CHAPTERS + 1))
        CHAPTER_CONTENT="# $CHAPTER_TITLE

*[Chapter $CHAPTER_NUM generation failed. Re-run with:]*

\`\`\`bash
./scripts/generate_book.sh --topic \"${TOPIC}\" --skip-compile
\`\`\`"
        LAST_TAIL=""
    else
        WRITTEN_CHAPTERS=$((WRITTEN_CHAPTERS + 1))
        LAST_TAIL=$(printf '%s' "$CHAPTER_CONTENT" | tail -c 700 | tr '\n' ' ' | tr -s ' ')
    fi

    echo "$CHAPTER_CONTENT" > "$CHAPTER_FILE"
    # Accumulate brief summary for continuity context (capped to avoid token bloat)
    EXISTING_CHAPTERS="${EXISTING_CHAPTERS}Chapter ${CHAPTER_NUM}: ${CHAPTER_TITLE} (written). "
done

if [[ $WRITTEN_CHAPTERS -eq 0 ]]; then
    die "Every chapter failed to generate — nothing worth compiling.
     Book directory: $BOOK_DIR
     Fix the provider problem reported above (API key, quota, or 'ollama serve')
     and run the same command again; chapters are written one file at a time."
fi

if [[ $FAILED_CHAPTERS -gt 0 ]]; then
    log "        ⚠️  $WRITTEN_CHAPTERS/$ACTUAL_CHAPTERS chapters written, $FAILED_CHAPTERS failed"
else
    log "        ✓ All $ACTUAL_CHAPTERS chapters written"
fi

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
