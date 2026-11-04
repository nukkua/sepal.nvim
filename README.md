# sepal.nvim

A CLI agent in a terminal split next to your code. Toggle it, or start a fresh chat. The first
toggle continues the last chat in this directory (`claude -c`), so the chat comes back after you
quit Neovim, or after the terminal or tmux session it ran in is gone.

## Requirements

- Neovim 0.12+
- a CLI agent: [Claude Code](https://claude.com/claude-code) by default, or any other (`codex`, `opencode`, `pi`, `aider`, …)

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
  cmd = { "claude", "--settings", '{"tui":"default"}' }, -- the agent (see below)
  resume = { "-c" },   -- appended to cmd to continue this directory's last chat; {} to always start fresh
  side = "right",      -- "right" | "left"
  width = 40,          -- split width, percent of the editor (1-99)
  focus = true,        -- move to the agent when it opens
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
| `<c-c><c-f>` | add a file under `Files:` (picked with [fff.nvim](https://github.com/dmtrKovalenko/fff.nvim) if installed, else a prompt) |
| `<c-c><c-c>` | send the spec to the agent and close the buffer                       |
| `<c-c><c-k>` | discard the spec                                                        |

Files go in as `@path`, which Claude Code reads as file references. If the agent isn't running,
sending starts it and waits for it to be ready. Closing the window keeps the draft, and
`:Sepal spec` brings it back.

`{"tui":"default"}` keeps Claude Code on the main screen. Its fullscreen renderer draws on the
alternate screen, which has no scrollback, so in normal mode `<C-u>`, `gg`, `/` would find nothing
above the current screen. Keep it in `cmd` if you add your own Claude Code flags.

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

`:checkhealth sepal` checks `cmd`, `resume`, `side` and `width`.

## Tests

```sh
nvim -l tests/run.lua
```

## License

[MIT](LICENSE)
