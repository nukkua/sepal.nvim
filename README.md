# sepal.nvim

Delegate, verify, land. You write a task next to your code and Claude Code or Devin CLI works on it
in a git worktree, so your files never change while it works. sepal runs the task's check itself, and
if it passes, the result lands in your work tree as unstaged changes. You review them with the git
tools you already use. Keep working while the agent runs, or open its terminal to watch it.

## Requirements

- Neovim 0.12+
- [Claude Code](https://claude.com/claude-code), or [Devin CLI](https://cli.devin.ai) (see Devin)
- Git with `git cat-file --batch -Z` support (tasks run in worktrees, so your project has to be a Git repo)
- optional: [fff.nvim](https://github.com/dmtrKovalenko/fff.nvim) to pick files for a task
- optional: [fidget.nvim](https://github.com/j-hui/fidget.nvim) for progress and info notifications
- optional: [blink.cmp](https://github.com/Saghen/blink.cmp) for skill completion (see Skills)
- optional: `wl-paste` (Wayland), `pngpaste` (macOS), or `xclip` (X11) to paste clipboard images

## Install

```lua
-- vim.pack
vim.pack.add({ "https://github.com/nukkua/sepal.nvim" })

-- lazy.nvim
{ "nukkua/sepal.nvim", opts = {} }
```

## Tutorial

Five minutes, in any git repo of yours.

**1. Add two keys.**

```lua
vim.keymap.set({ "n", "x" }, "<leader>as", ":Sepal task<cr>", { desc = "Agent: new task" })
vim.keymap.set("n", "<leader>ai", "<cmd>Sepal inbox<cr>", { desc = "Agent: inbox" })
```

**2. Write a task.** Select the code you mean (or don't) and press `<leader>as`, then pick what
kind of task it is: `s` swarm (a bigger job, planned as tasks for an agent swarm, see Swarm), `f`
feat (a change, below), `b` btw (a question, see Btw) or `g` guide (a guide you code from, see Guide). Each kind shows the logo and model
of the agent that will run it; with several `agents` you pick the agent next, each shown with its
logo and model (see Devin). Any other key cancels. A buffer opens above your code:

```
Goal: Finish queued tasks in ThreadPool::shutdown() before stopping, refuse new ones.

Done when: make test

Selection: src/pool.cpp:40-52
...

Files:
- @src/pool.cpp
```

`Done when:` is the check: a shell command that has to pass. sepal tells the agent to run only
narrower tests, then runs the check itself after the agent's turn. On failure it sends the output to
the agent for up to `retries` more tries. Leave the line empty or delete it to use the `check`
option (unset by default: no check).

A new feat (or a swarm with the feat template) prefills `Done when:` from `check` when set.
Otherwise sepal looks for a `Test:` or `Tests:` line with a command in backticks in `AGENTS.md`
or `CLAUDE.md`, a Makefile `test` target
(`make test`), a `test` script in `package.json` (`npm test`), `Cargo.toml` (`cargo test`), `go.mod`
(`go test ./...`), pytest (`pytest`). Its line says so: `✔ green lands  ✘ red goes back to the agent
· found in AGENTS.md, dd: no check`. Delete the line to skip the detected check (unless you've set
`check`). `<c-c><c-f>` adds more files. Pytest is detected from `pytest.ini` or a `[tool.pytest…]`
section in `pyproject.toml`.

Fields you leave empty (`Done when:` or `Files:` with nothing under it, say) aren't sent; code in a ``` block is
sent as it is. An empty `Goal:` sends nothing.

**3. Send it.** `<c-c><c-c>`. The buffer closes and you get `working on it: Finish queued tasks…`.
Keep coding. You can send more tasks, and they run in parallel, each in its own worktree (up to
`max_running`, the rest wait as `queued`). Outside a git repo, or if your work tree can't be saved,
the task comes back in its buffer.

**4. It lands.** When the check passes:

```
✔ landed: Finish queued tasks… · 2 files +31 −4 · make test ✔
· shutdown() blocks until the queue is empty
· tasks submitted after shutdown() throw std::runtime_error
```

The changes are now in your files, unstaged. The lines starting with `·` are the decisions the
agent made on its own. Nobody was there to answer its questions, so it lists them for you. They're
the part worth reading.

**5. Review it like a teammate's change.** `git diff`, gitsigns, fugitive: whatever you use. Don't
like it? `:Sepal undo` takes it back out. Your own edits since the task started stay in both
cases where they merge cleanly; overlapping edits can leave conflict markers. Save any modified
buffers for affected files before landing or undoing.

**6. When something needs you,** you get a warning instead. Open `<leader>ai`:

```
<CR> diff  L land  U undo  :w apply  u revert  r reply  c continue  o watch/chat  x stop  s swarm  v verify  m model  C clean  za fold  q close

✔ landed       2m   Finish queued tasks…   2 files +31 −4  make test ✔
    · shutdown() blocks until the queue is empty
✘ check failed 5m   flaky test             make test ✘
    │ FAIL test_timeout (expected 100ms, got 140ms)
▲ needs you    9m   rename Config          4 files +40 −40
    it overlaps your edits in src/config.rs: L lands it with conflict markers
```

The inbox is edited like a buffer, as in oil.nvim: `dd` a task's line and `:w` drops it (running tasks stay),
`u` before `:w` takes it back. Copy a line (`yyp`) and `:w` opens a new task with that task's text,
to add to and send. Several copies open their drafts one after another, each once the one before is
sent or discarded. For a ready, landed, check-failed, needs-you or stopped task with a chat, edit a
`·` decision and `:w` sends the change back to that chat. `u` before `:w` takes it back; changing
the number of `·` lines doesn't send anything.

Under each task are the lines worth reading: why it needs you, the error, the first lines of a
failing check, the `·` decisions, conflict markers it left, its files with their `+`/`−` counts. A
running task shows what its agent is on (`Edit src/pool.cpp`) and its running subagents (`↳ 2
subagents`).

- `r` opens a reply to a task with a chat ("the timeout is 200ms on CI"). `<c-c><c-c>` sends it;
  `<c-c><c-k>` discards it. The agent continues in the same chat. For a feat, sepal checks the
  result again and lands only what's new, following the task's landing mode.
- `c` continues a task that was cut short (Neovim quit, `x`, Esc, the agent crashed): what it had done
  is kept and the agent picks up in the same chat; one whose agent never started starts over. One cut
  short while sepal ran its check only has the check run again, on what the agent had finished (with
  `prepare` and a fresh `retries` budget), and the agent isn't sent anything unless it fails.
- `o` shows the agent at work (once it's done: its chat). See Watching.
- `x` stops a running or queued task (including preparation or checking; work so far is kept),
  or closes its chat.
- `m` picks the model of the task's next run: a queued one starts on it, `r` and `c` use it. On a
  planned swarm it picks the plan item's model (all of them on the plan's own line). Unlike the
  draft picker or a plan item's picker, changing an existing task's model doesn't switch its agent.
- `L` lands a task, `U` takes a landed one back out, `C` drops the tasks that are over (`:Sepal clean`).
- `<CR>` reviews what the task changed in a new tab: each file before | after in diff mode, all of them
  in a location list (it looks like the quickfix one) with their `+`/`−` counts (`]q` `[q` or `]l` `[l` next file, `]c` next change, `gf` the file in
  your work tree, `q` closes). A decision that ends in `(path:line)` shows above that line.
- Each task is a fold: `za` collapses or expands the lines under it, `zM`/`zR` all of them.
  `q` closes the inbox.

That's all of it: write, send, keep working, read the `·` lines.

### Btw

`b` instead of `f` asks the agent something about the project ("where are retries configured?").
The buffer is just a line for the question and `Files:`. Write it and send it with `<c-c><c-c>` (a
btw is sent as you wrote it: no `<c-c><c-w>`, no `<c-c><c-s>`). It runs on a cheaper model (sonnet by default, see
`models`) in your repo itself, read-only (Claude Code's plan mode or Devin's auto mode), so it
starts at once: no worktree,
and it doesn't wait for a `max_running` slot. You get the start of the answer as a notification, and
`<CR>` in the inbox shows all of it. Nothing it does lands. `r` asks a follow-up and `o` opens its chat. Copying its line (`yyp`, `:w`) turns the answer into
a feat: a draft with the question and the answer under `Asked:`/`Answer:` as context,
you write the `Goal:` and send it. The draft keeps the btw's agent; `<c-c><c-a>` picks another model.

### Guide

`g` is a btw for a change you want to write yourself: describe the bug, feature or change and send it
with `<c-c><c-c>`. It runs like a btw (read-only in your repo, no worktree, no check, nothing lands) but
answers with an implementation guide for a senior engineer new to the code: TL;DR, mental model, a
change plan of steps (where, what, why, watch out), verification and open decisions. `<CR>` in the inbox
reads it. Its model is `models.guide` (unset: the agent's default).

### Swarm

`s` (`orchestrate` in the `models` keys and the Lua API) is for a job too big for one task. Write it like a feat
(with `task_sharpen` set it starts as just your idea and `Files:`, and `<c-c><c-s>` writes it) and
send it: `<c-c><c-c>` plans it, `<c-c><c-w>` plans it and has its tasks wait for `L`. The agent reads
your repo (read-only, like a btw, on `models.orchestrate`) and plans it. It decides how many tasks
there are (as few as the work needs), what each one does and checks, and which model runs each
one, picked from your `agents`' models or left at the default. A multi-task swarm waits in the inbox
as `planned`, its plan unfolded:

```
◇ planned      1m   retries for the client    make test
    1. [opus] Retry with backoff in client.ts
    2. [haiku] Document the retry option
```

- `m` on an item changes its model: one of your `agents`' models (each agent's key, as in `:Sepal task`, or its number; the task then runs on that
  agent), one of the `models` option's (numbered after the agents), `d` default (the swarm agent's
  configured model, otherwise the feat's default) or `o` one you type (`d` and `o` move to `-` and
  `/` when an agent uses those keys). `m`
  on the swarm's own line changes all of them. You can also edit the `[model]` in the line and `:w`.
  `dd` an item (or move it) and `:w` drops (or reorders) it. On any other task `m` picks the model of
  its next run: a queued one starts on it, `r` and `c` use it.
- `s` swarms it: each item becomes a task of its own, run with its model and checked with its
  `Done when:` (the swarm's own if it has none). Each is told the plan's other tasks, so it does only
  its part. All of them start from one snapshot of your work
  tree, run in parallel up to `max_running`, and land the way you sent the swarm (`<c-c><c-c>` by
  themselves, `<c-c><c-w>` on `L`). The swarm stays as `swarmed`.
- `v` once a swarm is swarmed and its tasks are over: the planner verifies them, in its own chat (read-only,
  in your repo). It gets each task's instructions, its status, any check outcome and the `git diff`
  command for any saved result, and says whether the task did what it was asked and what to ask of
  it if not. `<CR>` reads the verdict under the swarm. It runs on `models.verify`
  (unset: the planner's model); `m` on the swarm picks another model.
- `r` asks for a different plan, `<CR>` reads the agent's whole reply. A reply without a `Plan:`
  list fails; `r` asks again.

If the plan has only one task, it doesn't wait in the inbox for `s`: the task starts at once,
still landing the way you sent the swarm (`<c-c><c-c>` by itself, `<c-c><c-w>` on `L`).

To try it by hand, run `nvim -u tests/demo.lua`: a throwaway repo with a fake agent that plans two
tasks. `SEPAL_DEMO_REAL=1 nvim -u tests/demo.lua` uses the real Claude Code instead.

## Setup

`setup()` is optional. These are the defaults:

```lua
require("sepal").setup({
  cmd = { "claude" },                            -- the agent: claude or devin
  args = { "--permission-mode", "acceptEdits" }, -- added to each Claude Code run (see Permissions)
  auto_mode = false,   -- true: Claude auto mode for feats and their chats; other kinds stay read-only
  check = nil,         -- the check for tasks without a `Done when:` line, e.g. "make test"
  retries = 1,         -- when the check fails, the agent gets its output and this many more tries
  land = "auto",       -- fallback when no mode was chosen (e.g. :Sepal qf); "manual" waits for L
  prepare = nil,       -- shell command run in each new worktree first ($SEPAL_ROOT is your repo)
  worktrees = vim.fn.stdpath("state") .. "/sepal", -- where worktrees and the inbox live
  task_sharpen = nil,  -- argv: rough task on stdin -> finished task on stdout (see Tasks)
  max_running = 3,     -- concurrent feats (at least 1); the rest wait as "queued"
  models = { btw = "sonnet" }, -- each task kind's --model; implement = nil: Claude Code's default (or args'); guide: g's; orchestrate: the swarm planner's; verify: v's (nil: the planner's)
  agents = nil,        -- agents :Sepal task asks you to pick from (see Devin)
  panel_width = 46,    -- :Sepal panel's width: columns, or a share of the editor's: "30%" (or 0.3)
  sakura = true,       -- blossom colors for sepal's accents; false: use theme links for those groups
  highlights = {},     -- Sepal* group -> nvim_set_hl spec, over everything: { SepalOk = { fg = "#a3be8c" } }
  icons = {},          -- inbox status -> icon: { landed = "✔", running = "~" }
  skills = {},         -- name -> SKILL.md path or text, over ~/.claude/skills and ~/.config/devin/skills; /name in a task sends it along: { how = "~/.claude/skills/how/SKILL.md" }
})
```

### Devin

With `agents`, `:Sepal task` asks which agent after the kind: by its `key`, or `1`, `2`… (its place
in the list) without one. With only one agent, it is used without asking; unset, `cmd` is used.
Each entry accepts `cmd` (a command string or argv), `model`, `args`, `name` (picker label), and `key`.
sepal runs two agents, known by the executable's name: `claude…` is Claude Code, `devin…` the Devin
CLI. Any other `cmd` (in `cmd` or `agents`) is an error in `setup()` and `:checkhealth sepal`, and a
task sent to it fails. A `cmd` whose executable name starts with `devin`
runs the [Devin CLI](https://cli.devin.ai) instead of Claude Code, the same way: sepal adds its hooks
and the check's allow rule to a copy of your `~/.config/devin/config.json`, so the panel shows what it
does, a permission prompt warns you, and ctrl-c in it stops the task (what it did is kept). It runs
in `dangerous` mode for feats and their chats: tools are approved without prompting. Btw, guide
and swarm runs and chats use Devin's read-only `auto` mode. These modes override any permission
mode in `args` or `auto_mode`. An agent's `model` wins over the kind's entry in `models`; its `args`
replace the global `args`, which only apply to Claude Code.
The config path follows `$XDG_CONFIG_HOME` when set. It must be valid JSON: an unreadable or
invalid config (including JSONC comments) is replaced by an empty config in sepal's copy.

```lua
agents = {
  { cmd = "claude", model = "claude-opus-5-5", key = "c" },
  { cmd = "devin", model = "fusion-claude-opus-5-5-medium-sidekick-swe-2-high", key = "d" },
},
```

### Colors

Everything sepal draws uses its own groups, linked to your colorscheme's: `SepalTitle` (Title),
`SepalAccent` (Special), `SepalInfo` (DiagnosticInfo), `SepalDim` (Comment), `SepalAdded`, `SepalRemoved`, `SepalInboxFolded`, `SepalPanelTitle` (@markup.strong), `SepalAgent` (SepalClaude, running subagents), and
`SepalShimmer` (SepalPanelTitle: the light running over a working task in the panel). With
`sakura = true` (the default) the title, accent, info and shimmer groups use cherry-blossom colors, a
lighter set on a dark background and a deeper one on a light background. The states don't follow
the theme: `SepalOk` (✔ landed, ready) is green, `SepalError` (✘) red and `SepalWarn` (▲) amber,
lighter on a dark background. `SepalClaude` is terracotta. A colorscheme that defines a `Sepal*`
group wins over sepal's defaults, and the `highlights` option wins over everything.

### Statusline

`require("sepal").status()` shows the tasks of the repo you're in: running (`~`), ready to land
(`●`) and needing you (`▲`), e.g. `~2 ●1 ▲1`, or nothing when there are none. A
missed notification still shows there. sepal fires `User SepalChanged` and redraws the statusline
when the counts move.
Running includes queued and checking tasks; ready includes planned swarms; needing you
includes check failures and agent errors. `icons` overrides status icons and the provider logos
(`devin`, `claude`, `openai`, `gemini`, `opencode`).

```lua
-- lualine
sections = { lualine_x = { require("sepal").status } }
-- plain statusline
vim.o.statusline = "%f %= %{v:lua.require'sepal'.status()}"
```

## Commands

| Command              | Does                                                                     |
| -------------------- | ------------------------------------------------------------------------ |
| `:[range]Sepal [task]` | write a task (with a range: those lines go in as a `Selection:`)         |
| `:Sepal inbox`       | every task of this repo and where it stands                              |
| `:Sepal panel`       | a board at the right: each task, what its agent is doing, a summary (toggle) |
| `:Sepal land`        | land the newest eligible task with a saved result (see How it works)     |
| `:Sepal undo`        | take the newest landed task back out                                     |
| `:Sepal open`        | watch the newest running task or task with a chat, in its agent         |
| `:Sepal stop`        | stop running and queued tasks, and close their chats                    |
| `:Sepal qf`          | the quickfix list as a planned swarm: one task per file, with its lines (`s` swarms it) |
| `:Sepal clean`       | drop landed, no changes, undone, stopped, interrupted, answered and swarmed tasks |

`:Sepal qf` opens the inbox with one plan item per file, containing its quickfix entries as
`lnum: text`. Use `m` to set models and `s` to start it, even if there's only one item. Its check
comes from `check` or the detected test command; landing follows `land`.

## How it works

1. **Start**: your work tree (uncommitted and untracked files too) is saved as a commit, through a
   temporary index. Your own index and branches aren't touched. The agent gets a worktree of that
   commit, so it starts from exactly what you see.
2. **Work**: the agent runs interactively in a hidden terminal with the task, plus a few rules from sepal: it's alone, it
   should make the smallest complete change that follows the codebase's conventions and cover new
   non-trivial logic with a small test. It shouldn't commit, push, switch branches or run the full
   check itself. It reports anything left undone or unchecked and the decisions it made.
3. **Check**: sepal runs `Done when:` in the worktree itself. If it fails, the agent gets the output
   and `retries` more tries.
4. **Land**: the change is applied to your work tree as unstaged changes, a three-way merge per file
   (`git merge-file` for overlapping text edits), so cleanly merging edits are kept. In auto mode
   this happens on its own, but only when it's clean. If changes conflict or an affected buffer
   has unsaved changes, it waits as "needs you". Landing and undo handle executable bits and
   symlinks without merging through them. Manual landing can leave text conflict markers; where
   markers aren't possible (e.g. binary, symlink or delete/modify conflicts), it keeps your version.
5. The worktree is removed and the result stays as a commit (`refs/sepal/<id>/*`) until you drop
   the task. The inbox is saved per repo, so it survives a restart. A task that was running when
   Neovim quit (including queued or checking tasks) shows as "interrupted", and `c` continues it
   with what it had done so far (one cut short in its check reruns just the check). If its initial
   snapshot never finished, send it again.

Tasks move through `queued`, `running`, `checking`, then `ready` (manual landing) or `landed`.
No diff gives `no changes`; exhausted checks give `check failed`; agent/setup errors give `failed`;
unsafe automatic landing gives `needs you`. Stopping gives `stopped`, undo gives `undone`.
Questions and guides finish as `answered`; a swarm becomes `swarmed` when its tasks start.
`L` / `:Sepal land` can also apply saved results from failed, stopped, interrupted or undone tasks:
it does not rerun the check. Dropping a task removes its refs, chat and pasted images, not landed edits.

## Tasks

| Key          | Action                                                                 |
| ------------ | ---------------------------------------------------------------------- |
| `<c-c><c-c>` | send the task and close the buffer; it lands by itself once it passes  |
| `<c-c><c-w>` | send the task and close the buffer; it waits in the inbox for `L`      |
| `<c-c><c-s>` | feat: have `task_sharpen` sharpen it (deeper, not bigger); swarm: write it (`u` undoes) |
| `<c-c><c-a>` | pick the model it runs on (your agents' models by each agent's key, as in `:Sepal task`, or its number; the models option's; default `d` or one you type `o`, which move to `-` and `/` when an agent uses those keys; an agents' model runs on that agent) |
| `<c-c><c-f>` | add a file under `Files:` (fff.nvim if installed, else a prompt)       |
| `<c-c><c-p>` | paste the clipboard's image (wl-paste, xclip or pngpaste)             |
| `<c-c><c-k>` | discard the task                                                       |

A dim line on top of the task shows who will work on it (the provider's logo and the model, or
the agent's name) and lists these keys, like the one on top of the inbox. A swarm's
`<c-c><c-c>` and `<c-c><c-w>` plan it (see Swarm); a btw or guide has only `<c-c><c-c>`. While
`task_sharpen` works, a spinner shows there; if you edit the task meanwhile, its answer is dropped
rather than overwriting your text.

`:'<,'>Sepal task` puts the selected lines in the task as a `Selection: path:10-20` code block and
lists the file. With a draft open, the selection is added to it. Closing the window drops the
draft, so `:Sepal task` always starts a new one.

A pasted image is saved under `stdpath("cache")/sepal` and listed under `Files:` by its path; the
agent is allowed to read it. It stays while its task is in the inbox (`r` may need it again) and is
deleted with the task; images of discarded drafts go after a day.

### Skills

`skills` names skills a task can ask for: `/name` as a word in the task appends that skill to what
the agent gets (`Skill /name:` and its text, the frontmatter dropped), once per skill. Each value is
a path to a `SKILL.md` or the skill's text itself. Your Claude Code and Devin user skills
(`~/.claude/skills/<name>/SKILL.md`, `~/.config/devin/skills/<name>/SKILL.md`) are found by name
without listing them. The roots follow `$CLAUDE_CONFIG_DIR` and `$XDG_CONFIG_HOME`. Claude's skill
wins over Devin's with the same name; an entry in `skills` wins over both:

```lua
require("sepal").setup({ skills = { how = "~/.claude/skills/how/SKILL.md", terse = "Answer in one line." } })
```

Typing `/` at the start of a word in the draft pops up the skill names (its `'omnifunc'`, `<c-x><c-o>`).
When blink.cmp is loaded, it handles the popup instead. Add the `sepal.blink` source for slash
completion with skill previews:

```lua
sources = { default = { "lsp", "path", "buffer", "sepal" }, providers = { sepal = { name = "sepal", module = "sepal.blink" } } }
```

### Writing the task for you

Set `task_sharpen` and a swarm starts as just your idea and `Files:`, and `<c-c><c-s>` has
the command write the task. A feat keeps its fields, and `<c-c><c-s>` sharpens them: its
filled-in fields go to the command under a prompt asking for a deeper task, not a bigger one (what
an expert would do, from the rawest material, with which methods, and what would prove it right),
keeping its `Done when:` and `Files:`. The answer replaces the buffer; `u` undoes it:

```lua
require("sepal").setup({
  task_sharpen = { "claude", "-p", "--model", "opus", "--effort", "medium",
    "--no-session-persistence", "--tools=Read,Grep,Glob",
    "Turn the rough idea on stdin into a short task: Goal, Done when "
    .. "(one shell command that proves it works, e.g. the test to run), Files (as @path). "
    .. "Read the files so it matches the code. Output only the task, no code fences, no filler." },
})
```

## Worktrees need your dependencies

A new worktree has your tracked and untracked files, but not ignored ones like `node_modules`,
`target` or `.env`. Use `prepare` to bring them in. Whatever it creates isn't counted as the
agent's work:

```lua
require("sepal").setup({ prepare = 'ln -s "$SEPAL_ROOT/node_modules" node_modules' })
require("sepal").setup({ prepare = "cp $SEPAL_ROOT/.env . && cargo fetch" })
```

## Permissions

By default Claude Code feats run with `--permission-mode acceptEdits`. sepal also allows the
check (including `cd <worktree> && <check>`), read-only Git commands (`git status`, `git diff`,
`git log`, `git show`) and reads for absolute paths listed as `- @path` (such as pasted images).
Devin gets the check and those reads in its config copy. When Claude needs approval for another
tool, it waits and sepal tells you: `▲ …: Claude needs your permission to use Bash · :Sepal open`.
Allow what you trust upfront in `args`:

```lua
require("sepal").setup({ args = { "--permission-mode", "acceptEdits", "--allowedTools", "Bash(npm run lint),Bash(git diff:*)" } })
```

Other flags go there too, e.g. `"--model", "opus"`.

Or let Claude Code's auto mode decide for implementation runs and chats (it replaces the
`--permission-mode` in `args`; btw, guide and swarm runs still use plan mode, without its ExitPlanMode
approval prompt: the reply is the answer or plan):

```lua
require("sepal").setup({ auto_mode = true })
```

## Watching

Each task runs the configured agent in a hidden terminal inside Neovim, so it works in any terminal
emulator, no tmux needed. `o` in the inbox, or `:Sepal open`, shows it full screen: you see the
agent at work and can type to it. `q` in normal mode hides it again and it keeps going, and so
does `:Sepal open` itself, so one key toggles it. Once the
task is done, the same key opens its chat with `claude --resume <id>` (`devin -r <id>`): it too keeps going when
hidden, until `x` or `:Sepal stop` ends it. If you're watching when its turn ends, the same screen
shows `Running the check` (when it has one), then its chat.

sepal follows the agent through hooks (Claude Code's `--settings` or Devin's config copy):
what tool it's on, Claude Code's subagents, when it asks for something, and when its turn is over.
Then it closes it and runs the check. Esc in Claude Code (or ctrl-c in Devin) ends the turn too: the
task stops with what it did kept, and `c` continues it.

While you're in an agent or a chat, sepal's notifications wait and show once you leave it. With
fidget.nvim, info goes there (warnings and errors stay in `vim.notify`), and fidget's window is
hidden while you're in an agent, the inbox or with the panel open.

At most `max_running` implementation tasks (3 by default) run at once, including preparation and
checking; the rest wait as `queued`. Btw, guide and swarm planning/verification bypass this limit.

Claude Code may ask to trust a task's new worktree before it starts. sepal warns
(`▲ …: Claude Code asks to trust the worktree · :Sepal open`), and you answer it there. Devin runs
with `--respect-workspace-trust false`, so it doesn't ask.

## Panel

`:Sepal panel` toggles a board at the right that only shows; your cursor stays where it is. Its
header counts the tasks by state (running, queued, need you, ready, answered, planned, landed).
Each task is a card behind a rail in its state's color: its title and age, the logo and model
working on it, its state with what to do about it (`r in :Sepal inbox to fix it`), the try
(`try 2/2`) and the check, its `+`/`−` counts, what the agent is doing right now and its
subagents, a swarm's tasks with their models, why it needs you or its error, a short summary of
what the agent said, and how many decisions there are to read. A working card's icon spins and a
light runs down its rail and over its state. `o` watches the task under the cursor (or opens its
chat), `q` closes the panel. To act on a task, use the inbox.

### Context bar

A task's card in the panel shows its context window: a 10-cell bar, the tokens used
against the window, and the percent, e.g. `██████░░░░ 120k/200k · 60%`. It turns amber at 70% and
red at 90%; past the window it says `over the limit`. The panel header shows the bar of the running
task closest to its limit, among running tasks with a reported limit, e.g.
`████████░░ 80% · fullest of 3: <title>` (with one such task,
just `80% context · <title>`). Queued tasks aren't paused at a limit: the bar only shows it.
The numbers are the agent's own, never estimates:

- Claude Code: the statusLine JSON (sepal sets its own statusLine in its hidden terminals, so your
  statusline doesn't show there): `current_usage` (input + cache creation + cache read) against
  `context_window_size`, the model's window. Its percent is Claude Code's `used_percentage`.
- Devin: its transcript's totals (`final_metrics`, read 4 KiB from its end, only when it changed),
  shown as `in · out` like its `/usage`. Devin exposes no context limit anywhere, so there is no
  bar, only the count: `37.8k in · 252 out · no limit: Devin exposes none`.

Nothing shows until the agent reports its first usage. Devin writes its transcript only as it
exits, so its count shows right after the turn. The last count stays on the card (and in the inbox
store) after the task finishes.

## Health

`:checkhealth sepal` checks Neovim, git, `cmd`, `args`, `check`, `retries`, `land`, `prepare`,
`max_running`, `models`, `agents` and their executables, swarm models, `task_sharpen`, `panel_width`, `sakura`,
`highlights`, `icons`, fidget.nvim and fff.nvim. It also reports `auto_mode` when enabled, where
worktrees and the inbox live, where the context bar reads from, and the worktree trust prompt.

## Lua

`require("sepal")`: `.pick(range)` is `:Sepal task`; `.task(range, lines, kind, agent)` opens a draft
without the picker (`kind`: `"implement"`, `"btw"`, `"guide"` or `"orchestrate"`); `.inbox()`, `.panel()`,
`.land()`, `.undo()`, `.open()`, `.stop()`, `.clean()` and `.qf()` are the commands; `.status()` is the
statusline; `.draft()` is the open task draft's buffer (nil when none).

## Tests

```sh
nvim -l tests/run.lua                         # all of them, with a fake agent: no Claude Code needed
SEPAL_TEST="lands" nvim -l tests/run.lua      # only the tests whose name contains it
SEPAL_DEMO_CHECK=1 nvim --headless -u tests/demo.lua  # the swarm demo, draft to two landed tasks
```

If your Git config uses `diff3` or `zdiff3`, run the suite with
`GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=merge.conflictStyle GIT_CONFIG_VALUE_0=merge nvim -l tests/run.lua`
so the conflict-marker test sees the expected marker style.

Designed and developed with AI-assisted implementation. I defined the requirements, workflows, and desired behavior.

## License

[MIT](LICENSE)
