#!/usr/bin/env bats

# Tests for scripts/image_gen.sh
#
# A local Python stub emulates Pollinations (GET) and the AUTOMATIC1111 API
# (POST) plus an OpenAI-compatible /images/generations endpoint, so the whole
# provider chain can be tested without a network or any API key.
# Run from the repository root:  bats tests/

setup_file() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export REPO_ROOT

    command -v convert >/dev/null 2>&1 || skip "imagemagick not installed"
    convert -size 400x640 gradient:'#123456-#89abcdef' "$BATS_FILE_TMPDIR/source.png"

    PORT=$(( 18100 + (RANDOM % 800) ))
    export PORT
    export IMAGE_STUB_LOG="$BATS_FILE_TMPDIR/stub_requests.log"
    : > "$IMAGE_STUB_LOG"

    python3 "$REPO_ROOT/tests/fixtures/image_stub_server.py" "$PORT" "$BATS_FILE_TMPDIR/source.png" \
        > "$BATS_FILE_TMPDIR/stub.out" 2>&1 &
    echo $! > "$BATS_FILE_TMPDIR/stub.pid"

    # wait for the stub to answer (max ~5s)
    for _ in $(seq 1 50); do
        curl -s -o /dev/null "http://127.0.0.1:$PORT/sdapi/v1/sd-models" && break
        sleep 0.1
    done
}

teardown_file() {
    if [ -f "$BATS_FILE_TMPDIR/stub.pid" ]; then
        kill "$(cat "$BATS_FILE_TMPDIR/stub.pid")" 2>/dev/null || true
    fi
}

# bats merges stderr into $output; discard it but keep the exit status
silenced() { "$@" 2>/dev/null; }

setup() {
    cd "$REPO_ROOT"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/image_gen.sh"
    : > "$IMAGE_STUB_LOG"

    # Point both free providers at the local stub
    export POLLINATIONS_BASE_URL="http://127.0.0.1:$PORT"
    export A1111_URL="http://127.0.0.1:$PORT"
    unset IMAGE_PROVIDER IMAGE_API_KEY IMAGE_API_BASE_URL IMAGE_MODEL 2>/dev/null || true
    unset OPENAI_API_KEY OPENAI_BASE_URL CUSTOM_API_KEY CUSTOM_API_BASE_URL POLLINATIONS_TOKEN 2>/dev/null || true
}

stub_calls() { wc -l < "$IMAGE_STUB_LOG" | tr -d ' '; }

@test "validate_image_file accepts real images and rejects non-images" {
    run validate_image_file "$BATS_FILE_TMPDIR/source.png"
    [ "$status" -eq 0 ]

    printf '<html><body>404</body></html>' > "$BATS_FILE_TMPDIR/error.html"
    run validate_image_file "$BATS_FILE_TMPDIR/error.html"
    [ "$status" -ne 0 ]

    : > "$BATS_FILE_TMPDIR/empty.png"
    run validate_image_file "$BATS_FILE_TMPDIR/empty.png"
    [ "$status" -ne 0 ]

    # too small to be a usable cover, even with a valid PNG header
    printf '\x89PNG\r\n\x1a\n' > "$BATS_FILE_TMPDIR/tiny.png"
    run validate_image_file "$BATS_FILE_TMPDIR/tiny.png"
    [ "$status" -ne 0 ]
}

@test "Pollinations provider downloads and validates an image" {
    out="$BATS_TEST_TMPDIR/cover.png"
    run silenced generate_image_pollinations "a quiet kitchen at dawn" "$out" 512 768
    [ "$status" -eq 0 ]
    run validate_image_file "$out"
    [ "$status" -eq 0 ]

    # the request must carry size, model and nologo, URL-encoded
    run grep -o 'width=512' "$IMAGE_STUB_LOG"
    [ "$status" -eq 0 ]
    run grep -o 'model=flux' "$IMAGE_STUB_LOG"
    [ "$status" -eq 0 ]
    run grep -o 'nologo=true' "$IMAGE_STUB_LOG"
    [ "$status" -eq 0 ]
    run grep -c 'a%20quiet%20kitchen' "$IMAGE_STUB_LOG"
    [ "$status" -eq 0 ]
}

@test "an HTML error page is never accepted as an image" {
    out="$BATS_TEST_TMPDIR/bad.png"
    run silenced generate_image_pollinations "FAILME please" "$out" 512 768
    [ "$status" -ne 0 ]
    [ ! -f "$out" ]
}

@test "local Stable Diffusion provider decodes the base64 image" {
    out="$BATS_TEST_TMPDIR/local.png"
    run silenced generate_image_a1111 "a tidy desk" "$out" 512 768
    [ "$status" -eq 0 ]
    run validate_image_file "$out"
    [ "$status" -eq 0 ]

    # request must be sane for SD: width/height multiples of 64, a negative prompt
    run grep -o '"width": 512' "$IMAGE_STUB_LOG"
    [ "$status" -eq 0 ]
    run grep -o 'negative_prompt' "$IMAGE_STUB_LOG"
    [ "$status" -eq 0 ]
}

@test "an empty A1111 response is a failure, not a blank cover" {
    out="$BATS_TEST_TMPDIR/empty-local.png"
    run silenced generate_image_a1111 "FAILME" "$out" 512 768
    [ "$status" -ne 0 ]
    [ ! -f "$out" ]
}

@test "auto chain falls through from a dead free provider to a working one" {
    export IMAGE_PROVIDER=auto
    export POLLINATIONS_BASE_URL="http://127.0.0.1:9"     # nothing listens here
    export A1111_URL="http://127.0.0.1:$PORT"            # stub is alive

    out="$BATS_TEST_TMPDIR/chain.png"
    run silenced generate_image "a warm kitchen" "$out" 512 768
    [ "$status" -eq 0 ]
    run validate_image_file "$out"
    [ "$status" -eq 0 ]

    # it must have ended up at the A1111 endpoint
    run grep -c 'txt2img' "$IMAGE_STUB_LOG"
    [ "$status" -eq 0 ]
}

@test "OpenAI-compatible images endpoint handles b64_json responses" {
    export IMAGE_PROVIDER=openai
    export IMAGE_API_BASE_URL="http://127.0.0.1:$PORT/v1"
    export IMAGE_API_KEY="test-key"
    export IMAGE_MODEL="stub-image-model"

    out="$BATS_TEST_TMPDIR/api.png"
    run silenced generate_image_openai "a tidy desk" "$out" 512 768
    [ "$status" -eq 0 ]
    run validate_image_file "$out"
    [ "$status" -eq 0 ]

    run grep -c '/v1/images/generations' "$IMAGE_STUB_LOG"
    [ "$status" -eq 0 ]
    run grep -o 'stub-image-model' "$IMAGE_STUB_LOG"
    [ "$status" -eq 0 ]
}

@test "IMAGE_PROVIDER=none disables image generation without touching the network" {
    export IMAGE_PROVIDER=none
    out="$BATS_TEST_TMPDIR/none.png"
    run silenced generate_image "anything" "$out" 512 768
    [ "$status" -ne 0 ]
    [ ! -f "$out" ]
    [ "$(stub_calls)" -eq 0 ]
}

@test "cover prompt asks for no text and reserves space for the typography" {
    run build_cover_prompt "The Quiet Kitchen" "Cooking Notes for Tired People"
    [ "$status" -eq 0 ]
    [[ "$output" == *"The Quiet Kitchen"* ]]
    [[ "$output" == *"no text"* ]]
    [[ "$output" == *"no watermark"* ]]
}

@test "generate_ai_cover composes art plus typography at cover dimensions" {
    out="$BATS_TEST_TMPDIR/generated_cover.png"
    run silenced generate_ai_cover "The Quiet Kitchen" "Cooking Notes" "Test Author" "$out" 1000 1600
    [ "$status" -eq 0 ]
    [ -f "$out" ]

    run identify -format "%wx%h" "$out"
    [ "$output" = "1000x1600" ]

    # the raw art must not be left behind
    [ ! -f "${out%.*}_art.png" ]
}

@test "generate_ai_cover reports failure instead of writing a broken cover" {
    export POLLINATIONS_BASE_URL="http://127.0.0.1:9"
    export A1111_URL="http://127.0.0.1:9"
    export IMAGE_PROVIDER=auto

    out="$BATS_TEST_TMPDIR/no_cover.png"
    run silenced generate_ai_cover "Title" "Sub" "Author" "$out" 800 1200
    [ "$status" -ne 0 ]
    [ ! -f "$out" ]
}

@test "compile_book.sh --illustrate embeds one image per chapter" {
    command -v pandoc || skip "pandoc not installed"

    book="$BATS_TEST_TMPDIR/illus-book"
    mkdir -p "$book"
    cat > "$book/outline.md" <<'EOF'
# The Quiet Kitchen

### Chapter 1: Six Staples
### Chapter 2: Eat Twice
EOF
    printf '# Chapter 1: Six Staples\n\nOlive oil and salt.\n' > "$book/chapter_01.md"
    printf '# Chapter 2: Eat Twice\n\nCook once.\n' > "$book/chapter_02.md"

    export POLLINATIONS_BASE_URL="http://127.0.0.1:$PORT"
    export IMAGE_PROVIDER=auto

    run env POLLINATIONS_BASE_URL="http://127.0.0.1:$PORT" IMAGE_PROVIDER=auto \
        "$REPO_ROOT/scripts/compile_book.sh" "$book" markdown 1 \
        --author "Test Author" --illustrate
    [ "$status" -eq 0 ]

    exports_dir=$(ls -d "$book"/exports_* | head -1)
    [ -f "$exports_dir/illustration_01.png" ]
    [ -f "$exports_dir/illustration_02.png" ]

    manuscript=$(ls "$exports_dir"/manuscript_*.md | grep -v _epub | head -1)
    run grep -c 'illustration_01.png\|illustration_02.png' "$manuscript"
    [ "$output" -ge 2 ]

    # the illustration sits after the chapter title, before the prose
    run bash -c "awk '/^# Chapter 1/{c=1} c && /illustration_01.png/{print \"after\"; exit}' '$manuscript'"
    [ "$output" = "after" ]
}

@test "generate_book.sh documents and forwards the image flags" {
    run "$REPO_ROOT/scripts/generate_book.sh" --help
    [[ "$output" == *"--images"* ]]
    [[ "$output" == *"--illustrate"* ]]
    [[ "$output" == *"--image-provider"* ]]

    run grep -c -- 'COMPILE_OPTS+=(--illustrate)' "$REPO_ROOT/scripts/generate_book.sh"
    [ "$output" = "1" ]
    run grep -c -- 'COMPILE_OPTS+=(--generate-cover)' "$REPO_ROOT/scripts/generate_book.sh"
    [ "$output" = "1" ]
}

@test "compile_book.sh warns instead of dying when the image provider is unreachable" {
    book="$BATS_TEST_TMPDIR/dead-provider-book"
    mkdir -p "$book"
    cat > "$book/outline.md" <<'EOF'
# Offline Book

### Chapter 1: One
EOF
    printf '# Chapter 1: One\n\nBody.\n' > "$book/chapter_01.md"

    run env POLLINATIONS_BASE_URL="http://127.0.0.1:9" IMAGE_PROVIDER=pollinations \
        "$REPO_ROOT/scripts/compile_book.sh" "$book" markdown 1 \
        --author "Test Author" --illustrate
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not be generated"* ]]

    exports_dir=$(ls -d "$book"/exports_* | head -1)
    [ ! -f "$exports_dir/illustration_01.png" ]
    manuscript=$(ls "$exports_dir"/manuscript_*.md | grep -v _epub | head -1)
    run grep -c 'illustration_01.png' "$manuscript"
    [ "$output" = "0" ] || [ -z "$output" ]
}
