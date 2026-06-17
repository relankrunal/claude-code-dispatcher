# Claude Code Model Dispatcher

Session-level model router for Claude Code. Describe your task once; a fast
classifier picks the right model (Haiku / Sonnet / Opus) by **task complexity**
and launches the session on it. The model stays locked for the whole session.

```powershell
ccs "what does the AuthMiddleware class do?"          # -> Haiku   (cheap, fast)
ccs "add unit tests for OrderValidator.Validate"      # -> Sonnet  (everyday work)
ccs "investigate the intermittent deadlock on save"   # -> Opus    (hard problems)
```

One command replaces `claude` + a manual `/model` guess. Right model, no thinking about it.

---

## Table of contents

- [Why this exists](#why-this-exists)
- [Mental model: how it actually works](#mental-model-how-it-actually-works)
- [Prerequisites](#prerequisites)
- [Install](#install-one-time-about-5-minutes)
- [What happens when you run it (end to end)](#what-happens-when-you-run-it-end-to-end)
- [Everyday use](#everyday-use)
- [How routing decides](#how-routing-decides)
- [Configuration](#configuration-tune-without-editing-code)
- [Reporting](#reporting)
- [Optional: the safety-net hook](#optional-the-safety-net-hook)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Scope & notes](#scope--notes)
- [License](#license)

---

## Why this exists

Claude Code defaults to a single model per session. That leaves you two bad options:

- Default to a **powerful** model (Opus) and overpay on routine work like renames and tests, or
- Default to a **light** model and manually switch up for the hard tasks — which you'll forget to do.

Claude Code has no built-in task-complexity routing, so the choice falls on you every
single session. This tool makes that choice automatically — **once per session**, where
it's cheap and accurate — so routine work runs on a cheaper model and hard problems get
the strong one, without you thinking about it.

---

## Mental model: how it actually works

Two ideas trip people up first. Read these two sentences and the rest is easy:

1. **The tool files live in ONE fixed place; you RUN the tool from anywhere.**
   You install the scripts once (e.g. `C:\tools\claude-dispatch\`). You do **not** copy
   them into each project. A small alias (`ccs`) lets you call them from inside any
   project folder.

2. **`ccs` REPLACES the `claude` command — it launches Claude Code for you.**
   You never type `claude` yourself. `ccs` figures out the model, then opens the normal
   interactive Claude Code session automatically, with your prompt already submitted.

```
                    ┌─────────────────────────────────────────────┐
   You type:        │  ccs "fix the null check in the auth handler" │
                    └───────────────────────┬─────────────────────┘
                                            │
                          (1) sends prompt to Haiku to classify (~1 sec)
                                            │
                          (2) picks model:  SIMPLE -> sonnet
                                            │
                          (3) runs:  claude --model sonnet "fix the null check..."
                                            │
                                            ▼
                    ┌─────────────────────────────────────────────┐
                    │  Normal Claude Code session opens on Sonnet,  │
                    │  your prompt already sent. Keep working.      │
                    └─────────────────────────────────────────────┘
```

---

## Prerequisites

Before installing this tool, you need these working **first**:

| Requirement | How to check | If missing |
|-------------|--------------|------------|
| **Windows PowerShell** (5.1+) or **PowerShell 7** | Open the Start menu, search "PowerShell" | Built into Windows 10/11. For PS7: `winget install Microsoft.PowerShell` |
| **Claude Code CLI** installed and working | Run `claude --version` in PowerShell | Install Node.js 18+, then `npm install -g @anthropic-ai/claude-code`. See Anthropic's docs. |
| **You can run `claude` on its own** | Run `claude` in a project, confirm it opens | Fix your Claude Code install/login before continuing |

> **Important:** this tool is a *wrapper* around Claude Code. It does not install or
> replace Claude Code — it assumes `claude` already works. If `claude --version` fails,
> stop and fix that first; nothing here will work until it does.

Use **PowerShell**, not Command Prompt (`cmd.exe`). These are `.ps1` scripts and the
`ccs` alias is defined in your PowerShell profile — they will not work in cmd.

---

## Install (one-time, about 5 minutes)

### Step 1 — Put the files in a permanent location

Create a folder that you will NOT delete, and copy the files in. Recommended:

```
C:\tools\claude-dispatch\
├── Start-ClaudeSession.ps1
├── Get-RoutingStats.ps1
├── dispatch-config.json
└── hooks\
    └── model-advisor-hook.ps1
```

> Keep `Start-ClaudeSession.ps1` and `dispatch-config.json` **in the same folder** —
> the script reads its config from its own directory. Do **not** put this folder inside
> a project you commit to git; it's a personal tool used across all projects.

### Step 2 — Allow local scripts to run (one time per machine)

Windows blocks unsigned scripts by default. Allow them for your user only:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

(Answer `Y` if prompted. This affects only your account, not the whole machine.)

### Step 3 — Add the `ccs` alias to your PowerShell profile

Your "profile" is a script PowerShell runs every time it starts. Open it:

```powershell
notepad $PROFILE
```

If Notepad says the file doesn't exist, click **Yes** to create it. Paste these two
lines, adjusting the path if you used a different folder in Step 1:

```powershell
function ccs   { & 'C:\tools\claude-dispatch\Start-ClaudeSession.ps1' @args }
function ccrep { & 'C:\tools\claude-dispatch\Get-RoutingStats.ps1' @args }
```

Save and close Notepad.

### Step 4 — Reload your profile

Either close and reopen PowerShell, or run:

```powershell
. $PROFILE
```

### Step 5 — Verify it works

```powershell
ccs -DryRun "what does the AuthMiddleware class do?"
```

You should see a routing decision like `[dispatch] TRIVIAL (conf 0.88) -> haiku`
**without** a session launching (that's what `-DryRun` does). If you see that line,
you're installed correctly.

If instead you get `ccs : The term 'ccs' is not recognized`, the alias didn't load —
recheck Step 3 (path correct? saved?) and Step 4.

---

## What happens when you run it (end to end)

A complete, real session from start to finish:

```powershell
# 1. Open PowerShell, go to the project you want to work on
cd C:\repos\my-project

# 2. Run ccs with your opening request (this REPLACES typing `claude`)
ccs "fix the null check in the auth handler"

# 3. You see the routing decision (Haiku classified it in ~1 second):
#    [dispatch] SIMPLE (conf 0.85) -> sonnet
#    [dispatch] well-specified single-component edit

# 4. Claude Code opens AUTOMATICALLY on Sonnet, your prompt already submitted.
#    You're now in a normal interactive Claude Code session:
> # ...Claude starts working on the null check...

# 5. Keep talking normally. The model stays Sonnet the whole session:
> "now add a test for the null case"
> "what other handlers have the same gap?"

# 6. When done, exit the session as you normally would (Ctrl+C or /quit).

# 7. Next task? Run ccs again — it re-classifies and may pick a different model:
ccs "redesign how we coordinate the background workers"
#    [dispatch] COMPLEX (conf 0.92) -> opus
```

Key points:
- You typed `claude` **zero** times. `ccs` launched it for you, twice, on different models.
- The classification happens **once** at launch, not on every follow-up message.
- Your prompt in quotes becomes the **first message** of the session — not a separate step.

---

## Everyday use

```powershell
ccs "investigate the intermittent deadlock on save"   # COMPLEX -> opus
ccs "add unit tests for OrderValidator.Validate"      # SIMPLE  -> sonnet
ccs "what does the AuthMiddleware class do?"          # TRIVIAL -> haiku
```

**Overrides** (when you already know which model you want):

```powershell
ccs -Model opus "anything"             # force a model via parameter
ccs "!sonnet rename getUserData"        # force a model via inline prefix
ccs -DryRun "some task"                # show the decision WITHOUT launching
```

**Passing extra Claude Code arguments** through to the session:

```powershell
ccs -ClaudeArgs '--add-dir','../shared-lib' "refactor the shared validators"
```

Inside the session it's plain Claude Code — ask follow-ups freely. To override the
model mid-session, use Claude Code's own command: `/model opus`.

---

## How routing decides

The launcher sends your task to a fast **Haiku classifier** (~1 sec, fractions of a
cent) that judges **task complexity, not prompt length**. A long, well-specified prompt
can still be SIMPLE; a short prompt demanding design judgment is COMPLEX.

| Tier | Model | Use it for |
|------|-------|-----------|
| **TRIVIAL** | Haiku | Explaining existing code, quick factual lookups, formatting, trivial Q&A |
| **SIMPLE** | Sonnet | Tests, renames, scaffolding, boilerplate, well-specified single-component edits |
| **COMPLEX** | Opus | Architecture, design trade-offs, cross-cutting changes, debugging unknown root causes, concurrency, performance, security |

**Fail-strong rule:** if the classifier's confidence is below the floor (default `0.6`),
the tier is bumped **up** one level (TRIVIAL→SIMPLE, SIMPLE→COMPLEX). A wrong guess
toward the stronger model costs a little money; a wrong guess toward the weaker model
costs quality. We bias toward quality.

The classifier runs **once per session**, never per prompt. A long back-and-forth is
still a single classification, and the model never changes mid-session — mid-session
switching breaks prompt caching and increases cost without improving results.

---

## Configuration (tune without editing code)

All tuning lives in `dispatch-config.json`, next to the script:

```json
{
  "models":  { "router": "haiku", "trivial": "haiku", "simple": "sonnet", "complex": "opus" },
  "confidenceFloor": 0.6,
  "logDir": null
}
```

| Field | What it does |
|-------|--------------|
| `models.router` | The model used to classify. Keep it on the cheapest fast model (Haiku). |
| `models.trivial/simple/complex` | Which model each tier launches. Accepts aliases (`haiku\|sonnet\|opus`) or full IDs like `claude-opus-4-8`. Pin full IDs for version stability across a team. |
| `confidenceFloor` | Raise toward `0.8` to route more aggressively to the stronger model (safer, costlier). Lower toward `0.4` to trust the cheaper tiers more (cheaper, riskier). |
| `logDir` | `null` uses `~/.claude-dispatch`. Set a path to relocate logs, or a shared path for team-wide logs. |

**Per-project bias:** because the script reads config from its own folder, you can keep
separate installs with different `dispatch-config.json` files — e.g. an architecture-heavy
project leaning Opus, a simple CRUD app leaning Sonnet.

---

## Reporting

```powershell
ccrep                     # summarize all logged sessions
ccrep -Since 2026-06-01   # only sessions since a date
```

Prints how your sessions split across models and an estimated saving versus an
all-Opus baseline:

```
  Claude Code Routing Report
  Total sessions: 48

  Model                        Count    Share
  --------------------------------------------
  sonnet                          27    56.3%
  opus                            14    29.2%
  haiku                            7    14.6%

  Relative cost vs all-Opus baseline: 41% of baseline
  Estimated saving from routing:      59%
```

The cost weights are planning estimates. For an accurate figure, pass current pricing
ratios: `ccrep -OpusWeight 1.0 -SonnetWeight 0.2 -HaikuWeight 0.05`.

---

## Optional: the safety-net hook

For people who launch `claude` directly instead of `ccs`, `hooks/model-advisor-hook.ps1`
checks the **first prompt only** and prints a suggestion (e.g. `consider /model opus`)
if the active model looks wrong for the task. It never auto-switches and goes silent
after the first prompt.

This is **per project**, registered in that project's `.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [
        { "type": "command",
          "command": "powershell -NoProfile -ExecutionPolicy Bypass -File .claude/hooks/model-advisor-hook.ps1" }
      ] }
    ]
  }
}
```

1. Copy `model-advisor-hook.ps1` into the project at `.claude/hooks/`.
2. Add the JSON above to `.claude/settings.json` (merge if the file already exists).
3. Commit both so teammates inherit it on pull.
4. Restart Claude Code; verify with `claude --debug`.

The hook is independent of the `ccs` launcher — you can use either, both, or neither.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `ccs : The term 'ccs' is not recognized` | Alias not loaded | Recheck profile (Step 3), then `. $PROFILE` or reopen PowerShell |
| `...cannot be loaded because running scripts is disabled` | Execution policy | Run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
| `Claude Code CLI ('claude') not found on PATH` | Claude Code not installed / not on PATH | Install Claude Code; confirm `claude --version` works |
| Routing always says `classifier-failure-fallback -> opus` | The Haiku classification call failed | Confirm `claude -p "hi" --model haiku` works; check network/login |
| `Could not parse dispatch-config.json` | Invalid JSON | Validate the file; the tool falls back to built-in defaults meanwhile |
| Runs in cmd.exe but `ccs` unknown | Wrong shell | Use PowerShell, not Command Prompt |

Diagnose without launching a session:

```powershell
ccs -DryRun "your prompt here"   # shows the model decision only
```

---

## FAQ

**Do I copy these files into every project?**
No. Install once in a fixed folder; the `ccs` alias works from any project.

**Do I open Claude Code separately?**
No. `ccs` launches it for you. You never type `claude` yourself.

**Does it work in cmd.exe?**
No — PowerShell only (Windows PowerShell 5.1 or PowerShell 7).

**Does it change the model mid-session?**
No. The model is chosen once at launch and stays. Use `/model` inside the session to override manually.

**How much does the classification cost?**
One Haiku call per session — fractions of a cent and about a second — regardless of how long the session runs.

**Can I force a model?**
Yes: `ccs -Model opus "..."` or the inline prefix `ccs "!opus ..."`.

**Does this work on macOS/Linux?**
The scripts are PowerShell. PowerShell 7 runs on macOS/Linux, but the install paths and profile examples here are Windows-flavored. The same logic could be ported to a shell script if needed.

---

## Scope & notes

- This is for **Claude Code only**. Some other coding assistants already ship native
  task-based model selection; Claude Code does not yet, which is the gap this fills.
- **PowerShell 5.1 and 7 both work** — no version-specific syntax is used.
- **`claude` must be on PATH** — the launcher checks and errors clearly if not.
- **Model aliases vs IDs** — Claude Code resolves `opus/sonnet/haiku` to current
  versions; pin full IDs in config if you need determinism across a team.
- The decision log is JSON-lines at `~/.claude-dispatch/sessions.jsonl` (or your
  configured `logDir`). It contains task snippets — treat it as you would shell history.

---

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Kunal.
