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
  if type(C.resume) ~= "table" then h.error("resume must be a list of arguments, e.g. { \"-c\" } or {}") end
  if C.side ~= "right" and C.side ~= "left" then h.error("side must be \"right\" or \"left\"") end
  if type(C.width) ~= "number" or C.width < 1 or C.width > 99 or C.width % 1 ~= 0 then h.error("width must be a whole percentage from 1 to 99, e.g. 40") end
end

return M
