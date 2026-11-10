# sepal.nvim

Write a spec next to your code and Claude Code works on it in the background, without a terminal
or chat window in Neovim. When it's done you get a notification, and its changes show up as hunks
in your buffers. Accept or reject each one where the code is. To see what the agent did and why,
`:Sepal open` opens its chat in a tmux window.

## Requirements

- Neovim 0.12+
- [Claude Code](https://claude.com/claude-code)
- git, to review the changes (outside a git repo the agent still works, you just don't get the review)
- optional: [fff.nvim](https://github.com/dmtrKovalenko/fff.nvim) to pick files for a spec (without it you get a path prompt)
- optional: [fidget.nvim](https://github.com/j-hui/fidget.nvim) for a spinner while the agent works and a "done"
  notification that stays (without it you get plain notifications; warnings and errors always go to `vim.notify`)

## Install

```lua
-- vim.pack
vim.pack.add({ "https://github.com/nukkua/sepal.nvim" })

-- lazy.nvim
{ "nukkua/sepal.nvim", opts = {} }
```

## Setup

`setup()` is optional. These are the defaults:

```lua
require("sepal").setup({
  cmd = { "claude" },                            -- the agent
  args = { "--permission-mode", "acceptEdits" }, -- added to each spec run (see Permissions)
  continue = true,     -- the first spec continues this directory's last chat; false: a new one
  spec_suggest = nil,  -- argv: rough spec on stdin -> finished spec on stdout (see Specs)
  open = nil,          -- function(argv, cwd) for :Sepal open (default: a new tmux window)
  keys = { next = "]r", prev = "[r", accept = "<c-c><c-y>", reject = "<c-c><c-n>" }, -- in buffers under review
})

vim.keymap.set("n", "<leader>ai", "<cmd>Sepal spec<cr>", { desc = "Agent: write a spec" })
vim.keymap.set("x", "<leader>ai", ":Sepal spec<cr>", { desc = "Agent: write a spec with the selection" })
vim.keymap.set("n", "<leader>ar", "<cmd>Sepal review<cr>", { desc = "Agent: review its changes" })
vim.keymap.set("n", "<leader>ao", "<cmd>Sepal open<cr>", { desc = "Agent: open its chat" })
vim.keymap.set("n", "<leader>al", "<cmd>Sepal resume<cr>", { desc = "Agent: pick the chat specs continue" })
```

## How it works

1. `:Sepal spec` and you write what you want. `<c-c><c-c>` runs it.
2. The spec runs as `claude -p` in the background, with a fidget spinner showing what it's doing
   (`Edit src/pool.cpp`, `Bash make test`). You keep working. Sending another spec while one runs
   puts it in a queue.
3. `✓ done · 3 changes in 2 files to review: <first line of the reply>`. With fidget it stays until
   you start reviewing.
4. The changed lines are highlighted in your buffers, and removed lines are shown where they used
   to be. `:Sepal review` puts every change in the quickfix list and takes you to the first.

Every spec continues one chat: at first this directory's last one, then the one the specs started.
It's a normal Claude Code chat, so the agent remembers your earlier specs and `claude -c` sees all
of it.

## Specs

`:Sepal spec` opens a buffer above your code with a spec to fill in:

```
Scope: ThreadPool::shutdown()
Goal: Implement graceful shutdown.

Constraints:
- Finish queued tasks
- Don't accept new tasks

Files:
- @src/thread_pool.cpp
```

| Key          | Action                                                                 |
| ------------ | ---------------------------------------------------------------------- |
| `<c-c><c-s>` | have `spec_suggest` write the spec from what's there (`u` undoes it)  |
| `<c-c><c-f>` | add a file under `Files:` (picked with [fff.nvim](https://github.com/dmtrKovalenko/fff.nvim) if installed, else a prompt) |
| `<c-c><c-c>` | run the spec in the background and close the buffer                    |
| `<c-c><c-k>` | discard the spec                                                        |

`:'<,'>Sepal spec` (the `x` mapping above) puts the selected lines in the spec as a
`Selection: path:10-20` code block above `Files:` and lists the file. With a draft open, the
selection is added to it. Selections are whole lines.

Files go in as `@path`, which Claude Code reads as file references. If the agent can't start (say,
the chat it should continue is gone), the spec comes back in its buffer. Closing the window keeps
the draft, and `:Sepal spec` brings it back.

### Writing the spec for you

Set `spec_suggest` and the spec buffer starts as just your idea and `Files:`. `<c-c><c-s>` pipes
it to the command, which answers with the spec (a spinner shows while it thinks), then
`<c-c><c-c>` runs it. If you edit while it's writing, your text is kept. For example, Opus at
medium effort, reading the files but not editing them:

```lua
require("sepal").setup({
  spec_suggest = { "claude", "-p", "--model", "opus", "--effort", "medium",
    "--no-session-persistence", "--tools=Read,Grep,Glob",
    "Turn the rough idea on stdin into a short spec: Scope, Goal, Constraints, Files (as @path). "
    .. "Read the files so it matches the code. Output only the spec, no code fences, no filler." },
})
```

Keep `--no-session-persistence`: without it, this one-off run would be saved as a chat, and
your next spec might continue it instead of your real chat.

## Review

Before a spec runs, sepal saves the work tree as a git tree object. Untracked files are included,
and your index and branches stay as they are. After the run, every file that differs is under
review, except files you saved yourself while it ran. In those buffers:

| Key          | Action                                                                  |
| ------------ | ----------------------------------------------------------------------- |
| `]r` / `[r`  | next / previous change; past the last one, the next file's first        |
| `<c-c><c-y>` | accept the change under the cursor                                      |
| `<c-c><c-n>` | reject it: the old text comes back and the file is written              |

- `:Sepal review` puts every change in the quickfix list and takes you to the first.
- `:Sepal accept` / `:Sepal reject` act on the change under the cursor. With `all`, they act on
  every change in every file.
- Rejecting a file the agent created deletes it. Rejecting a deletion brings the file back.

A file is done when you've accepted or rejected each of its changes. If more specs change it before
then, the review keeps the text from before the first one. Highlights: `SepalAdd`, `SepalChange`,
`SepalDelete` (removed lines) and `SepalAddSign`, `SepalChangeSign`, `SepalDeleteSign`.

What's under review is kept in memory, so restarting Neovim clears it. Edits you make yourself to a
file under review show up as changes too.

## Seeing what the agent did

`:Sepal open` opens the chat the specs went to with `claude --resume <id>` in a new tmux window.
There you can read every tool call and the agent's reasoning, or keep talking to it. Outside tmux
it copies the command for you to run. Set `open` for a different terminal:

```lua
require("sepal").setup({ open = function(argv, cwd) vim.system({ "wezterm", "cli", "spawn", "--cwd", cwd, "--", unpack(argv) }) end })
```

Running `claude -c` in that directory works too: the specs' chat is the newest one there.
Close that window before your next spec. Otherwise the open Claude doesn't see what the spec did,
and anything you type there starts a separate branch of the chat.

## Chats

- `:Sepal new`: the next spec starts a new chat.
- `:Sepal resume` picks the chat the next specs continue, by what you wrote in it. Each row is one
  message you typed, with its chat's title and age, newest first:

  ```
  2h  ThreadPool shutdown │ add graceful shutdown to the pool
  1d  Flaky test │ fix the flaky test in tests/pool.lua
  ```

  Type to fuzzy-filter, `<C-n>`/`<C-p>` to move, `<CR>` to pick, `<Esc>` to close. The header reads
  "continue with <title of the selected chat>". Its colors: `SepalPickHeader`, `SepalPickTitle`,
  `SepalPickAge`, `SepalPickPrompt`, `SepalPickMatch`, `SepalPickSelected`. If a picker plugin
  replaces `vim.ui.select` (snacks, fzf-lua, telescope, …), sepal uses it instead.
- `:Sepal stop` stops the running spec. Specs still in the queue come back to the spec buffer.

## Permissions

Specs run with `--permission-mode acceptEdits`: the agent can read and edit files, but nothing
else unless your Claude Code settings allow it. Nobody is there to answer a prompt, so a tool call
that would need one is refused. sepal tells you which ones:
`▲ the agent was not allowed: Bash(make test)`. Allow what you trust in `args`:

```lua
require("sepal").setup({ args = { "--permission-mode", "acceptEdits", "--allowedTools", "Bash(make test),Bash(git diff:*)" } })
```

Other flags go in `args` too, e.g. `"--model", "opus"`.

`:checkhealth sepal` checks `cmd`, `args`, git, `open`, `spec_suggest`, fidget and fff.

## Tests

```sh
nvim -l tests/run.lua
```

Designed and developed with AI-assisted implementation. I defined the requirements, workflows, and desired behavior.

## License

[MIT](LICENSE)
