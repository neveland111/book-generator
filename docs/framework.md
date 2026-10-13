# Framework Book Generator — Jabaran Lengkap

> Keadaan repo pada rilis **v1.6.0**, branch `arena/1b3521bd-book-generator`.
> Semua angka di dokumen ini diverifikasi langsung dari isi repo (jumlah baris, nama fungsi, dan 47 tes otomatis).

---

## 1. Gambaran besar: 8 lapisan

```
                    ┌──────────────────────────────────────────┐
   RISET PASAR      │ kdp_topic_finder · kdp_market_analyzer   │  cari topik yang
   (opsional)       │ get_keywords · topic_market_research     │  laku di Amazon
                    └───────────────────┬──────────────────────┘
                                        │ (topik + keyword)
                    ┌───────────────────▼──────────────────────┐
   OTAK AI          │ multi_provider_ai_simple.sh              │  6 provider teks,
   (lapisan inti)   │ gemini · groq · ollama · anthropic ·     │  fallback otomatis,
                    │ openai · custom(OpenAI-compatible)       │  .env, retry, cooldown
                    └───────┬───────────────────────┬──────────┘
                            │                       │
              ┌─────────────▼──────────┐  ┌─────────▼─────────────┐
   PIPE       │ generate_book.sh       │  │ agent_book.sh         │
   (2 pilihan)│ 6 langkah, batch       │  │ 4 langkah + loop      │
              │ deterministik          │  │ kritik → revisi       │
              └─────────────┬──────────┘  └─────────┬─────────────┘
                            └───────────┬───────────┘
                    ┌───────────────────▼──────────────────────┐
   GAMBAR           │ image_gen.sh                             │  pollinations
                    │ rantai gratis dulu → berbayar terakhir   │  → a1111 → openai
                    └───────────────────┬──────────────────────┘
                                        │
                    ┌───────────────────▼──────────────────────┐
   KOMPILASI        │ compile_book.sh                          │  3 versi naskah,
                    │ EPUB · PDF · HTML · MD · MOBI · AZW3     │  metadata, artwork
                    └───────────────────┬──────────────────────┘
                                        │
                    ┌───────────────────▼──────────────────────┐
   GERBANG MUTU     │ originality check · rubrik 0-10          │  berhenti kalau
                    │ validasi gambar · quality assessment     │  mutu di bawah ambang
                    └───────────────────┬──────────────────────┘
                                        │
                    ┌───────────────────▼──────────────────────┐
   UJI & DOKUMEN    │ 47 tes bats + stub provider offline      │  bukti, bukan klaim
                    │ README · CHANGELOG · cara-kerja.html     │
                    └──────────────────────────────────────────┘
```

Total: **16 skrip shell**, 11.647 baris, **47 tes otomatis**, 4 berkas dokumentasi.

---

## 2. Lapisan AI — `scripts/multi_provider_ai_simple.sh` (1.633 baris)

Ini jantungnya. Semua skrip lain memanggil fungsi dari sini (`smart_api_call`), bukan URL API langsung.

### Provider teks yang didukung

| Provider | Fungsi | Kunci | Biaya |
|---|---|---|---|
| Gemini | `call_gemini_api` | `GEMINI_API_KEY` | gratis (limit harian) |
| Groq | `call_groq_api` | `GROQ_API_KEY` | gratis (limit harian) |
| Ollama | `call_ollama_api` | — | gratis, lokal |
| Anthropic | `call_anthropic_api` | `ANTHROPIC_API_KEY` | berbayar |
| OpenAI | `call_custom_api` | `OPENAI_API_KEY` | berbayar |
| **custom** | `call_custom_api` | `CUSTOM_API_*` | tergantung |

Provider `custom` adalah pintu masuk universal: **apa pun** yang bicara format OpenAI `/chat/completions` —
OpenRouter, DeepSeek, Together, Mistral, xAI, Fireworks, LM Studio, vLLM, atau server sendiri.

### Yang ditangani lapisan ini

- **Fallback otomatis** — `SMART_API_PROVIDER=auto`: coba Gemini → Ollama → Groq → custom → (anthropic), turun ke provider berikutnya kalau yang sekarang gagal.
- **Pin provider** — `--provider gemini` memaksa satu provider, dan **berteriak** kalau kuncinya tidak ada (sebelumnya diam-diam diabaikan).
- **8 jenis tugas** dengan prompt berbeda: `outline`, `chapter`, `plagiarism`, `rewrite`, `critique`, `revise`, `appendices`, `references`.
- **Retry + cooldown** — `smart_api_call` bisa dikasih budget retry (default 3; appendices/references pakai 2), plus catatan waktu error per model (`get_model_error_time`) supaya model yang sedang mati tidak dipanggil berulang.
- **`clean_ai_response`** — membuang basa-basi pembuka ("Sure! Here is the chapter…"), pagar ```markdown, dan kalimat penutup; **tapi tetap mempertahankan blok kode asli** di bab teknis.
- **Ekstraksi judul bab** (`extract_outline_chapters`) — toleran terhadap heading markdown/bold/bullet, dan de-duplikasi per nomor bab supaya daftar ringkasan di bawah outline tidak menyusupkan bab ekstra.
- **Parsing skor** — `score_below_threshold`, `critique_overall_score`.
- **`.env` dimuat otomatis** (`load_dotenv_if_present`) tanpa menimpa variabel yang sudah di-`export` manual.

### CLI-nya sendiri

```bash
./scripts/multi_provider_ai_simple.sh status          # provider mana yang terbaca
./scripts/multi_provider_ai_simple.sh test            # uji semua provider
./scripts/multi_provider_ai_simple.sh estimate 12 2500  # estimasi biaya
```

---

## 3. Jalur A: Batch — `scripts/generate_book.sh` (373 baris)

Pipeline lurus 6 langkah, deterministik, tanpa pengambilan keputusan.

| Langkah | Yang dilakukan | Skrip yang dipanggil |
|---|---|---|
| `[1/6]` | Bikin outline (jumlah bab & kata sesuai permintaan) | `generate_outline_with_smart_api` |
| `[2/6]` | Tulis tiap bab, satu per satu | `generate_chapter_with_smart_api` |
| `[3/6]` | Lampiran | `generate_appendices.sh` |
| `[4/6]` | Bibliografi / daftar pustaka | `generate_references.sh` |
| `[5/6]` | Cek orisinalitas tiap bab | `check_plagiarism_with_smart_api` |
| `[6/6]` | Kompilasi jadi buku | `compile_book.sh` |

**Opsi CLI:** `--topic --genre --chapters --words-per-chapter --output-dir --pen-name --provider --style --tone --audience --skip-appendices --skip-references --skip-compile --quiet --images --illustrate --generate-cover --image-provider`

Setiap langkah bisa di-`--skip`, jadi bisa dipakai untuk menulis bab saja lalu dikompilasi manual.

---

## 4. Jalur B: Agent — `scripts/agent_book.sh` (358 baris)

Bukan sekadar batch: ada **loop penilaian diri**. Ini yang dimaksud "AI enhancer" di dokumen `cara-kerja.html`, dan sudah terpasang.

| Langkah | Yang dilakukan |
|---|---|
| `[1/4]` | **Planing** — susun outline |
| `[2/4]` | **Tulis → nilai → perbaiki** per bab |
| `[3/4]` | **Cek orisinalitas** |
| `[4/4]` | **Kompilasi** |

Loop di langkah 2 inilah bedanya:

1. Bab ditulis dengan AI.
2. Bab itu **dinilai sendiri** lewat rubrik → skor 0–10, ditulis ke `critique_chapter_NN.md`.
3. Kalau skor **< ambang** (default `--threshold 8`) → bab **ditulis ulang** dengan menyertakan kritiknya sebagai bahan (`revise_chapter_with_report`).
4. Bab dinilai **lagi** → skor baru; kalau masih di bawah ambang dan jatah revisi belum habis, ulangi.
5. Semua jejaknya direkam ke `agent_report.md` — skor awal, skor akhir, berapa kali direvisi.

**Opsi:** `--threshold N` (0–10, default 8), `--max-revisions N` (default 1; `0` = matikan revisi), `--skip-originality`, `--skip-compile`.

**Biaya:** karena tiap bab dinilai dan mungkin ditulis ulang, pemakaian API ≈ **2–3× lipat** dibanding jalur batch. Ini konsekuensi wajar dari "agent mode" — bukan bug.

---

## 5. Lapisan gambar — `scripts/image_gen.sh` (521 baris)

Baru di v1.6.0. Rantai provider, dicoba berurutan, pakai yang pertama berhasil:

| # | Provider | Biaya | Syarat |
|---|---|---|---|
| 1 | `pollinations` | **gratis** | tidak ada (model `flux`; `POLLINATIONS_TOKEN` opsional) |
| 2 | `a1111` | **gratis** | GPU sendiri, Stable Diffusion lokal via `--api` |
| 3 | `openai` | berbayar | key + endpoint `/images/generations` kompatibel OpenAI |
| — | `none` | — | mematikan gambar sepenuhnya |

**Fungsi penting:**

- `generate_image` — mencoba rantai provider sampai ada yang menghasilkan gambar sah.
- `validate_image_file` — **pemeriksa magic bytes**; file <1 KB atau yang bukan gambar (halaman error HTML 404/429) **selalu ditolak**. Ini yang mencegah halaman error jadi sampul buku.
- `generate_ai_cover` — komposisi **dua langkah**: model melukis seni **tanpa teks** → ImageMagick menempel judul/subjudul/penulis di pita transparan. Default 1600×2560 (standar KDP).
- `build_cover_prompt` / `build_illustration_prompt` — prompt dengan arahan seni; prompt sampul tegas menolak teks dan menyisakan sepertiga atas & bawah.
- `ig_find_font` — cari font dari `-list font`, kalau gagal cari file font di disk; kalau tidak ada keduanya, **kompilasi tetap jalan** (seni mentah dipakai).

**CLI:** `status` · `test` · `cover` · `illustration` · `prompt`

---

## 6. Lapisan kompilasi — `scripts/compile_book.sh` (2.267 baris, terbesar)

Dari markdown jadi buku jadi. Ini yang mengurus semua detail produksi.

**3 versi naskah** — `1` original · `2` edited · `3` final.

**7 format keluaran** — `all` · `epub` · `pdf` · `html` · `markdown` · `mobi` · `azw3`
(di dalamnya: EPUB via pandoc, PDF via LaTeX/xelatex dengan jatuh ke *print-ready HTML* kalau TeX tidak ada, MOBI/AZW3 via Calibre.)

**Yang dirakit otomatis:** halaman sampul · halaman judul · halaman hak cipta · daftar isi · bab-bab berurutan · bagian "Tentang Penulis" · Referensi · lampiran · `metadata.yaml` · `book.css`.

**Fitur teknis yang sudah beres:**

- **Auto-deteksi buku terbaru** di `book_outputs/` kalau argumennya dikosongkan.
- **Blok `EPUB_ONLY` / `PDF_ONLY`** — satu naskah bisa punya konten berbeda untuk EPUB dan PDF (di-strip otomatis via `sed` saat ekspor).
- **Post-processing page break** — token `PAGE_BREAK_TOKEN` dan sisa `{=latex}\newpage` diganti jadi blok LaTeX mentah yang sah.
- **Artwork opt-in** — tidak ada aset repo yang menempel ke buku Anda. Pakai `--cover --backcover --author-photo --logo --icon` (atau env `AUTHOR_PHOTO`, `PUBLISHER_LOGO`, `BOOK_ICON`, `BACK_COVER`); berkas `back-cover.*` di folder buku terdeteksi sendiri. Kompilasi mencetak persis apa yang dipakai: `icon: (none) / logo: logo.png / author photo: (none) / back cover: (none)`.
- **Quality assessment** di akhir — cek jumlah kata total (ambang 20k/25k–35k) dan rata-rata panjang bab (1.500/2.000–3.000 kata), lalu beri ✅/⚠️.

**Opsi:** `--author --cover --backcover --isbn --publisher --year --generate-cover --illustrate --cover-prompt --image-provider --author-photo --logo --icon --fast`

---

## 7. Lapisan riset pasar & KDP

Modul untuk memutuskan **buku apa yang layak ditulis** — sebelum satu kata pun ditulis AI.

| Skrip | Baris | Fungsi |
|---|---|---|
| `kdp_topic_finder.sh` | 480 | Cari topik yang sedang naik: Google Trends RSS + Reddit hot, filter jumlah review 5–800 (relung yang belum padat), cache 6 jam → CSV peluang |
| `kdp_market_analyzer.sh` | 230 | Analisis mendalam satu topik: kompetisi, harga, celah |
| `get_keywords.sh` | 890 | Riset keyword Amazon KDP → CSV siap tempel ke KDP |
| `topic_market_research.sh` | 1.757 | Riset pasar komprehensif, pakai cache + sumber terbuka, hasil JSON |
| `plagiarism_report_manager.sh` | 537 | Baca laporan orisinalitas: ringkasan (`summary`) atau detail per bab (`details`) |

---

## 8. Lapisan mutu: gerbang yang menghentikan pipeline

Tiga gerbang berbeda, di tiga titik:

1. **Originality check** (jalur batch & agent) — tiap bab dinilai AI. Hasilnya tiga tingkat: lolos · **Medium originality** (ditandai) · **Low originality** (peringatan tegas "review before publishing"). Di akhir dicetak berapa bab yang ditandai.
2. **Rubrik agent 0–10** — bab di bawah ambang ditulis ulang, bukan sekadar dilaporkan.
3. **Validasi berkas gambar** — magic bytes; gambar palsu/rusak tidak pernah lolos jadi sampul.

Ditambah **quality assessment** di akhir kompilasi (panjang buku & bab).

---

## 9. Lapisan uji & dokumentasi

**47 tes otomatis, 0 gagal** (terakhir dijalankan di sandbox):

| Berkas | Jumlah | Fokus |
|---|---|---|
| `tests/ai_layer.bats` | 18 | Lapisan AI: format request tiap provider, fallback, parsing skor, `.env`, pembersihan respons |
| `tests/generator.bats` | 15 | Pipeline & kompilasi: EPUB terbentuk, artwork tidak bocor, sampul yang diberikan benar-benar masuk EPUB |
| `tests/image_gen.bats` | 14 | Lapisan gambar: ketiga protokol provider, penolakan HTML, rantai jatuh ke provider hidup, komposisi sampul |
| `tests/fixtures/image_stub_server.py` | — | Server stub lokal: meniru Pollinations + A1111 + OpenAI-compatible sekaligus, jadi seluruh rantai gambar bisa diuji **tanpa internet dan tanpa API key** |

**Dokumentasi:** `README.md` (28 KB) · `CHANGELOG.md` (24 KB, terlacak dari v0.1.0 → v1.6.0) · `docs/cara-kerja.html` (36 KB, bahasa Indonesia) · `docs/framework.md` (dokumen ini) · `.env.example`

---

## 10. Yang BELUM ada — celah yang jujur

Supaya Anda tahu batasnya, bukan cuma isinya:

| Celah | Keterangan |
|---|---|
| **Belum ada unggah otomatis ke KDP** | Amazon tidak menyediakan API publik untuk ini. Selalu langkah manual di akhir. |
| **Belum ada generator copy marketing** | Deskripsi buku, blurb, 7 keyword KDP, kategori BISAC — belum ada skripnya, padahal ini wajib saat unggah. Yang ada baru riset keyword. |
| **"Plagiarism check" = penilaian AI** | Bukan pencocokan ke basis data Turnitin/iThenticate. Ia menilai orisinalitas gaya, bukan mendeteksi kemiripan teks dengan korpus global. |
| **Riset pasar bergantung pada sumber luar** | Google Trends RSS & Reddit — rapuh kalau situsnya berubah, dan rentan diblokir. |
| **`generate_covers.sh` sudah usang** | Ia mengotomasi UI ChatGPT/Gemini lewat Playwright — rapuh dan melanggar ToS. Sekarang sudah ada pengganti yang lebih baik: `image_gen.sh`. |
| **PDF butuh TeX Live, MOBI/AZW3 butuh Calibre** | Kalau tidak ada, PDF jatuh ke *print-ready HTML* dan MOBI/AZW3 dilewati dengan peringatan. |
| **Belum ada multi-bahasa eksplisit** | Prompt berbahasa Inggris; hasil bisa diminta bahasa lain, tapi belum ada saklar `--language`. |
| **Belum ada template genre** | Fiksi vs non-fiksi vs teknis belum punya kerangka berbeda. |
| **Belum ada CI** | Tidak ada GitHub Actions yang menjalankan 47 tes otomatis tiap push. |
| **Belum ada mode lanjut (resume)** | Kalau pipeline berhenti di bab 7, menjalankannya lagi mulai dari awal (kecuali pakai `--skip-*` manual). |
| **Belum ada audiobook** | Tidak ada jalur teks→suara. |

---

## 11. Peta berkas

```
book-generator/
├── scripts/
│   ├── generate_book.sh              ← jalur batch (6 langkah)
│   ├── agent_book.sh                 ← jalur agent (4 langkah + loop kritik)
│   ├── compile_book.sh               ← kompilasi 7 format, 2.267 baris
│   ├── image_gen.sh                  ← gambar gratis dulu (v1.6.0)
│   ├── multi_provider_ai_simple.sh   ← inti AI: 6 provider, fallback, .env
│   ├── multi_provider_ai.sh          ← versi lama (rate-limit berbasis file)
│   ├── generate_appendices.sh        ← lampiran
│   ├── generate_references.sh        ← bibliografi
│   ├── kdp_topic_finder.sh           ← cari topik laku
│   ├── kdp_market_analyzer.sh        ← analisis satu topik
│   ├── get_keywords.sh               ← keyword KDP
│   ├── topic_market_research.sh      ← riset pasar (1.757 baris)
│   ├── plagiarism_report_manager.sh  ← baca laporan orisinalitas
│   ├── generate_covers.sh            ← usang (Playwright UI scraping)
│   ├── optimized_chapter_handler.sh  ← helper panjang bab
│   └── migrate_book_outputs.sh       ← migrasi struktur output
├── tests/
│   ├── ai_layer.bats (18)
│   ├── generator.bats (15)
│   ├── image_gen.bats (14)
│   └── fixtures/image_stub_server.py
├── docs/cara-kerja.html              ← walkthrough (Indonesia)
├── docs/framework.md                 ← dokumen ini
├── README.md · CHANGELOG.md · .env.example · demo.sh · requirements.txt
```

---

## 12. Jalur tercepat mencoba semuanya

```bash
# 1. Cek provider yang siap
./scripts/multi_provider_ai_simple.sh status
./scripts/image_gen.sh status

# 2. Buku kecil dulu (1 bab, 800 kata) — murah, cepat
./scripts/generate_book.sh --topic "Topik uji" --chapters 1 --words-per-chapter 800 \
  --pen-name "Nama Anda" --skip-appendices --skip-references --images

# 3. Kalau sudah cocok, buku sungguhan dengan jalur agent
./scripts/agent_book.sh --topic "Topik Anda" --chapters 12 --words-per-chapter 2500 \
  --pen-name "Nama Anda" --threshold 8 --max-revisions 1

# 4. Rapikan untuk terbit
./scripts/compile_book.sh v3/<folder-buku> all 1 --author "Nama Anda" \
  --generate-cover --illustrate --isbn "978-..."
```
