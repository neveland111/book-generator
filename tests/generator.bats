#!/usr/bin/env bats

# Tests for book-generator

@test "generate_book.sh exists and is executable" {
    [ -x "./scripts/generate_book.sh" ]
}

@test "pandoc is available" {
    command -v pandoc || skip "pandoc not installed"
}

@test "markdown files can be created" {
    temp_md=$(mktemp /tmp/test_XXXXXX.md)
    echo "# Test" > "$temp_md"
    [ -f "$temp_md" ]
    rm "$temp_md"
}

@test "output directory can be created" {
    temp_dir=$(mktemp -d)
    [ -d "$temp_dir" ]
    rmdir "$temp_dir"
}

@test "date command works for timestamps" {
    run date +%Y-%m-%d
    [ "$status" -eq 0 ]
}

@test "script has proper shebang" {
    head -1 scripts/generate_book.sh | grep -q "#!/bin/bash"
}

@test "required tools check" {
    command -v echo
    command -v cat
    command -v mkdir
}

# ── Regression tests for the compile stage ────────────────────────────────────

@test "generate_book.sh passes a version that compile_book.sh accepts" {
    # compile_book.sh only accepts integer versions 1|2|3 — a dotted "1.0"
    # used to abort the orchestrator's final compile step with an error.
    run grep -qE '"all"[[:space:]]+"[123]"' scripts/generate_book.sh
    [ "$status" -eq 0 ]

    run grep -qE '"all"[[:space:]]+"[0-9]+\.[0-9]+"' scripts/generate_book.sh
    [ "$status" -ne 0 ]
}

@test "compile_book.sh builds a manuscript and EPUB from a minimal book" {
    command -v pandoc || skip "pandoc not installed"

    tmp_dir=$(mktemp -d)
    book_dir="$tmp_dir/demo-book"
    mkdir -p "$book_dir"
    cat > "$book_dir/outline.md" <<'EOF'
# Test Book
## A Subtitle

### Chapter 1: First
### Chapter 2: Second
EOF
    printf '# Chapter 1: First\n\nBody one.\n' > "$book_dir/chapter_01.md"
    printf '# Chapter 2: Second\n\nBody two.\n' > "$book_dir/chapter_02.md"

    run ./scripts/compile_book.sh "$book_dir" epub 1 --author "Test Author"
    [ "$status" -eq 0 ]

    # Zero-padded chapter files must be picked up without warnings (the
    # generator writes chapter_01.md while compile used to look for chapter_1.md)
    [[ "$output" != *"Could not find any file for chapter"* ]]
    [[ "$output" == *"Found 2 chapters"* ]]

    run bash -c "ls \"$book_dir\"/exports_*/*.epub"
    [ "$status" -eq 0 ]

    rm -rf "$tmp_dir"
}

@test "compile_book.sh finds the outline in a directory named with 'final'" {
    command -v pandoc || skip "pandoc not installed"

    # Topics like "Final Cut" produce directory names containing 'final', which
    # used to make compile_book.sh reject the book's own outline.md.
    tmp_dir=$(mktemp -d)
    book_dir="$tmp_dir/20260101_the_final_cut"
    mkdir -p "$book_dir"
    cat > "$book_dir/outline.md" <<'EOF'
# The Final Cut

### Chapter 1: One
EOF
    printf '# Chapter 1: One\n\nBody.\n' > "$book_dir/chapter_01.md"

    run ./scripts/compile_book.sh "$book_dir" epub 1 --author "Test Author"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Using outline: outline.md"* ]]
    [[ "$output" != *"No outline file found"* ]]

    rm -rf "$tmp_dir"
}

@test "compiled manuscript has no hardcoded placeholder content" {
    command -v pandoc || skip "pandoc not installed"

    tmp_dir=$(mktemp -d)
    book_dir="$tmp_dir/demo-book"
    mkdir -p "$book_dir"
    cat > "$book_dir/outline.md" <<'EOF'
# Test Book

### Chapter 1: First
EOF
    printf '# Chapter 1: First\n\nBody one.\n' > "$book_dir/chapter_01.md"

    run ./scripts/compile_book.sh "$book_dir" epub 1 --author "Test Author"
    [ "$status" -eq 0 ]

    manuscript=$(ls "$book_dir"/manuscript_*.md | head -1)
    ! grep -q "Elara Morgan" "$manuscript"
    ! grep -q "^# References" "$manuscript"

    rm -rf "$tmp_dir"
}
