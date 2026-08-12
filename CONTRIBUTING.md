# Contributing

## Building locally

```bash
swift build                      # build both targets
swift build -c release           # release build
./Scripts/build-app.sh release   # assemble dist/ChromaDB Manager.app
swift test                       # unit tests (needs a full Xcode, see the README)
```

The project has no external dependencies: SwiftUI, AppKit and Foundation only.

## Structure and layer boundaries

- `Sources/ChromaCore` — services and models. **Does not import SwiftUI.** Everything that can
  be covered by tests lives here.
- `Sources/ChromaDBManagerApp` — SwiftUI screens and view models only. No direct work with
  `Process`, `URLSession` or the file system — that goes through services from `ChromaCore`.
- Logs go through `LogHandler`, not `print`: the user has to see the operation in the "Logs"
  section.
- Any external command is printed to the app's console before it runs — that is part of the
  contract with the user.

## Style

- Swift API Design Guidelines, four-space indentation.
- User-facing strings are written in Russian (the source language of the interface) and
  translated in `Resources/en.lproj/Localizable.strings`; identifiers and comments are in
  English.
- Errors go through `LocalizedError` with text that can be shown to a user, without
  "Error Domain=…".

## Commits and pull requests

- Small commits with a meaningful title in the imperative:
  `Add LM Studio model type probing`.
- In a pull request, describe what you checked by hand (which screens, which scenarios) and
  attach a screenshot if the UI changed.
- Do not commit user data: databases, backups, logs, configs or keys. All of that lives in
  `~/Library/Application Support/ChromaDBManager/` and is covered by `.gitignore`.

## Before a pull request

1. `swift build -c release` with no errors and no warnings.
2. The tests.
3. A manual run of the affected screen in an assembled `.app`.

## Licensing of contributions

The project is under the [Mozilla Public License 2.0](LICENSE). By sending a pull request you
agree that your contribution is licensed under the same terms — that is section 5 of the
license, and no separate agreement is needed.
