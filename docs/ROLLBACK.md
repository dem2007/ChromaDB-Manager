# Getting back to a version that worked

Before a large rework — a redesign, for instance — the state is marked stable. The mark answers
two different questions, so it has two halves:

- **a git tag** — which code this was;
- **an archive of the assembled app** in `dist/stable/<mark>/` — a working application right
  now, with no rebuild.

The second without the first is useless a month later; the first without the second needs a
working Swift and several minutes — and they are needed exactly when there is no time.

## Marking the current state

```bash
Scripts/mark-stable.sh
```

The script refuses to run if there are uncommitted changes or the tests do not pass: a build is
called stable when that has been verified, not declared. It also rebuilds the app, so that the
archive holds exactly what the marked code produces.

## Getting the app back (a quick rollback)

```bash
Scripts/restore-stable.sh
```

Puts `dist/ChromaDB Manager.app` back from the latest stable archive. Code, settings and the
database are untouched. The previous build is not deleted but moved aside to
`dist/ChromaDB Manager.app.replaced-<date>` — it will still be needed to work out what broke.

The app has to be closed for this: swapping a bundle underneath a running process is a reliable
way to get a half-old application.

To see which marks exist:

```bash
Scripts/restore-stable.sh --list
```

## Getting the code back

To look without changing anything:

```bash
git switch --detach stable-20260809
```

To resume work from a stable version (a new branch from the mark):

```bash
git switch -c fix stable-20260809
```

To undo one bad change while keeping the rest — not by rolling the branch back but with a
reverse commit: the history stays, and it is visible what was undone and why.

```bash
git revert <commit>
```

## What a rollback does **not** bring back

- **The application's settings** — `~/Library/Application Support/ChromaDBManager/config.json`.
  They live apart from the code and survive any rollback. If a change broke the settings
  themselves, `config.previous.json` and `config.before-loss-*.json` snapshots lie next to them.
- **The database and the collections** — they are in `chroma_data/` and do not depend on the
  app version.
- **Source manifests** — what is already indexed stays indexed.

## Branches

A large rework goes in its own branch while `main` stays what works:

```bash
git switch -c design
```

Merge it back when the rework has been checked live and the tests are green.
