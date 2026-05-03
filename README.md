# Local LLM Pipeline Harness

Shell-first orchestration for a local multi-model Rust review and patch pipeline.

The harness owns model startup, prompt construction, worktrees, verification, diffs, policy gates, quality summaries, and final reports. Only the editor stage is allowed to modify source/test files, and it runs inside an isolated git worktree. Final approval means **ready for human inspection**, never automatic merge.

## Pipeline roles

| Stage | Role | Default model |
|---|---|---|
| 0 | Baseline snapshot + policy manifest | none |
| 1 | Finder | Qwen3.6-27B Q3_K_M |
| 1b | Optional shadow finder | Gemma 4 26B-A4B Q3_K_M |
| 2 | Challenge | Qwen3.6-35B-A3B Q3_K_M |
| 3 | Accepted issue extraction | shell |
| 4 | Patch writer | Qwen3.6-27B Q3_K_M |
| 5 | Editor / agent | Aider + local Qwen3-Coder-30B-A3B Q3_K_M |
| 6 | External verification + policy gates | shell |
| 7 | Final review | Qwen3.6-27B Q3_K_M |
| 8 | Revision writer | Qwen3.6-27B Q3_K_M |
| 12 | Optional second opinion | Gemma 4 26B-A4B Q3_K_M |

The same stage order supports three modes:

- `review`: finder/challenge produce accepted findings only; the pipeline stops before patch-writing and editing.
- `fix`: finder finds concrete bugs or missing preconditions, then accepted items may be patched.
- `feature`: finder creates a minimal implementation plan; challenge attacks the plan; accepted items may be patched.

## The enforced 16-rule policy

Every run writes `00-policy.md` and enforces these rules through scripts, not just prompts:

1. Separate review-only and patch-producing workflows.
2. Define quality through correctness, tests, safety, maintainability, overhead, observability, and dependency hygiene.
3. Hard-gate every patch with formatter, build, clippy, and tests.
4. Start from a mechanical baseline and context map.
5. Use local models only for file editing; cloud/strong agents may only be read-only outside this harness.
6. Use finder → challenge → accepted-items → patch-writer → editor → verifier → reviewer.
7. Enforce role permissions; only Stage 5 may edit the isolated worktree.
8. Apply subsystem/project-specific review addenda when available.
9. Run optional quality tools and record their result.
10. Source project-specific harness rules and context packs.
11. Use an isolated `llm/agent-*` worktree branch; no direct main/master edits.
12. Keep patches small and scoped; enforce changed-file and diff-size limits.
13. Feature prompts must include behavior, non-goals, compatibility, and tests.
14. Review-only mode stops before edits and outputs accepted findings.
15. Final approval means human inspection, not automatic merge.
16. Deterministic shell logs outrank LLM claims.

## Core safety rules

- The shell harness is the source of truth for `fmt`, `build`, `clippy`, `test`, workspace tests, and policy checks.
- The editor model is never trusted to report verification status.
- `cargo fmt` rescue is allowed, but it is recorded in `05-agent-result.md`.
- `build`, `clippy`, and `test` rescue are not allowed; failures go back through the revision loop.
- Raw review output never goes directly back to the editor. It always goes through the revision writer.
- No stage commits, pushes, merges, uses sudo/doas, installs packages, or uses network access inside the target repo.
- The editor model must be in `LOCAL_EDITOR_MODEL_ALLOWLIST` and must use a local `127.0.0.1` OpenAI-compatible endpoint.
- `APPROVED` means ready for human inspection, not merge permission.

## Hard verification gates

Stage 6 runs these by default:

```bash
RUSTUP_TOOLCHAIN=nightly cargo fmt --check
RUSTUP_TOOLCHAIN=nightly cargo build
RUSTUP_TOOLCHAIN=nightly cargo clippy --all-targets -- -D warnings
RUSTUP_TOOLCHAIN=nightly cargo test
RUSTUP_TOOLCHAIN=nightly cargo test --workspace
```

The exact commands are configurable in `config/pipeline.env` and project profiles. Formatting may be auto-corrected once by the harness, but build/clippy/test failures block the patch.

Stage 6 also enforces:

- editor did not commit or move `HEAD`
- changed files are inside the patch prompt's `Allowed files` section
- changed-file and diff-size limits
- feature source changes include test changes by default
- optional quality tools are recorded (`cargo audit`, `cargo deny`, `cargo machete`, `cargo llvm-cov`, `cargo mutants`) when enabled/available

## Project profiles

Project-specific policy lives under:

```text
config/projects/<repo-basename>.env
```

A `stutter` profile is included. It enforces the nightly toolchain, adds stutter-specific context packs, and loads `prompts/stutter-review-addendum.md` for eBPF/userspace ABI, scheduler accounting, process tracking, recording/reporting, affinity, and tune/scoring invariants.

## Repository layout

```text
config/
  models.env
  pipeline.env
  projects/stutter.env
prompts/
  finder.md
  finder-feature.md
  challenge.md
  challenge-feature.md
  patch-writer.md
  patch-writer-revision.md
  review.md
  second-opinion.md
  stutter-review-addendum.md
scripts/
  lib/context.sh
  lib/policy.sh
  model/start.sh
  model/stop.sh
  model/ask.sh
  stages/*.sh
  new-run.sh
  inspect-run.sh
  pipeline.sh
```

Run directories are created inside the target Rust repository:

```text
<target-repo>/.llm-runs/<RUN_ID>/
```

The writable agent worktree is created beside the target repo:

```text
<parent-of-target-repo>/llm-agent-<RUN_ID>/
```

## First-time setup

After cloning this harness repo, make scripts executable:

```bash
chmod +x scripts/*.sh scripts/model/*.sh scripts/stages/*.sh scripts/lib/*.sh
```

Edit `config/models.env` so portable defaults match your local model paths. Put machine-specific GPU/device overrides in the ignored file:

```bash
config/models.local.env
```

Put local context-budget or Aider overrides in the ignored file:

```bash
config/pipeline.local.env
```

Required tools:

```text
bash, git, jq, curl, cargo, aider, llama-server
```

Optional quality tools:

```text
cargo-audit, cargo-deny, cargo-machete, cargo-llvm-cov, cargo-mutants
```

## Smoke-test a model

```bash
bash scripts/model/start.sh qwen27b
printf 'You are a test model.\n' > /tmp/sys.md
printf 'Reply with exactly: OK\n' > /tmp/user.md
bash scripts/model/ask.sh 8081 /tmp/sys.md /tmp/user.md /tmp/out.md
cat /tmp/out.md
bash scripts/model/stop.sh qwen27b
```

## Start a review-only run

```bash
bash scripts/new-run.sh ~/projects/my-rust-project review \
  "Strictly review the affinity/restore path. Produce findings only; do not edit."

bash scripts/pipeline.sh ~/projects/my-rust-project/.llm-runs/<RUN_ID>
```

This stops after `03-accepted-issues.md` and writes a `REVIEW_READY` final decision.

## Start a bug-fix run

```bash
bash scripts/new-run.sh ~/projects/my-rust-project fix \
  "Review hwmon.rs for stale GPU sample bugs. Do not change public API unless required."

bash scripts/pipeline.sh ~/projects/my-rust-project/.llm-runs/<RUN_ID>
```

## Start a feature run

```bash
bash scripts/new-run.sh ~/projects/my-rust-project feature \
  "Implement CSV export for recorded GPU samples without changing existing JSON output. Add tests."

bash scripts/pipeline.sh ~/projects/my-rust-project/.llm-runs/<RUN_ID>
```

Feature mode requires test changes when Rust/Cargo source changes are made, unless you explicitly disable `FEATURE_REQUIRE_TEST_CHANGES` in a local override.

## After approval

The harness does not merge automatically. Inspect the worktree yourself.

Use the helper:

```bash
bash scripts/inspect-run.sh ~/projects/my-rust-project/.llm-runs/<RUN_ID>
```

Rerun verification manually inside the worktree with:

```bash
bash scripts/inspect-run.sh ~/projects/my-rust-project/.llm-runs/<RUN_ID> --verify
```

Manual equivalent:

```bash
cd ../llm-agent-<RUN_ID>
git status --short
git diff
cat <target-repo>/.llm-runs/<RUN_ID>/09-final-decision.txt
cat <target-repo>/.llm-runs/<RUN_ID>/05-agent-result.md
cat <target-repo>/.llm-runs/<RUN_ID>/06-quality-scorecard.md
```

If satisfied, merge manually from your target repo.
