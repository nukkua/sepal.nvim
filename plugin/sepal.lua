if vim.g.loaded_sepal then return end
vim.g.loaded_sepal = true

-- :Sepal toggles the agent split, :Sepal new starts a fresh chat, :Sepal spec writes a spec for it
local SUB = { toggle = "toggle", new = "new", spec = "spec" }
vim.api.nvim_create_user_command("Sepal", function(o)
  local f = SUB[o.args == "" and "toggle" or o.args]
  if not f then return require("sepal").notify("unknown subcommand " .. o.args, vim.log.levels.ERROR) end
  require("sepal")[f]()
end, { nargs = "?", complete = function(lead)
  return vim.tbl_filter(function(k) return vim.startswith(k, lead) end, vim.tbl_keys(SUB))
end, desc = "Sepal agent split" })
