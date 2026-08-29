---
name: chromadb-manager
description: Query the ChromaDB Manager document base over MCP.
version: 1.0.0
author: Max, Hermes Agent
license: MIT
platforms: [macos]
metadata:
  hermes:
    tags: [chromadb, mcp, rag, search, documents, tables, документы, поиск]
---

# ChromaDB Manager document base

Eight MCP tools over a local ChromaDB: search by meaning, full sweep by word,
whole-file reading, writing and deleting. This skill is about **which tool
answers which question** and how not to mistake a sample for the whole picture.
For the Chroma library itself see the `chroma` skill; this one is about the
application.

## When to Use

- Any question about the corpus held in ChromaDB Manager: specifications,
  contracts, estimates, tables, notes.
- Counting, comparing, summing — anything where **coverage** matters, not an
  example.
- Don't use for: another ChromaDB without this application, web search, files
  on disk that were never indexed.

## Prerequisites

- **ChromaDB Manager is running.** The `chromadb-mcp` helper is a client of the
  application; without it every call answers "the application is not running".
- The server is declared in `~/.hermes/config.yaml` under
  `mcp_servers.chromadb-manager`, with the key in `env.CHROMADB_MCP_KEY`. The key
  is issued in the application on the «Clients» screen and carries the rights:
  read, write, delete, the collection list and the result ceilings.
- Tools arrive prefixed `mcp__chromadb_manager__` — a double underscore, with hyphens turned into underscores.

## Language

The server answers **in English**: tool names, headers, counters, warnings. The
documents themselves are **in Russian** — as are the stems for `contains` and
the table column names, which are literal substrings of the corpus and must be
passed in Russian.

Do not let the English scaffolding pull your reply along with it: **answer the
user in the language the user wrote in.** Quote document text in the original.

## Quick Reference

| question | tool |
|---|---|
| "what does it say about this" | `mcp__chromadb_manager__search` |
| "is it in every specification", "show all the places" | `mcp__chromadb_manager__collect_mentions` |
| "collect every value of a column" | `mcp__chromadb_manager__get_documents` + `filter` |
| "read the whole document" | `mcp__chromadb_manager__get_file` |
| "give me the chunks with this word" | `mcp__chromadb_manager__get_documents` + `contains` |
| "where do I even look" | `mcp__chromadb_manager__list_collections` |
| "what fields are there" | `mcp__chromadb_manager__describe_collection` |
| write, delete | `add_documents`, `delete_documents` |

## Procedure

1. `list_collections` — which collections this key may reach, **and what its
   limits are**. The answer states them; read them.
   *Done when:* the collection name is taken from the answer, not invented.
2. `describe_collection` — **before** writing a filter, not after. Table column
   names cannot be guessed, and a wrong field returns emptiness, not an error.
   *Done when:* every field in the filter appears in that answer.
3. The tool from the table above.
4. For arithmetic — `get_file` on each file that entered the selection.
   *Done when:* the total is built from whole files, not from fragments.

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

**Semantic search does not give coverage.** Measured on a live base: for the
topic «резервное копирование» search returned chunks of three files out of
thirteen **at any** number of results — proximity keeps returning neighbouring
chunks of the same documents. Raising `n_results` buys length, not coverage.

```json
{"collection": "base_docs_4b", "contains": "резервн",
 "limit": 10, "per_file": 1, "fields": ["source_file"]}
```

- give the word as a **stem without the ending**: «приемк» finds «приемка»,
  «приемки», «приемке»;
- the comparison is literal — no synonyms, that is what `search` is for;
- `limit` counts **files**, not chunks; page on with the `offset` from the answer;
- **fewer files may come back than you asked for.** The answer has a size
  budget, and a long list is cut: with `limit: 100` over seventy matching files
  you get forty-five and a note saying so. The header still names the full
  count — «595 matches in 20 files» — so the total is never lost; take the rest
  with `offset`;
- **always pass `per_file: 1`** unless you truly need several chunks from the
  same file. Without it every file brings up to three, the answer trebles, and
  a large one gets spilled to a file by the client — which is where agents
  start parsing text they should have read from the answer;
- `per_file` above three is not returned.

Measured: «резервн» — 595 matches in 20 files.

### Read the totals, do not recount them

The first line of the answer already carries them: `«резервн»: 595 matches in
20 files, 20 shown`. Use those numbers.

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

## Several collections in one call

Instead of three `search` calls over three collections, pass them as a list in
`collections`: the query vector is computed once, every result says where it came
from, and the merged list is reranked as a whole, so candidates compete across
collections. Passing `collection` and `collections` together is refused.

## Tables

Every table column is a metadata field; the condition goes on the column, not
through search by meaning.

```json
{"collection": "base_docs_4b",
 "filter": {"стоимость_тыс_руб": {"$gt": 0}},
 "fields": ["source_file", "row_number", "стоимость_тыс_руб"],
 "limit": 100}
```

`fields` is required here in spirit: a table row drags all of its columns into
the answer — 1883 characters of metadata per row against 94 after a projection,
and fifty-six rows fit in one answer instead of eight.

Compare numbers with numbers: `2026` and `"2026"` are different conditions, and
the second returns nothing.

## Pitfalls

- **A word that is not there.** `contains` compares substrings literally. An
  empty answer means the word is absent from the corpus and no search will find
  it. Test the guess with one short call: «экранная форма» returned zero chunks
  on the live base although it looked obvious.
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
  and the reranker are loaded into LM Studio on demand.

## Verification

Three questions with known answers on the `base_docs_4b` collection:

1. `list_collections` — the collection is visible and the limits are stated.
2. `collect_mentions` with «резервн» — 595 matches in 20 files.
3. `search` on the same topic — three or four files.

The gap between the second and the third is the reason coverage is asked of
`collect_mentions`.
