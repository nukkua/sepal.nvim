local M = {}

local function argv(v) return type(v) == "table" and type(v[1]) == "string" end

function M.check()
  local h = vim.health
  local C = require("sepal").config()

  h.start("sepal")
  if vim.fn.has("nvim-0.12") == 1 then h.ok("Neovim " .. tostring(vim.version())) else h.error("Neovim 0.12+ is required") end
  if vim.fn.executable("git") == 1 then h.ok("git found") else h.error("git not found: tasks run in git worktrees") end
  if not argv(C.cmd) then
    h.error("cmd must be an argv list, e.g. { \"claude\" }")
  elseif vim.fn.executable(C.cmd[1]) == 0 then
    h.error("cmd: " .. C.cmd[1] .. " is not executable")
  else
    h.ok("cmd: " .. table.concat(C.cmd, " "))
  end
  if C.auto_mode then h.ok("auto_mode: tasks and chats run in Claude Code's auto mode") end
  if type(C.args) ~= "table" then h.error("args must be a list of arguments, e.g. { \"--permission-mode\", \"acceptEdits\" }")
  else h.ok("tasks run with: " .. table.concat(C.args, " ")) end
  if C.check == nil then h.info("check not set: tasks without a `Done when:` line aren't checked")
  elseif type(C.check) ~= "string" then h.error("check must be a shell command, e.g. \"make test\"")
  else h.ok("check: " .. C.check) end
  if type(C.retries) ~= "number" or C.retries < 0 then h.error("retries must be a number, 0 or more") end
  if C.land ~= "auto" and C.land ~= "manual" then h.error("land must be \"auto\" or \"manual\"")
  else h.ok("land: " .. C.land) end
  if C.prepare ~= nil and type(C.prepare) ~= "string" then h.error("prepare must be a shell command") end
  h.info("worktrees and the inbox: " .. tostring(C.worktrees))
  if C.max_running == nil then h.info("max_running not set: every task runs at once")
  elseif type(C.max_running) ~= "number" or C.max_running < 1 then h.error("max_running must be a number, 1 or more")
  else h.ok("max_running: " .. C.max_running .. " at once, the rest wait") end
  if type(C.models) ~= "table" then h.error("models must be a table: { implement = \"opus\", btw = \"sonnet\" }")
  else h.ok(("models: implement %s, btw %s"):format(C.models.implement or "Claude Code's default", C.models.btw or "Claude Code's default")) end
  h.ok(C.sakura and "sakura: blossom pinks for sepal's accents" or "sakura off: your colorscheme's colors")
  if type(C.highlights) ~= "table" then h.error("highlights must be a table: { SepalOk = { fg = \"#a3be8c\" } }") end
  if type(C.icons) ~= "table" then h.error("icons must be a table: { landed = \"✓\" }") end
  h.info("Claude Code may ask to trust a task's new worktree: sepal warns, answer it in :Sepal open")
  if pcall(require, "fidget") then h.ok("fidget.nvim found: progress spinners") else h.info("fidget.nvim not found: plain notifications") end
  if pcall(require, "fff") then h.ok("fff.nvim found: <c-c><c-f> in a task picks files with it") else h.info("fff.nvim not found: <c-c><c-f> in a task prompts for a path") end
  local ss = C.task_suggest
  if ss == nil then
    h.info("task_suggest not set: <c-c><c-s> in a task does nothing")
  elseif not argv(ss) then
    h.error("task_suggest must be an argv list, e.g. { \"claude\", \"-p\", \"...\" }")
  elseif vim.fn.executable(ss[1]) == 0 then
    h.error("task_suggest: " .. ss[1] .. " is not executable")
  else
    h.ok("task_suggest: " .. ss[1])
  end
end

return M
