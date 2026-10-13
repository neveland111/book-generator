#!/usr/bin/env bash
#
# generate_marketing_copy.sh — the "publishing" step: turn a finished book
# folder into a KDP-ready marketing pack.
#
# Produces, inside <book_dir>/marketing/:
#   description.html   the 4,000-character KDP description, ready to paste
#   description.txt    same copy with the HTML stripped (blogs, email, blurbs)
#   keywords.txt       exactly 7 keyword phrases, one per line, <= 50 chars each
#   categories.md      3 suggested Amazon browse categories with their path
#   social_copy.md     short blurbs for social posts and a launch email
#   kdp_listing.md     everything in one sheet, with the validation report
#
# The rules encoded here come from KDP itself:
#   - description: 4,000 characters maximum, and HTML tags count toward it
#   - description: no unicode emojis, no keyword/tag stuffing, no spoilers
#   - keywords:    7 fields, 50 characters each, phrases not single words
#   - categories:  up to 3, chosen through Amazon's browse selector
#
# `--check` re-validates an existing marketing/ folder without calling any AI,
# so it works offline and can run in CI.
#
# Usage:
#   ./scripts/generate_marketing_copy.sh [book_dir] [options]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd)"

# ── KDP limits ────────────────────────────────────────────────────────────────
KDP_DESC_LIMIT=4000
KDP_DESC_TARGET=3200        # aim below the limit so HTML tags never push it over
KDP_KEYWORD_LIMIT=50
KDP_KEYWORD_SLOTS=7
KDP_CATEGORY_SLOTS=3

# ── Options ───────────────────────────────────────────────────────────────────
# The book directory is positional and may appear anywhere; flags start with -.
BOOK_DIR=""

QUIET=false
CHECK_ONLY=false
GEN_DESCRIPTION=true
GEN_KEYWORDS=true
GEN_CATEGORIES=true
GEN_SOCIAL=true
STYLE="${MARKETING_STYLE:-clear and confident, warm but not gushy}"
TONE="${MARKETING_TONE:-}"

mc_log()  { [ "$QUIET" = false ] && echo "$@" >&2 || true; }
mc_warn() { echo "⚠️  $*" >&2; }
mc_err()  { echo "❌ $*" >&2; }
mc_die()  { echo "❌ Error: $*" >&2; exit 1; }

show_help() {
    cat <<EOF
generate_marketing_copy.sh — build a KDP-ready marketing pack from a book folder

USAGE:
    $0 [book_dir] [options]

ARGUMENTS:
    book_dir          Directory holding outline.md and chapter_*.md
                      (Optional: auto-detects the newest book it can find)

WHAT IT WRITES:
    <book_dir>/marketing/description.html    KDP description (<= 4000 chars incl. tags)
    <book_dir>/marketing/description.txt     Same copy, HTML stripped
    <book_dir>/marketing/keywords.txt        7 keyword phrases, <= 50 chars each
    <book_dir>/marketing/categories.md       3 suggested browse categories
    <book_dir>/marketing/social_copy.md      Social blurbs + launch email
    <book_dir>/marketing/kdp_listing.md      All of it in one sheet + validation

OPTIONS:
    --check              Validate an existing marketing/ folder. No AI, no network.
    --skip-description   Do not (re)generate the description
    --skip-keywords      Do not (re)generate keywords
    --skip-categories    Do not (re)generate categories
    --skip-social        Do not (re)generate social copy
    --style "TEXT"       Copy style  (default: "$STYLE")
    --tone "TEXT"        Copy tone   (default: derived from the book)
    --provider NAME      auto|gemini|ollama|groq|anthropic|openai|custom
    --quiet              Only errors

EXAMPLES:
    $0 ./v3/my-book
    $0 ./v3/my-book --check
    $0 ./v3/my-book --skip-social

The rules encoded here are KDP's own: 4000 characters including HTML tags, no
emojis, 7 keyword fields of 50 characters, 3 categories.
EOF
}

mc_parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --check)             CHECK_ONLY=true;            shift ;;
            --skip-description)  GEN_DESCRIPTION=false;      shift ;;
            --skip-keywords)     GEN_KEYWORDS=false;         shift ;;
            --skip-categories)   GEN_CATEGORIES=false;       shift ;;
            --skip-social)       GEN_SOCIAL=false;           shift ;;
            --style)             STYLE="${2:-$STYLE}";       shift 2 ;;
            --tone)              TONE="${2:-}";              shift 2 ;;
            --provider)          export SMART_API_PROVIDER="${2:-auto}"; shift 2 ;;
            --quiet)             QUIET=true;                 shift ;;
            --help|-h)           MARKETING_SHOW_HELP=true;   shift ;;
            -*)                  mc_err "Unknown option: $1"; MARKETING_SHOW_HELP=true; shift ;;
            *)                   if [ -z "$BOOK_DIR" ]; then BOOK_DIR="$1"; fi; shift ;;
        esac
    done
    [ "${MARKETING_SHOW_HELP:-false}" = true ] && { show_help; exit 0; }
    return 0
}

# ── AI layer (optional: --check never needs it) ───────────────────────────────
mc_load_ai_layer() {
MC_AI_AVAILABLE=false
if [ "$CHECK_ONLY" = false ]; then
    if [ -f "$SCRIPT_DIR/multi_provider_ai_simple.sh" ]; then
        # shellcheck source=/dev/null
        . "$SCRIPT_DIR/multi_provider_ai_simple.sh" >/dev/null 2>&1 || true
        if declare -F smart_api_call >/dev/null 2>&1; then
            MC_AI_AVAILABLE=true
        fi
    fi
    [ "$MC_AI_AVAILABLE" = false ] && mc_die "multi_provider_ai_simple.sh (smart_api_call) not found next to this script"
fi
return 0
}

# ── Small helpers ─────────────────────────────────────────────────────────────

# Character count (not bytes) — KDP counts characters.
mc_len() {
    local text="$1"
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$text" | python3 -c 'import sys; print(len(sys.stdin.read()))' 2>/dev/null && return 0
    fi
    printf '%s' "$text" | wc -m | tr -d ' '
}

mc_file_len() {
    local file="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8", errors="replace").read()))' "$file" 2>/dev/null && return 0
    fi
    wc -m < "$file" | tr -d ' '
}

mc_has_python() { command -v python3 >/dev/null 2>&1; }

# `grep -c` prints 0 *and* exits 1 when nothing matches, so `|| echo 0` would
# yield "0\n0" and break every numeric comparison. Normalise it here.
mc_count_lines() {
    local file="$1" n=""
    [ -f "$file" ] || { printf '0'; return 0; }
    n=$(grep -c . "$file" 2>/dev/null) || true
    printf '%s' "${n:-0}" | head -1
}

# Remove emojis and other pictographs, which KDP rejects outright.
# python3 -> perl -> loud warning (never silently ship an emoji).
mc_strip_emoji() {
    if mc_has_python; then
        # -c, not a heredoc: the copy arrives on stdin, and a heredoc would
        # consume stdin as the program text.
        python3 -c "
import re, sys
data = sys.stdin.read()
pattern = re.compile(
    \"[\"
    \"\\U0001F000-\\U0001FAFF\"   # pictographs, emoticons, transport
    \"\\U00002600-\\U000027BF\"   # misc symbols + dingbats
    \"\\U00002B00-\\U00002BFF\"   # more arrows/symbols
    \"\\U00002190-\\U000021FF\"   # arrows
    \"\\U0000FE00-\\U0000FE0F\"   # variation selectors
    \"\\U0001F1E6-\\U0001F1FF\"   # regional indicators (flags)
    \"]+\"
)
cleaned = pattern.sub(\"\", data)
# removing an emoji can leave a double space behind
cleaned = re.sub(r\"[ ]{2,}\", \" \", cleaned)
sys.stdout.write(cleaned)
"
    elif command -v perl >/dev/null 2>&1; then
        perl -CSD -pe 's/[\x{1F000}-\x{1FAFF}\x{2600}-\x{27BF}\x{2B00}-\x{2BFF}\x{FE0F}\x{1F1E6}-\x{1F1FF}]+//g'
    else
        mc_warn "Neither python3 nor perl is available: emoji removal skipped. Check the description manually — KDP rejects unicode emojis."
        cat
    fi
}

# Keep only the HTML tags KDP accepts, drop every attribute, and leave the text
# itself untouched. Anything unknown is unwrapped (tag removed, content kept).
mc_clean_description_html() {
    if mc_has_python; then
        python3 -c "
import re, sys

ALLOWED = {\"b\", \"strong\", \"i\", \"em\", \"u\", \"br\", \"p\", \"ul\", \"ol\", \"li\",
           \"h4\", \"h5\", \"h6\", \"blockquote\"}

html = sys.stdin.read()

# Scripts and styles never belong in a book description.
html = re.sub(r\"(?is)<(script|style)\\b.*?</\\1>\", \"\", html)

def fix_tag(match):
    slash, name = match.group(1), match.group(2).lower()
    if name not in ALLOWED:
        return \"\"                 # unwrap the tag, keep the text inside
    if name == \"br\":
        return \"<br>\"
    return \"<\" + slash + name + \">\"

html = re.sub(r\"(?i)<(/?)\\s*([a-z0-9]+)(?:\\s[^>]*)?/?>\", fix_tag, html)

# KDP wants real line breaks; two <br> for a paragraph gap is the safe encoding.
html = re.sub(r\"(?i)(<br>\\s*){3,}\", \"<br><br>\", html)
html = re.sub(r\"[ \\t]+\\n\", \"\\n\", html)
html = re.sub(r\"\\n{3,}\", \"\\n\\n\", html)
sys.stdout.write(html.strip() + \"\\n\")
"
    else
        # No python3: at least drop the tags that could break the field.
        sed -e 's/<[Ss][Cc][Rr][Ii][Pp][Tt][^>]*>.*<\/[Ss][Cc][Rr][Ii][Pp][Tt]>//g' \
            -e 's/<[Ss][Tt][Yy][Ll][Ee][^>]*>.*<\/[Ss][Tt][Yy][Ll][Ee]>//g' \
            -e 's/<[Aa][^>]*>//g' -e 's/<\/[Aa]>//g'
    fi
}

# Trim HTML to a character budget, preferring to cut at a paragraph or sentence
# boundary. Only used when the model will not respect the budget.
mc_trim_description() {
    local limit="$1"
    if mc_has_python; then
        python3 -c '
import re, sys
limit = int(sys.argv[1])
html = sys.stdin.read()
if len(html) <= limit:
    sys.stdout.write(html)
    raise SystemExit
window = html[:limit]
for boundary in ("</p>", "</li>", "</ul>", "</ol>", ". ", "! ", "? ", "<br>"):
    cut = window.rfind(boundary)
    if cut > limit * 0.5:
        cut += len(boundary)
        sys.stdout.write(window[:cut].rstrip())
        raise SystemExit
sys.stdout.write(window.rstrip())
' "$limit"
    else
        head -c "$limit"
    fi
}

# Strip every tag: the plain-text twin of the description.
mc_strip_tags() {
    if mc_has_python; then
        python3 -c '
import re, sys, html as h
data = sys.stdin.read()
data = re.sub(r"(?i)<br\s*/?>", "\n", data)
data = re.sub(r"(?i)</(p|li|ul|ol|h[4-6]|blockquote)>", "\n", data)
data = re.sub(r"<[^>]+>", "", data)
data = h.unescape(data)
data = re.sub(r"[ \t]+", " ", data)
data = re.sub(r"\n{3,}", "\n\n", data)
sys.stdout.write(data.strip() + "\n")
'
    else
        sed -e 's/<[^>]*>//g'
    fi
}

# ── Book context ──────────────────────────────────────────────────────────────

mc_find_book_dir() {
    local base candidate
    if [ -n "$BOOK_DIR" ]; then
        [ -d "$BOOK_DIR" ] || mc_die "Directory '$BOOK_DIR' not found"
        return 0
    fi
    for base in "$SCRIPT_DIR/book_outputs" "$SCRIPT_DIR/v3" "$SCRIPT_DIR/v2" "$SCRIPT_DIR/v1"; do
        [ -d "$base" ] || continue
        # Newest first. `stat` is spelled differently on BSD and GNU, and
        # `xargs -r` (used elsewhere in this repo) does not exist on macOS, so
        # sort explicitly instead.
        local ordered
        ordered=$(find "$base" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | while IFS= read -r d; do
            [ -n "$d" ] || continue
            printf '%s\t%s\n' "$(stat -f %m "$d" 2>/dev/null || stat -c %Y "$d" 2>/dev/null || echo 0)" "$d"
        done | sort -rn | cut -f2-)
        [ -n "$ordered" ] || continue
        while IFS= read -r candidate; do
            [ -n "$candidate" ] || continue
            if [ -f "$candidate/outline.md" ] || compgen -G "$candidate/chapter_*.md" >/dev/null 2>&1; then
                BOOK_DIR="$candidate"
                mc_log "🔍 No book directory given, using the newest one: $(basename "$BOOK_DIR")"
                return 0
            fi
        done <<< "$ordered"
    done
    mc_die "No book directory given and none found under book_outputs/, v3/, v2/ or v1/"
}

# metadata.yaml (written by compile_book.sh) wins; otherwise read the outline.
mc_meta_value() {
    local key="$1" file meta
    for meta in "$BOOK_DIR"/exports_*/metadata.yaml; do
        [ -f "$meta" ] || continue
        local value
        value=$(grep -iE "^[[:space:]]*${key}:" "$meta" 2>/dev/null | head -1 | sed -E 's/^[^:]+:[[:space:]]*//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')
        [ -n "$value" ] && { printf '%s' "$value"; return 0; }
    done
    file="$BOOK_DIR/outline.md"
    [ -f "$file" ] || return 1
    case "$key" in
        title)    grep -m1 -E '^#[[:space:]]+' "$file" | sed -E 's/^#[[:space:]]+//; s/[[:space:]]*\{[^}]*\}[[:space:]]*$//' ;;
        subtitle) grep -m1 -E '^##[[:space:]]+' "$file" | sed -E 's/^##[[:space:]]+//; s/[[:space:]]*\{[^}]*\}[[:space:]]*$//' ;;
        author)   printf '%s' "${AUTHOR_PEN_NAME:-}" ;;
    esac
}

mc_chapter_list() {
    local outline="$BOOK_DIR/outline.md"
    [ -f "$outline" ] || return 1
    grep -E '^[[:space:]]*(#+[[:space:]]*)?[*_> -]*[[:space:]]*[*_]*[Cc]hapter[[:space:]]+[0-9]+' "$outline" \
        | sed -E 's/^[[:space:]]*#*[[:space:]]*//; s/^\*+//; s/^[[:space:]]*//' | sort -u -t' ' -k2,2n
}

# A compact digest of the book: everything the copywriter AI needs to know,
# small enough to keep the prompt (and the bill) reasonable.
mc_build_digest() {
    local title subtitle author digest chapter_count excerpt
    title="$(mc_meta_value title || true)"
    subtitle="$(mc_meta_value subtitle || true)"
    author="$(mc_meta_value author || true)"

    digest="TITLE: ${title:-unknown}"
    [ -n "$subtitle" ] && digest+=$'\n'"SUBTITLE: $subtitle"
    [ -n "$author" ] && digest+=$'\n'"AUTHOR: $author"

    chapter_count=$(ls "$BOOK_DIR"/chapter_*.md 2>/dev/null | wc -l | tr -d ' ')
    digest+=$'\n'"CHAPTERS: ${chapter_count:-0}"

    if [ -n "${GENRE:-}" ]; then
        digest+=$'\n'"GENRE: $GENRE"
    fi
    if [ -n "${TARGET_AUDIENCE:-}" ]; then
        digest+=$'\n'"AUDIENCE: $TARGET_AUDIENCE"
    fi

    local chapters
    chapters="$(mc_chapter_list || true)"
    [ -n "$chapters" ] && digest+=$'\n\n'$'CHAPTER LIST:\n'"$chapters"

    # First ~150 words of each of the first three chapters: enough voice to match.
    local file n
    n=0
    for file in $(ls "$BOOK_DIR"/chapter_*.md 2>/dev/null | head -3); do
        n=$((n + 1))
        excerpt=$(sed -E '/^#/d; /^[[:space:]]*$/d' "$file" | tr '\n' ' ' | cut -c1-700)
        digest+=$'\n\n'"EXCERPT FROM CHAPTER $n: $excerpt"
    done

    # Any hand-written author bio is gold for the About-the-Author blurb.
    if [ -f "$BOOK_DIR/author_bio.md" ]; then
        digest+=$'\n\n'"AUTHOR BIO (author-supplied): $(head -c 600 "$BOOK_DIR/author_bio.md" | tr '\n' ' ')"
    fi

    printf '%s' "$digest"
}

# ── AI wrapper ────────────────────────────────────────────────────────────────

mc_ai() {  # mc_ai <prompt> <system> <temperature> <max_tokens> [retries]
    local prompt="$1" system="$2" temp="${3:-0.7}" tokens="${4:-4000}" retries="${5:-2}"
    local out
    if ! out=$(smart_api_call "$prompt" "$system" "marketing" "$temp" "$tokens" "$retries" "" 2>/dev/null); then
        return 1
    fi
    # An empty or whitespace-only answer is a failure, not copy.
    [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ] || return 1
    printf '%s\n' "$out"
}

DESCRIPTION_SYSTEM='You are a book marketing copywriter who writes Amazon KDP listing copy that converts browsers into buyers. You write in the language of the book itself. You output only the requested copy: no preamble, no explanation, no commentary, no code fences, no markdown headings. You never use emojis. You never mention that a book was AI-assisted.'

KEYWORDS_SYSTEM='You are an Amazon KDP metadata specialist. You understand that KDP gives seven backend keyword fields of up to 50 characters each, that each field should hold a reader search phrase rather than a single word, that commas waste characters, and that words already in the title are indexed already and should not be repeated. You output only the requested lines and nothing else.'

CATEGORIES_SYSTEM='You are an Amazon KDP categories specialist. You know the browse category tree and how to pick near-empty, winnable categories rather than crowded top-level ones. In The Amazon KDP interface only three categories can be chosen, and they should match how readers actually browse. You output only the requested lines and nothing else.'

SOCIAL_SYSTEM='You are a book publicist writing short launch copy. You write punchy, concrete lines with no emojis, no hashtag spam and no hype clichés. You output only the requested sections.'

# ── Validators (shared by generation and --check) ─────────────────────────────

MC_PROBLEMS=()      # hard failures
MC_WARNINGS=()      # advisory

mc_reset_findings() { MC_PROBLEMS=(); MC_WARNINGS=(); }
mc_problem() { MC_PROBLEMS+=("$1"); }
mc_warning() { MC_WARNINGS+=("$1"); }

mc_validate_description() {
    local file="$1"
    [ -f "$file" ] || { mc_problem "description file is missing: $(basename "$file")"; return 1; }

    local chars near_limit
    chars=$(mc_file_len "$file")
    [ -z "$chars" ] && chars=0
    near_limit=$((KDP_DESC_LIMIT - 200))
    if [ "$chars" -gt "$KDP_DESC_LIMIT" ]; then
        mc_problem "description is $chars characters — KDP's limit is $KDP_DESC_LIMIT (HTML tags count)"
    elif [ "$chars" -gt "$near_limit" ]; then
        mc_warning "description is $chars characters, within 200 of the $KDP_DESC_LIMIT limit"
    fi
    if [ "$chars" -lt 600 ]; then
        mc_warning "description is only $chars characters — Amazon listings usually do better above 1,500"
    fi

    # Emojis / pictographs are rejected by KDP. Counted with python3 when
    # available because BSD grep has no -P.
    local found_emoji=0
    if mc_has_python; then
        found_emoji=$(python3 -c '
import re, sys
data = open(sys.argv[1], encoding="utf-8", errors="replace").read()
print(len(re.findall(r"[\U0001F000-\U0001FAFF\U00002600-\U000027BF\U0000FE0F]", data)))
' "$file" 2>/dev/null) || found_emoji=0
    else
        found_emoji=$(LC_ALL=C grep -c $'[\xf0\x9f]' "$file" 2>/dev/null) || found_emoji=0
    fi
    [ -n "$found_emoji" ] || found_emoji=0
    if [ "$found_emoji" -gt 0 ]; then
        mc_problem "description contains emoji or pictographs, which KDP rejects"
    fi

    # Unknown tags: KDP only accepts a small HTML subset.
    local bad_tags
    bad_tags=$(grep -oE '<[a-zA-Z/][^>]*>' "$file" 2>/dev/null \
        | sed -E 's/<(\/?)([a-zA-Z0-9]+).*/\2/' | tr 'A-Z' 'a-z' | tr -d '/' \
        | grep -vE '^(b|strong|i|em|u|br|p|ul|ol|li|h4|h5|h6|blockquote)$' | sort -u | tr '\n' ' ')
    if [ -n "$(printf '%s' "$bad_tags" | tr -d ' ')" ]; then
        mc_problem "description uses tags KDP does not accept: $bad_tags"
    fi

    # Keyword stuffing: the description must not read like a tag list.
    local keyword_file="$MARKETING_DIR/keywords.txt"
    if [ -f "$keyword_file" ]; then
        local phrase stuffed=""
        while IFS= read -r phrase; do
            [ -n "$phrase" ] || continue
            local hits
            hits=$(grep -oiF "$phrase" "$file" 2>/dev/null | wc -l | tr -d ' ') || true
            [ -z "$hits" ] && hits=0
            [ "${hits:-0}" -ge 3 ] && stuffed+="\"$phrase\" ${hits}x "
        done < "$keyword_file"
        [ -n "$stuffed" ] && mc_warning "possible keyword stuffing, repeated 3+ times: $stuffed"
    fi

    return 0
}

# Significant words for the duplicate check: lowercase, >= 4 chars, no stopwords.
mc_significant_words() {
    local text="$1"
    printf '%s' "$text" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '\n' \
        | grep -E '^[a-z0-9]{4,}$' \
        | grep -vxE 'the|and|for|with|your|you|book|guide|that|this|from|are|was|were|will|can|all|more|than|then|when|what|who|why|not|but|how|into|their|them|they|have|has|had|out|about|over|most|some|very|just|like|make|made|also|been|being|does|each|other|only|such|take|these|those|through|under|while|would|every|after|before|between|untuk|yang|dan|atau|dengan|dari|pada|ini|itu|akan|bisa|juga|saja|lebih|agar|saat|sudah|belum|tidak|bukan|oleh|dalam|adalah|karena|supaya|secara|para|anda|kita|mereka|serta|tanpa|serta|bagi|hanya|masih|telah|sedang|mudah|untuk' \
        | sort -u
}

mc_validate_keywords() {
    local file="$1"
    [ -f "$file" ] || { mc_problem "keywords file is missing: $(basename "$file")"; return 1; }

    local -a slots=()
    while IFS= read -r line; do
        [ -n "$(printf '%s' "$line" | tr -d '[:space:]')" ] || continue
        slots+=("$line")
    done < "$file"

    local count="${#slots[@]}"
    if [ "$count" -ne "$KDP_KEYWORD_SLOTS" ]; then
        mc_problem "keywords file has $count entries — KDP gives exactly $KDP_KEYWORD_SLOTS fields"
    fi

    local i=0 line len
    for line in "${slots[@]}"; do
        i=$((i + 1))
        len=$(mc_len "$line")
        if [ "$len" -gt "$KDP_KEYWORD_LIMIT" ]; then
            mc_problem "keyword $i is $len characters — the limit is $KDP_KEYWORD_LIMIT: \"$line\""
        fi
        if [ "$len" -lt 12 ]; then
            mc_warning "keyword $i is only $len characters (\"$line\") — a phrase uses the 50 characters better than one word"
        fi
        case "$line" in
            *,*) mc_warning "keyword $i contains a comma, which wastes a character KDP would otherwise index" ;;
        esac
        # Amazon already indexes the title; repeating it burns a whole field.
        local title
        title="$(mc_meta_value title || true)"
        if [ -n "$title" ]; then
            local title_word
            for title_word in $(mc_significant_words "$title"); do
                case " $(printf '%s' "$line" | tr 'A-Z' 'a-z') " in
                    *" $title_word "*) mc_warning "keyword $i repeats \"$title_word\" from the title, which Amazon indexes already" ;;
                esac
            done
        fi
    done

    # Words repeated across fields are ignored by Amazon, so they waste space.
    local seen="" word field_no=0
    declare -A WORD_FIELD=()
    i=0
    for line in "${slots[@]}"; do
        i=$((i + 1))
        for word in $(mc_significant_words "$line"); do
            if [ -n "${WORD_FIELD[$word]:-}" ] && [ "${WORD_FIELD[$word]}" != "$i" ]; then
                mc_warning "\"$word\" appears in keyword fields ${WORD_FIELD[$word]} and $i — Amazon indexes a repeated word once"
            else
                WORD_FIELD[$word]="$i"
            fi
        done
    done
    unset WORD_FIELD

    return 0
}

mc_validate_categories() {
    local file="$1"
    [ -f "$file" ] || { mc_problem "categories file is missing: $(basename "$file")"; return 1; }
    local count
    count=$(grep -cE '^[[:space:]]*[0-9]+[.)]|^[[:space:]]*[-*]' "$file" 2>/dev/null) || true
    [ -z "$count" ] && count=0
    # plain paths with no bullet or number still count as categories
    if [ "$count" -eq 0 ]; then
        count=$(mc_count_lines "$file")
    fi
    if [ "$count" -lt "$KDP_CATEGORY_SLOTS" ]; then
        local noun="categories"
        [ "$count" -eq 1 ] && noun="category"
        mc_warning "only $count $noun found — KDP allows up to $KDP_CATEGORY_SLOTS; fill all of them"
    fi
    if ! grep -qE '>' "$file"; then
        mc_warning "categories have no browse path (e.g. \"Books > Cookbooks > Quick & Easy\") — a path is easier to apply in KDP"
    fi
    return 0
}

mc_report_findings() {
    local ok=true
    if [ "${#MC_PROBLEMS[@]}" -gt 0 ]; then
        ok=false
        echo "❌ Problems that would block the KDP upload:"
        local problem
        for problem in "${MC_PROBLEMS[@]}"; do echo "   • $problem"; done
    fi
    if [ "${#MC_WARNINGS[@]}" -gt 0 ]; then
        echo "⚠️  Suggestions:"
        local warning
        for warning in "${MC_WARNINGS[@]}"; do echo "   • $warning"; done
    fi
    [ "$ok" = true ]
}

# ── Generators ────────────────────────────────────────────────────────────────

mc_gen_description() {
    local digest="$1" out="$MARKETING_DIR/description.html" attempt raw chars
    local tone_line=""
    [ -n "$TONE" ] && tone_line="Tone: $TONE"

    mc_log "✍️  Writing the KDP description..."

    for attempt in 1 2; do
        local budget=$KDP_DESC_TARGET
        [ "$attempt" -eq 2 ] && budget=$((KDP_DESC_TARGET - 900))

        local prompt
        prompt=$(cat <<EOF
Write the Amazon KDP book description for the book below.

BOOK:
$digest

REQUIREMENTS
- Language: the same language the book is written in.
- Length: between 1,500 and $budget characters INCLUDING the HTML tags. This is a hard limit: KDP cuts the field off at $KDP_DESC_LIMIT characters.
- Format: HTML, using only these tags: <p>, <b>, <i>, <br>, <ul>, <li>, <h4>, <h5>. No <a>, no <div>, no <span>, no inline styles, no markdown, no emojis.
- Structure, in this order:
  1. A hook of one or two short sentences that names the reader's problem or desire.
  2. One or two paragraphs of what the book delivers, in the book's own voice.
  3. A short <ul> of 3 to 5 concrete things the reader gets, each <li> one line.
  4. A closing line telling the reader what to do (read the first chapter, start tonight, ...).
- Write benefit-led copy, not a table of contents.
- Never mention AI, prompts, models or automated writing.
- Do not stuff keywords: each important phrase appears once or twice, never three times.
- No spoilers, no price, no review quotes, no emojis.

Style: $STYLE
$tone_line

Output only the HTML description.
EOF
)

        if ! raw=$(mc_ai "$prompt" "$DESCRIPTION_SYSTEM" 0.7 3000 2); then
            mc_warn "The AI provider did not return a description (attempt $attempt/2)"
            continue
        fi

        # Clean it the same way every time: emojis out, tags whitelisted.
        printf '%s\n' "$raw" | mc_strip_emoji | mc_clean_description_html > "$out"

        chars=$(mc_file_len "$out")
        if [ "$chars" -gt "$KDP_DESC_LIMIT" ]; then
            mc_warn "Description came back at $chars characters (limit $KDP_DESC_LIMIT) — trimming to fit"
            local trimmed
            trimmed=$(mc_trim_description "$((KDP_DESC_LIMIT - 20))" < "$out")
            printf '%s\n' "$trimmed" | mc_clean_description_html > "$out"
            chars=$(mc_file_len "$out")
            [ "$chars" -gt "$KDP_DESC_LIMIT" ] && mc_die "Could not fit the description into $KDP_DESC_LIMIT characters"
            mc_warn "Description was trimmed — skim the end before uploading"
            mc_strip_tags < "$out" > "$MARKETING_DIR/description.txt"
            return 0
        fi

        mc_log "   ✅ description: $chars characters (limit $KDP_DESC_LIMIT)"
        mc_strip_tags < "$out" > "$MARKETING_DIR/description.txt"
        return 0
    done

    mc_warn "Skipped the description — no provider answered"
    return 1
}

mc_gen_keywords() {
    local digest="$1" out="$MARKETING_DIR/keywords.txt" attempt raw
    mc_log "🔍 Choosing the 7 keyword fields..."

    for attempt in 1 2; do
        local feedback=""
        if [ "$attempt" -eq 2 ] && [ -f "$out" ]; then
            feedback=$'\n'"Your previous answer broke a rule: $(mc_first_problem). Fix it and answer again."
        fi

        local prompt
        prompt=$(cat <<EOF
Choose the content for all seven Amazon KDP backend keyword fields for the book below.

BOOK:
$digest

RULES
- Output exactly 7 lines. Nothing else: no numbering, no bullets, no explanations, no blank lines.
- Each line is one reader search phrase of at most 50 characters, including spaces.
- Do not use commas. Separate ideas within a field with spaces only.
- Use the whole field: aim for 40 to 50 characters per line.
- Each line targets a different kind of search intent. No two lines should contain the same significant word.
- Never repeat a word that already appears in the book title or subtitle: Amazon indexes those already.
- Never use another author's name, a brand, or a competitor's book title.
- Write the phrases in the language the book is written in.
- Phrases readers would actually type into Amazon, not internal jargon.$feedback

Output only the 7 lines, best field first.
EOF
)

        if ! raw=$(mc_ai "$prompt" "$KEYWORDS_SYSTEM" 0.4 700 2); then
            mc_warn "The AI provider did not return keywords (attempt $attempt/2)"
            continue
        fi

        # Normalise: strip numbering/bullets/quotes/commas, trim, cap at 50 chars.
        printf '%s\n' "$raw" | tr -d '\r' \
            | sed -E 's/^[[:space:]]*[-*•]+[[:space:]]*//; s/^[[:space:]]*[0-9]+[.)][[:space:]]*//; s/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//; s/,/ /g; s/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//' \
            | grep -vE '^$' > "$out.candidates"

        # Cap each line at the KDP limit without cutting a word in half.
        : > "$out"
        while IFS= read -r candidate; do
            [ "${#out}" -ge 0 ] || true
            if [ "$(mc_len "$candidate")" -gt "$KDP_KEYWORD_LIMIT" ]; then
                candidate=$(printf '%s' "$candidate" | cut -c1-$KDP_KEYWORD_LIMIT)
                candidate=$(printf '%s' "$candidate" | sed -E 's/[[:space:]]*[^[:space:]]*$//')
            fi
            [ -n "$candidate" ] && printf '%s\n' "$candidate" >> "$out"
        done < "$out.candidates"
        rm -f "$out.candidates"

        # De-duplicate: identical fields are pure waste. Order is preserved
        # because the prompt asks for the most important phrase first; sorting
        # here would silently throw that ranking away.
        if [ -s "$out" ]; then
            awk '!seen[tolower($0)]++ { print }' "$out" > "$out.dedup" && mv "$out.dedup" "$out"
        fi

        local count
        count=$(mc_count_lines "$out")
        if [ "$count" -ge "$KDP_KEYWORD_SLOTS" ]; then
            head -n "$KDP_KEYWORD_SLOTS" "$out" > "$out.final" && mv "$out.final" "$out"
            mc_log "   ✅ keywords: $(mc_count_lines "$out") fields, longest $(mc_longest_line "$out") characters"
            return 0
        fi
        mc_warn "Only $count usable keywords came back (need $KDP_KEYWORD_SLOTS) — retrying"
    done

    if [ -s "$out" ]; then
        mc_warn "Using the $(mc_count_lines "$out") usable keywords returned; extend the list by hand"
        return 0
    fi
    mc_warn "Skipped keywords — no provider answered"
    return 1
}

mc_first_problem() {
    [ "${#MC_PROBLEMS[@]}" -gt 0 ] && printf '%s' "${MC_PROBLEMS[0]}" || printf 'a rule was broken'
}

mc_longest_line() {
    local file="$1" line longest=0
    while IFS= read -r line; do
        local len
        len=$(mc_len "$line")
        [ "$len" -gt "$longest" ] && longest=$len
    done < "$file"
    printf '%s' "$longest"
}

mc_gen_categories() {
    local digest="$1" out="$MARKETING_DIR/categories.md"
    mc_log "🗂️  Suggesting the 3 Amazon browse categories..."

    local prompt
    prompt=$(cat <<EOF
Choose the three best Amazon KDP browse categories for the book below.

BOOK:
$digest

RULES
- Output exactly 3 lines. Nothing else: no numbering, no bullets, no commentary.
- Each line is one full browse path, from the top level down, separated by " > ".
- Prefer deep, specific, winnable categories over crowded top-level ones.
- The three must not be near-duplicates of each other.

Example line format:
Books > Cookbooks, Food & Wine > Quick & Easy

Output only the 3 lines.
EOF
)

    if ! mc_ai "$prompt" "$CATEGORIES_SYSTEM" 0.3 400 2 | tr -d '\r' \
            | sed -E 's/^[[:space:]]*[-*•0-9.)]+[[:space:]]*//; s/[[:space:]]+$//' \
            | grep -vE '^$' | head -n "$KDP_CATEGORY_SLOTS" > "$out"; then
        mc_warn "Skipped categories — no provider answered"
        return 1
    fi
    [ -s "$out" ] || { mc_warn "Skipped categories — provider returned nothing usable"; return 1; }
    mc_log "   ✅ categories: $(grep -c . "$out") paths"
    return 0
}

mc_gen_social() {
    local digest="$1" out="$MARKETING_DIR/social_copy.md"
    mc_log "📣 Writing social blurbs and the launch email..."

    local prompt
    prompt=$(cat <<EOF
Write the launch copy for the book below.

BOOK:
$digest

Output exactly these sections, each introduced by its heading line exactly as written:

## Blurb 30
One line, at most 200 characters, for a quick social post. No emojis.

## Blurb 100
Two or three sentences, at most 600 characters, for an Instagram or LinkedIn post.

## Post thread
Three short paragraphs separated by blank lines, each on its own idea: the problem, what the book changes, and who should read it. At most 900 characters in total.

## Launch email
A short email: a subject line beginning with "Subject: ", then 4 to 6 sentences telling a reader why to buy now. At most 1,200 characters.

## About the author
Two sentences for the Amazon author page, written in the third person. If the author bio below is given, use it as the source of facts and invent nothing beyond it.

Rules: no emojis, no hashtags beyond one per post, no fake urgency, no invented reviews, no claims about bestseller status, never mention AI.
Style: $STYLE
EOF
)

    if ! mc_ai "$prompt" "$SOCIAL_SYSTEM" 0.8 2000 2 | mc_strip_emoji > "$out"; then
        mc_warn "Skipped social copy — no provider answered"
        return 1
    fi
    [ -s "$out" ] || { mc_warn "Skipped social copy — provider returned nothing usable"; return 1; }
    mc_log "   ✅ social copy written"
    return 0
}

# ── The listing sheet ─────────────────────────────────────────────────────────

mc_write_listing() {
    local out="$MARKETING_DIR/kdp_listing.md"
    local title subtitle author desc_chars
    title="$(mc_meta_value title || true)"
    subtitle="$(mc_meta_value subtitle || true)"
    author="$(mc_meta_value author || true)"
    desc_chars=$(mc_file_len "$MARKETING_DIR/description.html" 2>/dev/null || echo 0)

    {
        echo "# KDP listing sheet — ${title:-Untitled}"
        echo
        echo "Generated from \`$BOOK_DIR\` on $(date +'%Y-%m-%d %H:%M')."
        echo
        echo "## Fields to fill on KDP"
        echo
        echo "| Field | Value |"
        echo "|---|---|"
        echo "| Title | ${title:-(not found)} |"
        echo "| Subtitle | ${subtitle:-(none)} |"
        echo "| Author | ${author:-${AUTHOR_PEN_NAME:-(not set — add --author when compiling)}} |"
        echo "| Description length | ${desc_chars} / ${KDP_DESC_LIMIT} characters |"
        echo
        echo "## Description"
        echo
        echo "Copy the block below into the KDP description field (the Source/HTML view)."
        echo
        echo '```html'
        cat "$MARKETING_DIR/description.html" 2>/dev/null || echo "(missing)"
        echo '```'
        echo
        echo "Plain-text version for blogs, email and press: \`marketing/description.txt\`."
        echo
        echo "## Keywords (7 fields, 50 characters each)"
        echo
        echo "| # | Keyword | Characters |"
        echo "|---|---|---|"
        local i=0 line
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            i=$((i + 1))
            echo "| $i | $line | $(mc_len "$line") |"
        done < "$MARKETING_DIR/keywords.txt" 2>/dev/null
        echo
        echo "Order matters: put the phrase you most want to rank for in field 1."
        echo
        echo "## Categories"
        echo
        cat "$MARKETING_DIR/categories.md" 2>/dev/null || echo "(missing)"
        echo
        echo "Enable these in KDP's category selector — it accepts up to $KDP_CATEGORY_SLOTS."
        echo
        echo "## Validation"
        echo
        if [ "${#MC_PROBLEMS[@]}" -eq 0 ]; then
            echo "- ✅ Every field fits KDP's limits."
        else
            local problem
            for problem in "${MC_PROBLEMS[@]}"; do echo "- ❌ $problem"; done
        fi
        if [ "${#MC_WARNINGS[@]}" -gt 0 ]; then
            local warning
            for warning in "${MC_WARNINGS[@]}"; do echo "- ⚠️ $warning"; done
        fi
        echo
        echo "## Social and email copy"
        echo
        echo "See \`marketing/social_copy.md\`."
    } > "$out"
}

# ── Checklist ─────────────────────────────────────────────────────────────────

mc_check() {
    mc_reset_findings
    echo "🔎 Validating $MARKETING_DIR"
    echo

    [ -d "$MARKETING_DIR" ] || mc_die "No marketing/ folder in $BOOK_DIR — run this script without --check first"

    mc_validate_description "$MARKETING_DIR/description.html"
    mc_validate_keywords "$MARKETING_DIR/keywords.txt"
    mc_validate_categories "$MARKETING_DIR/categories.md"

    local desc_chars kw_count
    desc_chars=$(mc_file_len "$MARKETING_DIR/description.html" 2>/dev/null || echo 0)
    kw_count=$(mc_count_lines "$MARKETING_DIR/keywords.txt")
    echo "   📄 description: ${desc_chars} / ${KDP_DESC_LIMIT} characters"
    echo "   🔑 keywords:    ${kw_count} / ${KDP_KEYWORD_SLOTS} fields"
    echo "   🗂️  categories:  $(mc_count_lines "$MARKETING_DIR/categories.md") / ${KDP_CATEGORY_SLOTS} paths"
    echo

    if mc_report_findings; then
        echo "✅ This listing is ready to paste into KDP."
        return 0
    fi
    echo
    echo "Fix the ❌ items above and run --check again."
    return 1
}

# ── Main ──────────────────────────────────────────────────────────────────────

mc_main() {
mc_find_book_dir
MARKETING_DIR="$BOOK_DIR/marketing"

if [ "$CHECK_ONLY" = true ]; then
    mc_check
    exit $?
fi

mc_load_ai_layer
mkdir -p "$MARKETING_DIR"
mc_log "📣 Marketing pack for: $(basename "$BOOK_DIR")"
mc_log "   Output: $MARKETING_DIR"
mc_log ""

DIGEST="$(mc_build_digest)"
if [ -z "$DIGEST" ]; then
    mc_die "Could not read the book: no outline.md and no chapter_*.md in $BOOK_DIR"
fi

generated=0
[ "$GEN_DESCRIPTION" = true ] && { mc_gen_description "$DIGEST" && generated=$((generated + 1)); true; }
[ "$GEN_KEYWORDS" = true ]    && { mc_gen_keywords "$DIGEST"    && generated=$((generated + 1)); true; }
[ "$GEN_CATEGORIES" = true ]  && { mc_gen_categories "$DIGEST"  && generated=$((generated + 1)); true; }
[ "$GEN_SOCIAL" = true ]      && { mc_gen_social "$DIGEST"      && generated=$((generated + 1)); true; }

# Validate whatever now exists, and put the report in the listing sheet.
mc_reset_findings
mc_validate_description "$MARKETING_DIR/description.html"
mc_validate_keywords "$MARKETING_DIR/keywords.txt"
mc_validate_categories "$MARKETING_DIR/categories.md"
mc_write_listing

echo "" >&2
echo "📋 KDP listing sheet: $MARKETING_DIR/kdp_listing.md" >&2
mc_report_findings || true

if [ "$generated" -eq 0 ]; then
    mc_err "Nothing could be generated — check the AI provider (./scripts/multi_provider_ai_simple.sh status)"
    exit 1
fi
exit 0
}

# Run only when executed directly: this file is also sourced by the test suite.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    mc_parse_args "$@"
    mc_main
fi
