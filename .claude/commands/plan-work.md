---
description: "Plan owned tasks (files, interfaces, dependencies, review gate) in a file /implement can execute"
---

Plan `$ARGUMENTS` — a goal, an intake item, or a research or decision file; with nothing given, the work agreed in this conversation — as tasks that parallel implementers can run without colliding. Plan only: write no code. A Solana program's design (accounts, PDAs, instructions) comes from `/plan-feature` first; plan the tasks from its plan.

## Steps

1. **Inputs.** Read the decisions in force (`bash .claude/bin/decisions.sh in-force`; if the helper is missing or fails, say so and work from the conversation), the files named, and the code the goal touches (`Explore` subagents in parallel for a large codebase). Pin the base with `git rev-parse HEAD` (uncommitted changes are not in it): implementers branch from that commit, because a subagent's `isolation: worktree` starts from the default branch.
2. **Questions.** The user's calls ([triage](decide.md)) become briefs; plan around what they block and mark those tasks blocked. Minor calls go through `/decide`.
3. **Tasks.** Each names:
   - **Owner:** the kit agent that fits (`anchor-engineer`, `pinocchio-engineer`, `solana-frontend-engineer`, `rust-backend-engineer`, `mobile-engineer`, `tech-docs-writer`, …), else general-purpose.
   - **Files:** the exact paths it creates or modifies, then the ones it only reads. No file is written by two tasks.
   - **Interfaces:** what it consumes from other tasks and produces for them, as exact names, signatures and types: an implementer sees only its own task.
   - **Depends on:** task numbers.
   - **Gate:** the command that proves it done and the output that means pass (`/test-rust`, `/test-ts`, `/diff-review`, plus `/audit-solana` for code that holds funds). A gate that ran zero tests or reported SKIP has not passed.
4. **Shared files** have one owner, an integrator task after each wave: lockfiles (`Cargo.lock`, the package lockfile), `Anchor.toml`, the IDL and generated clients, `declare_id!`, CHANGELOG, VERSION and counts. Other tasks put the change they need there in their report instead of making it.
5. **Waves.** Order the tasks into waves by dependency; tasks in one wave write disjoint files. Merges happen one at a time, and they are the user's call.
6. **Attack the plan before handing it off.** An adversary subagent looks for a file two tasks write, an interface nobody produces, a gate that cannot fail, a premise nobody verified. Fix what it finds.

## Plan file

`.claude/context/plan-<YYYY-MM-DD>-<slug>.md`:

1. **Goal**, **base** (the SHA), and the **decisions in force** the plan builds on, id and one line each, so an executor still sees them where no hook delivers them.
2. **Stops:** the user's calls that halt execution, and the blocked tasks with what each waits on.
3. **Waves**, then each task under `### Task <n>: <name>` with the five fields above. That heading is the one superpowers' subagent-driven development reads, so either it or `/implement` can execute the plan.

## Output

The plan's path, one line per wave, and the briefs. Then stop for the user's approval: implementation starts with `/implement` or their go-ahead, never from this command.
