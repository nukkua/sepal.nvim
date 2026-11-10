local M = {}

local function argv(v) return type(v) == "table" and type(v[1]) == "string" end

function M.check()
  local h = vim.health
  local C = require("sepal").config()

  h.start("sepal")
  if vim.fn.has("nvim-0.12") == 1 then h.ok("Neovim " .. tostring(vim.version())) else h.error("Neovim 0.12+ is required") end
  if vim.fn.executable("git") == 1 then h.ok("git found") else h.error("git not found: specs run in git worktrees") end
  if not argv(C.cmd) then
    h.error("cmd must be an argv list, e.g. { \"claude\" }")
  elseif vim.fn.executable(C.cmd[1]) == 0 then
    h.error("cmd: " .. C.cmd[1] .. " is not executable")
  else
    h.ok("cmd: " .. table.concat(C.cmd, " "))
  end
  if type(C.args) ~= "table" then h.error("args must be a list of arguments, e.g. { \"--permission-mode\", \"acceptEdits\" }")
  else h.ok("specs run with: " .. table.concat(C.args, " ")) end
  if C.check == nil then h.info("check not set: specs without a `Done when:` line aren't checked")
  elseif type(C.check) ~= "string" then h.error("check must be a shell command, e.g. \"make test\"")
  else h.ok("check: " .. C.check) end
  if type(C.retries) ~= "number" or C.retries < 0 then h.error("retries must be a number, 0 or more") end
  if C.land ~= "auto" and C.land ~= "manual" then h.error("land must be \"auto\" or \"manual\"")
  else h.ok("land: " .. C.land) end
  if C.prepare ~= nil and type(C.prepare) ~= "string" then h.error("prepare must be a shell command") end
  h.info("worktrees and the inbox: " .. tostring(C.worktrees))
  if C.open ~= nil and type(C.open) ~= "function" then h.error("open must be a function(argv, cwd)")
  elseif C.open then h.ok(":Sepal open uses your open function")
  elseif vim.env.TMUX then h.ok(":Sepal open opens the chat in a new tmux window")
  else h.info("not in tmux: :Sepal open copies the command to run") end
  if pcall(require, "fidget") then h.ok("fidget.nvim found: progress spinners") else h.info("fidget.nvim not found: plain notifications") end
  if pcall(require, "fff") then h.ok("fff.nvim found: <c-c><c-f> in a spec picks files with it") else h.info("fff.nvim not found: <c-c><c-f> in a spec prompts for a path") end
  local ss = C.spec_suggest
  if ss == nil then
    h.info("spec_suggest not set: <c-c><c-s> in a spec does nothing")
  elseif not argv(ss) then
    h.error("spec_suggest must be an argv list, e.g. { \"claude\", \"-p\", \"...\" }")
  elseif vim.fn.executable(ss[1]) == 0 then
    h.error("spec_suggest: " .. ss[1] .. " is not executable")
  else
    h.ok("spec_suggest: " .. ss[1])
  end
end

return M
