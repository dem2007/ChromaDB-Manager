# Security policy

## Reporting a vulnerability

Please report privately, through GitHub's **"Report a vulnerability"** button on the Security
tab of this repository. That opens a private advisory visible only to the maintainers — please
do not open a public issue for something exploitable.

Useful things to include: what you did, what happened, what you expected, the app version
(Overview screen, or `CFBundleShortVersionString` in the bundle's `Info.plist`) and your macOS
version. A proof of concept helps; a crash log or the relevant lines from
`~/Library/Logs/ChromaDBManager/` help too — but please redact any keys before sending them.

**What to expect.** This is a small project maintained by one person, so there is no service
level agreement and no bounty. You will get an acknowledgement and an honest answer about
whether it will be fixed and roughly when. If a report is declined, you will be told why.

## Supported versions

The project is pre-1.0. Fixes go into the current version; there are no maintained release
branches, and older versions receive nothing.

| Version | Supported |
|---|---|
| the latest published 0.1.x | yes |
| anything earlier | no |

## What is in scope

- The proxy layer: authentication by client key, per-collection permissions, the read-only
  flag, the daily and per-document limits, and the refusal codes.
- The MCP server: the same keys and permissions, plus the rule that creating and deleting
  collections is not exposed as a tool at all.
- Key handling: only a SHA-256 and a prefix are stored, and a key is shown once at creation.
- Token and password storage in the Keychain, and the masking of secrets in the logs and in a
  settings export.
- The access log: anything that would let a request avoid being recorded.
- Anything that makes the app write to a collection with vectors from a model other than the
  one bound to it.

## Known limitations that are not vulnerabilities

These are design decisions, documented in the README. A report about them will not be treated
as a vulnerability — though an argument that a decision is wrong is always welcome as an issue.

- **The proxy certificate is self-signed.** Encryption is on by default and the app issues the
  certificate itself; the private key stays in the Keychain. A client must trust it explicitly,
  by file or by fingerprint — there is no public certificate authority behind it, and a client
  that skips verification gets no protection from it.
- **Running the proxy without TLS is possible and stays possible.** It is off by default and has
  to be turned on by hand. On loopback it is harmless; open to the network it means client keys
  travel in clear text, and the app says so as its loudest warning rather than quietly allowing
  it.
- **The protection is against the network, not against other users of the same Mac.** ChromaDB
  itself is always started on `127.0.0.1`, and anyone who reaches that port directly from the
  same machine reaches the database with no permissions at all — because ChromaDB has neither
  per-collection ACLs nor a read-only mode. The whole permission model lives in the proxy.
- **A model cannot be verified, only its dimension.** There is no way to tell which model
  produced a given vector, so "the client must use the same model" is enforced as a matching
  dimension. This is an approximation and is stated as one.
- **App Sandbox is off.** The app launches external executables (`chroma`, `python3`, `pip`),
  which is incompatible with the sandbox. Hardened Runtime is on.
- **Local builds are signed ad-hoc.** A build you assemble yourself is not notarised; macOS
  will treat it accordingly. Distribution builds will be signed with a Developer ID.
- **`allow_reset`, when you enable it, means what it says.** The app never enables it behind
  your back, but with it on, a reset through the API wipes the database.

## What the app sends over the network

Nothing about you, ever. There is no telemetry, no analytics and no crash reporting — the
project has no third-party dependencies at all, so there is nothing in it that could phone
home.

Every outbound address in the source code, and what it is for:

| Address | When |
|---|---|
| the ChromaDB server you pointed it at | all the time; usually a private one on `127.0.0.1` |
| LM Studio on your machine | embeddings and queries |
| `api.github.com` | checking for a new engine version, and only on a button press or with the setting explicitly on |
| `raw.githubusercontent.com` | downloading the official Chroma CLI installer, after you confirm |
| `pypi.org` | the same check for the `pip` installation path |
| `www.python.org` | a link opened in your browser when Python is missing; the app itself fetches nothing from it |

Web sources fetch the addresses you gave them, and nothing else.
