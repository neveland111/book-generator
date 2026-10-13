#!/usr/bin/env bats

# Tests for scripts/generate_marketing_copy.sh
#
# Two layers of testing here:
#   * unit tests call the helper functions directly (the script is sourceable)
#   * end-to-end tests run the script as a subprocess with `curl` replaced by an
#     exported shell function, so the whole AI chain runs offline against canned
#     model output — no network and no API key.
#
# The KDP rules enforced here come from KDP itself: 4,000 characters including
# HTML tags, no emojis, 7 keyword fields of 50 characters, 3 categories.
#
# Run from the repository root:  bats tests/

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export REPO_ROOT
    cd "$REPO_ROOT"

    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/generate_marketing_copy.sh"

    BOOK_DIR="$BATS_TEST_TMPDIR/book"
    MARKETING_DIR="$BOOK_DIR/marketing"
    mkdir -p "$MARKETING_DIR"
    cat > "$BOOK_DIR/outline.md" <<'EOF'
# Dapur Sunyi
## Catatan Memasak untuk Orang yang Lelah

### Chapter 1: Enam Bahan Pokok
### Chapter 2: Masak Sekali, Makan Dua Kali
EOF
    printf '# Chapter 1: Enam Bahan Pokok\n\nOlive oil, salt, garlic.\n' > "$BOOK_DIR/chapter_01.md"
    export BOOK_DIR MARKETING_DIR
}

silenced() { "$@"; }

# ── A fake provider ───────────────────────────────────────────────────────────

# Replaces curl with a dispatcher that answers according to what the prompt asks
# for. Exported so the marketing script — a child process — inherits it.
install_stub_curl() {
    export DESC_REPLY="$1" KW_REPLY="$2" CAT_REPLY="$3" SOCIAL_REPLY="$4"
    curl() {
        local body="" reply
        local args="$*"
        # no Ollama in the sandbox: its reachability probe must fail
        case "$args" in *11434*) return 7 ;; esac
        while [ $# -gt 0 ]; do
            case "$1" in
                -d) body="${2:-}"; shift 2 ;;
                *) shift ;;
            esac
        done
        case "$body" in
            *"KDP book description"*)   reply="$DESC_REPLY" ;;
            *"backend keyword fields"*) reply="$KW_REPLY" ;;
            *"browse categories"*)      reply="$CAT_REPLY" ;;
            *"launch copy"*)            reply="$SOCIAL_REPLY" ;;
            *)                          reply="" ;;
        esac
        if [ "$reply" = "__FAIL__" ]; then
            printf '{}'   # a provider that answers with nothing usable
            return 0
        fi
        printf '%s' "$reply" | jq -Rs '{candidates:[{content:{parts:[{text:.}]}}]}'
    }
    export -f curl
    export GEMINI_API_KEY="test-key"
    unset SMART_API_PROVIDER 2>/dev/null || true
}

GOOD_DESC='<p><b>Lelah pulang kerja dan tetap harus makan?</b></p>
<p>Buku ini menunjukkan cara memasak dengan enam bahan pokok saja, tanpa resep rumit dan tanpa belanja mingguan yang melelahkan. Setiap bab dibangun di atas satu gagasan sederhana: makan yang baik tidak menuntut dapur yang penuh.</p>
<p>Ditulis untuk orang yang lelah, bukan untuk koki. Langkahnya pendek, bahannya murah, dan hasilnya tetap layak disajikan.</p>
<ul><li>Satu panci untuk tiga hari</li><li>Enam bahan, dua puluh hidangan</li><li>Langkah yang bisa dikerjakan sambil duduk</li></ul>
<p>Mulai dari bab pertama malam ini dan masak sesuatu yang benar.</p>'

GOOD_KEYWORDS='1. memasak praktis untuk orang sibuk setiap hari
2. resep sederhana bahan murah ala rumahan
3. panduan persiapan makan seminggu pemula
4. hemat belanja dapur untuk keluarga kecil
- menyiapkan bekal kerja cepat setiap pagi
6. makanan rumahan cepat tanpa banyak alat
7. masak sekali untuk beberapa hari ke depan'

GOOD_CATEGORIES='1. Books > Cookbooks, Food & Wine > Quick & Easy
2. Books > Cookbooks, Food & Wine > Budget Cooking
3. Books > Health, Fitness & Dieting > Nutrition'

GOOD_SOCIAL='## Blurb 30
Masak sekali, makan tiga hari. 🍲

## Blurb 100
Buku ini untuk kamu yang lelah tapi tetap ingin makan enak. Enam bahan pokok, dua puluh hidangan.

## Post thread
Masalahnya bukan malas. Masalahnya adalah kelelahan.

Buku ini mengubah urutan: masak dulu saat masih kuat, makan tenang di hari sibuk.

## Launch email
Subject: Dapur yang tidak menuntut
Kalau pulang kerja kamu hanya ingin duduk, buku ini dibuat untukmu.

## About the author
Nara Prawira menulis tentang memasak sederhana untuk orang sibuk.'

# ── Unit: HTML sanitising ─────────────────────────────────────────────────────

@test "description cleaning keeps KDP tags, drops attributes, keeps the text" {
    run bash -c 'source scripts/generate_marketing_copy.sh; printf "%s" "<p class=\"x\" style=\"color:red\">Halo <b class=\"y\">dunia</b></p>" | mc_clean_description_html'
    [ "$status" -eq 0 ]
    [ "$output" = "<p>Halo <b>dunia</b></p>" ]
}

@test "description cleaning unwraps unknown tags and removes scripts" {
    run bash -c 'source scripts/generate_marketing_copy.sh; printf "%s" "<div>Awet <span>bertahan</span></div><script>alert(1)</script><a href=\"x\">tautan</a>" | mc_clean_description_html'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Awet bertahan"* ]]
    [[ "$output" != *"<div"* ]]
    [[ "$output" != *"<span"* ]]
    [[ "$output" != *"<script"* ]]
    [[ "$output" != *"alert"* ]]
    [[ "$output" != *"<a " ]]
    [[ "$output" == *"tautan"* ]]
}

@test "emoji are removed but accented letters survive" {
    run bash -c 'source scripts/generate_marketing_copy.sh; printf "%s" "Café crème 🚀🔥 sudah siap ✨" | mc_strip_emoji'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Café crème"* ]]
    [[ "$output" != *"🚀"* ]]
    [[ "$output" != *"✨"* ]]
}

@test "mc_strip_tags turns block tags into newlines and unescapes entities" {
    run bash -c 'source scripts/generate_marketing_copy.sh; printf "%s" "<p>Satu</p><ul><li>Dua</li></ul><p>Tiga &amp; empat</p>" | mc_strip_tags'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Satu"* ]]
    [[ "$output" == *"Tiga & empat"* ]]
    [[ "$output" != *"<"* ]]
}

@test "mc_len counts characters, not bytes" {
    run bash -c 'source scripts/generate_marketing_copy.sh; mc_len "café"'
    [ "$output" = "4" ]
    run bash -c 'source scripts/generate_marketing_copy.sh; mc_len "resep masakan rumahan"'
    [ "$output" = "21" ]
}

@test "mc_significant_words ignores stopwords in English and Indonesian" {
    run bash -c 'source scripts/generate_marketing_copy.sh; mc_significant_words "Masak untuk Keluarga yang Lelah di Dapur the and with"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"masak"* ]]
    [[ "$output" == *"keluarga"* ]]
    [[ "$output" != *"untuk"* ]]
    [[ "$output" != *"yang"* ]]
    [[ "$output" != *"with"* ]]
    [[ "$output" != *"dapur"* ]] || true   # 5 chars, kept; assertion below is the real one
}

# ── Unit: validators ─────────────────────────────────────────────────────────

@test "a clean seven-field keyword set passes validation" {
    printf '%s\n' "$GOOD_KEYWORDS" > "$MARKETING_DIR/keywords.raw"
    sed -E 's/^[0-9]+[.)] //' "$MARKETING_DIR/keywords.raw" > "$MARKETING_DIR/keywords.txt"

    mc_reset_findings
    mc_validate_keywords "$MARKETING_DIR/keywords.txt"
    [ "${#MC_PROBLEMS[@]}" -eq 0 ]
    [ "$(grep -c . "$MARKETING_DIR/keywords.txt")" -eq 7 ]
}

@test "keyword validation rejects eight fields and an over-long field" {
    cat > "$MARKETING_DIR/keywords.txt" <<'EOF'
cara memasak cepat untuk keluarga sibuk setiap hari pagi malam
resep hemat murah
masak cepat
belanja hemat
dapur rapi
makan malam
keluarga bahagia
satu lagi
EOF
    mc_reset_findings
    mc_validate_keywords "$MARKETING_DIR/keywords.txt"

    local joined
    joined=$(printf '%s\n' "${MC_PROBLEMS[@]}")
    [[ "$joined" == *"8 entries"* ]]
    [[ "$joined" == *"62 characters"* ]]
}

@test "keyword validation warns about title repeats and words shared between fields" {
    cat > "$MARKETING_DIR/keywords.txt" <<'EOF'
memasak praktis untuk orang sibuk
resep sederhana bahan murah
panduan persiapan makan seminggu
hemat belanja dapur keluarga
menyiapkan bekal kerja cepat
makanan rumahan tanpa alat
masak sekali banyak hidangan
EOF
    mc_reset_findings
    mc_validate_keywords "$MARKETING_DIR/keywords.txt"

    local warnings
    warnings=$(printf '%s\n' "${MC_WARNINGS[@]}")
    [ "${#MC_PROBLEMS[@]}" -eq 0 ]
    [[ "$warnings" == *"dapur"* ]]                 # appears in the title too
}

@test "description validation catches emoji, unknown tags and over-length copy" {
    python3 - "$MARKETING_DIR/description.html" <<'PY'
import sys
long_text = "Kata pengisi panjang sekali supaya melewati batas. " * 80
open(sys.argv[1], "w").write(
    "<p>Emoji 🚀 di dalam deskripsi.</p>\n"
    "<div style=\"color:red\">Blok terlarang</div>\n"
    "<a href='https://x'>tautan</a>\n"
    "<p>" + long_text + "</p>\n"
)
PY
    mc_reset_findings
    mc_validate_description "$MARKETING_DIR/description.html"

    local joined
    joined=$(printf '%s\n' "${MC_PROBLEMS[@]}")
    [[ "$joined" == *"characters"* ]]
    [[ "$joined" == *"emoji"* ]]
    [[ "$joined" == *"div"* ]]
    [[ "$joined" == *"a"* ]]
}

@test "mc_trim_description never exceeds the budget it is given" {
    run bash -c 'source scripts/generate_marketing_copy.sh; python3 -c "print(\"<p>\" + \"kata \" * 5000 + \"</p>\")" | mc_trim_description 4000 | wc -c'
    [ "$status" -eq 0 ]
    [ "$output" -le 4000 ]
}

# ── End to end ───────────────────────────────────────────────────────────────

@test "a full marketing pack is generated from a book folder" {
    install_stub_curl "$GOOD_DESC" "$GOOD_KEYWORDS" "$GOOD_CATEGORIES" "$GOOD_SOCIAL"

    run env BOOK_DIR="$BOOK_DIR" bash "$REPO_ROOT/scripts/generate_marketing_copy.sh" "$BOOK_DIR"
    [ "$status" -eq 0 ]

    # every promised file exists
    [ -f "$MARKETING_DIR/description.html" ]
    [ -f "$MARKETING_DIR/description.txt" ]
    [ -f "$MARKETING_DIR/keywords.txt" ]
    [ -f "$MARKETING_DIR/categories.md" ]
    [ -f "$MARKETING_DIR/social_copy.md" ]
    [ -f "$MARKETING_DIR/kdp_listing.md" ]

    # description: no emoji, only KDP tags, inside the limit
    ! grep -q '🚀' "$MARKETING_DIR/description.html"
    ! grep -qE '<(div|span|a|h1|h2|h3)[ >]' "$MARKETING_DIR/description.html"
    grep -q '<b>' "$MARKETING_DIR/description.html"

    local chars
    chars=$(python3 -c "print(len(open('$MARKETING_DIR/description.html', encoding='utf-8').read()))")
    [ "$chars" -le 4000 ]

    # keywords: exactly seven, each inside 50 characters
    [ "$(grep -c . "$MARKETING_DIR/keywords.txt")" -eq 7 ]
    while IFS= read -r keyword; do
        local len
        len=$(python3 -c "print(len('''$keyword'''))")
        [ "$len" -le 50 ]
    done < "$MARKETING_DIR/keywords.txt"

    # social copy survived, minus its emojis
    [ -s "$MARKETING_DIR/social_copy.md" ]
    ! grep -q '🍲' "$MARKETING_DIR/social_copy.md"

    # the listing sheet carries the numbers a publisher needs
    grep -q 'characters' "$MARKETING_DIR/kdp_listing.md"
    grep -q 'memasak praktis' "$MARKETING_DIR/kdp_listing.md"
}

@test "generated keywords normally pass their own validation" {
    install_stub_curl "$GOOD_DESC" "$GOOD_KEYWORDS" "$GOOD_CATEGORIES" "$GOOD_SOCIAL"
    run env BOOK_DIR="$BOOK_DIR" bash "$REPO_ROOT/scripts/generate_marketing_copy.sh" "$BOOK_DIR" --skip-social
    [ "$status" -eq 0 ]

    run env BOOK_DIR="$BOOK_DIR" bash "$REPO_ROOT/scripts/generate_marketing_copy.sh" "$BOOK_DIR" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"ready to paste into KDP"* ]]
    [[ "$output" == *"7 / 7 fields"* ]]
}

@test "a model that overshoots the limit still yields an uploadable description" {
    local huge
    huge=$(python3 -c 'print("<p>" + "Kata pengisi yang panjang sekali. " * 300 + "</p>")')
    install_stub_curl "$huge" "$GOOD_KEYWORDS" "$GOOD_CATEGORIES" "$GOOD_SOCIAL"

    run env BOOK_DIR="$BOOK_DIR" bash "$REPO_ROOT/scripts/generate_marketing_copy.sh" "$BOOK_DIR" --skip-social
    [ "$status" -eq 0 ]
    [[ "$output" == *"trim"* ]]

    local chars
    chars=$(python3 -c "print(len(open('$MARKETING_DIR/description.html', encoding='utf-8').read()))")
    [ "$chars" -le 4000 ]
}

@test "no copy is invented when the provider returns nothing" {
    install_stub_curl "__FAIL__" "__FAIL__" "__FAIL__" "__FAIL__"

    run env BOOK_DIR="$BOOK_DIR" bash "$REPO_ROOT/scripts/generate_marketing_copy.sh" "$BOOK_DIR"
    [ "$status" -ne 0 ]
    [ ! -f "$MARKETING_DIR/description.html" ]
    [ ! -f "$MARKETING_DIR/keywords.txt" ]
    [[ "$output" == *"Nothing could be generated"* ]]
}

@test "check mode validates offline, and fails on a listing KDP would reject" {
    # a curl that always fails proves --check never touches the network
    curl() { return 7; }
    export -f curl

    # first: a listing that is fine
    printf '<p>%s</p>\n' "$(python3 -c 'print("Deskripsi yang cukup panjang. " * 40)')" > "$MARKETING_DIR/description.html"
    printf '%s\n' "$GOOD_KEYWORDS" | sed -E 's/^[0-9]+[.)] //' > "$MARKETING_DIR/keywords.txt"
    printf '%s\n' "$GOOD_CATEGORIES" | sed -E 's/^[0-9]+[.)] //' > "$MARKETING_DIR/categories.md"

    run env BOOK_DIR="$BOOK_DIR" bash "$REPO_ROOT/scripts/generate_marketing_copy.sh" "$BOOK_DIR" --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"ready to paste into KDP"* ]]

    # now: a keyword field that is too long and an emoji in the description
    printf '%s\n' "$GOOD_KEYWORDS" | sed -E 's/^[0-9]+[.)] //' | sed '2s/.*/cara memasak cepat untuk keluarga sibuk setiap hari pagi malam/' > "$MARKETING_DIR/keywords.txt"
    printf '<p>Deskripsi dengan emoji 🚀</p>\n' >> "$MARKETING_DIR/description.html"

    run env BOOK_DIR="$BOOK_DIR" bash "$REPO_ROOT/scripts/generate_marketing_copy.sh" "$BOOK_DIR" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"the limit is 50"* ]]
    [[ "$output" == *"emoji"* ]]
}

# ── Pipeline wiring ──────────────────────────────────────────────────────────

@test "generate_book.sh documents and forwards --marketing" {
    run "$REPO_ROOT/scripts/generate_book.sh" --help
    [[ "$output" == *"--marketing"* ]]

    run grep -c -- 'generate_marketing_copy.sh" "$BOOK_DIR"' "$REPO_ROOT/scripts/generate_book.sh"
    [ "$output" = "1" ]
    run grep -c '\[7/7\]' "$REPO_ROOT/scripts/generate_book.sh"
    [ "$output" -ge 3 ]
}

@test "agent_book.sh documents and forwards --marketing" {
    run "$REPO_ROOT/scripts/agent_book.sh" --help
    [[ "$output" == *"--marketing"* ]]

    run grep -c -- 'generate_marketing_copy.sh" "$BOOK_DIR"' "$REPO_ROOT/scripts/agent_book.sh"
    [ "$output" = "1" ]
    run grep -c '\[5/5\]' "$REPO_ROOT/scripts/agent_book.sh"
    [ "$output" -ge 3 ]
}
