if vim.g.loaded_sepal then return end
vim.g.loaded_sepal = true

-- :[range]Sepal [task] writes a task for the agent (f feat, b btw: a question about the project, p plan: a job planned as tasks); :Sepal inbox lists every task (:Sepal panel shows them at the right); land, undo, open,
-- stop act on the newest one they apply to; clean drops the finished ones; qf plans the quickfix list as a plan, a task per file
local SUB = { "task", "inbox", "panel", "land", "undo", "open", "stop", "clean", "qf" }
vim.api.nvim_create_user_command("Sepal", function(o)
  local sub = o.fargs[1] or "task"
  local sepal = require("sepal")
  if not vim.tbl_contains(SUB, sub) then return sepal.notify("unknown subcommand " .. sub, vim.log.levels.ERROR) end
  if sub == "task" then return sepal.pick(o.range > 0 and { o.line1, o.line2 } or nil) end
  sepal[sub]()
end, { nargs = "?", range = true, complete = function(lead)
  return vim.tbl_filter(function(k) return vim.startswith(k, lead) end, SUB)
end, desc = "Sepal: tasks for the agent" })
