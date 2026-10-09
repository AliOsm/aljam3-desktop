# Product agents

The mandate, role instructions, proposal approvals and activation runbook live in [aljam3-product](https://github.com/ieasybooks/aljam3-product). Initial operation is disabled; setup and CI do not authorize a pilot or release.

Use an isolated worktree and `mise run agent:setup` after installing/trusting the repository's mise configuration. It runs the existing pinned `bin/setup` and prepares `.cache/agent-data/`. Commands through `python3 bin/agent-workspace run <command>` receive that disposable data path. Existing tests and native probes also use their own temporary fixtures. Never substitute the user's actual library to make a test pass.

Import the checked-in T3 actions. The setup hook blocks the agent until setup finishes. `peek` creates inspectable screenshots/layout output. Evidence stays local under `.cache/` until uploaded with a redacted report; the settle action reports its location without deleting it. A hook is setup/cleanup, not acceptance. A shell-created child worktree must be supplied explicitly in the task brief and prepared there; it does not change the T3 thread binding.

`CI` runs application tests and native input/layout/rendering checks on macOS and Windows for PRs and main commits. The aggregate `Aljam3 / CI` is the required status. Deep QA selects additional interaction, scrolling, layout and real-book smoke probes based on the change, and must inspect the actual images. Native Linux results alone do not validate packaged apps on supported platforms.

`bin/verify-ui` defaults to a 120-second overall probe allowance. Hosted Windows uses `ALJAM3_UI_TIMEOUT=300`: the audit exercised all assertions successfully but needed about 139 seconds on the runner. Per-scenario waits and assertions are unchanged. Invalid/non-positive timeout values fail before starting the probe.

`Build packages` remains a manually dispatched workflow and has an owner-only manual route plus a gated agent route. The agent route requires live policy, a product issue, an approved exact SHA and a unique delivery permit. It builds both platforms, validates installers and updates, signs metadata in the `aljam3-production` environment, publishes and verifies release assets. All evidence artifacts are retained for 30 days. Fork/PR CI receives no signing key.

Before activation, put `UPDATE_PRIVATE_KEY` only in the environment restricted to `main`, configure the private product repository's read-only `ALJAM3_PRODUCT_READ_TOKEN`, install the dedicated delivery GitHub App and finish the product runbook. A production key at repository scope would also be accessible to other permitted workflows; moving it into the environment is part of activation, not something this PR can do without its owner-provided value.

Each new release must include `docs/releases/<version>.md` with accurate Arabic user-facing notes, platform requirements, update/data preservation behavior and any installation caveats. Automated publication must never reuse notes from an earlier release. Existing owner-managed releases may use the legacy notes until the first governed release supplies versioned notes.
