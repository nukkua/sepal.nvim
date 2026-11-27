-- a blink.cmp source for /name skills in the task draft:
-- sources = { default = { ..., "sepal" }, providers = { sepal = { name = "sepal", module = "sepal.blink" } } }
local S = {}

function S.new() return setmetatable({}, { __index = S }) end
function S:enabled() return require("sepal").draft() == vim.api.nvim_get_current_buf() end
function S:get_trigger_characters() return { "/" } end

function S:get_completions(ctx, done)
  local sepal = require("sepal")
  local row, col = ctx.cursor[1] - 1, ctx.cursor[2]
  local start = sepal.complete_skills(1, "")
  if start < 0 then return done({ items = {} }) end
  local items = {}
  for _, it in ipairs(sepal.complete_skills(0, "/")) do
    items[#items + 1] = {
      label = it.word, kind = require("blink.cmp.types").CompletionItemKind.Keyword, documentation = it.info,
      textEdit = { newText = it.word, range = { start = { line = row, character = start }, ["end"] = { line = row, character = col } } },
    }
  end
  done({ items = items, is_incomplete_forward = false, is_incomplete_backward = false })
end

return S
