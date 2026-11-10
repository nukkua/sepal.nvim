if vim.g.loaded_sepal then return end
vim.g.loaded_sepal = true

-- :[range]Sepal [spec] writes a spec for the agent; :Sepal inbox lists every spec; land, undo, open,
-- stop act on the newest one they apply to; clean drops the finished ones
local SUB = { "spec", "inbox", "land", "undo", "open", "stop", "clean" }
vim.api.nvim_create_user_command("Sepal", function(o)
  local sub = o.fargs[1] or "spec"
  local sepal = require("sepal")
  if not vim.tbl_contains(SUB, sub) then return sepal.notify("unknown subcommand " .. sub, vim.log.levels.ERROR) end
  if sub == "spec" then return sepal.spec(o.range > 0 and { o.line1, o.line2 } or nil) end
  sepal[sub]()
end, { nargs = "?", range = true, complete = function(lead)
  return vim.tbl_filter(function(k) return vim.startswith(k, lead) end, SUB)
end, desc = "Sepal: specs for the agent" })
