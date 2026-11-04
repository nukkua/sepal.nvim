# sepal.nvim

A CLI agent in a terminal split next to your code. Toggle it, or start a fresh chat. The first
toggle continues the last chat in this directory (`claude -c`), so the chat comes back after you
quit Neovim, or after the terminal or tmux session it ran in is gone.

## Requirements

- Neovim 0.12+
- a CLI agent: [Claude Code](https://claude.com/claude-code) by default, or any other (`codex`, `opencode`, `pi`, `aider`, …)
- optional: [fff.nvim](https://github.com/dmtrKovalenko/fff.nvim) to pick files for a spec (without it you get a path prompt)
- optional: [fidget.nvim](https://github.com/j-hui/fidget.nvim) for notifications and a spinner while the agent starts
  (without it you get plain notifications; warnings and errors always go to `vim.notify`)

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
  cmd = { "claude", "--settings", "<tui=default + a Stop hook>" }, -- the agent (see below)
  resume = { "-c" },   -- appended to cmd to continue this directory's last chat; {} to always start fresh
  side = "right",      -- "right" | "left"
  width = 40,          -- split width, percent of the editor (1-99)
  focus = true,        -- move to the agent when it opens
  spec_suggest = nil,  -- argv: rough spec on stdin -> finished spec on stdout (see Specs)
})

vim.keymap.set("n", "<leader>aa", "<cmd>Sepal<cr>", { desc = "Agent: toggle" })
vim.keymap.set("n", "<leader>an", "<cmd>Sepal new<cr>", { desc = "Agent: new chat" })
vim.keymap.set("n", "<leader>ai", "<cmd>Sepal spec<cr>", { desc = "Agent: implement a spec" })
```

The commands are also available as functions: `require("sepal").toggle()`, `.new()`, `.spec()`.

## Usage

- `:Sepal` toggles the agent split. The first time, it starts `cmd` + `resume` in Neovim's
  directory. If there is nothing to continue there (the agent exits with an error right away), it
  starts a fresh chat instead. Hiding the split keeps the agent running.
- `:Sepal new` kills the agent and starts a fresh chat.
- If the agent exits, its split closes and the next `:Sepal` starts it again.

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
| `<c-c><c-c>` | send the spec to the agent (its split stays as it was) and close the buffer |
| `<c-c><c-k>` | discard the spec                                                        |

Files go in as `@path`, which Claude Code reads as file references. Sending doesn't open the
agent: if it isn't running, it starts in the background and gets the spec once it's ready. If it
can't start, the spec comes back in its buffer. Closing the window keeps the draft, and
`:Sepal spec` brings it back.

### Writing the spec for you

Set `spec_suggest` and the spec buffer starts as just your idea and `Files:`. `<c-c><c-s>` pipes
it to the command, which answers with the spec (a spinner shows while it thinks), then
`<c-c><c-c>` sends it. If you edit while it's writing, your text is kept. For example, Opus at
medium effort, reading the files but not editing them:

```lua
require("sepal").setup({
  spec_suggest = { "claude", "-p", "--model", "opus", "--effort", "medium",
    "--no-session-persistence", "--tools=Read,Grep,Glob",
    "Turn the rough idea on stdin into a short spec: Scope, Goal, Constraints, Files (as @path). "
    .. "Read the files so it matches the code. Output only the spec, no code fences, no filler." },
})
```

Keep `--no-session-persistence`: without it, `claude -c` in the agent would continue this
one-off run instead of your chat.

When Claude Code finishes a reply you get `✓ the agent is done: <first line of the reply>` (not
while you're in the agent). With fidget it stays until you enter the agent.

## The default `cmd`

`claude --settings` with two settings, on top of your own:

- `tui = "default"` keeps Claude Code on the main screen. Its fullscreen renderer draws on the
  alternate screen, which has no scrollback, so in normal mode `<C-u>`, `gg`, `/` would find
  nothing above the current screen.
- a `Stop` hook that tells this Neovim (through `$NVIM`) when a reply is done.

To add your own Claude Code flags, extend it instead of replacing it:

```lua
local cmd = vim.list_extend(vim.deepcopy(require("sepal").config().cmd), { "--model", "opus" })
require("sepal").setup({ cmd = cmd })
```

Other agents don't get the "done" notification.

The agent runs in a terminal buffer, so `<leader>` keys typed there go to the agent. Press
`<C-\><C-n>` to get back to normal mode first, or map a key in terminal mode:

```lua
vim.keymap.set("t", "<C-q>", "<cmd>Sepal<cr>", { desc = "Agent: hide" })
```

## Other agents

```lua
require("sepal").setup({ cmd = { "codex" }, resume = { "resume", "--last" } })
require("sepal").setup({ cmd = { "opencode" }, resume = { "--continue" } })
require("sepal").setup({ cmd = { "pi" }, resume = { "--continue" } })
require("sepal").setup({ cmd = { "aider" }, resume = { "--restore-chat-history" } })
```

`:checkhealth sepal` checks `cmd`, `resume`, `spec_suggest`, `side`, `width`, fidget and fff.

## Tests

```sh
nvim -l tests/run.lua
```

## License

[MIT](LICENSE)
