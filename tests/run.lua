-- nvim -l tests/run.lua  (from the repo root)
vim.opt.rtp:prepend(vim.fn.getcwd())

local sepal = require("sepal")
local S = sepal._t.state()
local default_cmd = vim.deepcopy(sepal.config().cmd)
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
  eq(win(), -1, "the agent split opened")
  assert(vim.wait(6000, function()
    return S.buf and table.concat(vim.api.nvim_buf_get_lines(S.buf, 0, -1, false), "\n"):find("Scope: fresh", 1, true) ~= nil
  end, 50), "spec never reached the agent")
end)

test("spec sent to a hidden agent leaves it hidden", function()
  sepal.spec()
  vim.api.nvim_buf_set_lines(spec_buf(), 0, 1, false, { "Scope: still hidden" })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-c>"), "tx", false)
  screen("Scope: still hidden")
  eq(win(), -1, "the agent split opened")
end)

test("Claude Code's Stop hook calls back and notifies the agent is done", function()
  local hook = vim.json.decode(default_cmd[3]).hooks.Stop[1].hooks[1].command
  local got = {}
  local notify = vim.notify
  vim.notify = function(msg) got[#got + 1] = msg end
  local reply = vim.json.encode({ last_assistant_message = "\n  Shutdown drains the queue now.\nDetails below." })
  vim.system({ "sh", "-c", hook }, { env = { NVIM = vim.fn.serverstart() }, stdin = reply })
  local ok = vim.wait(5000, function() return #got > 0 end, 20)
  vim.notify = notify
  assert(ok, "no notification")
  eq(got, { "the agent is done: Shutdown drains the queue now." })
end)

test("done stays in fidget until you enter the agent", function()
  local got, removed = {}, {}
  package.loaded.fidget = {
    notify = function(msg, _, o) got[#got + 1] = { msg, o.key, o.ttl } end,
    notification = { remove = function(g, k) removed[#removed + 1] = { g, k } end },
  }
  sepal.stopped()
  vim.wait(100)
  eq(got, { { "✓ the agent is done", "sepal-done", math.huge } })
  sepal.toggle()
  vim.api.nvim_set_current_win(win())
  package.loaded.fidget = nil
  eq(removed, { { "default", "sepal-done" } })
  vim.cmd.wincmd("p")
  sepal.toggle()
end)

test("no done notification while you're in the agent", function()
  sepal.toggle()
  vim.api.nvim_set_current_win(win())
  local got = {}
  local notify = vim.notify
  vim.notify = function(msg) got[#got + 1] = msg end
  sepal.stopped()
  vim.wait(100)
  vim.notify = notify
  eq(got, {})
  vim.cmd.wincmd("p")
  sepal.toggle()
end)

-- writes a fenced spec that quotes stdin, like a model that wraps its answer in ```
local suggest = { "sh", "-c", [[sleep 0.2; printf '```\nScope: from the idea\n'; sed 's/^/- got: /'; printf '```\n']] }

test("<c-c><c-s> turns the idea into the spec with spec_suggest", function()
  sepal.setup({ spec_suggest = suggest })
  sepal.spec()
  local b = spec_buf()
  eq(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "", "", "Files:" })
  vim.api.nvim_buf_set_lines(b, 0, 1, false, { "graceful shutdown" })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-s>"), "tx", false)
  assert(vim.wait(5000, function() return vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] == "Scope: from the idea" end, 20), "spec not written")
  eq(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "Scope: from the idea", "- got: graceful shutdown", "- got: ", "- got: Files:" })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-k>"), "tx", false)
end)

test("an empty idea line shows a hint that goes away when you type", function()
  local ns = vim.api.nvim_create_namespace("sepal.hint")
  local function marks(b) return #vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, {}) end
  sepal.spec()
  local b = spec_buf()
  eq(marks(b), 1)
  local tick = vim.b[b].changedtick
  vim.api.nvim_buf_set_lines(b, 0, 1, false, { "idea" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = b })
  eq(marks(b), 0)
  vim.api.nvim_buf_set_lines(b, 0, 1, false, { "" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = b })
  eq(marks(b), 1)
  eq(vim.b[b].changedtick, tick + 2, "the hint changed changedtick")
  eq(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "", "", "Files:" })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-s>"), "tx", false) -- still "write the idea first", nothing runs
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-k>"), "tx", false)
  sepal.config().spec_suggest = nil -- setup({ spec_suggest = nil }) is a no-op: nil keys vanish
  sepal.spec()
  eq(marks(spec_buf()), 0)
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-k>"), "tx", false)
  sepal.setup({ spec_suggest = suggest })
end)

test("<c-c><c-s> keeps what you typed while it was writing", function()
  sepal.spec()
  local b = spec_buf()
  vim.api.nvim_buf_set_lines(b, 0, 1, false, { "idea" })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-s>"), "tx", false)
  vim.api.nvim_buf_set_lines(b, 0, 1, false, { "idea, edited" })
  vim.wait(1500)
  eq(vim.api.nvim_buf_get_lines(b, 0, 1, false), { "idea, edited" })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-k>"), "tx", false)
end)

test("<c-c><c-s> with a failing spec_suggest leaves the buffer as it was", function()
  sepal.setup({ spec_suggest = { "sh", "-c", "echo boom >&2; exit 3" } })
  sepal.spec()
  local b = spec_buf()
  vim.api.nvim_buf_set_lines(b, 0, 1, false, { "idea" })
  local got = {}
  local notify = vim.notify
  vim.notify = function(msg) got[#got + 1] = msg end
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-s>"), "tx", false)
  local ok = vim.wait(3000, function() return #got > 0 end, 20)
  vim.notify = notify
  assert(ok, "no error")
  eq(got, { "spec_suggest failed (exit 3)\nboom" })
  eq(vim.api.nvim_buf_get_lines(b, 0, 1, false), { "idea" })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-k>"), "tx", false)
  sepal.config().spec_suggest = nil -- setup({ spec_suggest = nil }) is a no-op: nil keys vanish
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
