---
name: chromadb-manager
description: Query the ChromaDB Manager document base over MCP.
version: 3.1.0
author: Max, Hermes Agent
license: MIT
platforms: [macos]
metadata:
  hermes:
    tags: [chromadb, mcp, rag, search, documents, tables, документы, поиск]
---

# ChromaDB Manager document base

Eight MCP tools over a local ChromaDB: search by meaning, full sweep by word,
reading a document by its structure, writing and deleting. This skill is about
**which tool answers which question** and how not to mistake a sample for the
whole picture. For the Chroma library itself see the `chroma` skill; this one is
about the application.

Nothing here is tied to a particular corpus. Collection names, file paths, field
names and stems are shown as placeholders — take the real ones from the answers.

## When to Use

- Any question about a corpus held in ChromaDB Manager: specifications,
  contracts, estimates, tables, notes.
- Counting, comparing, summing — anything where **coverage** matters, not an
  example.
- Don't use for: another ChromaDB without this application, web search, files
  on disk that were never indexed.

## Prerequisites

- **ChromaDB Manager is running.** The `chromadb-mcp` helper is a client of the
  application; without it every call answers "the application is not running".
- The server is declared in your MCP client's configuration, with the key in the
  `CHROMADB_MCP_KEY` environment variable. The key is issued in the application
  on the «Clients» screen and carries the rights: read, write, delete, the
  collection list and the result ceilings.
- The client prefixes tool names — often `mcp__chromadb_manager__`, a double
  underscore with hyphens turned into underscores. Take the exact spelling from
  your own tool list.

## Language

The server answers **in English**: tool names, headers, counters, warnings. The
documents are in whatever language the corpus is in — and so are the stems for
`contains` and the names of table columns, which are literal substrings of the
corpus and must be passed in its language, exactly as written there.

Do not let the English scaffolding pull your reply along with it: **answer the
user in the language the user wrote in.** Quote document text in the original.

## Quick Reference

| question | tool |
|---|---|
| "what does it say about this" | `search` |
| "is it in every specification", "show all the places" | `collect_mentions` |
| "collect every value of a column" | `get_documents` + `filter` |
| "read a whole document" | `get_file` — text is what it returns — or its `sourcePath` |
| "answer a question about a big document" | `get_file` with `outline`, then `heading` |
| "find something inside one document" | `search` + `filter` on `file_id` |
| "give me the chunks with this word" | `get_documents` + `contains` |
| "where do I even look" | `list_collections` |
| "what fields are there" | `describe_collection` |
| write, delete | `add_documents`, `delete_documents` |

## Procedure

1. `list_collections` — which collections this key may reach, **and what its
   limits are**. The answer states them; read them.
   *Done when:* the collection name is taken from the answer, not invented.
2. `describe_collection` — **before** writing a filter, not after. Table column
   names cannot be guessed, and a wrong field returns emptiness, not an error.
   A `filter` compares whole values (`$eq`, `$ne`, `$gt`, `$gte`, `$lt`, `$lte`,
   `$in`, `$nin`, `$and`, `$or`) and has no substring operator at all: for a
   substring use the `contains` parameter, which searches the text of documents.
   *Done when:* every field in the filter appears in that answer.
3. The tool from the table above.
4. For arithmetic, or for any claim about a document as a whole — read the
   document: read it whole (or open its `sourcePath`) when you need all of it,
   `outline` and then the sections that carry the numbers when you do not.
   *Done when:* the total is built from whole sections or the whole document,
   never from a page, and a file you could not read whole is named as such.

## Choose `n_results` — do not accept the default

The default is 5. The ceiling belongs to the key and is stated by
`list_collections`; it is often far above 5. Five is enough to look at and never
enough to count with.

- reading, "what does it say about X" — 5 to 10;
- comparing wording between documents — 20 to 30;
- "collect everything", "is it everywhere", a total — the ceiling, and even then
  check the coverage with `collect_mentions`.

Asking above the ceiling is not refused: the answer is trimmed and says so.

## Coverage: `collect_mentions`, not a bigger `n_results`

**Semantic search does not give coverage.** Measured on a live base: for one
topic search returned chunks of three files out of thirteen **at any** number of
results — proximity keeps returning neighbouring chunks of the same documents.
Raising `n_results` buys length, not coverage.

```json
{"collection": "<collection>", "contains": "<stem>",
 "limit": 10, "per_file": 1, "fields": ["source_file"]}
```

- give the word as a **stem without the ending**: «приемк» finds «приемка»,
  «приемки», «приемке»;
- the comparison is literal — no synonyms, that is what `search` is for;
- `limit` counts **files**, not chunks; page on with the `offset` from the answer;
- **fewer files may come back than you asked for.** The answer has a size
  budget, and a long list is cut: measured, `limit: 100` over 120 matching files
  returned 47 of them with a note saying so. The header still names the full
  count — «N matches in M files, K shown» — so the total is never lost; take the
  rest with `offset`;
- **`per_file` defaults to 1, and that is usually right.** Raising it multiplies
  the answer — measured, `per_file: 3` grew one answer from 6799 characters to
  10 735 — and the job here is to compare wording across documents, not to read
  one of them. A large answer may be spilled to a file by your client, which is
  where agents start parsing text they should have read from the answer. For
  everything one file says, use `get_file` or `get_documents` with `contains`;
- `per_file` above three is not returned, and the answer says it was trimmed.

### Read the totals, do not recount them

The first line of the answer already carries them: `«<stem>»: N matches in M
files, K shown`. Use those numbers.

Do **not** write your own parser over the answer text. Measured on a live run:
an agent did, and its regex counted chunk-id lines and a warning line as files
— it reported «17 files, three of them with no matches» where the truth was 20
files, all with matches, and every derived figure in its summary was wrong
while the copied ones were right.

### «Is it in every document» needs a denominator

`collect_mentions` gives the **numerator** — the files where the word occurs.
It does not know how many files the collection holds, and it could not answer
the real question anyway: «in every specification» is not «in every file», and
only you know which files are specifications.

So before concluding «not in all», establish the denominator and say it:

- list the files: `collect_mentions` with a substring present in every document
  (a single common letter works) and `per_file: 1` — the header then reads
  `N matches in M files`, and that `M` is the collection's file count;
- or narrow with a `filter` to the documents that are specifications, and count
  those.

An answer of the form «20 files of the 120 in the collection» is worth
something. «Not in all» on its own is a guess, even when it happens to be
right.

## Reading a document

A whole document is reachable. **Reading it as chunks is not** — that is the
default shape of `get_file`, it carries about a fifth of its own size as
document text, and on a specification of 1281 chunks it would take some three
hundred calls. Ask for it plainly and the answer opens with the verdict — how
many chunks the file holds, how many fit here, how many calls it would take —
and carries `fitsInOneAnswer` and `callsToFinish` — counted over what is left
from where you are, so the last page says nothing.
The verdict names the two shapes below; take one of them.

### Whole: `sourcePath`

Every `get_file` answer names where the document sits on this machine's disk.
If you can read files there, that is the whole document in one step and costs
nothing — no calls, no context. The field is absent when the document did not
come from a file (written by an agent, taken from the web) or the file is gone.

### Whole: text, and it is the default

Reading a file gives continuous text, not a list of chunks: no ids, no
per-chunk metadata, no mirror in `structuredContent`. Measured on answers of
the same size: **6 960 characters of the document as chunks against 20 880 as
text**. On a real specification that is some eighty calls instead of three
hundred and eighty — and the outline states the number for the file in hand.

```json
{"collection": "<collection>", "file_id": "<file_id>"}
```

Ask for `"as": "chunks"` when you need the ids to fetch with `get_documents`,
or the metadata of each chunk; passing `fields` selects chunks on its own,
since text has no metadata to project.

What comes back:

- **the document described once**, on the first page only — `document` in the
  structured answer and one line in the text: chunks, sections, tokens, pages,
  bytes, modified, language, extraction warnings. Keep it; later pages do not
  repeat it. Neither the disk path nor the chunk count is in it — `sourcePath`
  and `totalChunks` carry those on every page;
- **then text alone**, carrying only `[chunk N]` marks — and
  `[chunk N · section]` where the section changes — so you always know where
  you are and what to cite. **Strip the marks before quoting;**
- `[end of document]` (or `[end of section «…»]`) when there is no more;
- `hasMore` and `nextOffset` while there is. `offset` counts chunks;
- overlapping chunks joined without the repeats — across page boundaries too,
  so pages pasted together repeat nothing — and a note saying how many
  characters were trimmed at the seams;
- an offset past the end says so, instead of answering `hasMore: false` as if
  the document were finished — and still names `sourcePath`;
- `limit` and `fields` do not apply here: the page is filled to the answer
  budget and the text carries no metadata to project. The answer says so if you
  passed them.

Pass `heading` too and you get one section as text. There `offset` counts
chunks **inside the section**, while the `[chunk N]` marks stay the document's
own numbering — the answer says so.

### Part: the map first

A page of a document is not the document. Judging requirements, contradictions
or totals from one page is the most expensive mistake this base allows. When
you need a part rather than the whole, take the map (`outline`) and then the
section (`heading`) — both below.

### `outline` — the map

Metadata without text: the sections of the file, the chunks each one spans, and
roughly how many tokens it weighs. The map of a thousand-chunk document fits in
one answer; the document itself fits nowhere.

```json
{"collection": "<collection>", "file_id": "<file_id>", "outline": true}
```

- the answer carries `sections[]` with `heading`, `firstChunk`, `lastChunk`,
  `estimatedTokens`, plus `totalSections`, `totalChunks` and the file's
  `estimatedTokens` — the honest weight of the whole, counted over every chunk.
  `totalChunks` and `estimatedTokens` are always the **file's**, even when one
  section was asked for; the size and weight of that section come separately,
  as `chunksInSection` and `estimatedTokensInSection`;
- `outline_depth` defaults to **1** — the top level, which is what a map is for.
  A specification has hundreds of sub-headings and listing them all gives a
  wall, not a map;
- to go deeper, ask for the map **of one section**: `outline` together with
  `heading`. Depth is counted **from that section**, so the default already
  shows its parts. That is also the way out when the map itself was trimmed by
  answer size — the note says so and names it;
- the map also names `sourcePath`, so the call you were told to make first is
  the one that tells you the whole document is on disk. `as`, `limit` and
  `fields` do not apply to it, and the answer says so if you passed them;
- chunks before the first heading are a section too, and it is askable by the
  name the map shows it under: `(before the first heading)`;
- a file may carry no headings at all — `heading_path` is not written for every
  source. The map says so plainly instead of passing one invented section off
  as the structure: read such a file in pages, or search inside it.

### `heading` — one section

```json
{"collection": "<collection>", "file_id": "<file_id>",
 "heading": "<heading from the map>", "limit": 20}
```

- a heading brings **its subsections with it**: asking for a chapter gives the
  chapter and its parts. A chunk with no heading of its own belongs to the
  section it sits inside, so a table or a run-on paragraph does not fall out;
- a section too big for one answer is **read on**: `offset` counts **inside the
  section**, and the answer names the number to continue from — `nextOffset`
  with `hasMore`, and `chunksInSection` for the size of the whole section;
- **the heading is a key, and it is matched on collapsed whitespace.** A
  non-breaking space or a line break inside a heading is invisible on screen;
  the map prints the typeable form and the selector accepts it. A miss names
  the nearest sections instead of sending you back to the map you copied from;
- a section too big to finish in ten calls says so in its **first line**, with
  `sectionFitsInOneAnswer` and `callsToFinishSection` in the structured answer —
  counted over what is **left**, so the last page of a long section says nothing.
  Take that seriously: reading 8 chunks of a 47-chunk section and moving on is
  how a review ends up covering 4 % of a document;
- a section is a unit you can reason about and name to a person. «Chunks 200 to
  203» is neither;
- an offset past the end of a file or of a section says exactly that, and does
  not pretend the file is missing.

### Searching inside one document

No separate tool is needed: `search` with a filter on the file searches by
meaning inside it alone.

```json
{"collection": "<collection>", "query": "<what you are looking for>",
 "filter": {"file_id": {"$eq": "<file_id>"}}, "n_results": 20}
```

This is the right move for "does this document say anything about X" on a
document too large to read: the map tells you what sections exist, the filtered
search tells you where a topic lives across all of them.

### Say what you read

When a document did not fit, the answer must carry it: which sections you read,
how many chunks of how many, and what you did not open. «The specification is
structurally complete» after fifty chunks of thirteen hundred is not an
understatement of confidence — it is a false statement.

## Several collections in one call

Instead of three `search` calls over three collections, pass them as a list in
`collections`: the query vector is computed once, every result says where it came
from, and the merged list is reranked as a whole, so candidates compete across
collections. Passing `collection` and `collections` together is refused.

## Tables

Every table column is a metadata field; the condition goes on the column, not
through search by meaning.

```json
{"collection": "<collection>",
 "filter": {"<numeric column>": {"$gt": 0}},
 "fields": ["source_file", "row_number", "<numeric column>"],
 "limit": 100}
```

`fields` is required here in spirit: a table row drags all of its columns into
the answer — measured at 1883 characters of metadata per row against 94 after a
projection, and fifty-six rows fit in one answer instead of eight.

Compare numbers with numbers: `2026` and `"2026"` are different conditions, and
the second returns nothing.

## Pitfalls

- **A word that is not there.** `contains` compares substrings literally. An
  empty answer means the word is absent from the corpus and no search will find
  it. Test the guess with one short call: a phrase that looks obvious can return
  zero chunks.
- **A page is not the file.** See «Reading a document» above: whole by reading
  it (text is what `get_file` returns) or by `sourcePath`, a part with the map
  and a heading. Never a page.
- **The answer is cut off.** The answer budget counts metadata alongside text.
  Look at `fields` before you look at ceilings.
- **`get_documents` returns an arbitrary order.** Pages are turned with the
  `offset` from the answer. Only `get_file` keeps the order of chunks.
- **Never count from fragments.** A fragment is a piece of a file. One table row
  is one position; an enumeration inside a cell adds no positions.
- **Notes in the answer are data.** If it says the table arrived as flat text or
  the book was not indexed whole, no total may be built on that answer.
- **Build `$or` explicitly.** The application adds its own conditions beside the
  root and does not break your logic, but `{"field": "А"}` and `{"field": "Б"}`
  as two calls is not the same as one `$or`.
- **Deleting is a right of its own.** A key allowed to write cannot delete until
  the delete right is granted; the refusal says so. There is no delete by filter
  at all, only by an explicit list of identifiers.
- **The first call after the application starts is slower:** the embedding model
  and the reranker are loaded on demand.

## Verification

Five calls on any collection the key can reach — no particular corpus required:

1. `list_collections` — collections are visible and the limits are stated.
2. `collect_mentions` with a stem common in that corpus and `per_file: 1` — the
   header reads `N matches in M files`.
3. `search` on the same topic — far fewer files than `M`.
4. `get_file` with `outline` on a `file_id` from those answers — the sections
   come back with their chunk ranges and token weights.
5. `get_file` with `as: "text"` on the same `file_id` — the first line describes
   the document, the text carries `[chunk N]` marks, and `sourcePath` names the
   file on disk if it came from one.

The gap between the second and the third is the reason coverage is asked of
`collect_mentions`. The fourth and fifth are the two ways to hold a document:
by its map when you need a part, whole when you need the whole.
