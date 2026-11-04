local M = {}

function M.check()
  local h = vim.health
  local C = require("sepal").config()

  h.start("sepal")
  if vim.fn.has("nvim-0.12") == 1 then h.ok("Neovim " .. tostring(vim.version())) else h.error("Neovim 0.12+ is required") end
  if type(C.cmd) ~= "table" or type(C.cmd[1]) ~= "string" then
    h.error("cmd must be an argv list, e.g. { \"claude\" }")
  elseif vim.fn.executable(C.cmd[1]) == 0 then
    h.error("cmd: " .. C.cmd[1] .. " is not executable")
  else
    h.ok("cmd: " .. table.concat(C.cmd, " ") .. " (resume: " .. (type(C.resume) == "table" and table.concat(C.resume, " ") or "?") .. ")")
  end
  if pcall(require, "fidget") then h.ok("fidget.nvim found: progress spinners") else h.info("fidget.nvim not found: plain notifications") end
  if pcall(require, "fff") then h.ok("fff.nvim found: <c-c><c-f> in a spec picks files with it") else h.info("fff.nvim not found: <c-c><c-f> in a spec prompts for a path") end
  local ss = C.spec_suggest
  if ss == nil then
    h.info("spec_suggest not set: <c-c><c-s> in a spec does nothing")
  elseif type(ss) ~= "table" or type(ss[1]) ~= "string" then
    h.error("spec_suggest must be an argv list, e.g. { \"claude\", \"-p\", \"...\" }")
  elseif vim.fn.executable(ss[1]) == 0 then
    h.error("spec_suggest: " .. ss[1] .. " is not executable")
  else
    h.ok("spec_suggest: " .. ss[1])
  end
  if type(C.resume) ~= "table" then h.error("resume must be a list of arguments, e.g. { \"-c\" } or {}") end
  if C.side ~= "right" and C.side ~= "left" then h.error("side must be \"right\" or \"left\"") end
  if type(C.width) ~= "number" or C.width < 1 or C.width > 99 or C.width % 1 ~= 0 then h.error("width must be a whole percentage from 1 to 99, e.g. 40") end
end

return M
