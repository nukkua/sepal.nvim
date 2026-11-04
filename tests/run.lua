-- nvim -l tests/run.lua  (from the repo root)
vim.opt.rtp:prepend(vim.fn.getcwd())

local sepal = require("sepal")
local S = sepal._t.state()
-- the agent prints its arguments and waits; with -c it fails unless $SEPAL_HISTORY is set,
-- like an agent with no chat to continue
local agent = [[
if [ "$1" = -c ] && [ -z "$SEPAL_HISTORY" ]; then exit 1; fi
printf "agent:[%s]\n" "$*"; exec cat]]
sepal.setup({ cmd = { "sh", "-c", agent, "sh" }, focus = false })

local fails, n = 0, 0
local function test(name, fn)
  n = n + 1
  local ok, err = pcall(fn)
  if not ok then
    fails = fails + 1
    print("FAIL " .. name .. "\n  " .. tostring(err))
  end
end
local function eq(a, b, msg)
  if not vim.deep_equal(a, b) then error((msg or "") .. "\n  expected: " .. vim.inspect(b) .. "\n  got: " .. vim.inspect(a), 2) end
end
local function screen(want)
  local text
  local ok = vim.wait(3000, function()
    text = S.buf and vim.api.nvim_buf_is_valid(S.buf) and table.concat(vim.api.nvim_buf_get_lines(S.buf, 0, -1, false), "\n") or ""
    return text:find(want, 1, true) ~= nil
  end, 10)
  assert(ok, "screen never showed " .. want .. ":\n" .. text)
end
local function win() return vim.fn.bufwinid(S.buf) end

test("toggle with nothing to continue starts a fresh chat on the right at 40%", function()
  sepal.toggle()
  screen("agent:[]")
  eq(vim.api.nvim_win_get_width(win()), math.floor(vim.o.columns * 0.4))
  eq(vim.fn.win_screenpos(win())[2] > 1, true, "not on the right")
end)

test("toggle hides it and brings the same agent back", function()
  local b = S.buf
  sepal.toggle()
  eq(win(), -1)
  eq(vim.fn.jobwait({ vim.bo[b].channel }, 0)[1], -1, "agent stopped when hidden")
  sepal.toggle()
  eq(S.buf, b)
  assert(win() ~= -1, "not shown")
end)

test("new starts a fresh chat in the same split", function()
  local b, w = S.buf, win()
  sepal.new()
  screen("agent:[]")
  assert(S.buf ~= b, "same buffer")
  eq(vim.api.nvim_buf_is_valid(b), false)
  eq(win(), w)
end)

test("an agent that exits closes its split", function()
  vim.fn.chanclose(vim.bo[S.buf].channel)
  assert(vim.wait(3000, function() return S.buf == nil end, 10), "still there")
  eq(#vim.api.nvim_tabpage_list_wins(0), 1)
end)

test("toggle continues the last chat when there is one", function()
  vim.env.SEPAL_HISTORY = "1"
  sepal.toggle()
  screen("agent:[-c]")
end)

test("hiding the only window is refused", function()
  vim.api.nvim_set_current_win(win())
  vim.cmd.only()
  sepal.toggle()
  eq(win(), vim.api.nvim_get_current_win())
end)

test("hiding the only window is refused with a float open", function()
  vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, { relative = "editor", row = 1, col = 1, width = 5, height = 1 })
  sepal.toggle()
  eq(win(), vim.api.nvim_get_current_win())
end)

test("checkhealth survives a resume that is not a list", function()
  sepal.setup({ resume = "-c" })
  require("sepal.health").check()
  sepal.setup({ resume = { "-c" } })
end)

test(":Sepal completes by prefix", function()
  vim.cmd.runtime("plugin/sepal.lua")
  eq(vim.fn.getcompletion("Sepal n", "cmdline"), { "new" })
end)

print(("%d/%d passed"):format(n - fails, n))
os.exit(fails == 0 and 0 or 1)
