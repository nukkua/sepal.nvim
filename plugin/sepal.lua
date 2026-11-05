if vim.g.loaded_sepal then return end
vim.g.loaded_sepal = true

-- :Sepal toggles the agent split, :Sepal new starts a fresh chat, :Sepal spec writes a spec for it
-- (:'<,'>Sepal spec puts those lines in it), :Sepal resume picks a conversation to continue
local SUB = { toggle = "toggle", new = "new", spec = "spec", resume = "resume" }
vim.api.nvim_create_user_command("Sepal", function(o)
  local f = SUB[o.args == "" and "toggle" or o.args]
  if not f then return require("sepal").notify("unknown subcommand " .. o.args, vim.log.levels.ERROR) end
  if f == "spec" then return require("sepal").spec(o.range > 0 and { o.line1, o.line2 } or nil) end
  require("sepal")[f]()
end, { nargs = "?", range = true, complete = function(lead)
  return vim.tbl_filter(function(k) return vim.startswith(k, lead) end, vim.tbl_keys(SUB))
end, desc = "Sepal agent split" })
