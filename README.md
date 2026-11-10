# sepal.nvim

Delegate, verify, land. You write a spec next to your code and Claude Code works on it in a git
worktree, so your files never change while it works. sepal then runs the spec's check itself, and
if it passes, the result lands in your work tree as unstaged changes. You review them with the git
tools you already use. You only hear from sepal when a spec has landed or when something needs you.
You don't watch the agent work.

## Requirements

- Neovim 0.12+
- [Claude Code](https://claude.com/claude-code)
- git (specs run in git worktrees, so your project has to be a git repo)
- optional: [fff.nvim](https://github.com/dmtrKovalenko/fff.nvim) to pick files for a spec
- optional: [fidget.nvim](https://github.com/j-hui/fidget.nvim) for a spinner showing what the agent is doing

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
vim.keymap.set({ "n", "x" }, "<leader>as", ":Sepal spec<cr>", { desc = "Agent: new spec" })
vim.keymap.set("n", "<leader>ai", "<cmd>Sepal inbox<cr>", { desc = "Agent: inbox" })
```

**2. Write a spec.** Select the code you mean (or don't) and press `<leader>as`. A buffer opens
above your code:

```
Scope: ThreadPool::shutdown()
Goal: Finish queued tasks before stopping, refuse new ones.

Constraints:
- don't change the public API

Done when: make test

Selection: src/pool.cpp:40-52
...

Files:
- @src/pool.cpp
```

`Done when:` is the check: a shell command that has to pass. The agent is allowed to run it, and
it keeps working until the check passes. Then sepal runs the check again itself before landing
anything. Leave it empty and the spec isn't checked. `<c-c><c-f>` adds more files.

**3. Send it.** `<c-c><c-c>`. The buffer closes and you get `working on it: Finish queued tasks…`.
Keep coding. You can send more specs, and they run in parallel, each in its own worktree.

**4. It lands.** When the check passes:

```
✓ landed: Finish queued tasks… · 2 files +31 −4 · make test ✓
· shutdown() blocks until the queue is empty
· tasks submitted after shutdown() throw std::runtime_error
```

The changes are now in your files, unstaged. The lines starting with `·` are the decisions the
agent made on its own. Nobody was there to answer its questions, so it lists them for you. They're
the part worth reading.

**5. Review it like a teammate's change.** `git diff`, gitsigns, fugitive: whatever you use. Don't
like it? `:Sepal undo` takes it back out. Your own edits since the spec started stay in both
cases.

**6. When something needs you,** you get a warning instead. Open `<leader>ai`:

```
<CR> diff  L land  u undo  r reply  o chat  x stop  D drop  q close

✓ landed       2m   Finish queued tasks…   2 files +31 −4  make test ✓
    · shutdown() blocks until the queue is empty
✗ check failed 5m   flaky test             make test ✗
    │ FAIL test_timeout (expected 100ms, got 140ms)
▲ needs you    9m   rename Config          4 files +40 −40
    it overlaps your edits in src/config.rs: L lands it with conflict markers
```

- `r` replies to a spec ("the timeout is 200ms on CI"). The agent continues from where it was, in the
  same chat, and the spec is checked and lands again.
- `o` opens the spec's chat in a tmux window, so you can read what the agent did and why.
- `<CR>` shows everything the spec changed as a diff.

That's all of it: write, send, keep working, read the `·` lines.

## Setup

`setup()` is optional. These are the defaults:

```lua
require("sepal").setup({
  cmd = { "claude" },                            -- the agent
  args = { "--permission-mode", "acceptEdits" }, -- added to each run (see Permissions)
  check = nil,         -- the check for specs without a `Done when:` line, e.g. "make test"
  retries = 1,         -- when the check fails, the agent gets its output and this many more tries
  land = "auto",       -- "auto": a spec that passes lands by itself; "manual": it waits for L in the inbox
  prepare = nil,       -- shell command run in each new worktree first ($SEPAL_ROOT is your repo)
  worktrees = vim.fn.stdpath("state") .. "/sepal", -- where worktrees and the inbox live
  spec_suggest = nil,  -- argv: rough spec on stdin -> finished spec on stdout (see Specs)
  open = nil,          -- function(argv, cwd) for :Sepal open (default: a new tmux window)
})
```

## Commands

| Command              | Does                                                                     |
| -------------------- | ------------------------------------------------------------------------ |
| `:[range]Sepal spec` | write a spec (with a range: those lines go in as a `Selection:`)         |
| `:Sepal inbox`       | every spec of this repo and where it stands                              |
| `:Sepal land`        | land the newest spec that's waiting (with conflict markers if it overlaps your edits) |
| `:Sepal undo`        | take the newest landed spec back out                                     |
| `:Sepal open`        | the newest spec's chat in Claude Code                                    |
| `:Sepal stop`        | stop every running spec                                                  |
| `:Sepal clean`       | drop the specs that are over (landed, no changes, undone, stopped)       |

## How it works

1. **Start**: your work tree (uncommitted and untracked files too) is saved as a commit, through a
   temporary index. Your own index and branches aren't touched. The agent gets a worktree of that
   commit, so it starts from exactly what you see.
2. **Work**: `claude -p` runs there with the spec, plus a few rules from sepal: it's alone, it
   shouldn't commit, it should run the check until it passes, and it should end with its
   assumptions.
3. **Check**: sepal runs `Done when:` in the worktree itself. If it fails, the agent gets the output
   and `retries` more tries.
4. **Land**: the change is applied to your work tree as unstaged changes, a three-way merge per file
   (`git merge-file`), so what you edited meanwhile is kept. With `land = "auto"` this happens on
   its own, but only when it's clean. If it overlaps your edits, or a buffer of a file it touches
   has unsaved changes, it waits as "needs you".
5. The worktree is removed and the result stays as a commit (`refs/sepal/<id>/*`) until you drop
   the spec. The inbox is saved per repo, so it survives a restart. A spec that was running when
   Neovim quit shows as "interrupted", and `r` continues it.

## Specs

| Key          | Action                                                                 |
| ------------ | ---------------------------------------------------------------------- |
| `<c-c><c-c>` | send the spec and close the buffer                                     |
| `<c-c><c-s>` | have `spec_suggest` write the spec from what's there (`u` undoes it)  |
| `<c-c><c-f>` | add a file under `Files:` (fff.nvim if installed, else a prompt)       |
| `<c-c><c-k>` | discard the spec                                                       |

When a spec opens, a notification lists these keys, the way petal does for the commit buffer.

`:'<,'>Sepal spec` puts the selected lines in the spec as a `Selection: path:10-20` code block and
lists the file. With a draft open, the selection is added to it. Closing the window keeps the
draft, and `:Sepal spec` brings it back.

### Writing the spec for you

Set `spec_suggest` and the spec buffer starts as just your idea and `Files:`. `<c-c><c-s>` pipes
it to the command, which answers with the spec:

```lua
require("sepal").setup({
  spec_suggest = { "claude", "-p", "--model", "opus", "--effort", "medium",
    "--no-session-persistence", "--tools=Read,Grep,Glob",
    "Turn the rough idea on stdin into a short spec: Scope, Goal, Constraints, Done when "
    .. "(one shell command that proves it works, e.g. the test to run), Files (as @path). "
    .. "Read the files so it matches the code. Output only the spec, no code fences, no filler." },
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

Specs run with `--permission-mode acceptEdits`, plus the spec's check: the agent can read files,
edit them, and run `Done when:`. Nobody is there to answer a permission prompt, so any other tool
call that needs one is refused, and sepal names it:
`▲ the agent was not allowed: Bash(npm run lint)`. Allow what you trust in `args`:

```lua
require("sepal").setup({ args = { "--permission-mode", "acceptEdits", "--allowedTools", "Bash(npm run lint),Bash(git diff:*)" } })
```

Other flags go there too, e.g. `"--model", "opus"`.

## The chat

Each spec has its own Claude Code chat. `o` in the inbox, or `:Sepal open`, opens it with
`claude --resume <id>` in a new tmux window. There you can read every tool call and the agent's
reasoning, or keep talking to it. Outside tmux it copies the command for you to run. For another
terminal:

```lua
require("sepal").setup({ open = function(argv, cwd) vim.system({ "wezterm", "cli", "spawn", "--cwd", cwd, "--", unpack(argv) }) end })
```

Close that window before you reply to the spec. The open Claude doesn't see what the reply did, and
anything you type there branches the chat.

`:checkhealth sepal` checks the setup.

## Tests

```sh
nvim -l tests/run.lua
```

Designed and developed with AI-assisted implementation. I defined the requirements, workflows, and desired behavior.

## License

[MIT](LICENSE)
