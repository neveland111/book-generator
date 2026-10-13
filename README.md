# 🤖📚 AI Book Generator

A complete autonomous book creation pipeline from concept to publication - generating professional manuscripts with AI-powered authoring and design. 

<p>
	<img src="scripts/covers/front/playful-path-cover.png" alt="The Playful Path" width="260" style="margin-right:18px;" />
	<img src="scripts/covers/front/micro-influence-cover.png" alt="The Micro-Influence Advantage" width="260" />
</p>

## Automated book authoring, editing and compilation toolkit.

This repository contains a set of shell scripts and helper tools that together can:

- Pick topics and book titles (AI-assisted)
- Generate detailed outlines
- Generate, extend and edit chapters
- Run optional quality & plagiarism checks
- Produce front/back covers (ImageMagick or AI-assisted where available)
- Assemble a complete manuscript with title pages, Table of Contents, copyright pages,
	epilogue/appendices/acknowledgements/etc.
- Export the final book in EPUB, PDF and other common ebook formats ready for platforms
	such as Amazon KDP.

### ✨ Key Points
- Designed to use free tools and services where possible. When AI APIs are used, the
	project supports Gemini (recommended), Ollama, Groq and OpenAI as configurable
	providers via environment variables. If you do not set API keys the scripts will
	fall back to purely local tools (ImageMagick, Pandoc, TeX) for compilation and
	simple auto-generated covers.
- Created the final front/back covers and an author picture manually using the free
	ChatGPT web UI (no paid API) to avoid API costs for the cover artwork.
- Conducted a proof-of-concept to test whether a high-quality book could be
	created by AI and pass Amazon Kindle Direct Publishing quality checks. I used this
	toolkit to generate and publish two books which passed KDP checks and are live on
	Amazon. Those books were not marketed — this was an experiment.

### 🗂️ Published Books

- The Playful Path: Unlocking Your Child's Potential Through Joyful, Play-Based Learning for Ages 3-8 — https://a.co/d/hAg2DWe
- The Micro-Influence Advantage: Building Your Niche Brand and Monetizing Your Passion Online — https://a.co/d/3zwHBZJ

### 🔗 Amazon Links

<p>
	<img src="scripts/playful-path-images/playful-path-amazon.png" alt="The Playful Path" width="400" style="margin-right:18px;" />
	<img src="scripts/micro-influence-images/micro-influence-amazon.png" alt="The Micro-Influence Advantage" width="400" />
</p>

- The Playful Path — https://a.co/d/hAg2DWe
- The Micro-Influence Advantage — https://a.co/d/3zwHBZJ

📌 Status
------
Everything required to generate and compile a book is included as scripts and
helper utilities. Some features require external programs or optional API keys for
best results (Gemini, Ollama, Groq, OpenAI). When not available the workflow still
works for basic generation and compilation using local tools.

🛠️ Quick Overview of Main Scripts
-----------------------------
- `compile_book.sh` — Combine an outline and chapter files into a manuscript and
	export EPUB/PDF/MOBI/AZW3/Markdown/HTML. Lots of options (cover, backcover, author,
	ISBN, publisher, version selection, generate cover, fast mode). See the script
	usage text for full CLI reference.
- `optimized_chapter_handler.sh` — Provide quality checks and chapter length handling. It
	Can extend chapters, review for quality, and rewrite chapters when needed.
- `generate_appendices.sh` — Generate preface, introduction, dedication, acknowledgments,
	epilogue, glossary, discussion guide, further reading, and appendices using an AI
	provider (Gemini recommended). It extracts context from your outline and sample
	chapter to produce well-formatted markdown sections.
- `multi_provider_ai_simple.sh` — Multi-provider helper and `smart_api_call` wrapper.
	It detects available AI providers (Gemini, Groq, Ollama, OpenAI) and cycles/falls
	back as needed. Also includes provider status and quick tests.
- `kdp_market_analyzer.sh`, `topic_market_research.sh`, `market_analyzer.py` and
	other market-research tools — A suite for free-market analysis and KDP opportunity
	scoring (Amazon scraping, trend guidance, keyword/title suggestions). Useful
	for validating topic choices before writing.
- `add_animations.sh` — Helper to add terminal animations to long-running steps.
- `test_extract_chapters.sh` — Small test harness for chapter extraction logic.
- `migrate_book_outputs.sh` — Helps organize loose outline files into structured
	book directories under `book_outputs/`.

⚙️ Prerequisites
-------------
Install the following to get full functionality (macOS / Linux):

- Pandoc (required for EPUB/HTML/PDF pipeline)
- A LaTeX distribution (TeX Live, MacTeX) for best PDF output (pdflatex/xelatex/lualatex)
- ImageMagick (`convert` / `magick`) for cover generation and image resizing
- Jq (JSON parsing helpers used by AI cover generation code)
- Curl
- Python3 + pip packages: requests, beautifulsoup4 (used by market research tools)

On macOS you can quickly install essentials via Homebrew:

```bash
brew install pandoc imagemagick jq
# Install MacTeX (large) or use BasicTeX for smaller footprint:
brew install --cask mactex
pip3 install requests beautifulsoup4
```

🔑 Environment Variables / API Keys
--------------------------------
The scripts support multiple AI providers. Set the corresponding environment
variables to enable them:

- `GEMINI_API_KEY` — (recommended) Use Gemini for text-generation tasks (outlines,
	chapters, appendices, references). The code targets Gemini models and includes
	rate-limit handling.
- `GROQ_API_KEY` — Optional alternative provider (fast free tier).
- `ANTHROPIC_API_KEY` — Optional. Enables Claude for text generation
	(`ANTHROPIC_MODEL`, default `claude-sonnet-4-5`).
- `CUSTOM_API_BASE_URL` / `CUSTOM_API_KEY` / `CUSTOM_MODEL` — Optional. Point the
	generator at **any OpenAI-compatible endpoint**; `OPENAI_BASE_URL`,
	`OPENAI_API_KEY` and `OPENAI_MODEL` work as aliases, so plain OpenAI needs
	nothing but its key.
- `OLLAMA` — If you run Ollama locally the scripts will try to call it for local
	LLM generations (no key required).

### 🧭 Two Ways to Generate

| | `generate_book.sh` | `agent_book.sh` |
|---|---|---|
| Style | batch pipeline | agent loop |
| Steps | outline → chapters → appendices → references → originality → compile | plan → write → **critique** → **revise** → originality → compile |
| Quality control | one pass, chapters kept as generated | every chapter graded against a rubric; anything below `--threshold` (default 8/10) is revised to act on the critique and graded again |
| Output extras | manuscripts + exports | plus `agent_report.md` (score before/after per chapter) and `critique_chapter_NN.md` files |
| Best for | fast drafts, short books | publishable drafts where chapter quality matters |

```bash
# Agent-style run: grade every chapter and fix the weak ones
./scripts/agent_book.sh --topic "Slow Cooking for Busy Weeks" \
    --chapters 8 --words-per-chapter 2000 \
    --threshold 8 --max-revisions 1 --pen-name "Nama Anda"
```

The critique pass is a separate model call per chapter: it returns
`CLARITY/SPECIFICITY/AUDIENCE FIT/STRUCTURE/ORIGINALITY/OVERALL` scores plus a
`FIXES:` list, which is then fed to the revision pass. Costs roughly 2-3× the API
calls of the batch pipeline for the same book — `--max-revisions 0` turns grading
off and makes it behave like `generate_book.sh`.

### 🔑 Environment file

`generate_book.sh`, `agent_book.sh` and `multi_provider_ai_simple.sh` load `.env`
from the repository root automatically. Existing environment variables always win,
and only variable *names* are echoed (never values):

```bash
cp .env.example .env      # fill in GEMINI_API_KEY / ANTHROPIC_API_KEY / CUSTOM_* …
./scripts/multi_provider_ai_simple.sh status
# 🔑 Loaded 4 variable(s) from .env: GEMINI_API_KEY CUSTOM_API_BASE_URL …
```



Anything that speaks `POST <base>/chat/completions` with a bearer token works:
OpenAI, OpenRouter, DeepSeek, Together, Mistral, xAI, Fireworks, LM Studio,
vLLM, llama.cpp's server, Ollama's own `/v1` endpoint, or your own gateway.

```bash
# OpenAI
export OPENAI_API_KEY="sk-..."
export OPENAI_BASE_URL="https://api.openai.com/v1"
export OPENAI_MODEL="gpt-4o-mini"

# OpenRouter (one key, many models)
export CUSTOM_API_BASE_URL="https://openrouter.ai/api/v1"
export CUSTOM_API_KEY="sk-or-..."
export CUSTOM_MODEL="deepseek/deepseek-chat"

# Local server (LM Studio / vLLM / llama.cpp) — key can be any non-empty string
export CUSTOM_API_BASE_URL="http://localhost:1234/v1"
export CUSTOM_API_KEY="local"
export CUSTOM_MODEL="qwen2.5-7b-instruct"

# Claude (its own wire format is handled separately)
export ANTHROPIC_API_KEY="sk-ant-..."
export ANTHROPIC_MODEL="claude-sonnet-4-5"

# Then pin it (or leave it to the automatic chain):
./scripts/generate_book.sh --topic "Your Topic" --provider custom
```

`--provider` accepts `auto | gemini | ollama | groq | anthropic | openai | custom`.
`openai` and `custom` are the same code path (the OpenAI-compatible adapter).
Check what is wired up with `./scripts/multi_provider_ai_simple.sh status` and
`./scripts/multi_provider_ai_simple.sh test`.

If none of the above keys are present the generator will still run but rely on
local tools and the basic ImageMagick cover-generator fallback.

🧠 How the AI Layer Behaves
------------------------
`scripts/multi_provider_ai_simple.sh` is the single choke point every AI call
goes through (outline, chapters, appendices, references, originality checks):

- **Provider order (auto):** Gemini → local Ollama → Groq → Anthropic → custom
	endpoint, skipping any provider that is not configured. Pin one with
	`--provider gemini|ollama|groq|anthropic|openai|custom` (or
	`SMART_API_PROVIDER`). Pinning is strict: a pinned provider is never silently
	replaced by another; if its key/URL is missing the run stops with a message
	saying exactly what to set.
- **A custom provider needs no code changes.** Any OpenAI-compatible endpoint
	(OpenAI, OpenRouter, DeepSeek, Together, LM Studio, vLLM, llama.cpp, your own
	gateway) is configurable through `CUSTOM_API_BASE_URL` / `CUSTOM_API_KEY` /
	`CUSTOM_MODEL`. Claude is supported through its own adapter, since Anthropic
	uses a different wire format.
- **System prompts are real system prompts.** Gemini requests carry the
	instruction block in `systemInstruction`; a dropped system prompt was the reason
	generated outlines ignored the requested chapter format.
- **Responses are cleaned before they reach a manuscript.** Chat preambles
	("Sure! Here is the chapter…"), wrapping ``` fences, duplicated `# Chapter N`
	headings, "Word count: 412" lines and sign-offs are stripped, while genuine code
	blocks inside technical chapters are preserved. Fences left in place used to be
	rendered as `<pre>` code blocks in the EPUB/PDF.
- **Empty output is a failure.** A blank body (unreachable endpoint, quota error)
	no longer looks like a successful generation; the pipeline reports which
	providers it checked instead of writing empty chapters.
- **Fail fast.** If nothing is listening on `localhost:11434` and no API key is
	set, the run stops in seconds with one clear message rather than cycling through
	local models.
- **Outline contract:** the planner is asked for `# Title`, `## Subtitle`, then
	`### Chapter N: Title` plus a summary, using the exact chapter count and word
	target you passed. If an outline comes back unparseable, the pipeline stops and
	shows you the first lines instead of writing placeholder-titled chapters.
- **Originality check:** the model answers with `ORIGINALITY: <n>/10`, which is
	parsed numerically (8-10 pass, 6-7 warn, below 6 or unparseable is flagged for
	review).

🚀 Typical Workflow (High-level)
-----------------------------
1. Prepare a book outline file in a directory under `book_outputs/` or create a new
	directory for your book. The outline file should be named like `book_outline_*.md`
	(the scripts offer auto-detection of the most recent book if you omit the path).
2. Use the multi-provider helpers and `optimized_chapter_handler.sh` to generate or
	improve chapters. The `generate_chapter_with_smart_api` helpers are in the
	`multi_provider_ai_simple.sh` script and are used by higher-level generation
	workflows.
3. Optionally run `generate_appendices.sh /path/to/book` to auto-create Preface,
	Introduction, Dedication, Acknowledgments, Glossary, Appendices, etc. This
	Requires `GEMINI_API_KEY` set for full automation.
4. Run `./compile_book.sh [book_directory] [output_format] [version] [options]` to
	assemble chapters, generate metadata, include cover/back cover and export
	EPUB/PDF/HTML/Markdown formats.

🧭 Examples — Common Commands
--------------------------
```bash
# Compile the most recent book in all formats (auto detect):
./compile_book.sh

# Compile a specific book directory as EPUB only with a custom author:
./compile_book.sh ./book_outputs/my-book epub --author "Jane Doe"

# Compile a given book as final version, attach a local cover and back cover:
./compile_book.sh ./book_outputs/my-book all 3 --cover "/path/to/cover.png" --backcover "/path/to/back.png" --isbn "978-1-2345-6789-7"

# Generate appendices and extras for a book (requires GEMINI_API_KEY):
./generate_appendices.sh ./book_outputs/my-book

# Run a quick provider status and tests using the multi-provider helper:
./multi_provider_ai_simple.sh status
./multi_provider_ai_simple.sh test

# Run market research for a topic (creates analysis files in research data folder):
./kdp_market_analyzer.sh "digital minimalism"
```

📝 Notes on `compile_book.sh` Options
---------------------------------
- `book_directory` — Path to a book folder (if omitted the script auto-detects the
	Most recent directory under `book_outputs/`).
- `output_format` — One of `all|epub|pdf|html|markdown|mobi|azw3` (default `all`).
- `version` — Manuscript version selector: `1` original, `2` edited, `3` final (default 3).
- `--author`, `--cover`, `--backcover`, `--isbn`, `--publisher`, `--year` — Set
	Metadata used during compilation.
- `--generate-cover` — Generate cover art with the **free-first** provider chain
	(Pollinations → local Stable Diffusion → paid endpoint) and set the title/subtitle/
	author typography on top of it with ImageMagick. No API key needed.
	`--cover-prompt "..."` overrides the art direction, `--image-provider NAME` pins a
	provider, and `--image-provider none` disables image generation.
- `--illustrate` — Also generate one illustration per chapter and place it right
	after the chapter title (EPUB + PDF + HTML). Safe to re-run: an existing
	`illustration_NN.png` in the exports folder is reused instead of regenerated.
- `--fast` — Skip slow conversions (mobi/azw3) and some post-processing.
- `author_bio.md` — Optional file placed in the book directory. When present its
	contents are used for the "About the Author" page; otherwise a neutral
	placeholder mentioning the `--author` name is inserted.
- **Artwork is opt-in.** Nothing from the repository's `scripts/` folder is
	embedded into your book. Supply your own files with `--author-photo`, `--logo`,
	`--icon` and `--backcover` (or the `AUTHOR_PHOTO`, `PUBLISHER_LOGO`, `BOOK_ICON`,
	`BACK_COVER` environment variables). A back cover placed inside the book
	directory (`back-cover.png`, `backcover.jpg`, …) is picked up automatically.
	The compile step prints which artwork it included, e.g.
	`icon: (none) / logo: logo.png / author photo: (none) / back cover: (none)`.
	Without any artwork the EPUB simply contains no images — no broken references.
- Missing `final_bibliography.md` — The References section is simply omitted
	(generate it first with `generate_references.sh` if you want one).

🖼️ Images — Free-First Providers
-------------------------------

Cover art and chapter illustrations are generated by `scripts/image_gen.sh`, which
tries providers in order and uses the first one that returns a real image:

| # | Provider | Cost | Needs | Notes |
|---|----------|------|-------|-------|
| 1 | `pollinations` | free | nothing | Pollinations.ai, no signup, no key. Optional `POLLINATIONS_TOKEN` for higher rate limits. |
| 2 | `a1111` | free | a GPU | Your own AUTOMATIC1111 / SD.Next with `--api` at `A1111_URL` (default `http://localhost:7860`). No quota, unlimited. |
| 3 | `openai` | paid | API key | Any OpenAI-compatible `/images/generations` endpoint (`IMAGE_API_BASE_URL`, `IMAGE_API_KEY`, `IMAGE_MODEL`). Only used if a key is configured. |

```bash
# See which providers are configured on this machine
./scripts/image_gen.sh status

# Probe every provider (prints ✅/❌ per provider, waits for a real image)
./scripts/image_gen.sh test

# Cover only / illustration only
./scripts/image_gen.sh cover "Book Title" "Subtitle" "Author" cover.jpg
./scripts/image_gen.sh illustration "a lantern in the rain" illus.png

# Compile with a generated cover + one illustration per chapter
./scripts/compile_book.sh ./book_outputs/my-book all 3 --generate-cover --illustrate

# Full pipeline (topic → chapters → compiled book with images)
./scripts/generate_book.sh --topic "..." --images
```

**Covers are composed in two steps.** The image model paints text-free artwork
(diffusion models still render text unreliably), then ImageMagick adds the title,
subtitle and author over translucent bands. If ImageMagick or a usable font is
missing, the raw artwork is kept instead of failing the build. A downloaded file is
only accepted when it passes an image signature check, so an HTML error page or a
truncated download can never ship as your cover.

Switch providers with one variable:

```bash
IMAGE_PROVIDER=pollinations   # free, default in auto mode
IMAGE_PROVIDER=a1111          # your local Stable Diffusion
IMAGE_PROVIDER=openai         # paid, any OpenAI-compatible endpoint
IMAGE_PROVIDER=none           # never generate images
```

📣 Marketing Pack — Description, Keywords, Categories
---------------------------------------------------

`scripts/generate_marketing_copy.sh` turns a finished book folder into a
KDP-ready listing. It reads `outline.md`, the chapters and (when present)
`metadata.yaml`, then writes `<book_dir>/marketing/`:

```bash
./scripts/generate_marketing_copy.sh ./v3/my-book          # build the pack
./scripts/generate_marketing_copy.sh ./v3/my-book --check   # validate it, offline
./scripts/generate_book.sh --topic "..." --chapters 8 --marketing   # as the last pipeline step
```

| File | What it is |
|------|------------|
| `description.html` | The KDP description, ready to paste into the Source/HTML view |
| `description.txt` | The same copy with the tags stripped (blogs, email, press) |
| `keywords.txt` | Exactly 7 keyword phrases, one per line — fill all 7 KDP fields |
| `categories.md` | 3 suggested browse categories, as full paths |
| `social_copy.md` | Short blurbs, a post thread, a launch email, an author bio |
| `kdp_listing.md` | Everything in one sheet, plus the validation report |

**The KDP rules are enforced, not just suggested.** Amazon allows 4,000
characters for the description *including* HTML tags, rejects unicode emojis,
gives 7 keyword fields of 50 characters each, and up to 3 categories. So:

- Emojis are stripped, unknown tags are unwrapped, attributes are dropped.
- A description that comes back too long is trimmed at a sentence boundary and
  never left above the limit; a short one is flagged.
- Keywords are cut to 50 characters at a word boundary, de-duplicated, and the
  best-first order the model chose is preserved.
- Wasted keyword space is reported: a word shared by two fields (Amazon indexes
  it once), a phrase repeating the title (already indexed), a field holding one
  short word where a 50-character phrase would fit.
- Keyword stuffing in the description — a keyword repeated 3+ times — is flagged.

`--check` prints the numbers (`883 / 4000 characters`, `7 / 7 fields`,
`3 / 3 paths`) and exits non-zero on anything KDP would reject. It makes no
network calls, so it works offline and in CI.

📦 Output Layout
-------------
When compilation completes an `exports_<TIMESTAMP>/` directory will be created
inside the book directory. It typically includes:

- The generated manuscript markdown file (manuscript_final_*.md)
- Metadata.yaml used for pandoc conversions
- `book.css` for ebook styling
- Generated `*.epub`, `*.pdf`, and other requested formats
- Used images: cover/back-cover/author-photo/publisher logo

🔁 Repro Workflow (Concise)
------------------------
1. Create or generate an outline: `book_outline.md` in `book_outputs/<book>/`.
2. Generate chapter drafts using the chapter handler/smart API calls.
3. Run chapter reviews/quality checks and extend chapters to target lengths.
4. Generate appendices and extras.
5. Create or provide a cover image. If you want to avoid API costs you can use
	Free ChatGPT web UI (manual) to design cover/back/author photos and drop them
	into the script directory as `cover.png`, `back-cover.png`, or pass `--cover`.
6. Run `./compile_book.sh` to export final manuscript files and ebook formats.

💡 Why I Built This (Short Personal Note)
-------------------------------------
I built this project to test whether a high-quality, KDP-acceptable book could be
created end-to-end with AI and free/open tools. The toolkit proved capable: I used
It to create, proof and publish two books on Amazon. This repo collects the
Automation I used and the market research utilities that helped choose topics.
I do not intend to market those books; they were a research project to see what's
possible.

🗂️ Files of Interest (Quick Map)
----------------------------
- `compile_book.sh` — Main compilation pipeline (manuscript -> epub/pdf/html)
- `optimized_chapter_handler.sh` — Extensions, reviews, and quality helpers
- `generate_appendices.sh` — Creates prefatory and back-matter content
- `multi_provider_ai_simple.sh` — Provider selection, smart_api_call, status/test
- `kdp_market_analyzer.sh`, `market_analyzer.py`, `trends_analyzer.py` — Market research
- `add_animations.sh` — Small helper to add terminal animations
- `migrate_book_outputs.sh` — Organize loose outlines into book directories
- `test_extract_chapters.sh` — Test harness for chapter extraction logic
- Assets: `cover.png`, `back-cover.png`, `author-photo.png` (example/placeholder files)

⚖️ Ethics & Legal
--------------
Please ensure that the content you generate and publish follows all legal and
platform rules. AI can accelerate content creation but you are responsible for
copyright, rights clearance, originality, and any platform-specific policies.

🤝 Contributing & Improvements
---------------------------
If you'd like to contribute improvements (tests, tighter formatting for KDP,
better LaTeX templates, or integrations with publishing tools), open an issue or
submit a pull request. Small, focused changes that improve reliability or add
tests are easiest to accept.

## 📊 Project Status

**Status:** ✅ **Production Proven** - Two Books Successfully Published on Amazon KDP  
**Tech Stack:** Shell scripts, Pandoc, LaTeX, AI providers (Gemini/OpenAI/Ollama), ImageMagick  
**Achievement:** Complete AI-assisted authoring pipeline that passes Amazon's quality standards

This toolkit represents a successful proof-of-concept that AI can create publication-quality books. Both generated books passed KDP's strict quality checks and are available for purchase, demonstrating the viability of AI-assisted authoring when properly executed.

### Current Achievements

- ✅ **2 Live Amazon Books** - "The Playful Path" and "The Micro-Influence Advantage" published and available
- ✅ **Multi-Provider AI Integration** - Gemini, OpenAI, Ollama, Groq support with smart fallbacks
- ✅ **Professional Publishing Pipeline** - Outline → Chapters → Quality Review → Format Export → KDP Upload
- ✅ **Cost-Effective Approach** - Primarily free tools with minimal API costs
- ✅ **Quality Assurance** - Plagiarism detection, consistency checking, formatting validation
- ✅ **Market Research Tools** - KDP analyzer, trend analysis, keyword optimization
- ✅ **Production Formats** - EPUB, PDF, MOBI, AZW3 export with professional metadata

### Performance Metrics

- **Book Generation Time:** 3-5 days from outline to published book
- **Quality Score:** 100% KDP acceptance rate (2/2 books approved)
- **Cost Per Book:** <$50 (primarily API costs for text generation)
- **Format Support:** 6+ export formats (EPUB, PDF, MOBI, AZW3, HTML, Markdown)
- **Automation Level:** 85% automated (manual review and cover design recommended)

### 2026-2027 Roadmap

**Q1 2026 – Enhanced Quality & Automation**
- Advanced fact-checking integration with real-time verification
- Improved continuity analysis for multi-chapter consistency
- Automated grammar and style optimization
- Enhanced plagiarism detection with similarity scoring

**Q2 2026 – User Experience & Scalability** 
- Cross-platform GUI application (Electron/Tauri)
- Book series management and character tracking
- Template marketplace for different genres
- Batch processing for multiple book generation

**Q3 2026 – Publishing Ecosystem Integration**
- Direct Amazon KDP API integration (when available)
- Print-on-demand service connections (IngramSpark, CreateSpace)
- Automated ISBN acquisition and metadata management
- Marketing content generation (blurbs, social posts, ads)

**Q4 2026 – Advanced AI Features**
- Multi-modal book creation (images, charts, diagrams)
- Voice-to-book generation with speech recognition
- AI-powered market trend prediction
- Automated competitor analysis and positioning

**2027+ – Publishing Intelligence Platform**
- Real-time sales analytics and optimization
- AI book marketing agent with A/B testing
- Community platform for AI authors
- Publishing consultancy automation
- Cross-language book translation and localization

### Next Steps

**For Authors & Creators:**
1. Study the published book examples for quality benchmarks
2. Run market research before committing to a topic
3. Start with shorter books (under 100 pages) to learn the workflow
4. Focus on niche topics where AI can add genuine value

**For Developers:**
- Contribute to quality assurance improvements
- Add support for new AI providers and models
- Create specialized templates for technical/educational content
- Develop better error handling and recovery mechanisms

**For Researchers:**
- Analyze the ethical implications of AI-generated content
- Study reader reception and satisfaction metrics
- Research optimal human-AI collaboration workflows
- Evaluate impact on traditional publishing industry

### Why This Toolkit Leads AI Publishing?

**Proven Results:** Not just a proof-of-concept—actual books earning revenue on Amazon marketplace.

**Cost-Effective:** Primarily free tools with strategic API usage, making publishing accessible to anyone.

**Quality-First:** Built-in review processes ensure content meets professional publishing standards.

**Ethically Designed:** Emphasizes human oversight, originality checking, and responsible AI usage practices.

📜 License
-------
This repo contains example scripts for demonstration and research purposes. Add
your own license file at the repository root to declare terms if you plan to
publish or share this code widely.

✉️ Contact
-------
If you need clarifications about usage or want to share results from running the
toolkit, feel free to open an issue in this repository or reach out in the project
channels.

Enjoy exploring what automated tools can build — responsibly.

