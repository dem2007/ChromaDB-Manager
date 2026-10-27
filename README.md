<img src="docs/app-icon-1024.png" width="128" alt="ChromaDB Manager" align="left">

# ChromaDB Manager

<br clear="left">

**English** · [Русский](README.ru.md)

A native macOS app (Swift + SwiftUI) for a local knowledge base on
[ChromaDB](https://www.trychroma.com/) — no terminal and no Python. It installs and
updates the engine, parses and indexes your documents, spreadsheets, websites and
repositories, searches them through a configurable pipeline, measures search
quality, and gives agents access to the base over MCP — with keys and permissions.
Vectors are computed by a local [LM Studio](https://lmstudio.ai/): documents never
leave the machine.

> **Version 0.4.2.** What follows describes what is implemented and works. What is
> deliberately not done, and where the app's limits are, is in
> [Known limitations](#known-limitations).

```
folders, sites,    parsing and      LM Studio        ChromaDB        search on screen,
git, sheets   ──►  chunking    ──►  (vectors)   ──►  (own or    ──►  agents over MCP,
                                                     external)       clients via the proxy
```

The interface is available in English and Russian.

---

## Contents

- [Features](#features)
  - [Database and server](#database-and-server)
  - [Collections](#collections)
  - [Sources and synchronisation](#sources-and-synchronisation)
  - [Document parsing](#document-parsing)
  - [Spreadsheets](#spreadsheets)
  - [Chunking](#chunking)
  - [Models and vectors](#models-and-vectors)
  - [Search](#search)
  - [Quality evaluation bench](#quality-evaluation-bench)
  - [Viewing the source document](#viewing-the-source-document)
  - [Agents and MCP](#agents-and-mcp)
  - [Access, keys and security](#access-keys-and-security)
  - [macOS integration](#macos-integration)
- [Installation](#installation)
- [Building from source](#building-from-source)
- [Documentation](#documentation)
- [Known limitations](#known-limitations)
- [License](#license)

---

## Features

The governing rule is **nothing silently.** A file that could not be read, a chunk
that did not fit the model, a row that vanished from a sheet — each goes into a
report with its reason and an action, instead of being lost. Nothing is ever
deleted from the base automatically: what disappeared from disk waits for a
person to decide.

### Database and server

- **Two ways to install the engine.** By default, the standalone Chroma CLI without
  Python: the app shows the version, size and URL of the official release and
  downloads only after you confirm. The second way is `pip install chromadb` into
  the app's own virtual environment; the system and Homebrew Pythons are left
  alone.
- **Updating without losing data:** collection counts → stop the server → copy the
  database → update → check that the database opens and the document count
  matches. Skipping the copy takes a separate "I understand the risk" checkbox.
- **A local database** is just a folder: the app starts a server for it on
  `127.0.0.1` itself, and ports stay out of sight. **An external server** is a
  profile with an address, tenant, database and token (tokens live in the
  Keychain). Without an installed engine you can work with an external server
  fully.
- **Server management:** start, stop, restart, process output with a filter, a log
  of every start on disk. Crashes are translated into plain language ("the port is
  already taken by another process" instead of a panic message), the port is
  checked before starting, and a server left over from the previous session is
  found and picked up.
- **Backups** with a free-space check, restore and an "incomplete copy" marker;
  **compacting the database** after mass deletions; **deleting the app's data**
  with a list of paths and sizes — the folders of your databases are never
  touched.
- **Disk usage** on the "Status" screen: the database, the engine, backups, the
  trash, the vector cache, service data and logs — part by part, with the free
  space of the volume and a warning when the next database backup will not fit.
  Each row leads to where that part is made smaller.

### Collections

- A list with record count, dimension, model and metric; collections not created
  by this app are marked "model unknown". A model can be bound to a foreign
  collection — with a dimension check.
- **The metric is set explicitly, `cosine` by default**, and read back from the
  server. ChromaDB's own default is `l2`, while LM Studio models are normalised for
  cosine.
- **An HNSW index with `ef_search` 500** for new collections: with the server's 100,
  the graph search lost up to half of the true nearest neighbours on short
  term-like queries. The other index parameters are in an "advanced" block.
- **Documents:** paged browsing of a collection of any size, full text, metadata
  and a vector preview; metadata editing; editing the text **always** recomputes
  the vector with the same model.
- **Filters as a tree:** eight metadata operators, nested `$and`/`$or`, search in
  document text, lossless "tree ↔ JSON" switching, saved filters per collection.
  Values the server would reject are named before sending.
- **Metadata schemas:** types, required fields, defaults, a date with a numeric
  twin for range filters; checking documents against the schema — as a report,
  without rewriting anything.
- **CSV and JSON import** with a preview and column mapping; **moving a collection
  as a `.chromaexport` package** — streamed, with a checksum, a filter, with or
  without vectors, resuming from where it broke off.
- **Recomputing vectors** — as a clone into a new collection or in place, with a
  mandatory backup, pause, cancel and a check at the end; re-chunking can use the
  strategy parameters of the source.
- **Health inspector:** empty and short documents, gaps in chunk numbering,
  orphans, schema mismatches, duplicates and near-duplicates — using the vectors
  already in the base, without a single model call. The inspector only reads;
  decisions are a person's.
- **Composition overview** — distributions by source, format, date and length —
  and **collection topics**: k-means over the vectors and topic names from a chat
  model, as a list with examples rather than a picture.
- **Files of a collection:** every file across the whole collection, not a
  sample — name, folder, chunk count, size and date; search by name and path;
  the `file_id` for `get_file` copied with one button; the file opens whole, and
  its chunks and a search inside it are one step away; the list exports to CSV.
- **Trash:** deleted documents and collections can be brought back; its limit is
  configurable, and a collection that does not fit into it is explained right in
  the delete dialog.

### Sources and synchronisation

- **Three kinds of source:** a folder on disk, the web (a page, a list of
  addresses or a site crawl) and a git repository.
- **Where things go:** the whole folder into one collection, subfolders into their
  own collections, one collection with the path in metadata, or your own rule by
  regular expression.
- **Fields from the path:** `Systems/2025/System 1/charter.docx` gives
  `year = 2025` and `system = System 1` — and the results are filtered by them
  instead of splitting into twenty collections. Levels are named against the
  folder tree with a preview; fields change without recomputing vectors.
- **Extensions in groups** (documents, spreadsheets, presentations, text, code)
  with the number of such files in the folder; **"Copy source"** — for a series
  of experiments without retyping the settings.
- **Incremental synchronisation by manifest:** nothing changed on disk — not a
  single model call; a change of chunking or model counts as a change too. "Plan"
  shows what a run would do without writing anything, with an estimate of volume
  and time from the model's measured speed.
- **An interruption loses no data.** New chunks are written first, old ones are
  removed afterwards and by an explicit list; the intent goes into a journal before
  the first write, and an interrupted run is completed on the next start.
- **The environment does not eat data:** a source remembers its disk by UUID — the
  wrong or a disconnected disk and the run does not happen; losing more than half
  of the files stops the run because it looks like a disconnected disk; a file
  being copied is not read halfway, and an iCloud file without content is not
  downloaded silently.
- **Automation:** at app start, on a schedule and on changes in the folder — in one
  task queue with priorities, a global pause and an indicator in the menu bar.
- **Web:** five mandatory crawl limits (depth, page count, domain, delay, volume),
  `robots.txt` and the sitemap, conditional requests with `ETag` — a repeated crawl
  is almost free. Non-HTML behind a link goes to document parsing.
- **Git:** the file list comes from `git ls-files`, changes from `git diff` against
  the saved commit; a rename costs no vectors; a branch switch is noticed and
  starts nothing by itself.
- **Diagnostics:** every file that was not read or was read with caveats, with a
  reason and an action — turn on recognition, enter a password, assign a sheet
  profile, retry, exclude. The run summary groups what was skipped by reason.

### Document parsing

**No third-party dependencies and not a line of Python:** everything is read with
system frameworks and the app's own format parsers.

| Format | How it is read |
|---|---|
| `.pdf` | PDFKit text layer; tables by rulings and character positions; the document outline as structure |
| `.docx`, `.doc`, `.odt`, `.rtf` | own parsers for `.docx` and binary `.doc`: styles, list numbering by the standard, tables, footnotes and comments |
| `.pptx` | slides in order, tables, SmartArt, charts, speaker notes |
| `.epub` | chapters by `spine`, table of contents, DRM told apart from font obfuscation |
| `.html` | headings become structure; menus, scripts and styles are dropped |
| `.pages`, `.key` | exported through Pages and Keynote themselves, with permission |
| text, Markdown, code, JSON | directly; UTF-8/16, cp1251, KOI8-R and CP866 encodings |
| scans | Vision, only if recognition is turned on for the source |

- **Tables stay tables.** In a PDF a table is assembled by its rulings rather than
  guessed from spaces; a cell broken by a page is one row; the rows of a numbered
  item ("Server, consisting of: …") are one record with its number and name. The
  value of a merged cell is in each of its cells, a caption across the full width
  appears once. A printed form with a grid of a hundred narrow columns is written
  as lines of text, and a table inside it as a grid.
- **Scans.** A scan inside a PDF with a text layer is recognised at its native
  resolution, tables on a scan are assembled into tables, a rotated page is turned
  upright, a drawing on a large sheet is read in tiles. The time limit is per page:
  a difficult page is skipped alone, with its number in the caveats, instead of
  failing the document.
- **Characters for search:** non-breaking spaces and hyphens, soft hyphens, Symbol
  and Wingdings font characters (list bullets) become ordinary characters; running
  headers and the table of contents do not duplicate the document text.
- **The origin is visible in metadata:** extractor and its version, format,
  structure source, page, section (`heading_path`), slide, table and OCR flags. A
  new extractor version is **an offer, not work:** files read by the previous one
  are listed on the source card, and nothing is recomputed until you press the
  button.
- **A password-protected PDF** asks for the password once and keeps it only in the
  Keychain.

### Spreadsheets

Spreadsheets have their own pipeline: a flat row "2024-03-15 | 4820 | Moscow"
yields a vector that means nothing.

- **Formats:** `.xlsx`, `.xlsm`, `.xls`, `.ods`, `.csv`, `.tsv` and `.numbers`
  (through Numbers itself). `.xlsb` gets a reason and advice to re-save.
- **A mode per sheet:** "Data table" — a row becomes a document, the chosen columns
  go into the text and the rest into metadata, and search combines a filter
  `warehouse = Moscow and price < 100` with the meaning of the description;
  "Document" — the sheet is cut by the source's strategy, with the header repeated
  in every chunk; "Do not index" — service and hidden sheets. Auto-detection only
  suggests, and says why.
- **Mapping profiles** are recognised by headers, kept with a source or for the
  whole app, describe a workbook as a whole (a variant per sheet), can be assigned
  to a file by hand and moved as a file. A sheet no profile fits is written as text
  by default instead of being lost.
- **Row-level synchronisation:** editing one cell in a 20,000-row sheet recomputes
  one row, editing only metadata recomputes none. A row that disappeared waits for
  a decision.
- **Numbers as in the workbook:** without binary-fraction tails, with as many
  decimals as the cell format says, percentages and currencies with their unit. A
  header spanning several rows is assembled from merges; file fields and path
  levels are on every row and every sheet chunk.
- **The cost is shown before starting:** the row count and the time from the
  model's measured speed, plus a trial run on the first rows.

### Chunking

- **Seven strategies:** Fixed-size, Recursive, Document-based (headings, HTML tags,
  functions), Hierarchical (parent and child in one collection), Semantic, Adaptive
  (size by text density) and LLM-based (a chat model places boundaries by sentence
  numbers; the text is cut from the original, not rewritten).
- **Tables are cut by rows:** every part is the header plus whole rows, the header
  counts towards the chunk size, and a row longer than a chunk is split by cells,
  keeping the item's number and name. `get_file` strips the repeated header at the
  seams.
- **A chunk longer than the model's context is cut further** instead of being
  silently truncated by the model or failing the file: by the context in tokens and
  by the limit measured with a probe.
- **Context for the vector:** the heading path in front of the chunk text, or a
  context line from a chat model — with giving up on a model that stays silent.
- Defaults are per strategy; the chunking preview on any file uses the same code as
  synchronisation and the settings of the chosen source.

### Models and vectors

- The list of LM Studio models with type and context from its native API, a default
  model for new collections, speed measurement.
- **Text longer than the context is not sent:** LM Studio accepts input of any
  length and silently reads only the beginning, so length is checked before sending.
- **A vector cache** (up to 2 GB by default): text already computed is not computed
  twice. It affects time only, not results.
- **A test bench:** the vector of a text, model comparison, similarity of two texts,
  a preview of parsing and chunking of a file.

### Search

Search is not one `query` call but a pipeline of nine stages in a fixed order:

| # | Stage | What it does |
|---|---|---|
| 1 | Candidates | vector search and/or text search |
| 2 | Fusion | Reciprocal Rank Fusion of the two lists |
| 3 | Collapsing | several hits from one section become one result |
| 4 | Diversity | MMR |
| 5 | Parent lift | the whole section instead of a child chunk |
| 6 | Context | neighbouring chunks of the same file |
| 7 | Reranking | by a chat model or a cross-encoder |
| 8 | Manual marks | pinned documents go up, even ones search did not find; demoted and outdated ones go down |
| 9 | Truncation | down to `n_results` |

- **No search setting requires recomputing vectors** — they are query parameters.
  **Search profiles** are named, bound to a collection and portable as a file;
  "Smart search" turns off with one click.
- **The query instruction for Qwen3-Embedding** is on by default for collections
  on that model: the model is trained to search with an instruction and finds
  worse without it.
- **Search across several collections at once** — by fusing ranks, with one shared
  reranking.
- **"How this result was obtained":** candidates in and out of every stage, what was
  dropped and why, how long each took. **Query history** — with search, pinning
  and an "add to set" button for the evaluation bench.

### Quality evaluation bench

A "variant → run → mark up → compare" cycle — so settings are chosen by
measurement rather than by eye. How to set up an experiment so that it means
something — [docs/EVALUATION.md](docs/EVALUATION.md) (in Russian).

- **A query set** is collected from the search history; the reference is a text
  fragment rather than a chunk id: ids are not comparable between different
  chunkings. A query has tags and a filter, visible while marking up.
- **A variant** is "collection + search profile": two profiles over the same
  vectors are compared without recomputing anything.
- **Markup** — three buttons on each result, the card shows the most informative
  part of the chunk; a chat model's hint is optional and never enters the metrics.
- **The report:** hit rate@k, recall@k, MRR, nDCG@k, points, latencies and the
  **cost of a hit** — how many characters an agent reads per useful result,
  attached neighbours included: large chunks do not win just because they are
  large. Queries where the variants diverged, a "before/after" comparison, export
  to Markdown and JSON.

### Viewing the source document

From a search result, the bench or the inspector, the document opens at the
chunk's place: a PDF at its page, text and Word at the paragraph, a spreadsheet at
the row under its header. The highlight is assembled from the chunk's parts —
sentences, list items, cells — and finds a table chunk in a PDF, including one that
continues onto the next page. If the place was found only in part, the viewer says
so.

### Agents and MCP

Agent apps connect to the base through **tools**, not API requests. The main
difference from the proxy: the agent sends **text**, and the app computes the vector
with the collection's model — writing a vector from a foreign model is impossible
by design.

- **Tools:** `list_collections`, `describe_collection` (fields with types and
  examples), `search` (through the same pipeline as on screen, with filters),
  `get_documents`, `get_file` (a whole file as text, as a map of sections or as
  chunks in order; a section by its heading; the file's path on disk),
  `collect_mentions` (every place a word occurs, grouped by file — what semantic
  search does not answer), `list_files` (the files of a collection, one line per
  file with its `file_id` — "which documents are there" without a search),
  `add_documents`, `delete_documents`.
- **Two transports:** stdio through the `chromadb-mcp` helper inside the bundle
  (this Mac only) and HTTP `/mcp` on the proxy port, with TLS and the same keys
  (off by default).
- **Permissions are the same keys as the proxy's:** a collection list, read, write,
  delete, rate and volume limits, ceilings on results and characters in an
  answer. A foreign collection answers "not found". A read-only mode applies to all
  keys at once.
- **One-button agent setup** for Hermes and Bionic: the app writes the server into
  the agent's configuration, installs a skill with the rules for working with the
  base, then checks the connection with a test call. Other clients get a ready
  configuration snippet.
- Every call goes into the access log with its parameters; documents added by an
  agent are marked `origin: "mcp"`, deleted ones go to the trash.

The tool reference is [docs/MCP.md](docs/MCP.md), Hermes setup is
[docs/HERMES.md](docs/HERMES.md) (both in Russian).

### Access, keys and security

ChromaDB itself has neither per-collection permissions nor a read-only mode, so
access control lives in a proxy in front of it.

- **The proxy** forwards bytes as they are — the official `chromadb` client works
  through it unchanged. **Traffic is encrypted** with a certificate the app issues
  itself; the fingerprint and a file for the client are on the "Security" screen.
- **A key is stored nowhere** — only its hash; it is shown once. A new key is
  created with no permissions at all: a collection list, write access, a daily
  limit, a maximum document size, a check of vector dimensions.
- **The access log:** who, when, which operation, collection, status and size —
  with filters and export; it never deletes itself.
- **Only the proxy is exposed to the network**, the database server always stays on
  `127.0.0.1`. The "Security" screen shows what is open, how many keys are active
  and what deserves a look; an **emergency stop** shuts everything down and revokes
  the keys with one button.

### macOS integration

- **Menu bar:** indexing progress, the task queue, pause and quick search; a
  **global hotkey** opens search above any app — without the Accessibility
  permission.
- **Drag and drop** a folder or files onto the window or the Dock icon; **Services**
  — add selected text or Finder files; **Shortcuts** — search a collection, add
  text, synchronise a source.
- **Notifications** about a server crash, denied access and the results of
  background operations.
- **English and Russian interface** — following the system language or chosen in
  Settings.

---

## Installation

A ready build is on the releases page: download the archive for your processor —
`ChromaDB-Manager-<version>-apple-silicon.zip` for M1 and later Macs or
`ChromaDB-Manager-<version>-intel.zip` for Intel Macs (the processor is named in
the Apple menu → About This Mac) — unpack it and move the app to Applications.

The package is not notarised, so on first launch macOS says it cannot verify the
developer:

- **macOS 14** — right-click the app → "Open", confirm once;
- **macOS 15 and later** — launch the app (the system refuses), then "System
  Settings → Privacy & Security" → "Open Anyway".

| What | Needed? |
|---|---|
| macOS | 14 Sonoma or later |
| Processor | Apple Silicon or Intel — each has its own archive (since 0.4.2) |
| ChromaDB | 1.x — the app installs it itself |
| LM Studio | for vectors and semantic search; installed separately, models are loaded in it |
| Python 3 | not needed; only for the second way of installing the engine |
| Pages, Keynote, Numbers | only for `.pages`, `.key` and `.numbers` |

**On an Intel Mac** LM Studio does not run: it is released for Apple Silicon
only. Use [Ollama](https://ollama.com) instead (macOS 14+, CPU-only on Intel):
Embeddings → Connection → Ollama, default address `http://localhost:11434`; on
Intel the app starts with it by itself. Models are downloaded in Ollama
(`ollama pull nomic-embed-text`), and it reports their type and context; the
working context on Intel is 4096 tokens by default, more in Ollama's settings. You can
also keep LM Studio on another computer by entering its address — texts for
vectors then go to that computer.

---

## Building from source

You need Xcode 15 or later (tested on 26.6) and Swift 5.9+. There are no external
dependencies.

```bash
git clone https://github.com/dem2007/ChromaDB-Manager.git && cd ChromaDB-Manager
./Scripts/build-app.sh release && open "dist/ChromaDB Manager.app"
```

The script builds `dist/ChromaDB Manager.app` with the icon, entitlements, Shortcuts
intents and a signature (Hardened Runtime, ad-hoc). In Xcode: `open Package.swift` →
the `ChromaDBManager` scheme → "My Mac".

```bash
swift test              # the whole suite on recorded responses, no ChromaDB or LM Studio
CHROMA_IT=1 swift test  # plus live tests against a real server and LM Studio
```

App Sandbox is off: the app runs external executables (`chroma`, `git`, and with the
second install way `python3`), which the sandbox does not allow. Hardened Runtime is
on; the entitlements are network client and server (the latter for the proxy).

The system registers Services only for an app in `/Applications` or
`~/Applications`; Shortcuts intents are built only when Xcode is installed.

---

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the app is built: layers, the
  data path, the task queue.
- [docs/MCP.md](docs/MCP.md) — MCP tools, parameters and answers (in Russian).
- [docs/HERMES.md](docs/HERMES.md) — Hermes Agent and this base (in Russian).
- [docs/EVALUATION.md](docs/EVALUATION.md) — how to measure search quality (in
  Russian).
- [docs/TEXTS.md](docs/TEXTS.md) — how the interface texts are written.
- [docs/ROLLBACK.md](docs/ROLLBACK.md) — how to get back to a working version.
- [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md).

---

## Known limitations

- **Vectors are computed by the app, not by the server.** That is why a model is
  bound to a collection, and which model computed the vectors of a foreign
  collection cannot be known — only the dimension is checked. The same holds in the
  proxy: an external client sends a vector, and "is it the right model" is checked
  only as a dimension match.
- **A collection's dimension is fixed by its first write forever**: recomputing in
  place works only for a model of the same dimension; for another one, clone.
- **ChromaDB does not guarantee document order when paging.** If a collection
  changes while you page through it, pages may repeat — the app checks the count
  and warns. Only `get_file` guarantees the order of a file's chunks.
- **`>` and `<` in a filter work with numbers only.** Dates are compared through the
  field's numeric twin, turned on in the metadata schema.
- **Token counts are approximate (`≈`):** the model's tokenizer is not available
  through the LM Studio API, so length checks are deliberately pessimistic.
- **Late chunking is impossible:** LM Studio returns one vector per text, not per
  token.
- **Recognition takes seconds per page** — hours on a large folder of scans; the
  heading structure of recognised text is not restored.
- **Tracked changes** do not reach the text; comments, footnotes and notes do.
- **The web is read without a "reader mode":** a little navigation from a page with
  a complex layout can get into the text; pages rendered by a script in the browser
  are not supported and go to "needs a decision".
- **`.pages`, `.key`, `.numbers`** require Pages, Keynote and Numbers installed and
  automation permission; in automatic runs the export is off by default — it brings
  up the app's window.
- **Automation lives while the app is running:** it installs no background daemons
  or `launchd` agents.
- **Protection is designed for the network, not for other users of this Mac:** the
  database port on `127.0.0.1` is reachable by any process on the machine,
  bypassing the proxy.
- **The proxy certificate is self-signed** — a client has to trust it explicitly, by
  file or fingerprint.
- **The package is not notarised** — see [Installation](#installation).

**Never going to be done:** a built-in chat with the base, model management, cloud
sync, a multi-user mode, a mobile client, built-in auto-update and vector
visualisation (2D/3D projections, PCA, UMAP, t-SNE) — collection topics are shown as
a list, not a picture.

---

## License

[Mozilla Public License 2.0](LICENSE).

File-level copyleft: modified files of the project stay open under the same license,
while your own code next to them can be licensed any way you like, including
closed. A patent license from contributors is granted explicitly (section 2.1);
trademarks are not (section 2.3). The license notice is in `LICENSE` at the root
and covers the whole repository.
