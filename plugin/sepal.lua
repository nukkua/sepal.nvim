if vim.g.loaded_sepal then return end
vim.g.loaded_sepal = true

-- :[range]Sepal [spec] writes a spec and runs it in the background; :Sepal review / accept / reject
-- go through what it changed; :Sepal open shows the chat; new, resume pick the chat; stop stops it
local SUB = { "spec", "review", "accept", "reject", "open", "new", "resume", "stop" }
vim.api.nvim_create_user_command("Sepal", function(o)
  local sub, arg = o.fargs[1] or "spec", o.fargs[2]
  local sepal = require("sepal")
  if not vim.tbl_contains(SUB, sub) then return sepal.notify("unknown subcommand " .. sub, vim.log.levels.ERROR) end
  if sub == "spec" then return sepal.spec(o.range > 0 and { o.line1, o.line2 } or nil) end
  if sub == "accept" or sub == "reject" then return sepal[sub](arg == "all") end
  sepal[sub]()
end, { nargs = "*", range = true, complete = function(lead, line)
  local words = vim.split(vim.trim(line:gsub("^%S*", "")), "%s+")
  if (words[1] == "accept" or words[1] == "reject") and (#words > 1 or line:match("%s$")) then
    return vim.startswith("all", lead) and { "all" } or {}
  end
  return vim.tbl_filter(function(k) return vim.startswith(k, lead) end, SUB)
end, desc = "Sepal: specs for the agent and its changes" })
