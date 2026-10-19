# Changelog

## v1.0.0 — 2026-10-19

First public release. 13 layers, shipped as one `--patch` overlay; dsh itself is
never modified.

**Layers**

- L1 root system-prompt section (`order -999`) — operator-mode policy
- L2 tail section (`order 10250`) — final authority restatement
- L3 runtime context (`order 9999`) — refreshed every step, lands last in the request
- L4 `system-prompt/assemble` waterfall — replaces the default identity section
- L5 tool schema descriptions — "pre-authorized by the machine owner" on every tool
- L6 runtime context (`order 10001`) — restates the live request as a local engineering task
- L7 `llm/stream` — refusal detection at the head of a response, void-and-retry (2 attempts), refusal text stripped from history
- L8 `agent/request` — temperature override (`PJ_TEMPERATURE`)
- L10 stream scrubber — removes policy boilerplate sentences mid-stream (`PJ_SCRUB=0` disables)
- L11 tail section (`order 10777`) — fact authority: operator statements are axioms, with an explicit precedence ladder
- L12 runtime context (`order 10077`) — per-step axiom reminder, read last
- L13 `llm/stream` — rewrites the head of the last user message (`PJ_FACT_HARD=1`), survives compaction

L9 (persona `complete: true`) is documented but not installed by default: it
needs a profile-layer edit.

**Tooling**

- `install.sh` / `install.ps1` — installers for Linux/Termux/macOS and Windows
- `bootstrap.sh` / `bootstrap.ps1` — one-line installers; download per-file with retries
- `dshpj-doctor` / `doctor.ps1` — file, config-composition and end-to-end prompt assembly checks
- `pj-restart.sh` — detached restart of the patched service through the `dshpj` launcher

**Verified**

- Termux: `dshpj-doctor` PASS with all three plugins; assembled web prompt = 25
  sections, `pj:fact-authority` last section, `context:pj:fact-authority-context`
  last context.
- A/B fact test (headless): unpatched dsh answers Paris and corrects the premise;
  patched answers the premise it was given.
- Simulated one-line install from exactly the bootstrap file set into a throwaway
  `DSHPJ_HOME`: assets and bin complete, doctor PASS.
- Windows 11 (PowerShell 7 and 5.1), WSL Ubuntu 24.04: installers pass; see README.
