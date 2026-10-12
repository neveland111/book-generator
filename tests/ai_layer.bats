#!/usr/bin/env bats

# Tests for the AI layer in scripts/multi_provider_ai_simple.sh
#
# Every test replaces `curl` with a bash function, so the whole provider
# pipeline runs offline against canned model output. This is how the
# prompt/response handling bugs were found and fixed, and it keeps them fixed.
# Run from the repository root:  bats tests/

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export REPO_ROOT
    cd "$REPO_ROOT"

    REPLY_FILE="$BATS_TEST_TMPDIR/reply.json"
    CALL_LOG="$BATS_TEST_TMPDIR/calls.log"
    PAYLOAD_FILE="$BATS_TEST_TMPDIR/payload.json"
    INPUT_FILE="$BATS_TEST_TMPDIR/sample_input.txt"
    export REPLY_FILE CALL_LOG PAYLOAD_FILE INPUT_FILE
    : > "$CALL_LOG"

    export GEMINI_API_KEY="test-key"
    unset SMART_API_PROVIDER 2>/dev/null || true
    unset GROQ_API_KEY 2>/dev/null || true

    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/multi_provider_ai_simple.sh" >/dev/null 2>&1

    # Canned reply + recorded call. `curl` is only ever called through the
    # fake below for the duration of a test.
    curl() {
        local body=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -d) body="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        echo "CALLED" >> "$CALL_LOG"
        [ -n "$body" ] && printf '%s' "$body" > "$PAYLOAD_FILE"
        cat "$REPLY_FILE" 2>/dev/null || true
    }
}

# bats merges stderr into $output, so progress/warning lines would pollute the
# assertions below. This runs a command with stderr discarded but keeps the
# exit status.
silenced() { "$@" 2>/dev/null; }

gemini_reply() {  # $1 = text the fake model returns
    printf '%s' "$1" | jq -Rs '{candidates:[{content:{parts:[{text:.}]}}]}' > "$REPLY_FILE"
}

groq_reply() {
    printf '%s' "$1" | jq -Rs '{choices:[{message:{content:.}}]}' > "$REPLY_FILE"
}

clean_input_file() { clean_ai_response < "$INPUT_FILE"; }

@test "clean_ai_response strips chat wrapper but keeps real content" {
    cat > "$INPUT_FILE" <<'EOT'
Sure! Here is the chapter you asked for:

```markdown
# Chapter 1: Title

Real prose.

## A Section

More prose.
```

Word count: 412

I hope this helps! Let me know if you need changes.
EOT

    run silenced clean_input_file
    [ "$status" -eq 0 ]
    [[ "$output" == *"Real prose."* ]]
    [[ "$output" == *"## A Section"* ]]
    [[ "$output" != *"Sure!"* ]]
    [[ "$output" != *'```'* ]]
    [[ "$output" != *"Word count"* ]]
    [[ "$output" != *"I hope this helps"* ]]
    # the duplicated chapter heading is dropped (the pipeline adds its own)
    [[ "$output" != *"# Chapter 1"* ]]
}

@test "clean_ai_response keeps code blocks inside technical chapters" {
    cat > "$INPUT_FILE" <<'EOT'
## Installing the Toolchain

Run this:

```bash
brew install pandoc imagemagick jq
```

Done.
EOT

    run silenced clean_input_file
    [ "$status" -eq 0 ]
    [[ "$output" == *'```bash'* ]]
    [[ "$output" == *"brew install pandoc imagemagick jq"* ]]
    [[ "$output" == *"## Installing the Toolchain"* ]]
}

@test "Gemini requests carry the system prompt as systemInstruction" {
    curl() {
        local body=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -d) body="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        printf '%s' "$body" > "$PAYLOAD_FILE"
        printf '%s' '{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}'
    }

    run silenced smart_api_call "USER-TEXT" "SYSTEM-TEXT-MUST-TRAVEL" "general" 0.7 150 1
    [ "$status" -eq 0 ]
    [ "$output" = "ok" ]

    run jq -r '.systemInstruction.parts[0].text' "$PAYLOAD_FILE"
    [ "$output" = "SYSTEM-TEXT-MUST-TRAVEL" ]

    run jq -r '.contents[0].parts[0].text' "$PAYLOAD_FILE"
    [ "$output" = "USER-TEXT" ]

    run jq -r '.generationConfig.maxOutputTokens' "$PAYLOAD_FILE"
    [ "$output" = "150" ]
}

@test "Ollama requests use num_predict, not the ignored max_tokens key" {
    curl() {
        local body=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -d) body="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        if [ -n "$body" ]; then
            printf '%s' "$body" > "$PAYLOAD_FILE"
            printf '%s' '{"response":"# Chapter 1: T\n\nBody text."}'
        else
            printf '%s' '{"models":[]}'      # /api/tags connectivity probe
        fi
    }

    run silenced call_ollama_api "prompt" "system" "general" 0.7 1234 1 "llama3:8b"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Body text."* ]]

    run jq -r '.options.num_predict' "$PAYLOAD_FILE"
    [ "$output" = "1234" ]

    run jq -r '.options.max_tokens // "absent"' "$PAYLOAD_FILE"
    [ "$output" = "absent" ]
}

@test "empty or whitespace-only provider output is not a success" {
    : > "$REPLY_FILE"
    run silenced call_gemini_api "prompt" "system" 0.7 100
    [ "$status" -ne 0 ]
    [ -z "$output" ]

    printf '%s' '{"error":{"message":"model not found"}}' > "$REPLY_FILE"
    run silenced call_gemini_api "prompt" "system" 0.7 100
    [ "$status" -ne 0 ]

    printf '%s' '{"response":"   "}' > "$REPLY_FILE"
    run silenced call_ollama_api "prompt" "system" "general" 0.7 100 1 "llama3:8b"
    [ "$status" -ne 0 ]
}

@test "SMART_API_PROVIDER pins the provider" {
    gemini_reply "SHOULD-NOT-BE-USED"

    # provider=groq without a key must not fall back to Gemini
    export SMART_API_PROVIDER=groq
    run silenced smart_api_call "p" "s" "general" 0.7 100 1
    [ "$status" -ne 0 ]
    [ ! -s "$CALL_LOG" ]

    # provider=gemini must call the Gemini endpoint exactly once
    export SMART_API_PROVIDER=gemini
    run silenced smart_api_call "p" "s" "general" 0.7 100 1
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$CALL_LOG" | tr -d ' ')" -eq 1 ]
}

@test "plagiarism scores are parsed numerically" {
    chapter="$BATS_TEST_TMPDIR/chapter.md"
    echo "Some chapter text." > "$chapter"

    gemini_reply "ORIGINALITY: 9/10
CONCERNS: none"
    run silenced check_plagiarism_with_smart_api "$chapter"
    [ "$status" -eq 0 ]

    gemini_reply "ORIGINALITY: 7/10
CONCERNS: one boilerplate paragraph"
    run silenced check_plagiarism_with_smart_api "$chapter"
    [ "$status" -eq 1 ]

    # Regression: the old regex matched the '10' inside '3/10' and reported
    # full originality for a chapter that scored 3.
    gemini_reply "ORIGINALITY: 3/10
CONCERNS: copied paragraphs"
    run silenced check_plagiarism_with_smart_api "$chapter"
    [ "$status" -eq 2 ]

    gemini_reply "I would rate it 5 out of 10, and the word count of 10,000 is fine."
    run silenced check_plagiarism_with_smart_api "$chapter"
    [ "$status" -eq 2 ]
}

@test "a failed rewrite leaves the chapter file untouched" {
    chapter="$BATS_TEST_TMPDIR/chapter.md"
    printf 'Original chapter text.\n' > "$chapter"

    : > "$REPLY_FILE"          # provider returns nothing
    run silenced rewrite_chapter_with_smart_api "$chapter" ""
    [ "$status" -ne 0 ]
    run cat "$chapter"
    [ "$output" = "Original chapter text." ]
}

@test "outline chapter extraction tolerates markdown headings and de-duplicates" {
    outline="$BATS_TEST_TMPDIR/outline.md"
    cat > "$outline" <<'EOF'
# A Book
## A Subtitle

### Chapter 1: First Things
Summary one.

**Chapter 2 — Second Things**
Summary two.

- Chapter 3: Third Things
Summary three.

### Chapter 1: First Things
(repeated in a summary list at the bottom)
EOF

    # Extract the helper straight out of generate_book.sh so it can be tested alone
    sed -n '/^extract_outline_chapters() {/,/^}/p' scripts/generate_book.sh > "$BATS_TEST_TMPDIR/fn.sh"
    # shellcheck disable=SC1090
    source "$BATS_TEST_TMPDIR/fn.sh"

    run extract_outline_chapters "$outline" 10
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Chapter 1: First Things" ]
    [ "${lines[1]}" = "Chapter 2: Second Things" ]
    [ "${lines[2]}" = "Chapter 3: Third Things" ]
    [ "${#lines[@]}" -eq 3 ]

    run extract_outline_chapters "$outline" 2
    [ "${#lines[@]}" -eq 2 ]
}
