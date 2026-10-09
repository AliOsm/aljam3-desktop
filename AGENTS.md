# Aljam3 desktop

Aljam3 serves Sharia students and Muslims generally. Favor consistency, simplicity, performance, accuracy, quality and accessibility in everyday reading, searching and citation. Assess the same user tasks in Shamela.com and Turath.io when researching improvements; record observations rather than assuming feature parity is the goal.

## Workflow and authority

- Read `mise.toml`, `bin/`, and `docs/automation.md` before adding commands or patterns. Use simple English. Resolve routine reversible details independently; escalate material ambiguity, changed scope or missing authority.
- Follow `ieasybooks/aljam3-product`: CPO proposal → AliOsm approves its exact revision → CTO → independent QA → CPO accepts the experience → CEO → deterministic delivery gate. Existing app issues and labels are research inputs, not authorization.
- Keep the approved issue, revision, PR commits and evidence linked. Scope changes need renewed owner approval; code/base changes need new role reviews. Never waive checks, merge directly, publish updates locally or change agent authority.
- Check documentation when native/Ruby/Rust behavior is uncertain. Challenge the approach, test realistic failure cases and review the final diff before reporting completion.

## Code and experience

- Use the existing Ruby 3.4.7, pinned Scarpe/Rust runtime, SQLite/Arabic tokenizer and PDFium architecture. Read the pinned revisions and patches in `bin/setup`; don't silently upgrade native dependencies.
- Prefer direct code, existing components, and small useful abstractions. Apply KISS, DRY, YAGNI, SOLID and test-first work when beneficial. Estimate a line budget and review material overruns. Propose unrelated refactoring separately.
- Keep UI responsive during large-library search, downloads, PDF rendering, cancellation and background updates. Avoid blocking the UI thread; measure resource use and latency with realistic books.
- Preserve source quotations, edition/page references and attribution. Never silently rewrite religious text or present generated interpretation as source material. Content/scholarly changes require human review.
- Verify Arabic/RTL and mixed-direction text, keyboard focus, accessibility, light/dark themes, reduced motion and minimum window size. Stay consistent with web terminology while respecting native controls.
- Preserve existing libraries, downloads, bookmarks and reading state across offline/online transitions, failures, migrations and updates. Installed clients must continue to work with the public `/api/v1`; any breaking transition needs an approved migration plan.
- Windows x64, Windows 11 ARM emulation, and supported Apple silicon macOS releases are real targets. Linux headless checks do not prove a Windows installer or macOS package works.

## Verification and workspaces

- Use a dedicated worktree and `mise run agent:setup`. It prepares pinned dependencies and a disposable `ALJAM3_DATA_DIR`. Use `python3 bin/agent-workspace run …` for exploratory commands; never use the user's real library as a test fixture.
- Run `mise run test` for Ruby behavior. Use `test-native`, `verify-ui`, `verify-layout`, `verify-scroll`, `smoke` and the targeted probes appropriate to the change. Inspect screenshots using `peek`; do not claim a visual review based only on test exit codes.
- Reuse the Minitest fixture helpers and temporary stores. Keep tests focused, useful, deterministic and maintainable. Don't write tests merely to mirror implementation or raise coverage.
- QA addresses correctness, security, performance, accessibility, localization, data integrity, regression, compatibility and experience. Preserve concrete repro steps and resolve every finding with evidence or a justified dismissal.
- Keep redacted evidence under `.cache/agent-evidence/`, then attach durable reports/screenshots to GitHub. Don't upload credentials, personal libraries, telemetry identities or unrestricted copies of copyrighted books.

## Releases and PRs

- Commit, push and open PRs only when explicitly requested or in an owner-approved product cycle. Link PRs to T3 immediately. Explain the problem, behavior change, validation and material limitations; add screenshots and performance measurements where relevant.
- The delivery workflow builds and verifies both platform packages before publication. Update signing keys live only in protected GitHub environments. Signed metadata, artifact checksums, current version notes and exact commit provenance are required.
- Do not hard-wrap Markdown prose. Keep comments minimal and useful. Propose governance improvements through review; don't silently relax instructions or release policy.

General engineering guidance adapted from `milkstraw/MetalStraw/AGENTS.md`; Rails/Vue-specific rules do not apply to this native app.
