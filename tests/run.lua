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

local function spec_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do if vim.b[b].sepal_spec then return b end end
end

test("spec opens the template above, <c-c><c-f> adds files with fff", function()
  sepal.spec()
  local b = spec_buf()
  eq(vim.api.nvim_get_current_buf(), b)
  eq(vim.api.nvim_buf_get_lines(b, 0, 3, false), { "Scope: ", "Goal: ", "" })
  package.loaded.fff = { find_files = function(o) o.on_submit({}, { relative_path = "src/pool.cpp" }) end }
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-f>"), "tx", false)
  package.loaded.fff.find_files = function(o) o.on_submit({}, { relative_path = "src/pool.h" }) end
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-f>"), "tx", false)
  package.loaded.fff = nil
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  eq(vim.list_slice(lines, #lines - 2), { "Files:", "- @src/pool.cpp", "- @src/pool.h" })
end)

test("spec <c-c><c-c> sends it to the running agent without empty bullets and closes it", function()
  local b = spec_buf()
  vim.api.nvim_set_current_win(vim.fn.bufwinid(b))
  vim.api.nvim_buf_set_lines(b, 0, 1, false, { "Scope: ThreadPool::shutdown()" })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-c>"), "tx", false)
  eq(spec_buf(), nil)
  screen("Scope: ThreadPool::shutdown()")
  screen("- @src/pool.h")
  eq(vim.tbl_contains(vim.api.nvim_buf_get_lines(S.buf, 0, -1, false), "- "), false, "empty bullet sent")
end)

test("spec starts the agent when it is not running and sends once the resume fallback settles", function()
  vim.wait(3000) -- past the resume fallback window, so the kill isn't taken for "nothing to continue"
  vim.fn.jobstop(vim.bo[S.buf].channel)
  assert(vim.wait(3000, function() return S.buf == nil end, 10), "agent still there")
  vim.env.SEPAL_HISTORY = nil -- the resume fails, so the spec has to reach the fresh agent that replaces it
  sepal.spec()
  vim.api.nvim_buf_set_lines(spec_buf(), 0, 1, false, { "Scope: fresh" })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-c>"), "tx", false)
  screen("agent:[]")
  assert(vim.wait(6000, function()
    return S.buf and table.concat(vim.api.nvim_buf_get_lines(S.buf, 0, -1, false), "\n"):find("Scope: fresh", 1, true) ~= nil
  end, 50), "spec never reached the agent")
end)

test("spec <c-c><c-k> discards it", function()
  sepal.spec()
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-k>"), "tx", false)
  eq(spec_buf(), nil)
end)

test("notify: info goes to fidget, warnings to vim.notify", function()
  local got = {}
  package.loaded.fidget = { notify = function(msg, lvl, o) got[#got + 1] = { "fidget", msg, lvl, o.annote } end }
  local notify = vim.notify
  vim.notify = function(msg, lvl, o) got[#got + 1] = { "notify", msg, lvl, o.title } end -- a notifier plugin
  sepal.notify("spec sent")
  sepal.notify("the spec is empty", vim.log.levels.WARN)
  vim.notify, package.loaded.fidget = notify, nil
  eq(got, { { "fidget", "spec sent", vim.log.levels.INFO, "sepal" }, { "notify", "the spec is empty", vim.log.levels.WARN, "sepal" } })
end)

test("notify: the builtin vim.notify gets a colored echo", function()
  vim.cmd.messages("clear")
  sepal.notify("the agent is the only window", vim.log.levels.WARN)
  eq(vim.trim(vim.fn.execute("messages")), "▲ sepal the agent is the only window")
end)

test("a spec that cannot be sent comes back in its buffer", function()
  vim.fn.jobstop(vim.bo[S.buf].channel)
  assert(vim.wait(3000, function() return S.buf == nil end, 10), "agent still there")
  local cmd = sepal.config().cmd
  sepal.setup({ cmd = { "sepal-no-such-agent" } })
  sepal.spec()
  vim.api.nvim_buf_set_lines(spec_buf(), 0, 1, false, { "Scope: keep me" })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-c>"), "tx", false)
  sepal.setup({ cmd = cmd })
  assert(spec_buf(), "spec lost")
  eq(vim.api.nvim_buf_get_lines(spec_buf(), 0, 1, false), { "Scope: keep me" })
  eq(vim.fn.bufwinid(spec_buf()) ~= -1, true, "spec not shown")
end)

print(("%d/%d passed"):format(n - fails, n))
os.exit(fails == 0 and 0 or 1)
