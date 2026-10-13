#!/bin/bash
# agent_book.sh — agent-style book pipeline: plan → write → critique → revise → compile
#
# The difference from generate_book.sh (which is a straight batch pipeline):
# every chapter is graded against a rubric by a "critic" pass, and chapters that
# score below the threshold are revised to act on that critique, then graded
# again. The whole run leaves an audit trail in agent_report.md.
#
# Usage: ./scripts/agent_book.sh --topic "My Topic" [OPTIONS]
# Run:   ./scripts/agent_book.sh --help  for full documentation.

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
THRESHOLD=8          # a chapter scoring below this gets revised
MAX_REVISIONS=1      # revision rounds per chapter
SKIP_COMPILE=false
MARKETING=false
SKIP_ORIGINALITY=false
QUIET=false

usage() {
    cat <<EOF
Usage: $(basename "$0") --topic TOPIC [OPTIONS]

Plan, write, critique and revise a complete book, then compile it.
Every chapter is graded against a rubric; chapters below the threshold are
revised to act on the critique and graded again. An audit trail is written to
agent_report.md inside the book directory.

Required:
  --topic TEXT            Book subject / title concept

Options:
  --genre TEXT            Genre (default: non-fiction)
  --chapters N            Number of chapters (default: 12)
  --words-per-chapter N   Target words per chapter (default: 3000)
  --output-dir DIR        Parent output directory (default: ./v3)
  --pen-name NAME         Author name — overrides AUTHOR_PEN_NAME env var
  --provider NAME         Pin one provider (auto|gemini|ollama|groq|anthropic|openai|custom)
  --style TEXT            Writing style (default: "engaging and informative")
  --tone TEXT             Writing tone  (default: "accessible and professional")
  --audience TEXT         Target audience (default: "general audience")
  --threshold N           Revision threshold, 0-10 (default: 8)
  --max-revisions N       Revision rounds per chapter (default: 1, 0 disables)
  --skip-originality      Skip the originality check step
  --skip-compile          Stop before the final EPUB/PDF compilation
  --marketing             Also build the KDP marketing pack (description, 7 keywords,
                          categories, social copy) — one extra AI call per artifact
  --quiet                 Suppress progress output (errors still shown)
  --help                  Show this message and exit

Environment: same as generate_book.sh. A .env file in the repo root is loaded
automatically (GEMINI_API_KEY, ANTHROPIC_API_KEY, CUSTOM_API_BASE_URL, …).

Example:
  ./scripts/agent_book.sh --topic "Slow Cooking for Busy Weeks" \\
      --chapters 8 --words-per-chapter 2000 --threshold 8 --pen-name "Nama Anda"
EOF
}

log() { [ "$QUIET" = false ] && echo "$@" >&2; }
die() { echo "❌ Error: $*" >&2; exit 1; }

# ── Argument parsing ─────────────────────────────────────────────────────────
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
        --threshold)         THRESHOLD="$2";          shift 2 ;;
        --max-revisions)     MAX_REVISIONS="$2";      shift 2 ;;
        --skip-originality)  SKIP_ORIGINALITY=true;   shift ;;
        --skip-compile)      SKIP_COMPILE=true;       shift ;;
        --marketing)        MARKETING=true;           shift ;;
        --quiet)             QUIET=true;              shift ;;
        --help|-h)           usage; exit 0 ;;
        *)                   die "Unknown option: $1  (run --help for usage)" ;;
    esac
done

# ── Validation ───────────────────────────────────────────────────────────────
[[ -z "$TOPIC" ]] && die "--topic is required  (run --help for usage)"
[[ "$CHAPTERS" =~ ^[0-9]+$ ]] && [ "$CHAPTERS" -gt 0 ] || die "--chapters must be a positive integer"
[[ "$WORDS_PER_CHAPTER" =~ ^[0-9]+$ ]] && [ "$WORDS_PER_CHAPTER" -gt 0 ] || die "--words-per-chapter must be a positive integer"
[[ "$THRESHOLD" =~ ^[0-9]+$ ]] && [ "$THRESHOLD" -ge 0 ] && [ "$THRESHOLD" -le 10 ] || die "--threshold must be 0-10"
[[ "$MAX_REVISIONS" =~ ^[0-9]+$ ]] || die "--max-revisions must be 0 or a positive integer"

[[ -n "$PEN_NAME" ]] && export AUTHOR_PEN_NAME="$PEN_NAME"
if [[ -n "$PROVIDER" ]]; then
    case "$PROVIDER" in
        auto|gemini|ollama|groq|anthropic|openai|custom) : ;;
        *) die "Unknown --provider '$PROVIDER'. Valid values: auto | gemini | ollama | groq | anthropic | openai | custom" ;;
    esac
    export SMART_API_PROVIDER="$PROVIDER"
fi

# ── Source the AI layer ──────────────────────────────────────────────────────
source "$SCRIPT_DIR/multi_provider_ai_simple.sh" \
    || die "Cannot source multi_provider_ai_simple.sh — check scripts directory"

load_dotenv_if_present

case "${SMART_API_PROVIDER:-auto}" in
    anthropic)
        [[ -z "${ANTHROPIC_API_KEY:-}" ]] && die "--provider anthropic requires ANTHROPIC_API_KEY" ;;
    openai|custom)
        if [[ -z "${CUSTOM_API_BASE_URL:-${OPENAI_BASE_URL:-}}" || -z "${CUSTOM_API_KEY:-${OPENAI_API_KEY:-}}" ]]; then
            die "--provider $SMART_API_PROVIDER requires CUSTOM_API_BASE_URL and CUSTOM_API_KEY (or OPENAI_BASE_URL and OPENAI_API_KEY)"
        fi ;;
esac

# ── Output directory ─────────────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SAFE_TOPIC=$(echo "$TOPIC" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -dc '[:alnum:]_' | cut -c1-40)
BOOK_DIR="$OUTPUT_DIR/${TIMESTAMP}_${SAFE_TOPIC}"
mkdir -p "$BOOK_DIR"
REPORT_FILE="$BOOK_DIR/agent_report.md"

MIN_WORDS=$WORDS_PER_CHAPTER
MAX_WORDS=$((WORDS_PER_CHAPTER + 1000))
MAX_TOKENS=$(( WORDS_PER_CHAPTER * 2 ))
[[ $MAX_TOKENS -lt 4096 ]] && MAX_TOKENS=4096
[[ $MAX_TOKENS -gt 8192 ]] && MAX_TOKENS=8192

log "🤖 Agent Book Pipeline  (plan → write → critique → revise → compile)"
log "   Topic:        $TOPIC"
log "   Genre:        $GENRE"
log "   Chapters:     $CHAPTERS  (${WORDS_PER_CHAPTER}-${MAX_WORDS} words each)"
log "   Threshold:    revises anything below ${THRESHOLD}/10 (max ${MAX_REVISIONS} round(s))"
log "   Provider:     ${SMART_API_PROVIDER:-auto}"
log "   Output:       $BOOK_DIR"
log ""

START_EPOCH=$(date +%s)

{
    echo "# Agent run report"
    echo
    echo "- **Topic:** $TOPIC"
    echo "- **Genre:** $GENRE · **Audience:** $TARGET_AUDIENCE · **Style:** $STYLE · **Tone:** $TONE"
    echo "- **Provider preference:** ${SMART_API_PROVIDER:-auto}"
    echo "- **Target:** $CHAPTERS chapters × ${WORDS_PER_CHAPTER}-${MAX_WORDS} words"
    echo "- **Revision policy:** threshold ${THRESHOLD}/10, max ${MAX_REVISIONS} round(s) per chapter"
    echo "- **Started:** $(date '+%Y-%m-%d %H:%M:%S')"
    echo
    echo "| Chapter | Score before | Revisions | Score after | Words | Status |"
    echo "|---|---|---|---|---|---|"
} > "$REPORT_FILE"

# ── [1/5] Plan (outline) ─────────────────────────────────────────────────────
log "🧭 [1/5] Planning the book (outline)..."
OUTLINE_FILE="$BOOK_DIR/outline.md"

OUTLINE_CONTENT=$(generate_outline_with_smart_api \
    "$TOPIC" "$GENRE" "$TARGET_AUDIENCE" "$STYLE" "$TONE" "$CHAPTERS" "$WORDS_PER_CHAPTER")

[[ -z "$OUTLINE_CONTENT" ]] && die "Outline generation returned empty content. Check the provider reported above."
echo "$OUTLINE_CONTENT" > "$OUTLINE_FILE"

mapfile -t CHAPTER_LINES < <(extract_outline_chapters "$OUTLINE_FILE" "$CHAPTERS")
if [[ ${#CHAPTER_LINES[@]} -eq 0 ]]; then
    die "The outline contains no 'Chapter N: Title' headings, so no chapters could be planned.
     Outline file: $OUTLINE_FILE
     First lines of the outline:
$(head -n 5 "$OUTLINE_FILE" | sed 's/^/       /')
     Edit that file so each chapter starts with a '### Chapter N: Title' line and re-run the compile step by hand."
fi
ACTUAL_CHAPTERS=${#CHAPTER_LINES[@]}
log "        Outline saved (outline.md) — $ACTUAL_CHAPTERS chapters planned"

# ── [2/5] Write, critique and revise each chapter ────────────────────────────
log "✍️  [2/5] Writing, then grading each chapter..."
EXISTING_CHAPTERS=""
LAST_TAIL=""
WRITTEN=0
FAILED=0
REVISED_TOTAL=0

for i in "${!CHAPTER_LINES[@]}"; do
    CHAPTER_NUM=$((i + 1))
    CHAPTER_TITLE=$(echo "${CHAPTER_LINES[$i]}" | sed -E 's/^Chapter [0-9]+:[[:space:]]*//')
    PADDED=$(printf "%02d" "$CHAPTER_NUM")
    CHAPTER_FILE="$BOOK_DIR/chapter_${PADDED}.md"
    CRITIQUE_FILE="$BOOK_DIR/critique_chapter_${PADDED}.md"

    log ""
    log "   ── Chapter $CHAPTER_NUM/$ACTUAL_CHAPTERS — $CHAPTER_TITLE"

    PRIOR_CONTEXT="$EXISTING_CHAPTERS"
    if [[ -n "$LAST_TAIL" ]]; then
        PRIOR_CONTEXT="${PRIOR_CONTEXT}
End of the previous chapter, for voice and continuity: ...${LAST_TAIL}"
    fi

    # 2a. draft
    log "        ✍️  writing draft..."
    CHAPTER_CONTENT=$(generate_chapter_with_smart_api \
        "$CHAPTER_NUM" "$CHAPTER_TITLE" "$PRIOR_CONTEXT" "$OUTLINE_CONTENT" \
        "$MIN_WORDS" "$MAX_WORDS" "$STYLE" "$TONE" "$MAX_TOKENS") || true

    if [[ -z "$CHAPTER_CONTENT" ]]; then
        log "        ⚠️  draft failed — placeholder written"
        FAILED=$((FAILED + 1))
        CHAPTER_CONTENT="# $CHAPTER_TITLE

*[Chapter ${CHAPTER_NUM} generation failed. Re-run:]*

\`\`\`bash
./scripts/agent_book.sh --topic \"${TOPIC}\" --skip-compile
\`\`\`"
        printf '%s\n' "$CHAPTER_CONTENT" > "$CHAPTER_FILE"
        echo "| $CHAPTER_NUM | — | 0 | — | 0 | ❌ generation failed |" >> "$REPORT_FILE"
        LAST_TAIL=""
        EXISTING_CHAPTERS="${EXISTING_CHAPTERS}Chapter ${CHAPTER_NUM}: ${CHAPTER_TITLE} (failed). "
        continue
    fi

    printf '%s\n' "$CHAPTER_CONTENT" > "$CHAPTER_FILE"
    WRITTEN=$((WRITTEN + 1))

    # 2b. critique → revise loop
    SCORE_BEFORE=""
    SCORE_AFTER=""
    REVISIONS=0
    STATUS="ok"

    if [ "$MAX_REVISIONS" -gt 0 ]; then
        log "        🔎 grading (rubric)..."
        GRADED=false
        if critique_chapter_with_smart_api "$CHAPTER_FILE" "$OUTLINE_FILE" > "$CRITIQUE_FILE" 2>/dev/null; then
            # CURRENT_SCORE drives the loop; SCORE_BEFORE/SCORE_AFTER are kept for
            # the report, so the "before" column shows the first grade (they used
            # to be the same variable, which made every row read "before = after").
            CURRENT_SCORE=$(critique_overall_score "$CRITIQUE_FILE")
            SCORE_BEFORE="$CURRENT_SCORE"
            GRADED=true
        else
            log "        ⚠️  grading failed — chapter kept as drafted"
            STATUS="ungraded"
        fi
        log "        📊 score: ${SCORE_BEFORE:-n/a}/10 (threshold $THRESHOLD)"

        # Only revise when a critique actually exists to act on.
        while [ "$GRADED" = true ] && [ "$REVISIONS" -lt "$MAX_REVISIONS" ] \
                && score_below_threshold "$CURRENT_SCORE" "$THRESHOLD"; do
            REVISIONS=$((REVISIONS + 1))
            log "        🛠️  revision $REVISIONS (score below threshold)..."
            if ! revise_chapter_with_report "$CHAPTER_FILE" "$CRITIQUE_FILE"; then
                STATUS="revision failed"
                break
            fi
            log "        🔎 re-grading..."
            AFTER_FILE="${CRITIQUE_FILE%.md}_after_revision_${REVISIONS}.md"
            if critique_chapter_with_smart_api "$CHAPTER_FILE" "$OUTLINE_FILE" > "$AFTER_FILE" 2>/dev/null; then
                CURRENT_SCORE=$(critique_overall_score "$AFTER_FILE")
                SCORE_AFTER="$CURRENT_SCORE"
                log "        📊 new score: ${SCORE_AFTER:-n/a}/10"
            else
                log "        ⚠️  re-grading failed"
                SCORE_AFTER=""
                break
            fi
        done
        REVISED_TOTAL=$((REVISED_TOTAL + REVISIONS))
    else
        STATUS="grading disabled"
    fi

    WORDS=$(wc -w < "$CHAPTER_FILE" | tr -d ' ')
    FINAL_SCORE="${SCORE_AFTER:-$SCORE_BEFORE}"
    if [ -n "$FINAL_SCORE" ] && score_below_threshold "$FINAL_SCORE" "$THRESHOLD"; then
        [ "$STATUS" = "ok" ] && STATUS="below threshold"
    fi
    echo "| $CHAPTER_NUM | ${SCORE_BEFORE:-—} | $REVISIONS | ${SCORE_AFTER:-—} | $WORDS | $STATUS |" >> "$REPORT_FILE"

    LAST_TAIL=$(printf '%s' "$CHAPTER_CONTENT" | tail -c 700 | tr '\n' ' ' | tr -s ' ')
    EXISTING_CHAPTERS="${EXISTING_CHAPTERS}Chapter ${CHAPTER_NUM}: ${CHAPTER_TITLE} (written). "
done

log ""
if [ "$WRITTEN" -eq 0 ]; then
    die "Every chapter failed to generate — nothing worth compiling.
     Book directory: $BOOK_DIR"
fi
log "        ✓ $WRITTEN/$ACTUAL_CHAPTERS chapters written, $REVISED_TOTAL revision round(s) applied"

# ── [3/5] Originality check ──────────────────────────────────────────────────
if [ "$SKIP_ORIGINALITY" = false ]; then
    log "🔍 [3/5] Originality check..."
    flagged=0
    for chapter_file in "$BOOK_DIR"/chapter_*.md; do
        [[ -f "$chapter_file" ]] || continue
        result=0
        check_plagiarism_with_smart_api "$chapter_file" || result=$?
        if [[ $result -eq 1 ]]; then
            log "        ⚠️  medium originality: $(basename "$chapter_file")"
            flagged=$((flagged + 1))
        elif [[ $result -ge 2 ]]; then
            log "        ❌ low originality:    $(basename "$chapter_file") — review before publishing"
            flagged=$((flagged + 1))
        fi
    done
    [ "$flagged" -eq 0 ] && log "        ✓ all chapters passed" || log "        ⚠️  $flagged chapter(s) flagged for review"
    echo "" >> "$REPORT_FILE"
    echo "**Originality:** $flagged chapter(s) flagged for review." >> "$REPORT_FILE"
else
    log "⏭️  [3/5] Originality check skipped"
fi

# ── [4/5] Compile ────────────────────────────────────────────────────────────
if [ "$SKIP_COMPILE" = false ]; then
    log "📦 [4/5] Compiling the book..."
    COMPILE_OPTS=()
    [[ -n "$PEN_NAME" ]] && COMPILE_OPTS+=(--author "$PEN_NAME")
    if bash "$SCRIPT_DIR/compile_book.sh" "$BOOK_DIR" all 1 ${COMPILE_OPTS[@]+"${COMPILE_OPTS[@]}"}; then
        log "        ✓ Compilation complete"
        COMPILED="yes"
    else
        log "        ⚠️  Compilation failed — raw chapters are available in $BOOK_DIR"
        COMPILED="failed"
    fi
else
    log "⏭️  [4/5] Compilation skipped"
    COMPILED="skipped"
fi

# ── [5/5] Marketing pack (opt-in) ────────────────────────────────────────────
if [ "$MARKETING" = true ]; then
    log "📣 [5/5] Building the KDP marketing pack..."
    if bash "$SCRIPT_DIR/generate_marketing_copy.sh" "$BOOK_DIR"; then
        log "        ✓ marketing pack ready in $BOOK_DIR/marketing"
    else
        log "        ⚠️  Marketing pack incomplete — read the messages above"
    fi
else
    log "⏭️  [5/5] Marketing pack skipped (pass --marketing to build it)"
fi

DURATION=$(( $(date +%s) - START_EPOCH ))
{
    echo ""
    echo "**Finished:** $(date '+%Y-%m-%d %H:%M:%S') (${DURATION}s)"
    echo "**Chapters written:** $WRITTEN/$ACTUAL_CHAPTERS · **revision rounds:** $REVISED_TOTAL"
    echo "**Compilation:** $COMPILED"
    echo ""
    echo "Per-chapter critiques are saved next to the chapters as \`critique_chapter_NN.md\`."
} >> "$REPORT_FILE"

log ""
log "✅ Agent run finished (${DURATION}s)"
log "   📁 $BOOK_DIR"
log "   📊 Report: agent_report.md"
log "   📋 Critiques: critique_chapter_*.md"
exit 0
