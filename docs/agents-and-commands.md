# Agents and commands

The complete reference: 15 agents with the model each one runs on, 47 workflow commands, how the agent-workflow commands chain from intake to merge, and how to compose agents into a team. Nothing here loads up front — Claude Code lists only each agent's and command's one-line description, and reads a body when a task needs it.

## Agents

| Agent | Purpose | Model |
|-------|---------|-------|
| **solana-architect** | System design, PDA schemes, token economics, multi-program architecture | Opus |
| **anchor-engineer** | Anchor development, IDL generation, account constraints | Opus |
| **pinocchio-engineer** | CU optimization (80-95% savings), zero-copy, minimal binary | Opus |
| **defi-engineer** | DeFi integrations: Jupiter, Kamino, Raydium, Orca, Meteora | Opus |
| **token-engineer** | Token-2022 extensions, token economics, launch mechanics | Opus |
| **solana-frontend-engineer** | React/Next.js, wallet UX, transaction flows, accessibility | Opus |
| **mobile-engineer** | React Native/Expo, mobile wallet adapter, deep linking | Opus |
| **rust-backend-engineer** | Axum APIs, indexers, WebSocket services | Opus |
| **devops-engineer** | CI/CD, monitoring, RPC infrastructure, Cloudflare Workers | Opus |
| **solana-qa-engineer** | Testing (Mollusk/LiteSVM/Trident), CU profiling, code quality | Opus |
| **tech-docs-writer** | READMEs, API docs, integration guides | Opus |
| **game-architect** | Solana game design, Unity architecture, on-chain game state, PlaySolana | Opus |
| **unity-engineer** | Unity/C# implementation, Solana.Unity-SDK, wallet integration, NFT display | Opus |
| **solana-guide** | Learning, tutorials, concept explanations, progressive learning paths | Opus |
| **solana-researcher** | Ecosystem research, protocol investigation, SDK analysis | Opus |

**Model routing:** every agent pins `model: opus`, because Opus 5.5 is currently the best value for this work — implementation, docs and research included, not only deep reasoning. The trade accepted: a pinned agent ignores your session model, so a Fable session's subagents run on Opus. The kit never pins `fable`. Commands inherit your session model, except `/doctor`, `/setup-mcp` and `/scaffold`, which run on Sonnet for that turn: they are mechanical and you run them at the start of a session, where a model switch costs no cached prompt. Since no agent inherits, `CLAUDE_CODE_SUBAGENT_MODEL` in your settings `env` changes none of them on its own; add `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` to apply it to every agent.

## Agent Teams

Each agent loads its own specialized context on invocation:

```
"Use solana-architect to design the vault program"
"Use anchor-engineer to implement the deposit instruction"
"Use defi-engineer to integrate Jupiter swaps"
"Use solana-qa-engineer to write comprehensive tests"
```

Claude will spawn each specialized agent by itself based on context. Agent teams, where several Claude sessions share a task list and message each other, are an experimental Claude Code feature that is off by default, and the kit leaves it off: while it is on, a subagent Claude names can launch as a teammate, which costs more tokens. To opt in, add this to `.claude/settings.local.json`:

```json
{ "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" } }
```

Then ask for a team:

```
"Create an agent team: solana-architect for design, anchor-engineer for implementation, solana-qa-engineer for testing"
```

Recommended team patterns:

| Pattern | Flow | Use Case |
|---------|------|----------|
| **program-ship** | architect → anchor/pinocchio → qa | Build program from spec to tested |
| **full-stack** | architect → anchor → frontend → qa | End-to-end feature |
| **audit-and-fix** | qa → auditor-skill context → anchor | Audit and remediate |
| **game-ship** | game-architect → unity → qa | Game feature |
| **research-and-build** | researcher → architect → anchor/pinocchio | Investigate a protocol or pattern, then design and implement |
| **defi-compose** | researcher → defi-engineer → qa | DeFi integration |
| **token-launch** | token-engineer → frontend → qa | Token creation + launch UI |

## Commands

### Building
| Command | Purpose |
|---------|---------|
| `/build-program` | Build Anchor or native Solana program |
| `/build-app` | Build Next.js/Vite web client |
| `/build-unity` | Build Unity project (WebGL, Desktop, PSG1) |
| `/scaffold` | Generate project scaffolding (program + frontend + tests + CI) |

### Testing & Quality
| Command | Purpose |
|---------|---------|
| `/test-rust` | Run Mollusk, LiteSVM, Surfpool, Trident tests |
| `/test-ts` | Run TypeScript tests (Anchor, Vitest, Playwright) |
| `/test-dotnet` | Run .NET/C# tests (Unity Test Framework, NUnit) |
| `/test-and-fix` | Run tests and auto-fix common issues |
| `/audit-solana` | Comprehensive security audit |
| `/audit-infra` | Infra-first security audit: secrets, supply chain, CI/CD, LLM/skill security, OWASP, STRIDE |
| `/product-review` | Product quality review — UX walkthrough, 8-dimension scorecard (`--harsh` for the roast variant) |
| `/diff-review` | AI-powered diff review for Solana-specific issues |
| `/profile-cu` | CU profiling per instruction with optimization suggestions |
| `/benchmark` | CU benchmarks with before/after comparison |
| `/debug-user-tx` | Replay a user's failing tx against forked state, map error to source |
| `/inspect-mint` | Decode a mint from raw bytes (RPC `jsonParsed` drops extensions), list live authorities, flag integration risks |

### Deployment & Migration
| Command | Purpose |
|---------|---------|
| `/deploy` | Deploy to devnet (always first) or mainnet |
| `/migrate-web3` | Migrate from @solana/web3.js to @solana/kit |
| `/generate-idl-client` | Generate typed clients from IDL (Codama/Shank) |

### Workflow & Setup
| Command | Purpose |
|---------|---------|
| `/quick-commit` | Create branch, format, lint, conventional commit |
| `/pr-description` | Write a PR title and body a reviewer can verify: repro without funds, test plan with real counts, risk |
| `/commit-claude-config` | Version the kit config in git (un-ignores `.claude/`, `.mcp.json`, `.gitmodules` and commits them with `CLAUDE.md`) |
| `/setup-ci-cd` | Configure GitHub Actions pipeline |
| `/firewall` | Show or switch the firewall tier (Off / Relaxed / Medium / High) |
| `/setup-mcp` | Configure MCP server API keys and connections |
| `/resync` | Resync external skill submodules to latest |
| `/add-skill` | Install a pinned skill extension on demand, or list core packs and extensions |
| `/write-docs` | Generate documentation for programs, APIs, components |
| `/explain-code` | Explain complex code with visual diagrams |
| `/plan-feature` | Plan feature implementation with specifications |
| `/update` | Update config to latest version from upstream |
| `/cleanup` | Initialize forked template — setup CLAUDE.md, remove scaffolding |
| `/doctor` | Health check for dev environment + config — read-only, one fix-it command per failure |
| `/dream` | Memory consolidation — dedupe, prune, re-rank MEMORY.md and Project Learnings |

### Agent workflow

A command per step of taking work from a backlog to a merge, two modifiers, and two for picking work back up. [How the agent workflow chains](#how-the-agent-workflow-chains) shows how they fit together.

| Command | Purpose |
|---------|---------|
| `/intake` | Step 1. PRs, issues, a board or a goal into a numbered work list and the questions only you can answer; flags work an open PR or another worktree already covers |
| `/research` | Step 2. Researchers by angle plus an adversary; dated, sourced claims with re-verify-by dates, written to a file |
| `/decide` | Step 3. Settle a question: a verified panel decides and records the clear calls, and yours come to you as numbered briefs plus a decision sheet you answer in the browser (`--no-sheet` skips it). With no argument, lists every open decision |
| `/plan-work` | Step 4. Owned tasks in waves (files, interfaces, dependencies, a review gate each) in a plan file `/implement` executes |
| `/implement` | Step 5. Run an approved plan: implementers in worktrees from a pinned commit, one integrator, cherry-picks, no merges |
| `/review-round` | Step 6. Review a PR, branch, range or `since <date>` by lens, reproduce High and Critical findings before reporting them, and write a numbered sheet bound to the head commit (`--candidates`, `--clear-wins`) |
| `/fix-wave` | Step 7. Apply the fixes you approved on that sheet and re-verify each |
| `/ship` | Step 8, yours to type. Merge PRs inside a standing order you gave, after green checks and a review of the head commit; closes their issues |
| `/crew` | Steps 1–7 in one run, stopping at your gates; ends by asking you to type `/ship` |
| `/parallel` | Modifier, yours to type. Run any task with parallel agents: file-owned lanes, a worktree per writer, one integrator, verified reports |
| `/adversarial` | Modifier, yours to type. Put a task's load-bearing claims and decisions through a proposer and an adversary, with proof per premise |
| `/proceed` | Yours to type. Resume interrupted work from what is on disk, relaunching only what is unfinished |
| `/rundown` | Status for a returning user: decided while you were away, needs your call, in flight, blocked, next. `--handoff` also writes it to a file |

## How the agent workflow chains

The steps split one cycle — read the backlog, settle the open questions, plan, build, review, fix, merge — so you can run any step alone, hand its output to the next, or let `/crew` run steps 1 to 7:

```text
/intake → /research → /decide → /plan-work → /implement → /review-round → /fix-wave → /ship
   gate 1 if questions        gate 2 always             gate 3 if anything open    you type it
```

**Your gates.** `/crew` stops after `/intake` when it has questions for you, always at the plan (nothing is built before you approve it), after `/review-round` when the sheet holds anything to answer or approve, and always before shipping, where it asks you to push the branch, open the PR and type `/ship`. It runs at most two fix waves. A scope you name is a hard stop: plan-only ends at the plan, investigate-only after `/decide`, candidates-only at `/review-round --candidates`'s sheet, and clear-wins-only runs `/review-round --clear-wins`.

**Your calls come as briefs.** Each one is numbered so you answer by number: the question, a recommendation and the best case against it, its premises marked verified or assumed, whether it is reversible, and what it blocks, restated in full until you answer or drop it. Always yours: product intent, a material change of scope or architecture, contradicting a decision you made or a fact you stated, operational approvals (merge, push, publish, deploy, authority changes, anything on another repository), deleting what you did not name, claims in documents others will read, and keys, funds and mainnet. A clear call — every premise verified, the panel agrees or the proof settles it, and it is reversible — is decided, recorded and reported under Done; a cloudy one, and every taste or wording call, comes to you.

**`/decide`'s decision sheet.** Whenever a call needs you, `/decide` also puts its briefs on a local HTML page, unless you pass `--no-sheet`: a card per decision with its options as buttons, the context folded away and a notes box, and a Copy answers button. `/decide` gives you the line to open it, `! open <path>` (`! xdg-open <path>` on Linux): the sandbox keeps the agent from opening it, a command you type at the `!` prompt runs outside the sandbox, and `.claude/bin/decision-sheet.sh`, which renders the page, never opens anything. Pick, add notes, press Copy answers and paste the text back; `/decide` records each answered line word for word as your answer to the proposal it names, and a line left `not answered` stays open. The numbered list still comes in the reply, so the sheet is never the only way to answer. The page and the JSON it is rendered from stay beside the decision record under the git directory, or under `$TMPDIR` where there is no record, and never in `.claude/context/`: a project that commits `.claude/` would publish them. The page makes no network request, and your drafts stay in that browser until you copy them.

**The decision record.** The commands read the decisions in force with `.claude/bin/decisions.sh` and paste them into every agent's brief, and they write to the record from the main session only: your answers and standing orders in your own words, a panel's clear calls, and calls made while recovering from an interruption, which stay provisional until you ratify them. It lives in the git common directory, shared by every worktree of the clone and never committed. Where the helper is missing or fails, a command says so and works from the conversation.

**Hand-offs are files.** Results go to `.claude/context/`, which both install modes gitignore, so the next step, a resumed session or a teammate reads a file rather than a memory: research, work lists, plans, review sheets (named after the head commit they cover), per-task reports, `/crew`'s stage file and `/rundown --handoff`'s handoff. `/decide`'s briefs are the exception: they go to the decision record and its sheet, as above.

**Fan-out.** Work that fans out runs as a dynamic workflow when the session can run one, so you can watch every agent in `/workflows`, and otherwise as background subagents, in `/tasks`. Each writer gets a worktree under `.claude/worktrees/` (also gitignored), made with git from a pinned commit because a subagent's own worktree starts from the default branch, and reports to a file; the session re-runs the check behind each claim the next step rests on before relaying it. Nothing in the chain pushes or opens a PR, and only `/ship` merges one.

**Modifiers stack.** At the terminal prompt, type `/parallel` or `/adversarial` in front of any task, or both: `/parallel /adversarial plan the best path ahead` loads both and hands each the same text, and `/parallel proceed` fans out whatever is unfinished. Claude Code expands up to six stacked commands; under `claude -p` or the Agent SDK it loads only the first, and the modifiers say so before carrying on.

**Each step has a default mode.** A modifier typed in front of a step adds the mode it lacks, for that run only: `/adversarial /intake 41 42` puts the work list's claims to an adversary as well. `/crew` runs every step in its default.

| Step | Runs by default |
|------|-----------------|
| `/intake` | Parallel: one reader per input when there are several |
| `/research` | Both: a researcher per angle at once, then an adversary on their claims |
| `/decide` | Adversarial: a proposer and an adversary, and a verifier per premise |
| `/plan-work` | Adversarial: an adversary attacks the plan before you see it |
| `/implement` | Parallel: a wave's tasks at once, one owner per file |
| `/review-round` | Both: a reviewer per lens at once; High and Critical findings reproduced, then confirmed, disputed or downgraded by a peer |
| `/fix-wave` | Parallel: approved fixes grouped by the files they touch, each fix re-checked |
| `/ship` | Neither: one PR at a time |

**`/ship`'s limits.** It merges one PR at a time, only inside a standing order you gave (PR numbers typed with `/ship` are one), once every check has passed and a review covers the PR's head commit: a `/review-round` sheet naming that SHA, or a GitHub review of it by the reviewer your order named. With no reviewer named, the sheet must have nothing open at Critical or High. It merges with `--match-head-commit`, so GitHub refuses if the head moved; never uses `--admin`, `--auto` or `--delete-branch`; never pushes to a PR branch; re-checks the files that changed on the base since the PR branched; closes the linked issues left open; and stops the train at the first failure. No standing order covers mainnet, program upgrades, authority changes, keys, funds, deletions or another repository. The firewall lets `gh pr merge` through at Relaxed and asks at Medium, an ask a bypassed permission mode skips, so below High these rules are what holds; High denies it, and `/ship` hands you the merge commands to run.

**Resuming and catching up.** `/proceed` takes stock from disk — git, the worktrees, and the files in `.claude/context/` — re-reads the decisions and relaunches only what is unfinished, never two writers on one lane; a call it makes without you is recorded as provisional. `/rundown` reports from the record, git and `gh`: what was decided while you were away (one-way calls and calls against a recommendation first), what needs your call, what is in flight, what is blocked and what is next.

**Cost.** Nine of the thirteen are model-invocable, so Claude can run one when your request matches it ("another review round", "give me the rundown"); their descriptions join every session's listing, about 860 characters (roughly 200 tokens) in all. `/ship`, `/parallel`, `/adversarial` and `/proceed` set `disable-model-invocation: true`: Claude cannot invoke them, and they cost no context until you type them.

**Other installs.** A plugin install namespaces them (`/solana-ai-kit:crew`) and has no `.claude/bin/`, so the record and the decision sheet are absent and each command works from the conversation; [plugin.md](plugin.md) has what else to set up. An `--agents` install copies them to `.agents/commands/` as reference prompts an agent can follow when you point it at one; workflows, stacking and `/crew`'s chaining through the Skill tool are Claude Code features and do not carry over.
