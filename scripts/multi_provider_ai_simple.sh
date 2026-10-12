#!/bin/bash

# Simplified Multi-Provider AI System for testing
# This version focuses on integration with existing book generator

# ============================================================================
# CONFIGURATION
# ============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'

# ============================================================================
# RESPONSE CLEANUP
# ============================================================================

# Strip the chat wrapper that models habitually add around book prose:
#   "Sure! Here is the chapter you asked for:", ```markdown fences, a duplicate
#   "Chapter N: Title" heading, "Word count: 412", "I hope this helps!".
# Left in place, fences are rendered as <pre> code blocks in the EPUB/PDF and the
# chatter ends up in print. Every line that belongs to the manuscript is kept,
# including real code blocks inside technical chapters.
clean_ai_response() {
    awk '
    function is_fence(line) {
        return line ~ /^[[:space:]]*```[[:space:]]*[[:alnum:]+#-]*[[:space:]]*$/
    }
    function is_preamble(line,   l) {
        if (length(line) > 200) return 0
        if (line ~ /^[[:space:]]*#/) return 0
        l = tolower(line)
        gsub(/^[[:space:]]*[*_>`-]+[[:space:]]*/, "", l)
        if (l ~ /^(sure|certainly|of course|absolutely|no problem|got it)[!,.]?[[:space:]]*$/) return 1
        if (l ~ /^(sure|certainly|of course|absolutely|no problem|got it|here is|here'"'"'s|below is|the following is|this is)/) return 1
        if (l ~ /^i('"'"'ll| will| have written|'"'"'ve written| am happy to| hope this)/) return 1
        return 0
    }
    function is_trailing_meta(line,   l) {
        l = tolower(line)
        gsub(/^[[:space:]]*[*_>`()#-]+[[:space:]]*/, "", l)
        gsub(/[[:space:]]*$/, "", l)
        if (l ~ /^(word count|total words?|chapter length|approximate word count|this chapter is (approximately )?[0-9])[[:space:]:~-]/) return 1
        if (l ~ /^(i hope (this|it) helps|let me know|would you like|feel free to|is there anything|happy to (revise|adjust)|end of chapter [0-9]+)/) return 1
        if (l ~ /^\(?approximately [0-9,]+ words\)?$/) return 1
        return 0
    }
    function norm_title(line,   t) {
        t = line
        gsub(/^[[:space:]]*#+[[:space:]]*/, "", t)
        gsub(/^[[:space:]]*[*_]+/, "", t)
        gsub(/[*_]+[[:space:]]*$/, "", t)
        gsub(/[[:space:]]+/, " ", t)
        return tolower(t)
    }
    { raw[++n] = $0 }
    END {
        start = 1
        end = n

        while (start < end && raw[start] ~ /^[[:space:]]*$/) start++
        while (end > start && raw[end] ~ /^[[:space:]]*$/) end--

        # Unwrap a fence that wraps the entire response
        if (start < end && is_fence(raw[start]) && is_fence(raw[end])) {
            start++
            end--
        }

        # Drop leading chatter, blank lines and stray fences
        while (start <= end) {
            if (raw[start] ~ /^[[:space:]]*$/) { start++; continue }
            if (is_preamble(raw[start])) { start++; continue }
            if (is_fence(raw[start])) { start++; continue }
            break
        }

        # Drop a "Chapter N: Title" heading — assemble/compile adds its own
        if (start <= end && norm_title(raw[start]) ~ /^chapter[[:space:]]+[0-9]+/) {
            title = norm_title(raw[start])
            start++
            while (start <= end && raw[start] ~ /^[[:space:]]*$/) start++
            if (start <= end && norm_title(raw[start]) == title) start++
        }

        # Drop trailing chatter, meta lines and stray fences
        while (end >= start) {
            if (raw[end] ~ /^[[:space:]]*$/) { end--; continue }
            if (is_trailing_meta(raw[end])) { end--; continue }
            if (is_fence(raw[end])) { end--; continue }
            break
        }

        blanks = 0
        for (i = start; i <= end; i++) {
            line = raw[i]
            sub(/[[:space:]]+$/, "", line)
            if (line ~ /^[[:space:]]*$/) {
                blanks++
                if (blanks > 1) continue
                print ""
            } else {
                blanks = 0
                print line
            }
        }
    }
    '
}

# ============================================================================
# HELPERS
# ============================================================================

# Cheap connectivity probe so the pipeline fails fast (with one clear message)
# instead of cycling through every known local model for ~20 seconds when
# nothing is listening on the Ollama port.
ollama_reachable() {
    curl -s --max-time 2 -o /dev/null "http://localhost:11434/api/tags" 2>/dev/null
}

# ============================================================================
# CORE FUNCTIONS
# ============================================================================

# Rainbow text animation
rainbow_text() {
    local duration=${1:-3}
    local message="${2:-Processing}"
    local count=0
    local colors=("$RED" "$YELLOW" "$GREEN" "$CYAN" "$BLUE" "$MAGENTA")
    
    while [ $count -lt $((duration * 10)) ]; do
        printf "\r\033[K"
        for ((i=0; i<${#message}; i++)); do
            local color_idx=$(( (count+i) % ${#colors[@]} ))
            printf "${colors[$color_idx]}%s${RESET}" "${message:$i:1}"
        done
        
        printf " 🌈"
        sleep 0.1
        count=$((count + 1))
    done
    printf "\r\033[K"
}

# Progress bar animation
progress_bar() {
    local duration=${1:-5}
    local message="${2:-Loading}"
    local width=30
    local count=0
    local total=$((duration * 10))
    
    while [ $count -lt $total ]; do
        local progress=$((count * width / total))
        local percent=$((count * 100 / total))
        
        # Create the bar
        local bar="["
        for ((i=0; i<width; i++)); do
            if [ $i -lt $progress ]; then
                bar+="${GREEN}=${RESET}"
            else
                bar+=" "
            fi
        done
        bar+="]"
        
        printf "\r\033[K🔄 $message $bar ${BLUE}%d%%${RESET}" "$percent"
        sleep 0.1
        count=$((count + 1))
    done
    printf "\r\033[K"
}

setup_multi_provider_system() {
    echo "🔧 Initializing Multi-Provider AI System..."
    
    # Create tracking directory
    mkdir -p "./multi_provider_logs"
    
    local available_count=0
    
    # Check Gemini API key and initialize models
    if [ -n "$GEMINI_API_KEY" ]; then
        echo "✅ Gemini API key found"
        echo "   Available models: ${#GEMINI_MODELS[@]}"
        
        # Output model details for reference
        echo "   Models configured:"
        for model_data in "${GEMINI_MODELS[@]}"; do
            local model_name=$(echo "$model_data" | cut -d':' -f1)
            local rpm=$(echo "$model_data" | cut -d':' -f2)
            local rpd=$(echo "$model_data" | cut -d':' -f4)
            echo "     - $model_name (${rpm} req/min, ${rpd} req/day)"
        done
        
        # Initialize tracking directory for model cycling
        mkdir -p "$MODEL_ERROR_DIR"
        # Clear any old error timestamps
        rm -f "$MODEL_ERROR_DIR"/*
        
        ((available_count++))
    else
        echo "⚠️  Gemini API key missing"
    fi
    
    # Check Groq API key
    if [ -n "$GROQ_API_KEY" ]; then
        echo "✅ Groq API key found"
        ((available_count++))
    else
        echo "⚠️  Groq API key missing"
    fi
    
    # Check Ollama
    if command -v ollama >/dev/null 2>&1; then
        echo "✅ Ollama CLI found"
        ((available_count++))
    else
        echo "⚠️  Ollama CLI not found"
    fi
    
    echo "✅ Initialization complete. $available_count provider types available."
    return 0
}

# Smart API call with task-specific model selection and fallbacks
# Smart API call with task-specific model selection and fallbacks
function smart_api_call() {
    # Canonical call signature used across the project:
    # smart_api_call <prompt> <system_prompt> <task_type> <temperature> <max_tokens> <max_retries> <model>
    local prompt="$1"           # User prompt
    local system_prompt="$2"    # System prompt
    local task_type="${3:-general}"
    local temperature="${4:-0.7}"
    local max_tokens="${5:-8192}"
    local max_retries="${6:-3}"
    local model="${7:-}"        # Optional: pin a specific model

    # Honour an explicitly requested provider (--provider / SMART_API_PROVIDER).
    # generate_book.sh has always exported this, but nothing ever read it, so
    # `--provider ollama` silently did nothing.
    local provider_pref="${SMART_API_PROVIDER:-auto}"
    case "$provider_pref" in
        ""|auto) provider_pref="auto" ;;
        gemini|groq|ollama) : ;;
        *)
            echo "⚠️ Unknown SMART_API_PROVIDER '$provider_pref' — using auto" >&2
            provider_pref="auto"
            ;;
    esac

    # Callers may pass their own retry budget (generate_appendices.sh and
    # generate_references.sh pass 2); it used to be overwritten with 3.
    if [ -z "$max_retries" ] || ! [[ "$max_retries" =~ ^[0-9]+$ ]]; then
        max_retries=3
    fi

    local success=false
    local output=""
    local provider_used=""
    local attempt
    local fallback_models=("llama3:8b" "llama3.2:1b" "llama3:latest" "gemma:7b" "tinyllama:latest" "mixtral:latest" "llama2:latest")

    for ((attempt = 1; attempt <= max_retries; attempt++)); do

        # A caller-specified model pins this call to that exact model
        if [ -n "$model" ]; then
            echo "🤖 Using specified model: $model" >&2
            if [[ "$model" == gemini-* ]]; then
                if output=$(call_gemini_api "$prompt" "$system_prompt" "$temperature" "$max_tokens") \
                        && [ -n "$output" ]; then
                    success=true
                    provider_used="Gemini/$model"
                    break
                fi
            else
                if output=$(call_ollama_api "$prompt" "$system_prompt" "$task_type" \
                        "$temperature" "$max_tokens" "$max_retries" "$model") \
                        && [ -n "$output" ]; then
                    success=true
                    provider_used="Ollama/$model"
                    break
                fi
            fi
        fi

        # Gemini (recommended provider, tried first)
        if [ "$provider_pref" = "auto" ] || [ "$provider_pref" = "gemini" ]; then
            if [ -n "${GEMINI_API_KEY:-}" ]; then
                echo "🔄 Trying Gemini API (attempt $attempt/$max_retries)" >&2
                if output=$(call_gemini_api "$prompt" "$system_prompt" "$temperature" "$max_tokens") \
                        && [ -n "$output" ]; then
                    success=true
                    provider_used="Gemini"
                    break
                fi
                sleep 1
            elif [ "$provider_pref" = "gemini" ]; then
                echo "⚠️ SMART_API_PROVIDER=gemini but GEMINI_API_KEY is not set" >&2
            fi
        fi

        # Local Ollama models
        if [ "$provider_pref" = "auto" ] || [ "$provider_pref" = "ollama" ]; then
            if ollama_reachable; then
                for fallback_model in "${fallback_models[@]}"; do
                    echo "🔄 Trying local Ollama model: $fallback_model (attempt $attempt/$max_retries)" >&2
                    if output=$(call_ollama_api "$prompt" "$system_prompt" "$task_type" \
                            "$temperature" "$max_tokens" "$max_retries" "$fallback_model") \
                            && [ -n "$output" ]; then
                        success=true
                        provider_used="Ollama/$fallback_model"
                        break
                    fi
                    sleep 1
                done
                [ "$success" = true ] && break
            elif [ "$provider_pref" = "ollama" ]; then
                echo "⚠️ SMART_API_PROVIDER=ollama but nothing answers at http://localhost:11434 (run 'ollama serve')" >&2
            fi
        fi

        # Groq (fallback)
        if [ "$provider_pref" = "auto" ] || [ "$provider_pref" = "groq" ]; then
            if [ -n "${GROQ_API_KEY:-}" ]; then
                echo "🔄 Trying Groq API (attempt $attempt/$max_retries)" >&2
                if output=$(call_groq_api "$prompt" "$system_prompt" "$temperature" "$max_tokens") \
                        && [ -n "$output" ]; then
                    success=true
                    provider_used="Groq"
                    break
                fi
                sleep 1
            elif [ "$provider_pref" = "groq" ]; then
                echo "⚠️ SMART_API_PROVIDER=groq but GROQ_API_KEY is not set" >&2
            fi
        fi

        if [ "$success" = false ] && [ "$attempt" -lt "$max_retries" ]; then
            sleep 2
        fi
    done

    if [ "$success" != true ] || [ -z "$output" ]; then
        echo "❌ No AI provider returned usable text after $max_retries attempt(s)" >&2
        echo "   Checked: GEMINI_API_KEY, GROQ_API_KEY, local Ollama at http://localhost:11434" >&2
        echo "   Provider preference: $provider_pref" >&2
        return 1
    fi

    echo -e "${GREEN}✓ Generated with $provider_used${RESET}" >&2

    # Hand back clean manuscript text (no chat preamble, fences or meta notes)
    printf '%s\n' "$output" | clean_ai_response
    return 0
}

# Gemini models with rate limits
# Model array format: "model_name:RPM:TPM:RPD"
GEMINI_MODELS=(
    # Gemini 2.5 models (newest, try these first)
    # "gemini-2.5-pro:5:250000:100"
    
    "gemini-2.5-flash:10:250000:250"
    "gemini-2.0-flash:15:1000000:200"
    "gemini-2.5-flash-lite:15:250000:1000"
    "gemini-2.0-flash-lite:30:1000000:200"

    "gemini-1.5-flash:10:250000:250"

    "gemini-1.5-pro:5:250000:100" 
    
    # Gemini 2.0 models
    
    # Gemini 1.5 models (fallback)
    
    "gemini-1.5-flash-latest:15:250000:1000"
)
# Keep track of model attempts to cycle through them
GEMINI_MODEL_INDEX=0
# Rate limit tracking - Store last error timestamp for each model (file-based for bash 3 compatibility)
# Directory for storing model error timestamps
MODEL_ERROR_DIR="./multi_provider_logs/model_errors"
mkdir -p "$MODEL_ERROR_DIR"
# How long to wait before retrying a rate-limited model (in seconds)
RATE_LIMIT_COOLDOWN=60

# Helper functions for file-based model error tracking
get_model_error_time() {
    local model_name="$1"
    local error_file="$MODEL_ERROR_DIR/${model_name//\//_}"
    if [ -f "$error_file" ]; then
        cat "$error_file"
    else
        echo "0"
    fi
}

set_model_error_time() {
    local model_name="$1"
    local timestamp="${2:-$(date +%s)}"
    local error_file="$MODEL_ERROR_DIR/${model_name//\//_}"
    echo "$timestamp" > "$error_file"
}

# Gemini API call with model cycling
call_gemini_api() {
    local prompt="$1"
    local system_prompt="$2"
    local temperature="$3"
    local max_tokens="$4"

    API_KEY="${GEMINI_API_KEY}"
    local top_k=40
    local top_p=0.9
    
    # Try each model until one works or we've tried them all
    local total_models=${#GEMINI_MODELS[@]}
    local models_tried=0
    
    for attempt in {1..8}; do
        # Get current model and its details
        local model_data="${GEMINI_MODELS[$GEMINI_MODEL_INDEX]}"
        local model_name=$(echo "$model_data" | cut -d':' -f1)
        local rpm=$(echo "$model_data" | cut -d':' -f2)
        
        # Check if this model recently had rate limit errors
        local current_time=$(date +%s)
        local last_error_time=$(get_model_error_time "$model_name")
        
        local time_since_error=$((current_time - last_error_time))
        
        if [[ $time_since_error -lt $RATE_LIMIT_COOLDOWN ]]; then
            echo "⏳ Model $model_name is cooling down from rate limit, waiting time: $((RATE_LIMIT_COOLDOWN - time_since_error))s" >&2
            # Move to next model
            GEMINI_MODEL_INDEX=$(( (GEMINI_MODEL_INDEX + 1) % ${#GEMINI_MODELS[@]} ))
            models_tried=$((models_tried + 1))
            
            # If we've tried all models, break out
            if [ $models_tried -ge $total_models ]; then
                echo "⚠️ All Gemini models are currently in cooldown period" >&2
                break
            fi
            continue
        fi

        echo "➡️ Trying Gemini model: $model_name" >&2
        local url="https://generativelanguage.googleapis.com/v1beta/models/${model_name}:generateContent"
        echo "📡 Sending request to: $url" >&2

        # Guard the JSON payload against empty/invalid numeric args
        [[ -z "$temperature" || ! "$temperature" =~ ^[0-9]+(\.[0-9]+)?$ ]] && temperature=0.7
        [[ -z "$max_tokens" || ! "$max_tokens" =~ ^[0-9]+$ ]] && max_tokens=8192

        # The system prompt MUST travel with the request: Gemini has a dedicated
        # systemInstruction field and silently ignores anything else. Previously
        # only the user prompt was sent, so every role/style/format instruction
        # (including "format chapters as: Chapter N: Title") was dropped.
        local payload=$(jq -n \
            --arg prompt "$prompt" \
            --arg system "$system_prompt" \
            --argjson temp "$temperature" \
            --argjson maxtokens "$max_tokens" \
            --argjson topk "$top_k" \
            --argjson topp "$top_p" \
            '{
                contents: [{
                    role: "user",
                    parts: [{text: $prompt}]
                }]
            }
            + (if ($system | length) > 0
               then {systemInstruction: {parts: [{text: $system}]}}
               else {}
               end)
            + {
                generationConfig: {
                    temperature: ($temp | tonumber),
                    maxOutputTokens: ($maxtokens | tonumber),
                    topK: ($topk | tonumber),
                    topP: ($topp | tonumber)
                }
            }')

    echo -e "🤖 Generating response with Gemini..." >&2

    # Make the API call
    local response=$(curl -s -X POST --max-time 120 \
        -H "Content-Type: application/json" \
        -H "x-goog-api-key: $API_KEY" \
        -d "$payload" \
        "$url")
    local curl_exit_code=$?

        # Check for a usable response. Note: `jq -e` succeeds on an empty body,
        # so an unreachable endpoint used to look like a successful (empty)
        # generation — require actual text now.
        local text
        text=$(echo "$response" | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null)
        if [ -n "$text" ]; then
            printf '%s\n' "$text"
            return 0
        fi

        # Check if error is rate limit related
        if echo "$response" | grep -q "Resource has been exhausted" || \
           echo "$response" | grep -q "rateLimitExceeded" || \
           echo "$response" | grep -q "quota exceeded"; then
            echo "⚠️ Rate limit hit for $model_name, cycling to next model" >&2
            # Record the error time for this model
            set_model_error_time "$model_name"
        elif [ "$curl_exit_code" -ne 0 ]; then
            echo "❌ Gemini request failed (curl exit $curl_exit_code) for $model_name" >&2
        elif echo "$response" | grep -q '"finishReason": *"MAX_TOKENS"'; then
            echo "⚠️ $model_name stopped at the output token limit (raise --words-per-chapter budget or lower the target length)" >&2
        else
            echo "❌ Gemini API error with $model_name: $response" >&2
        fi

        # Move to next model for the next attempt
        GEMINI_MODEL_INDEX=$(( (GEMINI_MODEL_INDEX + 1) % ${#GEMINI_MODELS[@]} ))
    done
    
    echo "❌ All Gemini models failed or hit rate limits" >&2
    return 1
}

# Groq API call
call_groq_api() {
    local prompt="$1"
    local system_prompt="$2"
    local temperature="$3"
    local max_tokens="$4"
    
    local url="https://api.groq.com/openai/v1/chat/completions"

    # Guard the JSON payload against empty/invalid numeric args
    [[ -z "$temperature" || ! "$temperature" =~ ^[0-9]+(\.[0-9]+)?$ ]] && temperature=0.7
    [[ -z "$max_tokens" || ! "$max_tokens" =~ ^[0-9]+$ ]] && max_tokens=8192

    local payload=$(jq -n \
        --arg system "$system_prompt" \
        --arg prompt "$prompt" \
        --arg temp "$temperature" \
        --arg max "$max_tokens" \
        '{
            "messages": [
                {"role": "system", "content": $system},
                {"role": "user", "content": $prompt}
            ],
            "model": "llama-3.1-8b-instant",
            "temperature": ($temp | tonumber),
            "max_tokens": ($max | tonumber)
        }')
    
    local response=$(curl -s --max-time 60 \
        -H "Authorization: Bearer $GROQ_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$url")
    local curl_exit_code=$?

    # Only treat a response as successful when it actually carries text
    local text
    text=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    if [ -n "$text" ]; then
        printf '%s\n' "$text"
        return 0
    fi

    if [ "$curl_exit_code" -ne 0 ]; then
        echo "❌ Groq request failed (curl exit $curl_exit_code)" >&2
    else
        echo "Groq API error: $response" >&2
    fi
    return 1
}

# Ollama API call with improved context handling
call_ollama_api() {
    local prompt="$1" # User prompt
    local system_prompt="$2" # System prompt
    local task_type="$3" # Task type
    local temperature="$4" # Temperature
    local max_tokens="$5" # Max tokens
    local max_retries="$6" # Max retries
    local model="$7" # Model

    local LOG_FILE="multi_provider_logs/debug.log"
    
    # Create log directory if it doesn't exist
    mkdir -p "$(dirname "$LOG_FILE")"
    
    echo "DEBUG: call_ollama_api started with prompt length: ${#prompt}, system_prompt length: ${#system_prompt}" >> "$LOG_FILE"
    
    # Validate temperature is a number and fix common format issues
    # Handle missing or empty temperature
    if [ -z "$temperature" ]; then
        echo "⚠️ Warning: Empty temperature value, defaulting to 0.7" >&2
        temperature=0.7
    else
        # First clean up the temperature value - convert '.65' to '0.65'
        if [[ "$temperature" =~ ^\.[0-9]+$ ]]; then
            temperature="0$temperature"
            echo "⚠️ Note: Reformatted temperature from '.$temperature' to '$temperature'" >&2
        fi
        
        # Now validate that it's a proper number
        if ! [[ "$temperature" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            echo "⚠️ Warning: Invalid temperature value '$temperature', defaulting to 0.7" >&2
            temperature=0.7
        fi
        
        # Ensure temperature is within valid range (0-2)
        if awk "BEGIN {exit !($temperature > 2.0)}"; then
            echo "⚠️ Warning: Temperature too high ($temperature), capping at 2.0" >&2
            temperature=2.0
        elif awk "BEGIN {exit !($temperature < 0.0)}"; then
            echo "⚠️ Warning: Temperature too low ($temperature), setting to 0.1" >&2
            temperature=0.1
        fi
    fi
    
    # Default to the requested model. `model_name` used to be referenced before
    # it was ever assigned (only the fallback loop below set it), so whenever
    # the `ollama` CLI was missing — the normal case when talking to the HTTP
    # API directly — every model-based branch compared against an empty string
    # and the context-window tuning below silently did nothing.
    local model_name="${model:-llama3:8b}"

    # Choose appropriate model based on availability (needs the Ollama CLI; the
    # HTTP API works without it, in which case the requested model is used).
    if command -v ollama >/dev/null 2>&1; then
        if ! ollama list 2>/dev/null | grep -q "$model_name"; then
            # First try popular high-quality models
            local fallback_models=(
                "llama3.1:8b"
                "phi3:3.8b"
                "phi4-mini:3.8b"
                "gemma3:4b"
                "gemma2:2b"
                "llama3.2:1b"
                "qwen2.5:1.5b"
                "granite3:3b"
            )

            for fallback in "${fallback_models[@]}"; do
                if ollama list 2>/dev/null | grep -q "$fallback"; then
                    model_name="$fallback"
                    echo "⚠️ Model '$model' not found, using fallback: $model_name" >&2
                    break
                fi
            done
        fi
    else
        echo "DEBUG: ollama CLI not found — using the HTTP API with model '$model_name'" >> "$LOG_FILE"
    fi
    
    # Calculate optimal context window based on model and prompt size
    local prompt_length=${#prompt}
    local system_length=${#system_prompt}
    local total_length=$((prompt_length + system_length + 200)) # Adding buffer
    
    # Set context window based on model capabilities
    local ctx_window=4096
    local num_batch=128
    local stream=false
    local top_k=40
    local top_p=0.9
    
    # Adjust context window and batch size based on model
    if [[ "$model_name" == *"llama3.1:8b"* ]]; then
        ctx_window=8192
        num_batch=256
    elif [[ "$model_name" == *"phi3:3.8b"* ]] || [[ "$model_name" == *"phi4-mini"* ]]; then
        ctx_window=4096
        num_batch=192
    elif [[ "$model_name" == *"gemma3"* ]]; then
        ctx_window=8192
        num_batch=256
    elif [[ "$model_name" == *"granite"* ]]; then
        ctx_window=16384
        num_batch=512
    fi

    # Latency-focused overrides for specific models
    # These reduce context, lower batch sizes, enable streaming, and tighten sampling to reduce wall-clock time
    if [[ "$model_name" == *"qwen2:7b"* ]] || [[ "$model_name" == *"qwen2.5"* ]] || [[ "$model_name" == *"qwen2.5:14b"* ]]; then
        ctx_window=4096
        num_batch=32
        stream=true
        top_k=20
        top_p=0.95
        # Cap long responses by default to avoid long-running generations
        if [ -z "$max_tokens" ] || [ "$max_tokens" -gt 2048 ]; then
            max_tokens=2048
        fi
    fi

    if [[ "$model_name" == *"gemma2:9b"* ]] || [[ "$model_name" == *"gemma2"* ]]; then
        ctx_window=4096
        num_batch=48
        stream=true
        top_k=30
        top_p=0.95
        if [ -z "$max_tokens" ] || [ "$max_tokens" -gt 4096 ]; then
            max_tokens=4096
        fi
    fi

    # Write message directly without using grep in pipe
    echo -e "🖥️  Using local Ollama model: $model_name with temperature $temperature" >&2
    echo "DEBUG: Using model: $model_name, temperature: $temperature, max_tokens: $max_tokens, ctx: $ctx_window" >> "$LOG_FILE"
    
    local url="http://localhost:11434/api/generate"
    
    # Format prompts according to model's preferred format
    local formatted_prompt=""
    if [[ "$model_name" == *"llama"* ]]; then
        # LLaMA format
        formatted_prompt="<|system|>\n$system_prompt\n\n<|user|>\n$prompt\n\n<|assistant|>"
    elif [[ "$model_name" == *"phi"* ]]; then
        # Phi format
        formatted_prompt="<|system|>\n$system_prompt\n\n<|user|>\n$prompt\n\n<|assistant|>"
    elif [[ "$model_name" == *"gemma"* ]]; then
        # Gemma format
        formatted_prompt="<start_of_turn>system\n$system_prompt<end_of_turn>\n<start_of_turn>user\n$prompt<end_of_turn>\n<start_of_turn>model"
    else
        # Default/generic format
        formatted_prompt="System: $system_prompt\n\nUser: $prompt\n\nAssistant:"
    fi
    
    echo "DEBUG: Using formatted prompt length: ${#formatted_prompt}" >> "$LOG_FILE"
    
    # Use jq to properly format the JSON payload
    local payload=$(jq -n \
        --arg model "$model_name" \
        --arg prompt "$formatted_prompt" \
        --argjson temp "$temperature" \
        --argjson max_tokens "$max_tokens" \
        --argjson ctx_window "$ctx_window" \
        --argjson num_batch "$num_batch" \
        --argjson stream_val "$stream" \
        --argjson topk "$top_k" \
        --argjson topp "$top_p" \
        '{
            "model": $model,
            "prompt": $prompt,
            "stream": ($stream_val == true),
            "options": {
                "temperature": $temp,
                "num_predict": $max_tokens,
                "top_k": $topk,
                "top_p": $topp,
                "num_batch": $num_batch,
                "num_ctx": $ctx_window
            }
        }')
    
    echo "DEBUG: About to make curl request to Ollama" >> "$LOG_FILE"
    
    # Command line for Ollama - verbose debug
    # local response=$(ollama generate --model "$model" --prompt "$formatted_prompt" --temperature "$temperature" --max_tokens "$max_tokens" --ctx_window "$ctx_window" --num_batch "$num_batch" --stream "$stream" --top_k "$top_k" --top_p "$top_p")

    # Make the API call with longer timeout for bigger models
    local response=$(curl -s --max-time 300 \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$url")
    local curl_exit_code=$?
    
    echo "DEBUG: curl completed with exit code: $curl_exit_code" >> "$LOG_FILE"
    echo "DEBUG: Response length: ${#response} characters" >> "$LOG_FILE"
    
    # Check for a usable response. `jq -e` succeeds on an empty body, so an
    # unreachable Ollama used to be reported as a successful empty generation.
    local extracted_response
    extracted_response=$(echo "$response" | jq -r '.response // empty' 2>/dev/null)

    if [ -n "$extracted_response" ]; then
        # Strip chat template markers that a local model may echo back. The
        # previous code also tried to cut the original prompt out with
        # `sed "s|$prompt||g"` — that broke on any prompt containing regex
        # characters, newlines or slashes, and could delete real prose.
        extracted_response=$(printf '%s\n' "$extracted_response" | sed -E \
            -e 's/^.*<\|assistant\|>//g' \
            -e 's/^.*<start_of_turn>model//g' \
            -e 's/^.*Assistant://g' \
            -e 's/<\|system\|>.*<\|user\|>//g' \
            -e 's/<\|user\|>.*<\|assistant\|>//g')

        # A response that is only whitespace is not a success either
        if [ -n "$(printf '%s' "$extracted_response" | tr -d '[:space:]')" ]; then
            echo "DEBUG: Successfully extracted response, length: ${#extracted_response}" >> "$LOG_FILE"
            printf '%s\n' "$extracted_response"
            return 0
        fi
    fi

    # Provide better error info
    local error_message
    error_message=$(echo "$response" | jq -r '.error // "empty response"' 2>/dev/null)
    if [ "$curl_exit_code" -ne 0 ]; then
        echo "❌ Ollama request failed (curl exit $curl_exit_code) — is 'ollama serve' running?" >&2
        error_message="curl exit $curl_exit_code"
    else
        echo "❌ Ollama API error with $model_name: $error_message" >&2
    fi
    echo "DEBUG: Failed to extract .response from JSON, error: $error_message" >> "$LOG_FILE"
    return 1
}

# ============================================================================
# BOOK GENERATION FUNCTIONS
# ============================================================================

generate_outline_with_smart_api() {
    local topic="$1"
    local genre="$2"
    local audience="$3"
    local style="${4:-detailed}"
    local tone="${5:-professional}"
    # Optional (6th/7th): the requested shape of the book. Without these the
    # outline claimed 12-15 chapters of 2,500-3,000 words no matter what the
    # user asked for, so chapter summaries described a different book.
    local chapters="${6:-12}"
    local words_per_chapter="${7:-3000}"

    if ! [[ "$chapters" =~ ^[0-9]+$ ]] || [ "$chapters" -lt 1 ]; then chapters=12; fi
    if ! [[ "$words_per_chapter" =~ ^[0-9]+$ ]] || [ "$words_per_chapter" -lt 1 ]; then words_per_chapter=3000; fi
    local total_words=$(( chapters * words_per_chapter ))

    local system_prompt="You are a book planner and publishing professional who designs commercially viable books for KDP and other platforms. You reply with a single clean Markdown outline: no preamble, no closing commentary, no explanation of your process, and no code fences.

The outline always follows this exact structure so downstream tooling can parse it:

# <Book Title>
## <Book Subtitle>
### Chapter 1: <Chapter Title>
<2-3 sentence summary of the chapter and the value it delivers>
### Chapter 2: <Chapter Title>
<summary>
... and so on for every requested chapter ...

## Core Themes
- <3-5 bullets>

## Target Reader
<one short paragraph on reading level and tone>"

    local user_prompt="Create a detailed outline for a ${genre} book about '${topic}' targeting ${audience}.

The finished book will have exactly ${chapters} chapters of roughly ${words_per_chapter} words each (about ${total_words} words in total), written in a ${style} style with a ${tone} tone.

Output format — follow it exactly:
- First line: '# ' followed by the book title
- Second line: '## ' followed by the subtitle
- Then one '### Chapter N: Title' line per chapter (numbered 1 to ${chapters}, in order), each followed by its 2-3 sentence summary
- Finish with the '## Core Themes' and '## Target Reader' sections described above

Chapter titles must be specific and promise clear value. Each chapter must cover a distinct topic with no overlap, and the chapters must build on each other in a logical order. Do not add anything before the title line or after the Target Reader section."

    smart_api_call "$user_prompt" "$system_prompt" "analytical" 0.7 8192
}

generate_chapter_with_smart_api() {
    local chapter_num="$1"
    local chapter_title="$2"
    local prior_context="$3"
    local outline="$4"
    local min_words="$5"
    local max_words="$6"
    local style="${7:-engaging and informative}"
    local tone="${8:-accessible and professional}"
    # Optional 9th argument: output-token budget (derived from the requested
    # chapter length by generate_book.sh, otherwise a long chapter can be cut
    # off mid-sentence by the provider's default cap).
    local max_tokens="${9:-8192}"

    if [ -z "$prior_context" ]; then
        prior_context="(nothing yet — this is the opening chapter)"
    fi

    local system_prompt="You are a professional book author. You write ${style} prose in a ${tone} tone, and you output finished manuscript text only: no preamble, no closing remarks, no notes about word counts or about what you did, and no code fences."

    local user_prompt="Write Chapter ${chapter_num} of the book, titled \"${chapter_title}\".

=== BOOK OUTLINE ===
${outline}

=== ALREADY WRITTEN (use for continuity, do not repeat) ===
${prior_context}

=== REQUIREMENTS ===
- Length: ${min_words}-${max_words} words of finished prose.
- Write only the chapter body. Start directly with the first paragraph or with a section heading.
- Do not repeat the chapter title as a heading, do not add an introduction like 'In this chapter we will', and do not add a summary or sign-off at the end.
- Use Markdown headings (##, ###) for sections, and keep paragraphs short.
- Include concrete examples, numbers or steps where they help.
- Do not re-explain concepts that earlier chapters already covered; instead build on them.
- Keep the ${style} style and ${tone} tone consistent with the rest of the book.

Write the first sentence of the chapter now."

    smart_api_call "$user_prompt" "$system_prompt" "creative" 0.8 "$max_tokens"
}

check_plagiarism_with_smart_api() {
    local chapter_file="$1"
    local content
    content=$(cat "$chapter_file")

    local system_prompt="You are an expert plagiarism checker and originality assessor. You judge whether text looks independently written, flags passages that read like copied or boilerplate material, and you always answer in the requested machine-readable shape."

    local user_prompt="Assess this chapter for originality and potential copyright concerns.

=== CHAPTER TEXT ===
${content}

=== ANSWER FORMAT (follow exactly, nothing else) ===
ORIGINALITY: <whole number from 0 to 10, where 10 is fully original>
CONCERNS: <short list, or 'none'>
RECOMMENDATIONS: <short list, or 'none'>"

    local result score
    result=$(smart_api_call "$user_prompt" "$system_prompt" "analytical" 0.3 4096)

    # Parse the score numerically. The previous check (`grep -E "(score|rating).*[8-9]|10"`)
    # matched any stray '10' anywhere in the reply, so a chapter scoring 3/10
    # was reported as fully original.
    score=$(printf '%s\n' "$result" \
        | grep -oiE 'originality[^0-9]{0,15}([0-9]{1,2})' \
        | grep -oE '[0-9]{1,2}' | head -1)

    if [ -z "$score" ]; then
        # Fall back to any "<n>/10" or "<n> out of 10" phrasing
        score=$(printf '%s\n' "$result" \
            | grep -oE '[0-9]{1,2}[[:space:]]*(/|out of)[[:space:]]*10' \
            | grep -oE '^[0-9]{1,2}' | head -1)
    fi

    if [ -z "$score" ]; then
        echo "⚠️ Could not parse an originality score from the assessment — treating the chapter as needing review" >&2
        return 2
    fi

    if [ "$score" -ge 8 ]; then
        return 0  # High originality
    elif [ "$score" -ge 6 ]; then
        return 1  # Medium risk
    else
        return 2  # Low originality/high risk
    fi
}

rewrite_chapter_with_smart_api() {
    local chapter_file="$1"
    local plagiarism_report="$2"
    local content
    content=$(cat "$chapter_file")
    local report_content=""

    if [ -f "$plagiarism_report" ]; then
        report_content=$(cat "$plagiarism_report")
    fi

    local system_prompt="You are an expert editor who rewrites text to improve originality while keeping its message, structure and voice. You output the rewritten chapter body only: no preamble, no commentary, no code fences."

    local user_prompt="Rewrite this chapter so it reads as independent, original writing while keeping its message intact.

=== ORIGINAL CHAPTER ===
${content}

=== PLAGIARISM / ORIGINALITY ANALYSIS ===
${report_content}

=== REQUIREMENTS ===
- Keep the same core message, structure and section order
- Roughly the same length as the original
- Replace any borrowed or boilerplate phrasing with fresh wording
- Output only the rewritten chapter body, starting directly with the first paragraph

Rewrite the chapter now:"

    local result
    # Note: `local result=$(...)` followed by `[ $? -eq 0 ]` tested the exit
    # status of `local`, not of the API call — a failed rewrite then overwrote
    # the chapter file with an empty string.
    if result=$(smart_api_call "$user_prompt" "$system_prompt" "creative" 0.8 8192) \
            && [ -n "$result" ]; then
        printf '%s\n' "$result" > "$chapter_file"
        return 0
    fi

    echo "⚠️ Rewrite failed for $(basename "$chapter_file") — original chapter left unchanged" >&2
    return 1
}

# ============================================================================
# STATUS AND MONITORING
# ============================================================================

display_gemini_models_status() {
    echo "  ${CYAN}Gemini Models:${RESET}"
    
    local current_time=$(date +%s)
    local current_model="${GEMINI_MODELS[$GEMINI_MODEL_INDEX]%%:*}"
    
    # Display models by generation for better organization
    echo "    ${CYAN}📌 Gemini 2.5 Models:${RESET}"
    for model_data in "${GEMINI_MODELS[@]}"; do
        local model_name=$(echo "$model_data" | cut -d':' -f1)
        [[ "$model_name" == *"2.5"* ]] || continue
        
        _display_model_status "$model_name" "$model_data" "$current_model" "$current_time"
    done
    
    echo "    ${CYAN}📌 Gemini 2.0 Models:${RESET}"
    for model_data in "${GEMINI_MODELS[@]}"; do
        local model_name=$(echo "$model_data" | cut -d':' -f1)
        [[ "$model_name" == *"2.0"* ]] || continue
        
        _display_model_status "$model_name" "$model_data" "$current_model" "$current_time"
    done
    
    echo "    ${CYAN}📌 Gemini 1.5 Models:${RESET}"
    for model_data in "${GEMINI_MODELS[@]}"; do
        local model_name=$(echo "$model_data" | cut -d':' -f1)
        [[ "$model_name" == *"1.5"* ]] || continue
        
        _display_model_status "$model_name" "$model_data" "$current_model" "$current_time"
    done
    
    echo ""
}

# Helper function to display individual model status
_display_model_status() {
    local model_name="$1"
    local model_data="$2"
    local current_model="$3" 
    local current_time="$4"
    
    local rpm=$(echo "$model_data" | cut -d':' -f2)
    local rpd=$(echo "$model_data" | cut -d':' -f4)
    
    # Get last error time from file
    local last_error_time=$(get_model_error_time "$model_name")
    local time_since_error=$((current_time - last_error_time))
    
    # Indicator for current model
    local indicator=""
    if [[ "$model_name" == "$current_model" ]]; then
        indicator=" ${YELLOW}(active)${RESET}"
    fi
    
    if [[ $time_since_error -lt $RATE_LIMIT_COOLDOWN ]]; then
        local cooldown_remaining=$((RATE_LIMIT_COOLDOWN - time_since_error))
        echo -e "      ${YELLOW}⏳${RESET} $model_name - Cooling down (${cooldown_remaining}s remaining)$indicator"
    else
        echo -e "      ${GREEN}✅${RESET} $model_name - Ready (${rpm} req/min, ${rpd} req/day)$indicator"
    fi
}

show_provider_status() {
    echo -e "\n${CYAN}📊 Multi-Provider Status:${RESET}"
    echo "────────────────────────────────────────"
    
    if [ -n "$GEMINI_API_KEY" ]; then
        echo -e "${GREEN}✅${RESET} Gemini API - Available"
        display_gemini_models_status
    else
        echo -e "${RED}❌${RESET} Gemini API - Missing key"
    fi
    
    if [ -n "$GROQ_API_KEY" ]; then
        echo -e "${GREEN}✅${RESET} Groq API - Available"
    else
        echo -e "${RED}❌${RESET} Groq API - Missing key"
    fi
    
    if command -v ollama >/dev/null 2>&1; then
        echo -e "${GREEN}✅${RESET} Ollama - Available"
    else
        echo -e "${RED}❌${RESET} Ollama - Not installed"
    fi
    
    echo "────────────────────────────────────────"
}

test_all_providers() {
    echo "🧪 Testing all configured providers..."
    
    local test_prompt="Write a brief hello message."
    local test_system="You are a helpful assistant."
    
    # Test Gemini
    if [ -n "$GEMINI_API_KEY" ]; then
        echo -n "Testing Gemini: "
        if call_gemini_api "$test_prompt" "$test_system" 0.7 50 >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Working${RESET}"
        else
            echo -e "${RED}❌ Failed${RESET}"
        fi
    fi
    
    # Test Groq
    if [ -n "$GROQ_API_KEY" ]; then
        echo -n "Testing Groq: "
        if call_groq_api "$test_prompt" "$test_system" 0.7 50 >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Working${RESET}"
        else
            echo -e "${RED}❌ Failed${RESET}"
        fi
    fi
    
    # Test Ollama
    if command -v ollama >/dev/null 2>&1; then
        echo -n "Testing Ollama: "
        if call_ollama_api "$test_prompt" "$test_system" 0.7 50 >/dev/null 2>&1; then
            echo -e "${GREEN}✅ Working${RESET}"
        else
            echo -e "${RED}❌ Failed${RESET}"
        fi
    fi
}

estimate_book_cost() {
    local num_chapters="${1:-12}"
    local words_per_chapter="${2:-2200}"
    
    echo "💰 Estimated Book Generation Cost:"
    echo "   Chapters: $num_chapters"
    echo "   Words per chapter: $words_per_chapter"
    echo "   Total words: $((num_chapters * words_per_chapter))"
    echo ""
    echo "   Using free tiers: $0.00"
    echo "   Using paid tiers: $0.50 - $2.00"
    echo ""
}

# ============================================================================
# MAIN FUNCTION
# ============================================================================

main() {
    case "${1:-}" in
        "test")
            setup_multi_provider_system
            test_all_providers
            show_provider_status
            ;;
        "status")
            setup_multi_provider_system
            show_provider_status
            ;;
        "estimate")
            estimate_book_cost "${2:-12}" "${3:-2200}"
            ;;
        *)
            echo "Multi-Provider AI System for Book Generation"
            echo ""
            echo "Usage:"
            echo "  $0 test      - Test all providers"
            echo "  $0 status    - Show provider status"
            echo "  $0 estimate [chapters] [words] - Estimate costs"
            echo ""
            echo "This script is meant to be sourced by other scripts."
            ;;
    esac
}

# Only run main if script is executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
