# Project overview / 项目概览

[Actual application views](PROJECT_SHOWCASE.md) · [Development timeline and evidence scope](DEVELOPMENT_HISTORY.md)

## What this project is

SyncNote Community is an MIT-licensed Windows and Android workspace that connects personal capture, task execution, linked Markdown notes, journals, literature discovery, and AI-assisted research. It is a newly published community edition derived from a personal-use application, not an established ecosystem project with a claimed large user base.

Its core idea is continuity: captured information can become structured knowledge, research can become notes, and an assistant can work with explicitly selected personal sources rather than an isolated prompt. Users configure their own Firebase, WebDAV and optional AI accounts.

## Distinctive engineering work

- A cross-platform Flutter client with cloud data, media, task reminders, Android integrations and Windows tray workflows.
- User-directed AI context: conversations, source selection, long-term memories, conversation resources and usage visibility.
- A literature workflow spanning multi-provider discovery, relevance assessment, open-PDF reading, saved interpretations, excerpts, citation relationships and Markdown notes.
- A separate Python execution core for a forward-time virtual stock experiment, with decision journals, execution events, refusals, costs and periodic reporting. Its incomplete corporate-action handling is documented.
- Storage lifecycle work: pagination, archives, WebDAV cold storage, backup / restore, history and capacity references.
- Community release engineering: empty first-run configuration, platform secure storage, separate application identifiers and signing, tests, CI and sanitized distribution packages.

## Code map

| Path | Responsibility |
| --- | --- |
| `lib/core/` | Configuration, theme, auth and routing |
| `lib/features/` | Recording, tasks, notes, journals, search and exploration screens |
| `lib/shared/services/` | Cloud files, backup, AI, notifications and shared workflows |
| `lib/features/exploration/services/` | News, literature, knowledge and stock research tools |
| `quant_core/src/` | Deterministic research and paper-execution foundation |
| `test/`, `quant_core/tests/` | Flutter and Python regression tests |
| `.github/`, `docs/` | Contribution workflow, CI, setup and known limitations |

## Maintenance and contribution focus

Current work includes improving retrieval quality, making research evidence reproducible, validating cross-platform behavior, controlling AI context cost, and completing data / execution edge cases. The public repository is intentionally separate from private service credentials, personal data and private Git history.

Codex has been used as a development assistant for debugging, review, documentation and release work. The application currently uses DeepSeek and optional Gemini services at runtime; it does not claim an existing OpenAI API integration or OpenAI endorsement.

Public adoption, releases and maintenance activity should be assessed from the repository's real history, Issues, checks and Releases. No user, download, star or external-impact numbers are implied by this overview.
