# Local LLM Pipeline Harness

Shell-first orchestration for a local multi-model Rust review and patch pipeline.

The harness owns model startup, prompt construction, worktrees, verification, diffs, and final reports. Only the editor stage is allowed to modify source/test files, and it runs inside an isolated git worktree.

## Pipeline roles

| Stage | Role | Default model |
|---|---|---|
| 0 | Baseline snapshot | none |
| 1 | Finder | Qwen3.6-27B Q3_K_M |
| 1b | Optional shadow finder | Gemma 4 26B-A4B Q3_K_M |
| 2 | Challenge | Qwen3.6-35B-A3B Q3_K_M |
| 3 | Accepted issue extraction | shell |
| 4 | Patch writer | Qwen3.6-27B Q3_K_M |
| 5 | Editor / agent | Aider + Qwen3-Coder-30B-A3B Q3_K_M |
| 6 | External verification | shell |
| 7 | Final review | Qwen3.6-27B Q3_K_M |
| 12 | Optional second opinion | Gemma 4 26B-A4B Q3_K_M |

The same stage order supports both bug-fix review and feature implementation:

- `fix`: finder finds concrete bugs or missing preconditions.
- `feature`: finder reads the code and creates an implementation plan; challenge attacks the plan.

## Core safety rules

- The shell harness is the source of truth for `fmt`, `clippy`, and `test` results.
- The editor model is never trusted to report verification status.
- `cargo fmt` rescue is allowed, but it is recorded in `05-agent-result.md`.
- `clippy` and `test` rescue are not allowed; failures go back through the revision loop.
- Raw review output never goes directly back to the editor. It always goes through the revision writer.
- No stage commits, pushes, merges, uses sudo/doas, installs packages, or uses network access inside the target repo.
- Treat `APPROVED` as ready for human inspection, not as permission to merge automatically.

## Recommended first-use policy

Use the harness as a supervised local code-review and patch assistant.

Good first tasks:

```text
- Small bug fixes with clear symptoms
- Clippy/test/build failures
- Localized Rust refactors
- Adding focused regression tests
- Build-script/config/error-message improvements
- Pre-release review of changed files
```

Avoid starting with:

```text
- Huge architecture rewrites
- Security-sensitive changes without manual review
- Vague "review the whole project and fix everything" prompts
- Tasks that require network access or package installation in the target repo
```

## Repository layout

```text
config/
  models.env
  pipeline.env
prompts/
  finder.md
  finder-feature.md
  challenge.md
  challenge-feature.md
  patch-writer.md
  patch-writer-revision.md
  review.md
  second-opinion.md
scripts/
  lib/context.sh
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
chmod +x scripts/*.sh scripts/model/*.sh scripts/stages/*.sh
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

## Smoke-test a model

```bash
bash scripts/model/start.sh qwen27b
printf 'You are a test model.\n' > /tmp/sys.md
printf 'Reply with exactly: OK\n' > /tmp/user.md
bash scripts/model/ask.sh 8081 /tmp/sys.md /tmp/user.md /tmp/out.md
cat /tmp/out.md
bash scripts/model/stop.sh qwen27b
```

## Start a bug-fix run

```bash
bash scripts/new-run.sh ~/projects/my-rust-project fix \
  "Review hwmon.rs for stale GPU sample bugs. Do not change public API unless required."

bash scripts/pipeline.sh ~/projects/my-rust-project/.llm-runs/<RUN_ID>
```

## Start a feature run

```bash
bash scripts/new-run.sh ~/projects/my-rust-project feature \
  "Implement CSV export for recorded GPU samples without changing existing JSON output."

bash scripts/pipeline.sh ~/projects/my-rust-project/.llm-runs/<RUN_ID>
```

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
```

If satisfied, merge manually from your target repo.
