# Changelog

All notable changes to Book Generator will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned for v1.1
- Enhanced editing workflow with AI revision suggestions
- Multiple book format support (technical, fiction, non-fiction templates)
- Collaborative authoring features
- Version control integration for manuscripts

### Planned for v1.2
- Direct Amazon KDP API integration
- Automated cover design generation
- Marketing copy generation (description, keywords, categories)
- Multi-language book generation

### Planned for v2.0
- Full publishing pipeline automation (draft → edited → formatted → published)
- Analytics dashboard for sales tracking
- Author community platform
- AI-powered reader feedback analysis

## [1.2.0] - 2026-10-12

### Fixed — AI layer (`scripts/multi_provider_ai_simple.sh`)

- **Gemini ignored the system prompt.** `call_gemini_api` built the JSON payload
	from the user prompt only (a `full_prompt` variable combined the two and was
	never used), so every role/style/format instruction was silently dropped — most
	visibly the "format chapters as `Chapter N: Title`" contract. The system prompt
	is now sent in Gemini's dedicated `systemInstruction` field.
- **No response cleanup anywhere.** Model chatter went straight into
	`chapter_NN.md`: "Sure! Here is the chapter you asked for:", a wrapping
	```markdown fence (rendered as a `<pre>` code block in EPUB/PDF), a duplicated
	`# Chapter N` heading, "Word count: 412" and "I hope this helps!". New
	`clean_ai_response` strips these from every provider and is applied to all text
	handed back to callers, while preserving genuine code blocks in technical books.
- **Originality scores were mis-parsed.** The check
	`grep -E "(score|rating).*[8-9]|10"` matched any stray "10" in the reply, so a
	chapter scoring 3/10 was reported as fully original. Scores are now extracted
	numerically (`ORIGINALITY: <n>/10`, plus `n/10` / `n out of 10` fallbacks) with a
	conservative "needs review" result when no score can be parsed.
- **Empty responses counted as success.** `jq -e` succeeds on an empty body, so an
	unreachable endpoint produced a "✓ Generated" message and empty text. Every
	provider now requires non-empty output before reporting success.
- **A failed rewrite destroyed the chapter.** `local result=$(smart_api_call …)`
	followed by `[ $? -eq 0 ]` tested the exit status of `local`, so a failed rewrite
	overwrote the chapter file with an empty string. The file is now only replaced by
	a non-empty result.
- **`SMART_API_PROVIDER` / `--provider` did nothing.** The flag was exported by
	`generate_book.sh` and read nowhere; the provider is now honoured (strictly).
- **Ollama ignored the token budget.** The request sent `max_tokens`, which the
	Ollama API does not read; it now sends `num_predict`.
- **`model_name` was used before it was assigned** in `call_ollama_api` (only the
	fallback loop ever set it), so when the `ollama` CLI was absent every model check
	compared against an empty string and context-window tuning silently did nothing.
	The requested model is now the default, and the `ollama list` probing is skipped
	when the CLI is missing.
- Removed the `sed "s|$prompt||g"` prompt-echo hack: it broke on any prompt
	containing regex characters, newlines or slashes — and could delete real prose.
- The caller-supplied retry budget (`generate_appendices.sh` and
	`generate_references.sh` pass 2) is no longer overwritten with 3.

### Changed

- **Prompts:** the outline prompt now asks for the exact chapter count and word
	target (it hardcoded "12-15 chapters of 2,500-3,000 words" regardless of the
	arguments) and for a machine-parseable `# Title` / `## Subtitle` /
	`### Chapter N: Title` structure; chapter prompts state explicitly that only the
	chapter body may be returned, and receive the tail of the previous chapter for
	voice continuity.
- **`generate_book.sh`:** chapter headings are extracted tolerantly (markdown,
	bold and bulleted `Chapter N` lines, de-duplicated by number). An outline with no
	usable chapter headings now aborts with the outline excerpt instead of writing
	chapters titled "Chapter 1: Chapter 1". Failed chapters are counted and the run
	aborts if every chapter failed.
- **Output-token budget** for a chapter is derived from `--words-per-chapter`
	(2×words, clamped to 4,096-8,192) so long chapters are no longer cut off
	mid-sentence by a provider default.
- **Fail fast:** an unreachable local Ollama is detected with a 2-second probe
	instead of cycling through every known model (~20 s of noise per call).
- **`compile_book.sh`:** the random pen-name default is gone. Compiling without
	`--author` used to attribute the book to a stranger from a hardcoded list
	("Elara Morgan"); the documented `AI-Assisted Author` default is kept.
- **`compile_book.sh`:** outline discovery compares file names instead of full
	paths. Any book directory whose name contained "final", "manuscript" or
	"chapter_" (a topic such as "The Final Cut") had its own `outline.md` rejected,
	so the export step failed with "No outline file found".
- **`compile_book.sh`:** chapter labels use the numeric chapter number, so a
	zero-padded file `chapter_01.md` now prints "Chapter 1" and finds its outline
	title (previously the label was duplicated as "Chapter 01 Chapter 01" because the
	`Chapter 1` outline lookup missed).

### Added

- `tests/ai_layer.bats` — 9 offline tests covering response cleanup, the Gemini
	`systemInstruction` payload, Ollama's `num_predict`, empty-response handling,
	provider pinning, originality-score parsing, the rewrite safety fix and outline
	chapter extraction. `curl` is replaced with a shell function, so no network or
	API key is needed (`bats tests/` → 19 tests).
- `README.md` — new "How the AI Layer Behaves" section.

## [1.1.1] - 2026-10-12

### Fixed — compile stage (the orchestrator could not finish a book)

- `scripts/generate_book.sh` passed version `1.0` to `compile_book.sh`, which only
  accepts `1|2|3`. Every run of the master pipeline therefore ended with
  `❌ Unknown argument: 1.0` and no exports were produced. Both the call site and the
  "compile manually" hint now use `1`.
- `scripts/compile_book.sh` wrote the `# References` heading and then ran
  `cat "$BIB_FILE"` unconditionally. Without a `final_bibliography.md` (the common
  case when `--skip-references` is used or `GEMINI_API_KEY` is unset) the failing
  `cat` aborted the script under `set -e` right after the chapters were assembled.
  The References section is now only emitted when a bibliography file exists.
- `scripts/compile_book.sh` chapter lookup only tried unpadded names
  (`chapter_1.md`) while `generate_book.sh` writes zero-padded ones (`chapter_01.md`).
  Every chapter was reported missing and only recovered by the autodetect fallback.
  The lookup now accepts both forms.
- `scripts/compile_book.sh` contained a hardcoded "About the Author" biography
  (a persona unrelated to the user's book) that was appended to every compilation.
  The bio now comes from an optional `author_bio.md` in the book directory, with a
  neutral placeholder mentioning `--author` as fallback.

### Fixed — AI layer

- `scripts/multi_provider_ai_simple.sh` used `bc` for temperature range validation,
  which is not installed by default on many systems (`bc: command not found`).
  Replaced with `awk`, removing an undocumented dependency.

### Added

- `tests/generator.bats` — three regression tests for the compile stage:
  version wiring between `generate_book.sh` and `compile_book.sh`, a minimal book
  building to EPUB, and the compiled manuscript containing no hardcoded placeholder
  content.

### Changed

- `.gitignore` — ignore `multi_provider_logs/` runtime output created by the AI layer.
- `README.md` — document `author_bio.md` and the bibliography behaviour.

## [1.1.0] - 2025-01-01

### Phase 1: Foundation Fixes

#### Added
- `scripts/generate_book.sh` — master orchestrator chaining the full 6-step pipeline
  (outline → chapters → appendices → references → plagiarism check → compile)
- `requirements.txt` — runtime Python dependencies (`requests`, `beautifulsoup4`)
- `.env.example` — template for API keys and optional defaults

#### Fixed
- Model override (`--model` / `-m` flag) was silently ignored; now correctly pins Gemini
  models via temp `GEMINI_MODELS` override and Ollama models via direct API call
  (`scripts/multi_provider_ai_simple.sh`)
- Removed ~70 lines of unreachable dead code in `generate_book_cover()` that followed
  an early `return 0` (`scripts/compile_book.sh`)
- `demo.sh` existence check pointed to `./generate_book.sh`; corrected to
  `./scripts/generate_book.sh`
- Two BATS tests in `tests/generator.bats` pointed to `./generate_book.sh`; corrected
  to `./scripts/generate_book.sh`

## [1.0.0] - 2024-12-15

### 🎉 Proof-of-Concept Complete

Book Generator has successfully demonstrated feasibility by producing **books on Amazon KDP**
using a fully Bash-based pipeline driven by multi-provider AI (Gemini, Groq, Ollama).

### Achievements

**Published Books (v3/ pipeline):**
- Full-length manuscripts (50,000+ words) generated end-to-end via shell scripts
- Amazon KDP formatting compliance
- Cover design integrated via ImageMagick (`generate_book_cover()`)
- Metadata and keyword optimization workflow

**Validation:**
- ✅ Full manuscript generation
- ✅ Chapter structure and organisation
- ✅ PDF, EPUB, HTML, MOBI output via Pandoc + ImageMagick
- ✅ Multi-provider AI fallback (Gemini → Groq → Ollama)
- ✅ Plagiarism detection pass per chapter

### Core Scripts

| Script | Purpose |
|--------|---------|
| `scripts/generate_book.sh` | Master orchestrator — full pipeline in one command |
| `scripts/multi_provider_ai_simple.sh` | AI provider abstraction + all generation functions |
| `scripts/compile_book.sh` | Assembles chapters → PDF / EPUB / HTML / MOBI |
| `scripts/generate_appendices.sh` | AI-generated appendices (requires `GEMINI_API_KEY`) |
| `scripts/generate_references.sh` | AI-generated bibliography (requires `GEMINI_API_KEY`) |
| `scripts/generate_covers.sh` | Standalone cover generation utility |
| `scripts/kdp_topic_finder.sh` | KDP market research and topic discovery |
| `scripts/plagiarism_report_manager.sh` | Plagiarism report utilities |

### AI Provider Priority

1. **Gemini** (if `GEMINI_API_KEY` set) — primary provider, model rotation via `GEMINI_MODELS` array
2. **Ollama** — local fallback, model array with priority order
3. **Groq** — cloud fallback

### Known Limitations

1. **Human Editing Required** — AI generates high-quality drafts; final polish is manual
2. **Cover Design via ImageMagick** — B&W programmatic covers; AI image covers require `OPENAI_API_KEY`
3. **KDP Upload Manual** — no API integration yet
4. **Appendices/References** require Gemini API key (Ollama path not implemented)

### Technical Dependencies

- Bash 4+ (macOS: `brew install bash`)
- Pandoc (PDF/EPUB/HTML/MOBI compilation)
- ImageMagick (cover generation)
- `jq` (JSON parsing for AI responses)
- Python 3.9+ with `requests`, `beautifulsoup4` (optional tooling)
- At least one AI provider key or local Ollama running

## [0.3.0] - 2024-10-01

### Added
- Multi-format export (PDF, EPUB, MOBI) via Pandoc
- Amazon KDP formatting utilities
- Cover image generation via ImageMagick

### Changed
- Improved chapter generation prompts for better consistency
- Enhanced outline structure with hierarchical chapters
- Better error handling in pipeline scripts

## [0.2.0] - 2024-08-15

### Added
- Chapter-by-chapter generation workflow
- Multi-provider AI fallback (Gemini → Ollama)
- Word count tracking per chapter
- Plagiarism check integration

### Fixed
- API rate limiting with exponential backoff
- Chapter ordering and accumulation logic

## [0.1.0] - 2024-06-01

### Added
- Initial proof-of-concept
- Basic outline generation
- Single chapter generation
- Simple text compilation
- README documentation

### Notes
- First working prototype
- Successfully generated 10-chapter test book
- Validated AI content generation approach

---

## Version History

- **1.0.0** (2024-12-15) - POC complete, 2 books published
- **0.3.0** (2024-10-01) - Multi-format export added
- **0.2.0** (2024-08-15) - Chapter workflow improvements
- **0.1.0** (2024-06-01) - Initial prototype

---

## Links

- **Repository**: https://github.com/wesleyscholl/book-generator
- **Published Books**: See Amazon KDP author profile
- **Issues**: https://github.com/wesleyscholl/book-generator/issues

---

## Future Vision

The goal is to evolve Book Generator from a proof-of-concept into a **full-featured AI-assisted authoring platform** that:

1. **Democratizes Publishing** - Make book creation accessible to everyone
2. **Maintains Quality** - Ensure AI-generated content meets human standards
3. **Automates Tedium** - Handle formatting, metadata, and distribution logistics
4. **Empowers Creativity** - Let authors focus on ideas, not mechanics
5. **Builds Community** - Connect AI-assisted authors for learning and support

---

**Disclaimer:** This tool assists in content generation but does not replace human creativity, editing, and oversight. All AI-generated content should be reviewed, fact-checked, and refined before publication.
