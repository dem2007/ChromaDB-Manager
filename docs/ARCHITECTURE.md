# Architecture

MVVM, three layers, and not a single exception to the rules below.

```
Sources/
├── ChromaCore/                  # services and models, no SwiftUI — this is what the tests see
│   ├── Models/                  # AppPaths, Configuration, ChromaModels, SemanticVersion,
│   │                            # EnvironmentStatus, CollectionNaming, DocumentFilter,
│   │                            # MetadataSchema, SourceRouting, SourceManifest,
│   │                            # SyncTriggers, ChromaRoute, ExternalClient,
│   │                            # NetworkExposure, SecurityAssessment
│   ├── Services/                # ChromaClient, ChromaProcessManager, ToolLocator,
│   │                            # EnvironmentInspector, InstallationService, BackupService,
│   │                            # KeychainStore, ModelBindingService, LMStudioClient,
│   │                            # SchemaStore, ImportService, DocumentImportService,
│   │                            # TextExtractor, SourceSyncService, FolderWatcher,
│   │                            # ReembeddingService, MetricsStore, ProxyServer,
│   │                            # AccessController, AuditLog, Notifier,
│   │                            # ShellRunner, LogStore, ServerLog
│   └── Chunking/                # the seven chunking strategies and a shared ChunkingPipeline
└── ChromaDBManagerApp/
    ├── App/                     # entry point, NSApplicationDelegate
    ├── ViewModels/              # @MainActor, screen state, orchestration
    └── Views/                   # SwiftUI only
```

The boundary rules:

- `Views/` know nothing about `Process`, `URLSession` or the file system.
- `ViewModels/` do not build HTTP requests and do not parse responses — they only call services.
- `ChromaCore` does not import SwiftUI. Logging goes through `LogHandler`, never `print`.
- Services that hold state are actors (`ChromaClient`, `LMStudioClient`, `ModelBindingService`)
  or `@MainActor` objects when the state is displayed in the UI (`ChromaProcessManager`,
  `LogStore`).

---

## A single path to the data

Everything to do with collections and documents goes through `ChromaClient` over HTTP API **v2**.
The app neither reads nor writes the database files; CLI output is never parsed for data.
API v1 has been removed from ChromaDB, so there is no fallback to it — a 410 response turns into
a "the server is too old" message.

Operations address a collection by UUID; the name → UUID resolution happens once and is cached
inside the client.

## Two modes, one client

| Mode | Who owns the process | What the user sees |
|---|---|---|
| Local database | the app | a folder on disk |
| Server (own profile) | the app | a name, host, port, start/stop buttons |
| Server (external) | somebody else | an address and a token |

ChromaDB's `PersistentClient` is a Python class and is unavailable from Swift. So a "local
database" is a private `chroma run` on `127.0.0.1` and an ephemeral port, raised and stopped by
`ChromaProcessManager`. There is still exactly one data-access layer.

Server parameters are passed in a YAML config (`chroma run <config>`) rather than as flags:
that is the only way to set `allow_reset` and `persist_path`.

## Process survivability

`ChromaProcessManager` writes the PID, port, path and binary path of a running server into
`Application Support/ChromaDBManager/servers/running.json` — one record per process, without
overwriting the others: a server left over from a previous session has to survive the launch of
a new one.

Before **any** signal, the process's identity is confirmed through `libproc`
(`ProcessIdentity`): the executable path, the start time (10 s tolerance) and the fact that the
process holds the recorded port must all match. A server cannot be identified over HTTP — two
servers with different databases answer identically — and the system reuses PIDs. A confirmed
process is either reused (same folder) or offered for stopping; an unconfirmed record is
discarded with a log entry, and the process itself is left alone.

`ManagedProcessRegistry` stops only its own processes in `applicationWillTerminate` and checks
the same identity against a snapshot taken at registration time.

## The task queue

Anything that takes minutes goes through `TaskQueue`. The queue decides **when** a task may
run; the caller still performs it — which is why the call timeout is counted from the start of
the work, cancellation stays ordinary Swift task cancellation, and progress is reported by the
services themselves.

Five priorities: a user action → an agent (MCP) request → a manual operation → an automatic one
→ a background check; within a priority, arrival order. Resource groups: `lmStudio` is strictly
sequential, while `filesystem` and `database` run in parallel with it. There is no preemption —
long tasks yield the queue between embedding batches.

## Finding executables

`ToolLocator` does not rely on `PATH`: an app launched from Finder gets a stripped environment.
The candidate order is the app's own directory (`…/ChromaDBManager/bin`), the app's venv,
`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `~/.local/bin`; if none of those has it, the
login shell is asked (`/bin/zsh -lc 'command -v chroma'`). The **absolute** path that was found
is cached, and a bare command name is never executed.

## The app computes the embeddings

In client-server mode ChromaDB's embedding function runs on the client side, and the client
here is a Swift application with no access to Python functions. So vectors are always computed
by LM Studio, and explicit `embeddings` and `query_embeddings` go into the API. The server-side
EF is not used.

The consequence is the "collection → model" binding:

- it is written into the collection's metadata (`_cdbm_model`, `_cdbm_dimension`) so that the
  database stays self-describing when moved to another machine;
- the absence of those fields is a normal situation (the collection was created by something
  else);
- `ModelBindingService` checks the dimension before a request: `_cdbm_dimension`, and where
  that is missing, the `dimension` the server reports. A mismatch blocks both writing and
  binding.

## Errors

Typed (`ChromaError`, `BindingError`, `InstallationError`, `ShellError`,
`ChromaProcessManager.ServerError`) with `errorDescription` and, where it makes sense,
`recoverySuggestion`. The UI shows both strings. There is no `try!` and no force-unwrapping in
the service layer.

## Who listens to whom

```
external client ──▶ ProxyServer (127.0.0.1 or 0.0.0.0, port 8900)
                        │  key → AccessController (permissions, limits, dimension)
                        │  every request → AuditLog
                        ▼
                   chroma run (always 127.0.0.1, private port)
```

Only the proxy is ever exposed; ChromaDB itself never reaches a network address. That is held
by three independent checks: a profile is created with `127.0.0.1`,
`ChromaProcessManager.start` refuses a non-loopback address, and `ProxyServer.start` refuses to
open outward in front of a server that is not on loopback.

The listener and the connections live in `ProxyCore` on a queue of their own, not on the main
actor: a proxy that stops answering while the window redraws is not a proxy. The `@MainActor`
`ProxyServer` wrapper holds only what is shown on screen.

`Notifier` is the only place where the app touches Notification Center, and it checks for a
bundle before calling: outside an `.app` that API kills the process.

## Secrets and logs

Tokens live only in the Keychain (`KeychainStore`); they are not in the JSON config and not in
UserDefaults. `SecretRegistry` masks registered values and token-like strings in the logs. Logs
go both to the app's panel and to `~/Library/Logs/ChromaDBManager/`.

## Where state is kept

| What | Where |
|---|---|
| Server profiles, sources, mode, database path | `Application Support/ChromaDBManager/config.json` |
| Tokens | Keychain |
| Server configs and the running PID | `Application Support/ChromaDBManager/servers/` |
| The venv and the standalone CLI | `Application Support/ChromaDBManager/{venv,bin}` |
| Backups | `Application Support/ChromaDBManager/backups/` |
| Logs | `~/Library/Logs/ChromaDBManager/` |

None of it sits next to the sources, and none of it reaches git.

## The sandbox

App Sandbox is off: the app launches arbitrary executables. Hardened Runtime is on, and the
entitlements are `network.client` and `network.server`. Distribution is by Developer ID,
outside the Mac App Store. It follows that security-scoped bookmarks are unnecessary: folder
paths are stored as plain strings.
