#!/bin/bash
# image_gen.sh — image generation for book covers and chapter illustrations
#
# Free-first provider chain (no API key needed to start):
#   1. pollinations — Pollinations.ai, free HTTP API, no key
#   2. a1111       — a local Stable Diffusion server (AUTOMATIC1111 / SD.Next)
#   3. openai      — any OpenAI-compatible /images/generations endpoint (paid)
#   4. none        — caller falls back to ImageMagick typography only
#
# Sourced by compile_book.sh, and usable standalone:
#   ./scripts/image_gen.sh test                         # probe providers
#   ./scripts/image_gen.sh cover "Title" "Subtitle" "Author" out.png
#   ./scripts/image_gen.sh illustration "a quiet kitchen at dawn" out.png
#
# Configuration (all optional):
#   IMAGE_PROVIDER        auto | pollinations | a1111 | openai | custom | none
#   POLLINATIONS_MODEL    default "flux"
#   POLLINATIONS_TOKEN    optional token for higher rate limits
#   POLLINATIONS_BASE_URL default https://image.pollinations.ai
#   A1111_URL             default http://localhost:7860
#   IMAGE_API_BASE_URL    paid endpoint base; falls back to CUSTOM_API_BASE_URL /
#                         OPENAI_BASE_URL, then https://api.openai.com/v1
#   IMAGE_API_KEY         falls back to CUSTOM_API_KEY / OPENAI_API_KEY
#   IMAGE_MODEL           default "gpt-image-1"
#   IMAGE_STYLE           art-direction suffix appended to every prompt

# ── Small helpers ────────────────────────────────────────────────────────────
IG_RED='\033[0;31m'; IG_GREEN='\033[0;32m'; IG_YELLOW='\033[1;33m'; IG_RESET='\033[0m'

ig_log()  { echo "$@" >&2; }
ig_warn() { echo -e "${IG_YELLOW}⚠️  $*${IG_RESET}" >&2; }

# URL-encode using jq (already a project dependency)
ig_urlencode() {
    printf '%s' "$1" | jq -sRr '@uri'
}

ig_base_url() {
    local base="${POLLINATIONS_BASE_URL:-https://image.pollinations.ai}"
    printf '%s' "${base%/}"
}

# ── Validation ───────────────────────────────────────────────────────────────
# Reject error pages, empty downloads and truncated files: only real image magic
# bytes with a plausible size are accepted. Without this, a 404 HTML page would
# be saved as cover.png and shipped inside the EPUB.
validate_image_file() {
    local file="$1"
    [ -s "$file" ] || return 1
    local size
    size=$(wc -c < "$file" | tr -d ' ')
    [ "$size" -ge 1024 ] || return 1

    local head_hex
    head_hex=$(head -c 12 "$file" | od -An -tx1 | tr -d ' \n')
    case "$head_hex" in
        89504e470d0a1a0a*) return 0 ;;            # PNG
        ffd8ff*)           return 0 ;;            # JPEG
        52494646*57454250*) return 0 ;;           # RIFF….WEBP
        47494638*)         return 0 ;;            # GIF87a/89a
        *) return 1 ;;
    esac
}

# ── Provider configuration ───────────────────────────────────────────────────
image_api_base_url() {
    printf '%s' "${IMAGE_API_BASE_URL:-${CUSTOM_API_BASE_URL:-${OPENAI_BASE_URL:-https://api.openai.com/v1}}}"
}

image_api_key() {
    printf '%s' "${IMAGE_API_KEY:-${CUSTOM_API_KEY:-${OPENAI_API_KEY:-}}}"
}

image_api_model() {
    printf '%s' "${IMAGE_MODEL:-${OPENAI_IMAGE_MODEL:-gpt-image-1}}"
}

a1111_base_url() {
    printf '%s' "${A1111_URL:-http://localhost:7860}"
}

a1111_reachable() {
    curl -s --max-time 2 -o /dev/null "$(a1111_base_url)/sdapi/v1/sd-models" 2>/dev/null
}

image_openai_configured() {
    [ -n "$(image_api_key)" ]
}

# Does this configuration look like it can produce an image right now?
# (pollinations/a1111 need no key, so "available" means "worth trying")
image_provider_order() {
    case "${IMAGE_PROVIDER:-auto}" in
        none)         echo "" ;;
        pollinations) echo "pollinations" ;;
        a1111)        echo "a1111" ;;
        openai|custom) echo "openai" ;;
        auto|*)
            # free first, paid only when explicitly configured
            local chain="pollinations"
            a1111_reachable && chain="$chain a1111"
            image_openai_configured && chain="$chain openai"
            echo "$chain"
            ;;
    esac
}

# ── Provider: Pollinations.ai (free, no key) ─────────────────────────────────
generate_image_pollinations() {
    local prompt="$1"
    local out="$2"
    local width="${3:-1024}"
    local height="${4:-1536}"

    local model="${POLLINATIONS_MODEL:-flux}"
    local encoded
    encoded=$(ig_urlencode "$prompt")

    local url="$(ig_base_url)/prompt/${encoded}?width=${width}&height=${height}&model=${model}&nologo=true"
    [ -n "${POLLINATIONS_TOKEN:-}" ] && url="${url}&token=${POLLINATIONS_TOKEN}"

    ig_log "   🎨 Pollinations (${model}, ${width}x${height})..."

    local attempt
    for attempt in 1 2; do
        # Pollinations generates on demand, so allow a generous timeout
        curl -s --max-time 180 -L "$url" -o "$out" || true
        if validate_image_file "$out"; then
            return 0
        fi
        rm -f "$out"
        [ "$attempt" -lt 2 ] && sleep 3
    done

    ig_warn "Pollinations did not return a usable image (free tier is rate limited — try again in a minute)"
    return 1
}

# ── Provider: local Stable Diffusion (AUTOMATIC1111 API) ─────────────────────
generate_image_a1111() {
    local prompt="$1"
    local out="$2"
    local width="${3:-1024}"
    local height="${4:-1536}"

    local base
    base=$(a1111_base_url)
    ig_log "   🖥️  Local Stable Diffusion at ${base} (${width}x${height})..."

    local negative="text, watermark, signature, logo, blurry, lowres, extra fingers, deformed"
    # SD checkpoints want ~512px steps; round to a multiple of 64
    local w=$(( width / 64 * 64 )) h=$(( height / 64 * 64 ))
    [ "$w" -lt 512 ] && w=512
    [ "$h" -lt 512 ] && h=512

    local payload
    payload=$(jq -n \
        --arg prompt "$prompt" \
        --arg negative "$negative" \
        --argjson w "$w" --argjson h "$h" \
        --argjson steps "${A1111_STEPS:-28}" \
        --arg sampler "${A1111_SAMPLER:-DPM++ 2M Karras}" \
        '{prompt: $prompt, negative_prompt: $negative, width: $w, height: $h,
          steps: $steps, sampler_name: $sampler, cfg_scale: 6.5}')

    local response
    response=$(curl -s --max-time 300 -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${base}/sdapi/v1/txt2img") || {
        ig_warn "Could not reach the local Stable Diffusion server at ${base}"
        return 1
    }

    # A1111 returns base64 PNG(s) in images[0]; anything else means failure
    if printf '%s' "$response" | jq -e '.images[0]' >/dev/null 2>&1; then
        if printf '%s' "$response" | jq -r '.images[0]' | base64 -d > "$out" 2>/dev/null \
                && validate_image_file "$out"; then
            return 0
        fi
        rm -f "$out"
    fi

    ig_warn "Local Stable Diffusion returned no usable image"
    return 1
}

# ── Provider: OpenAI-compatible /images/generations (paid) ───────────────────
generate_image_openai() {
    local prompt="$1"
    local out="$2"
    local width="${3:-1024}"
    local height="${4:-1536}"

    local key
    key=$(image_api_key)
    if [ -z "$key" ]; then
        ig_warn "No image API key (set IMAGE_API_KEY / OPENAI_API_KEY / CUSTOM_API_KEY)"
        return 1
    fi

    local base url
    base=$(image_api_base_url); base="${base%/}"
    case "$base" in
        */images/generations) url="$base" ;;
        *) url="$base/images/generations" ;;
    esac

    local model size
    model=$(image_api_model)
    size="${IMAGE_SIZE:-${width}x${height}}"
    ig_log "   🤖 ${model} at ${url} (${size})..."

    local payload
    payload=$(jq -n --arg model "$model" --arg prompt "$prompt" --arg size "$size" \
        '{model: $model, prompt: $prompt, n: 1, size: $size}')

    local response tmp_raw
    response=$(curl -s --max-time 300 -X POST \
        -H "Authorization: Bearer $key" \
        -H "Content-Type: application/json" \
        -d "$payload" "$url") || {
        ig_warn "Image API request failed (network)"
        return 1
    }

    # Endpoints differ: b64_json (OpenAI default), url (many gateways), or
    # data[0].b64_json (Together/Fireworks style). Handle all three.
    local b64
    b64=$(printf '%s' "$response" | jq -r '.data[0].b64_json // empty' 2>/dev/null)
    if [ -n "$b64" ]; then
        printf '%s' "$b64" | base64 -d > "$out" 2>/dev/null && validate_image_file "$out" && return 0
        rm -f "$out"
    fi

    local remote_url
    remote_url=$(printf '%s' "$response" | jq -r '.data[0].url // empty' 2>/dev/null)
    if [ -n "$remote_url" ]; then
        curl -s --max-time 180 -L "$remote_url" -o "$out" || true
        if validate_image_file "$out"; then
            return 0
        fi
        rm -f "$out"
    fi

    local err
    err=$(printf '%s' "$response" | jq -r '.error.message // .error // "unexpected response"' 2>/dev/null)
    ig_warn "Image API error ($model): $err"
    return 1
}

# ── Unified entry point ──────────────────────────────────────────────────────
# generate_image <prompt> <output file> [width] [height]
generate_image() {
    local prompt="$1"
    local out="$2"
    local width="${3:-1024}"
    local height="${4:-1536}"

    [ -z "$prompt" ] && { ig_warn "Empty image prompt"; return 1; }

    local providers
    providers=$(image_provider_order)
    if [ -z "$providers" ]; then
        ig_warn "Image generation disabled (IMAGE_PROVIDER=none)"
        return 1
    fi

    mkdir -p "$(dirname "$out")"
    local provider
    for provider in $providers; do
        case "$provider" in
            pollinations)
                generate_image_pollinations "$prompt" "$out" "$width" "$height" && return 0 ;;
            a1111)
                generate_image_a1111 "$prompt" "$out" "$width" "$height" && return 0 ;;
            openai)
                generate_image_openai "$prompt" "$out" "$width" "$height" && return 0 ;;
        esac
        ig_warn "Falling back to the next image provider..."
    done

    ig_warn "No image provider produced an image (tried: $providers)"
    return 1
}

# ── Prompt builders ──────────────────────────────────────────────────────────
# The model paints; ImageMagick sets the type. Asking a diffusion model for
# legible title text is still unreliable, so covers are composed in two steps.
build_cover_prompt() {
    local title="$1"
    local subtitle="$2"
    local style="${3:-${IMAGE_STYLE:-clean modern editorial illustration, muted palette, generous negative space}}"

    cat <<EOF
Book cover artwork for a book titled "${title}"${subtitle:+ (subtitle: "${subtitle}")}.
${style}.
Composition: single strong focal subject, vertical portrait framing, soft light.
IMPORTANT: absolutely no text, no words, no letters, no numerals, no typography,
no logos and no watermarks anywhere in the image — leave clean empty space at the
top third and bottom third for the title and author name to be placed later.
EOF
}

build_illustration_prompt() {
    local subject="$1"
    local style="${2:-${IMAGE_STYLE:-clean modern editorial illustration, muted palette}}"
    cat <<EOF
Interior book illustration: ${subject}.
${style}. Horizontal composition, no text, no letters, no captions, no watermark.
EOF
}

# Find a usable font for ImageMagick: prefer a font name it knows, otherwise a
# font file on disk. Returns non-zero when the system has no fonts at all, in
# which case the caller ships the artwork without a title overlay.
ig_find_font() {
    local img_cmd="$1" candidate
    for candidate in DejaVu-Sans-Bold DejaVu-Sans Liberation-Sans-Bold Helvetica-Bold Arial-Bold FreeSans-Bold; do
        if $img_cmd -list font 2>/dev/null | grep -qi "Font: *${candidate}$"; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    local file
    file=$(find /usr/share/fonts /usr/local/share/fonts /Library/Fonts /System/Library/Fonts \
        -type f \( -name '*Bold*.ttf' -o -name '*Bold*.otf' -o -name '*.ttf' -o -name '*.otf' \) \
        2>/dev/null | head -1)
    if [ -n "$file" ]; then
        printf '%s' "$file"
        return 0
    fi
    return 1
}

# ── Cover composition: AI art + ImageMagick typography ───────────────────────
# generate_ai_cover <title> <subtitle> <author> <output file> [w] [h]
generate_ai_cover() {
    local title="$1"
    local subtitle="$2"
    local author="$3"
    local out="$4"
    local width="${5:-1600}"
    local height="${6:-2560}"

    local art="${out%.*}_art.png"
    local prompt
    prompt=$(build_cover_prompt "$title" "$subtitle")

    if ! generate_image "$prompt" "$art" "$width" "$height"; then
        rm -f "$art"
        return 1
    fi

    # Overlay typography when ImageMagick is available; otherwise ship the art.
    local img_cmd=""
    command -v magick >/dev/null 2>&1 && img_cmd="magick"
    [ -z "$img_cmd" ] && command -v convert >/dev/null 2>&1 && img_cmd="convert"

    if [ -z "$img_cmd" ]; then
        ig_warn "ImageMagick not found — using the raw artwork without a title overlay"
        mv "$art" "$out"
        return 0
    fi

    local font
    font=$(ig_find_font "$img_cmd") || {
        ig_warn "No usable font found — using the raw artwork without a title overlay"
        mv "$art" "$out"
        return 0
    }

    # One single-image pass: fit the art to cover size, lay translucent bands
    # behind the text areas, then set the title / subtitle / author.
    # (Doing this as a multi-image -composite chain is fragile on ImageMagick 6.)
    local band_top=$(( height * 24 / 100 ))
    local band_bottom=$(( height * 78 / 100 ))
    local title_pt=$(( width / 11 ))
    local subtitle_pt=$(( width / 26 ))
    local author_pt=$(( width / 22 ))

    if ! $img_cmd "$art" \
            -resize "${width}x${height}^" -gravity center -extent "${width}x${height}" \
            -fill 'rgba(0,0,0,0.42)' -draw "rectangle 0,0 ${width},${band_top}" \
            -fill 'rgba(0,0,0,0.42)' -draw "rectangle 0,${band_bottom} ${width},${height}" \
            -font "$font" -stroke 'rgba(0,0,0,0.30)' -strokewidth 2 \
            -fill white -pointsize "$title_pt" -gravity north \
            -annotate +0+$(( band_top / 3 )) "$title" \
            -fill white -pointsize "$subtitle_pt" -gravity north \
            -annotate +0+$(( band_top / 3 + title_pt + 30 )) "$subtitle" \
            -fill white -pointsize "$author_pt" -gravity south \
            -annotate +0+$(( height / 20 )) "$author" \
            "$out"; then
        ig_warn "Cover composition failed — using the raw artwork"
        mv "$art" "$out"
        return 0
    fi

    rm -f "$art"

    if ! validate_image_file "$out"; then
        ig_warn "Cover composition produced an unusable file"
        rm -f "$out"
        return 1
    fi
    ig_log "   🖼️  Cover written: $out"
    return 0
}

# ── CLI ──────────────────────────────────────────────────────────────────────
image_gen_status() {
    echo "🖼️  Image providers"
    echo "────────────────────────────────────────"
    echo "Preference:  ${IMAGE_PROVIDER:-auto}"
    echo "Chain:       $(image_provider_order)"
    echo
    echo "Pollinations (free, no key)"
    echo "  base:      $(ig_base_url)"
    echo "  model:     ${POLLINATIONS_MODEL:-flux}"
    echo "  token:     $( [ -n "${POLLINATIONS_TOKEN:-}" ] && echo "set" || echo "not set (free tier)" )"
    echo
    echo "Local Stable Diffusion (free, local)"
    echo "  url:       $(a1111_base_url)"
    if a1111_reachable; then
        echo -e "  status:    ${IG_GREEN}✅ reachable${IG_RESET}"
    else
        echo -e "  status:    ${IG_RED}❌ not answering${IG_RESET} (start A1111/SD.Next with --api)"
    fi
    echo
    echo "OpenAI-compatible images API (paid)"
    echo "  base:      $(image_api_base_url)"
    echo "  model:     $(image_api_model)"
    echo "  key:       $( [ -n "$(image_api_key)" ] && echo "set" || echo "not set" )"
    echo
    echo "Local tools"
    echo "  imagemagick: $( command -v magick || command -v convert || echo 'not found' )"
    echo "  jq:          $( command -v jq || echo 'not found' )"
    echo "────────────────────────────────────────"
}

image_gen_test() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local prompt="A tidy wooden desk by a window, morning light, editorial illustration"
    local provider ok=0

    for provider in $(image_provider_order); do
        local out="$tmp_dir/$provider.png"
        printf '  %-14s ' "$provider"
        local t0 t1
        t0=$(date +%s)
        case "$provider" in
            pollinations) generate_image_pollinations "$prompt" "$out" 512 768 >/dev/null 2>&1 ;;
            a1111)        generate_image_a1111 "$prompt" "$out" 512 768 >/dev/null 2>&1 ;;
            openai)       generate_image_openai "$prompt" "$out" 512 768 >/dev/null 2>&1 ;;
        esac
        t1=$(( $(date +%s) - t0 ))
        if validate_image_file "$out"; then
            echo -e "${IG_GREEN}✅ works${IG_RESET} ($(wc -c < "$out" | tr -d ' ') bytes, ${t1}s)"
            ok=$((ok + 1))
        else
            echo -e "${IG_RED}❌ failed${IG_RESET} (${t1}s)"
        fi
    done

    [ "$ok" -eq 0 ] && ig_warn "No provider produced an image. Free tiers are rate limited — retry shortly, or set IMAGE_PROVIDER."
    rm -rf "$tmp_dir"
    [ "$ok" -gt 0 ]
}

main() {
    local cmd="${1:-status}"
    shift || true
    case "$cmd" in
        status)
            image_gen_status
            ;;
        test)
            image_gen_test
            ;;
        cover)
            # cover <title> <subtitle> <author> <out.png> [w] [h]
            generate_ai_cover "${1:?title}" "${2:-}" "${3:-}" "${4:?output file}" "${5:-1600}" "${6:-2560}"
            ;;
        illustration)
            # illustration <subject> <out.png> [w] [h]
            local subject="${1:?subject}" out="${2:?output file}" w="${3:-1024}" h="${4:-768}"
            local prompt
            prompt=$(build_illustration_prompt "$subject")
            generate_image "$prompt" "$out" "$w" "$h"
            ;;
        prompt)
            build_cover_prompt "${1:?title}" "${2:-}"
            ;;
        *)
            cat <<EOF
image_gen.sh — image generation for book covers and illustrations

Usage:
  $0 status                          Show providers and where they point
  $0 test                            Try every provider, report what works
  $0 cover TITLE SUBTITLE AUTHOR OUT [W] [H]
  $0 illustration SUBJECT OUT [W] [H]
  $0 prompt TITLE [SUBTITLE]         Print the cover prompt it would send

Environment:
  IMAGE_PROVIDER      auto | pollinations | a1111 | openai | custom | none
  POLLINATIONS_MODEL  default flux          (free, no key required)
  POLLINATIONS_TOKEN  optional, higher rate limits
  A1111_URL           default http://localhost:7860
  IMAGE_API_BASE_URL / IMAGE_API_KEY / IMAGE_MODEL   paid endpoint (optional)
  IMAGE_STYLE         art-direction suffix for every prompt
EOF
            ;;
    esac
}

# Run main only when executed directly (this file is also sourced)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
