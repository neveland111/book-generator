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

@test "custom OpenAI-compatible endpoint is used with its own URL, key and model" {
    export CUSTOM_API_BASE_URL="https://openrouter.ai/api/v1"
    export CUSTOM_API_KEY="sk-or-test"
    export CUSTOM_MODEL="deepseek/deepseek-chat"
    unset OPENAI_API_KEY OPENAI_BASE_URL OPENAI_MODEL 2>/dev/null || true

    # capture the full curl invocation (URL + headers) and return a reply
    curl() {
        printf '%s\n' "$*" > "$BATS_TEST_TMPDIR/curl_args.txt"
        local body=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -d) body="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        printf '%s' "$body" > "$PAYLOAD_FILE"
        printf '%s' '{"choices":[{"message":{"content":"Custom endpoint text."}}]}'
    }

    run silenced call_custom_api "PROMPT" "SYSTEM" 0.7 1234
    [ "$status" -eq 0 ]
    [ "$output" = "Custom endpoint text." ]

    run cat "$BATS_TEST_TMPDIR/curl_args.txt"
    [[ "$output" == *"https://openrouter.ai/api/v1/chat/completions"* ]]
    [[ "$output" == *"Authorization: Bearer sk-or-test"* ]]

    run jq -r '.model' "$PAYLOAD_FILE"
    [ "$output" = "deepseek/deepseek-chat" ]
    run jq -r '.messages[0].role' "$PAYLOAD_FILE"
    [ "$output" = "system" ]
    run jq -r '.messages[1].content' "$PAYLOAD_FILE"
    [ "$output" = "PROMPT" ]
}

@test "a full chat/completions URL is not doubled up" {
    export CUSTOM_API_BASE_URL="http://localhost:1234/v1/chat/completions"
    export CUSTOM_API_KEY="not-needed"
    export CUSTOM_MODEL="local-model"

    curl() {
        printf '%s\n' "$*" > "$BATS_TEST_TMPDIR/curl_args.txt"
        printf '%s' '{"choices":[{"message":{"content":"Local text."}}]}'
    }

    run silenced call_custom_api "PROMPT" "SYSTEM" 0.7 100
    [ "$status" -eq 0 ]

    run cat "$BATS_TEST_TMPDIR/curl_args.txt"
    [[ "$output" == *"http://localhost:1234/v1/chat/completions"* ]]
    [[ "$output" != *"chat/completions/chat/completions"* ]]
}

@test "Anthropic requests use the messages format and x-api-key header" {
    export ANTHROPIC_API_KEY="sk-ant-test"
    export ANTHROPIC_MODEL="claude-sonnet-4-5"

    curl() {
        printf '%s\n' "$*" > "$BATS_TEST_TMPDIR/curl_args.txt"
        local body=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -d) body="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        printf '%s' "$body" > "$PAYLOAD_FILE"
        printf '%s' '{"content":[{"type":"text","text":"Claude text."}]}'
    }

    run silenced call_anthropic_api "PROMPT" "SYSTEM" 0.7 1000
    [ "$status" -eq 0 ]
    [ "$output" = "Claude text." ]

    run cat "$BATS_TEST_TMPDIR/curl_args.txt"
    [[ "$output" == *"https://api.anthropic.com/v1/messages"* ]]
    [[ "$output" == *"x-api-key: sk-ant-test"* ]]
    [[ "$output" == *"anthropic-version: 2023-06-01"* ]]

    run jq -r '.model' "$PAYLOAD_FILE"
    [ "$output" = "claude-sonnet-4-5" ]
    # Anthropic takes the system prompt as a top-level field, not as a message
    run jq -r '.system' "$PAYLOAD_FILE"
    [ "$output" = "SYSTEM" ]
    run jq -r '.messages | length' "$PAYLOAD_FILE"
    [ "$output" = "1" ]
    run jq -r '.max_tokens' "$PAYLOAD_FILE"
    [ "$output" = "1000" ]
}

@test "anthropic and custom can be pinned with SMART_API_PROVIDER" {
    export ANTHROPIC_API_KEY="sk-ant-test"
    curl() {
        printf '%s\n' "$*" >> "$CALL_LOG"
        printf '%s' '{"content":[{"type":"text","text":"pinned"}]}'
    }
    export SMART_API_PROVIDER=anthropic
    run silenced smart_api_call "p" "s" "general" 0.7 100 1
    [ "$status" -eq 0 ]
    [ "$output" = "pinned" ]
    run cat "$CALL_LOG"
    [[ "$output" == *"api.anthropic.com"* ]]

    # custom pinned without configuration must fail instead of silently using Gemini
    export SMART_API_PROVIDER=custom
    gemini_reply "SHOULD-NOT-BE-USED"
    run silenced smart_api_call "p" "s" "general" 0.7 100 1
    [ "$status" -ne 0 ]
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

@test ".env is loaded without overriding the existing environment" {
    dotenv="$BATS_TEST_TMPDIR/.env"
    cat > "$dotenv" <<'EOT'
# comment line
GEMINI_API_KEY=from-dotenv-file
CUSTOM_API_BASE_URL="https://example.test/v1"
  SPACED_KEY = spaced-value
export EXPORTED_KEY=exported-value
NOT A VALID LINE
EOT

    unset GEMINI_API_KEY CUSTOM_API_BASE_URL SPACED_KEY EXPORTED_KEY 2>/dev/null || true
    export GROQ_API_KEY="already-set-in-env"
    printf 'GROQ_API_KEY=should-not-win\n' >> "$dotenv"

    # Called directly (not via `run`) because the loader exports into the current
    # shell — bats runs `run` in a subshell, where those exports would vanish.
    load_dotenv_if_present "$dotenv" > "$BATS_TEST_TMPDIR/loader.out" 2>&1

    [ "$GEMINI_API_KEY" = "from-dotenv-file" ]
    [ "$CUSTOM_API_BASE_URL" = "https://example.test/v1" ]
    [ "$SPACED_KEY" = "spaced-value" ]
    [ "$EXPORTED_KEY" = "exported-value" ]
    # an explicit export in the environment must never be clobbered by the file
    [ "$GROQ_API_KEY" = "already-set-in-env" ]

    # the values themselves must not be echoed anywhere
    run cat "$BATS_TEST_TMPDIR/loader.out"
    [[ "$output" != *"from-dotenv-file"* ]]
    [[ "$output" == *"GEMINI_API_KEY"* ]]
}

@test "critique scores are parsed from the rubric report" {
    report="$BATS_TEST_TMPDIR/critique.md"
    printf 'CLARITY: 7\nSPECIFICITY: 5\nOVERALL: 6\nFIXES:\n- add examples\n' > "$report"
    run critique_overall_score "$report"
    [ "$output" = "6" ]

    printf 'Overall score: 9 out of 10\n' > "$report"
    run critique_overall_score "$report"
    [ "$output" = "9" ]

    printf 'no numeric verdict here\n' > "$report"
    run critique_overall_score "$report"
    [ -z "$output" ]
    [ "$status" -eq 0 ]
}

@test "score_below_threshold treats missing scores as needing revision" {
    run score_below_threshold 5 8;  [ "$status" -eq 0 ]   # 5 < 8  → revise
    run score_below_threshold 8 8;  [ "$status" -ne 0 ]   # 8 >= 8 → keep
    run score_below_threshold 9 8;  [ "$status" -ne 0 ]
    run score_below_threshold "" 8; [ "$status" -eq 0 ]   # unparseable → revise
    run score_below_threshold abc 8; [ "$status" -eq 0 ]
}

@test "a critique report is written for a chapter" {
    chapter="$BATS_TEST_TMPDIR/chapter_01.md"
    printf 'Some prose about a topic.\n' > "$chapter"
    printf '# Book\n### Chapter 1: One\n' > "$BATS_TEST_TMPDIR/outline.md"

    gemini_reply "CLARITY: 4
SPECIFICITY: 3
AUDIENCE FIT: 6
STRUCTURE: 5
ORIGINALITY: 6
OVERALL: 4
FIXES:
- add two concrete examples"

    run silenced critique_chapter_with_smart_api "$chapter" "$BATS_TEST_TMPDIR/outline.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OVERALL: 4"* ]]

    printf '%s' "$output" > "$BATS_TEST_TMPDIR/report.md"
    run critique_overall_score "$BATS_TEST_TMPDIR/report.md"
    [ "$output" = "4" ]
}

@test "revision rewrites a chapter from a critique and refuses to empty it" {
    chapter="$BATS_TEST_TMPDIR/chapter_02.md"
    printf 'Vague original prose.\n' > "$chapter"
    printf 'OVERALL: 4\nFIXES:\n- be specific\n' > "$BATS_TEST_TMPDIR/report.md"

    gemini_reply "Sharp revised prose with a concrete example."
    run silenced revise_chapter_with_report "$chapter" "$BATS_TEST_TMPDIR/report.md"
    [ "$status" -eq 0 ]
    run cat "$chapter"
    [ "$output" = "Sharp revised prose with a concrete example." ]

    # a failing provider must leave the existing chapter alone
    : > "$REPLY_FILE"
    run silenced revise_chapter_with_report "$chapter" "$BATS_TEST_TMPDIR/report.md"
    [ "$status" -ne 0 ]
    run cat "$chapter"
    [ "$output" = "Sharp revised prose with a concrete example." ]
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
    sed -n "/^extract_outline_chapters() {/,/^}/p" scripts/multi_provider_ai_simple.sh > "$BATS_TEST_TMPDIR/fn.sh"
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
