# Adaptive Optopatch audit worker

Work only on the single finding below. `main` at the recorded base SHA is authoritative.

- Read `AGENTS.md` from the parent workspace and the repository documentation before editing.
- Make no scientific or experimental policy decisions. If the finding requires one, stop and explain the blocker in your final response.
- Do not make unrelated fixes or broad refactors.
- Add or update focused regression tests and relevant documentation when warranted.
- Run the focused test named in the handoff if practical. Do not run the full
  repository suite; the orchestrator serializes full suites after workers exit.
- Inspect the final diff for scope and accidental generated files.
- Create exactly one coherent git commit. Do not push, merge, rebase, or alter `main`.
- Leave the worktree clean. Your final response must state the commit SHA and tests run.
