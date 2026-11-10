-- nvim -l tests/run.lua  (from the repo root)
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.cmd.runtime("plugin/sepal.lua")

local sepal = require("sepal")
local review = require("sepal.review")
local S = sepal._t.state()

-- everything runs in a fresh git repo, with an empty Claude Code config dir
local T = vim.fn.tempname()
local work = vim.fs.joinpath(T, "work")
vim.fn.mkdir(work, "p")
vim.fn.chdir(work)
vim.system({ "git", "init", "-q" }):wait()
vim.env.CLAUDE_CONFIG_DIR = vim.fs.joinpath(T, "claude")
vim.env.SEPAL_T = T

-- a headless agent: logs its arguments and stdin, runs $SEPAL_EDIT (its "edits"), prints stream-json.
-- $SEPAL_FAIL=start: dies before starting; =result: ends with an error; $SEPAL_DENY: permission_denials
local agent = [[
prompt=$(cat)
printf '%s\n' "$*" >> "$SEPAL_T/args"
printf '%s\n--\n' "$prompt" >> "$SEPAL_T/prompts"
if [ "$SEPAL_FAIL" = start ]; then echo "No conversation found with session ID: x" >&2; exit 1; fi
printf '{"type":"system","subtype":"init","session_id":"s1"}\n'
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"a.txt"}}]}}\n'
if [ -n "$SEPAL_SLEEP" ]; then sleep "$SEPAL_SLEEP"; fi
if [ -n "$SEPAL_EDIT" ]; then sh -c "$SEPAL_EDIT"; fi
if [ "$SEPAL_FAIL" = result ]; then printf '{"type":"result","is_error":true,"result":"API error: overloaded","session_id":"s1"}\n'; exit 1; fi
printf '{"type":"result","subtype":"success","is_error":false,"result":"\\nShutdown drains the queue now.\\nDetails.","session_id":"s1","permission_denials":%s}' "${SEPAL_DENY:-[]}"]]
sepal.setup({ cmd = { "sh", "-c", agent, "sh" } })

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
local function read(p)
  local f = io.open(p)
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end
local function args() return vim.split(vim.trim(read(T .. "/args") or ""), "\n") end
local function prompts() return read(T .. "/prompts") or "" end
local function reset() os.remove(T .. "/args"); os.remove(T .. "/prompts") end
local function idle()
  assert(vim.wait(8000, function() return S.run == nil and #S.queue == 0 end, 10), "the spec never finished")
  vim.wait(50)
end
-- notifications while fn runs: { msg, level }
local function notified(fn)
  local got, notify = {}, vim.notify
  vim.notify = function(msg, lvl) got[#got + 1] = { msg, lvl or vim.log.levels.INFO } end
  local ok, err = pcall(fn)
  vim.notify = notify
  if not ok then error(err, 0) end
  return got
end
local function msgs(got) return vim.tbl_map(function(g) return g[1] end, got) end
local function spec_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do if vim.b[b].sepal_spec then return b end end
end
-- write a spec and send it with <c-c><c-c>
local function send(lines)
  sepal.spec()
  vim.api.nvim_buf_set_lines(spec_buf(), 0, -1, false, lines)
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-c>"), "tx", false)
end
local function write(p, lines) vim.fn.writefile(lines, vim.fs.joinpath(work, p)) end
local function path(p) return vim.fs.joinpath(work, p) end

test("a spec runs the agent in the background with the spec on stdin, without empty bullets", function()
  reset()
  local got = notified(function()
    send({ "Scope: ThreadPool::shutdown()", "Goal: ", "", "Constraints:", "- ", "", "Files:", "- @src/pool.cpp" })
    eq(spec_buf(), nil, "the spec buffer stayed")
    eq(#vim.api.nvim_tabpage_list_wins(0), 1, "a window opened")
    idle()
  end)
  eq(args(), { "-p --output-format stream-json --verbose --permission-mode acceptEdits" })
  eq(prompts(), "Scope: ThreadPool::shutdown()\nGoal: \n\nConstraints:\n\nFiles:\n- @src/pool.cpp\n--\n")
  eq(msgs(got), { "done: Shutdown drains the queue now." })
end)

test("the next spec continues the chat the first one went to", function()
  reset()
  notified(function() send({ "Scope: more" }); idle() end)
  eq(args(), { "-p --output-format stream-json --verbose --permission-mode acceptEdits --resume s1" })
end)

test(":Sepal new: the next spec starts a new chat, and the one after continues it", function()
  reset()
  notified(function()
    vim.cmd("Sepal new")
    send({ "Scope: fresh" }); idle()
    send({ "Scope: again" }); idle()
  end)
  eq(args(), { "-p --output-format stream-json --verbose --permission-mode acceptEdits",
    "-p --output-format stream-json --verbose --permission-mode acceptEdits --resume s1" })
end)

-- a Claude Code config dir with two chats of `cwd` and a `claude -p` run, ccc written last
local function claude_dir(cwd)
  local root = vim.fn.tempname()
  local d = vim.fs.joinpath(root, "projects", (cwd:gsub("[^%w]", "-")))
  vim.fn.mkdir(d, "p")
  local function rec(t) return vim.json.encode(t) end
  local function user(text, ts, extra)
    return rec(vim.tbl_extend("force", { type = "user", timestamp = ts, entrypoint = "cli", message = { role = "user", content = text } }, extra or {}))
  end
  vim.fn.writefile({
    user("<system-reminder>\nnot typed", "2026-11-01T10:00:00Z", { isMeta = true }),
    user("add graceful shutdown\nto the pool", "2026-11-01T10:00:01Z"),
    rec({ type = "ai-title", aiTitle = "ThreadPool shutdown", sessionId = "aaa" }),
    user("<pasted_content id=\"x\">\nScope: drain the queue\n</pasted_content id=\"x\">", "2026-11-01T11:00:00Z"),
  }, vim.fs.joinpath(d, "aaa.jsonl"))
  vim.fn.writefile({ user("fix the flaky test", "2026-11-02T09:00:00Z") }, vim.fs.joinpath(d, "bbb.jsonl"))
  vim.fn.writefile({ user("write a commit message", "2026-11-03T09:00:00Z", { entrypoint = "sdk-cli" }) }, vim.fs.joinpath(d, "ccc.jsonl"))
  for i, id in ipairs({ "aaa", "bbb", "ccc" }) do vim.uv.fs_utime(vim.fs.joinpath(d, id .. ".jsonl"), 1000 + i, 1000 + i) end
  return root
end

test("the first spec continues this directory's last chat; with continue = false a new one", function()
  local cfg = vim.env.CLAUDE_CONFIG_DIR
  vim.env.CLAUDE_CONFIG_DIR = claude_dir(vim.fn.getcwd())
  reset()
  S.session = nil
  notified(function() send({ "Scope: x" }); idle() end)
  S.session = nil
  sepal.setup({ continue = false })
  notified(function() send({ "Scope: y" }); idle() end)
  sepal.setup({ continue = true })
  vim.env.CLAUDE_CONFIG_DIR = cfg
  eq(vim.tbl_map(function(a) return a:match("%-%-resume (%S+)") or "new" end, args()), { "ccc", "new" })
end)

test("a spec sent while one runs waits, then runs in the same chat", function()
  reset()
  vim.env.SEPAL_SLEEP = "0.4"
  local got = notified(function()
    send({ "Scope: first" })
    send({ "Scope: second" })
    idle()
  end)
  vim.env.SEPAL_SLEEP = nil
  eq(prompts(), "Scope: first\n--\nScope: second\n--\n")
  eq(msgs(got), { "queued after the running spec (1 waiting)", "done: Shutdown drains the queue now.", "done: Shutdown drains the queue now." })
  eq(vim.endswith(args()[2], "--resume s1"), true)
end)

test(":Sepal stop stops the spec and brings the queued ones back", function()
  reset()
  vim.env.SEPAL_SLEEP = "3"
  local got = notified(function()
    send({ "Scope: long" })
    send({ "Scope: waiting" })
    vim.cmd("Sepal stop")
    idle()
  end)
  vim.env.SEPAL_SLEEP = nil
  eq(msgs(got), { "queued after the running spec (1 waiting)", "1 queued spec back in the spec buffer", "stopped" })
  eq(vim.api.nvim_buf_get_lines(spec_buf(), 0, -1, false), { "Scope: waiting" })
  vim.api.nvim_buf_delete(spec_buf(), { force = true })
end)

test("a spec the agent never started on comes back in its buffer", function()
  vim.env.SEPAL_FAIL = "start"
  local got = notified(function() send({ "Scope: keep me" }); idle() end)
  vim.env.SEPAL_FAIL = nil
  eq(got, { { "the agent didn't start: No conversation found with session ID: x\nthe spec is back in its buffer", vim.log.levels.ERROR } })
  eq(vim.api.nvim_buf_get_lines(spec_buf(), 0, -1, false), { "Scope: keep me" })
  eq(vim.fn.bufwinid(spec_buf()) ~= -1, true, "spec not shown")
  vim.api.nvim_buf_delete(spec_buf(), { force = true })
end)

test("an agent that can't be run gives the spec back", function()
  local cmd = sepal.config().cmd
  sepal.setup({ cmd = { "sepal-no-such-agent" } })
  local got = notified(function() send({ "Scope: keep me too" }) end)
  sepal.setup({ cmd = cmd })
  eq(got[1][2], vim.log.levels.ERROR)
  eq(vim.api.nvim_buf_get_lines(spec_buf(), 0, -1, false), { "Scope: keep me too" })
  vim.api.nvim_buf_delete(spec_buf(), { force = true })
end)

test("a failed run says why", function()
  vim.env.SEPAL_FAIL = "result"
  local got = notified(function() send({ "Scope: x" }); idle() end)
  vim.env.SEPAL_FAIL = nil
  eq(got, { { "the spec failed: API error: overloaded", vim.log.levels.ERROR } })
end)

test("tool calls the agent wasn't allowed to make are named", function()
  vim.env.SEPAL_DENY = '[{"tool_name":"Bash","tool_input":{"command":"make test"}},{"tool_name":"Bash","tool_input":{"command":"make test"}}]'
  local got = notified(function() send({ "Scope: x" }); idle() end)
  vim.env.SEPAL_DENY = nil
  eq(got[2], { "the agent was not allowed: Bash(make test)\nallow tools with --allowedTools in args, see :h sepal-args", vim.log.levels.WARN })
end)

test("done stays in fidget until you look at the changes", function()
  local got, removed = {}, {}
  package.loaded.fidget = {
    notify = function(msg, _, o) got[#got + 1] = { msg, o.key, o.ttl } end,
    notification = { remove = function(g, k) removed[#removed + 1] = { g, k } end },
  }
  send({ "Scope: x" }); idle()
  review.jump(1)
  package.loaded.fidget = nil
  eq(got[1], { "✓ done: Shutdown drains the queue now.", "sepal-done", math.huge })
  eq(removed, { { "default", "sepal-done" } })
end)

-- review --------------------------------------------------------------------------------------

local function marks(b) return vim.api.nvim_buf_get_extmarks(b, review._t.NS, 0, -1, { details = true }) end
local function hunks(p) return #review._t.hunks(path(p)) end

test("what the agent changed is in the review: changes, new files and deleted ones", function()
  write("a.txt", { "one", "two", "three" })
  write("c.txt", { "gone" })
  vim.cmd.edit("a.txt")
  vim.env.SEPAL_EDIT = [[printf 'one\nTWO\nthree\nfour\n' > a.txt; printf 'new\n' > b.txt; rm c.txt]]
  local got = notified(function() send({ "Scope: edit" }); idle() end)
  vim.env.SEPAL_EDIT = nil
  eq(msgs(got), { "done · 4 changes in 3 files to review: Shutdown drains the queue now." })
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "one", "TWO", "three", "four" }, "buffer not reloaded")
  local b = vim.api.nvim_get_current_buf()
  local hl = {}
  for _, m in ipairs(marks(b)) do
    if m[4].line_hl_group then hl[#hl + 1] = { m[2], m[4].line_hl_group } end
    if m[4].virt_lines then eq(vim.trim(m[4].virt_lines[1][1][1]), "two"); eq(m[4].virt_lines_above, true) end
  end
  eq(hl, { { 1, "SepalChange" }, { 3, "SepalAdd" } })
  eq(vim.b[b].sepal_review, true)
end)

test("<c-c><c-y> accepts the change under the cursor, <c-c><c-n> rejects it and writes the file", function()
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-y>"), "tx", false)
  eq(hunks("a.txt"), 1)
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "one", "TWO", "three", "four" })
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-n>"), "tx", false)
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "one", "TWO", "three" })
  eq(read(path("a.txt")), "one\nTWO\nthree\n")
  eq(review._t.files()[path("a.txt")], nil, "a.txt still under review")
  eq(#marks(0), 0)
  eq(vim.b.sepal_review, nil)
  eq(vim.fn.maparg("<c-c><c-y>", "n"), "", "map left behind")
end)

test(":Sepal review lists the changes and goes to the first; rejecting a new file deletes it", function()
  vim.cmd("Sepal review")
  eq(vim.tbl_map(function(i) return { vim.fn.bufname(i.bufnr), i.lnum } end, vim.fn.getqflist()), { { "b.txt", 1 }, { "c.txt", 1 } })
  eq(vim.fn.expand("%"), "b.txt")
  vim.cmd("Sepal reject")
  eq(vim.uv.fs_stat(path("b.txt")), nil, "b.txt still there")
end)

test("]r goes to the next file's change; rejecting a deletion brings the file back", function()
  vim.cmd.edit("a.txt")
  write("a.txt", { "one", "TWO", "three" })
  review.jump(1)
  eq(vim.fn.expand("%"), "c.txt")
  eq(vim.trim(marks(0)[1][4].virt_lines[1][1][1]), "gone")
  vim.cmd("Sepal reject")
  eq(read(path("c.txt")), "gone\n")
  eq(notified(function() vim.cmd("Sepal review") end), { { "nothing to review", vim.log.levels.INFO } })
end)

test(":Sepal accept all keeps everything, :Sepal reject all puts everything back", function()
  vim.env.SEPAL_EDIT = [[printf 'x\n' > a.txt; printf 'y\n' > d.txt]]
  notified(function() send({ "Scope: x" }); idle() end)
  eq(review.count(), 2)
  notified(function() vim.cmd("Sepal accept all") end)
  eq(review.count(), 0)
  eq(read(path("a.txt")), "x\n")
  write("a.txt", { "one" })
  vim.fn.delete(path("d.txt"))
  notified(function() send({ "Scope: x" }); idle() end)
  eq(review.count(), 2)
  eq(msgs(notified(function() vim.cmd("Sepal reject all") end)), { "put 2 files back as before" })
  vim.env.SEPAL_EDIT = nil
  eq(read(path("a.txt")), "one\n")
  eq(vim.uv.fs_stat(path("d.txt")), nil)
end)

test("a file you save during the run is yours, not the agent's", function()
  vim.env.SEPAL_SLEEP, vim.env.SEPAL_EDIT = "0.5", [[printf 'agent\n' > e.txt]]
  notified(function()
    send({ "Scope: x" })
    vim.cmd.edit("mine.txt")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "mine" })
    vim.cmd.write()
    idle()
  end)
  vim.env.SEPAL_SLEEP, vim.env.SEPAL_EDIT = nil, nil
  eq(vim.tbl_map(function(p) return vim.fs.basename(p) end, vim.tbl_keys(review._t.files())), { "e.txt" })
  notified(function() review.accept_all() end)
end)

test(":Sepal open opens the specs' chat with cmd --resume", function()
  local got
  sepal.setup({ open = function(argv, cwd) got = { argv[#argv - 1], argv[#argv], cwd } end })
  sepal.open()
  eq(got, { "--resume", "s1", vim.fn.getcwd() })
  sepal.config().open = nil
  local tmux = vim.env.TMUX
  vim.env.TMUX = nil
  local m = msgs(notified(function() sepal.open() end))[1]
  vim.env.TMUX = tmux
  eq(vim.endswith(m, "'--resume' 's1'"), true, m)
end)

test(":Sepal completes subcommands and accept/reject all", function()
  eq(vim.fn.getcompletion("Sepal re", "cmdline"), { "review", "reject", "resume" })
  eq(vim.fn.getcompletion("Sepal reject ", "cmdline"), { "all" })
end)

test("checkhealth runs", function() require("sepal.health").check() end)

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
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-k>"), "tx", false)
end)

test(":'<,'>Sepal spec puts the selected lines in the spec and lists the file", function()
  sepal.config().spec_suggest = nil
  vim.cmd.edit("tests/pool.lua")
  vim.bo.filetype = "lua"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local a = 1", "local b = a", "-", "return b" })
  vim.cmd("2,3Sepal spec")
  local b = spec_buf()
  eq(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "Scope: ", "Goal: ", "", "Constraints:", "- ", "",
    "Selection: tests/pool.lua:2-3", "```lua", "local b = a", "-", "```", "", "Files:", "- @tests/pool.lua" })
end)

test("a selection joins the open draft, its file listed once", function()
  vim.cmd.wincmd("j")
  vim.cmd("4Sepal spec")
  local lines = vim.api.nvim_buf_get_lines(spec_buf(), 0, -1, false)
  eq(vim.list_slice(lines, 13), { "Selection: tests/pool.lua:4", "```lua", "return b", "```", "", "Files:", "- @tests/pool.lua" })
end)

test("code in a selection is sent as it is, even a line that is just -", function()
  reset()
  vim.api.nvim_set_current_win(vim.fn.bufwinid(spec_buf()))
  notified(function() vim.api.nvim_feedkeys(vim.keycode("<c-c><c-c>"), "tx", false); idle() end)
  local got = vim.split(prompts(), "\n")
  eq(vim.tbl_contains(got, "-"), true, "the - code line was dropped")
  eq(vim.tbl_contains(got, "- "), false, "the empty bullet was sent")
  vim.cmd("bwipeout! tests/pool.lua")
end)

test("resume lists what you typed per conversation, newest first, claude -p runs too", function()
  vim.env.CLAUDE_CONFIG_DIR = claude_dir("/work/pool")
  local rows = require("sepal.resume").items("/work/pool")
  eq(vim.tbl_map(function(r) return { r.id, r.text } end, rows), {
    { "ccc", "write a commit message │ write a commit message" },
    { "bbb", "fix the flaky test │ fix the flaky test" },
    { "aaa", "ThreadPool shutdown │ Scope: drain the queue" },
    { "aaa", "ThreadPool shutdown │ add graceful shutdown to the pool" },
  })
  eq(require("sepal.resume").latest("/work/pool"), "ccc")
end)

test("the picker narrows by fuzzy match and <CR> picks the selected row", function()
  local rows = require("sepal.resume").items("/work/pool")
  local picked
  require("sepal.resume").pick(rows, "resume", function(r) picked = r end)
  local b = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(b, 0, 1, false, { "shtdwn" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = b })
  eq(#vim.api.nvim_buf_get_lines(b, 1, -1, false), 2, "not narrowed to the 2 shutdown rows")
  local line = vim.api.nvim_buf_get_lines(b, 2, 3, false)[1] -- the second row on screen
  local second = vim.iter(rows):find(function(r) return vim.endswith(line, r.msg) end)
  -- the picker lives in insert mode, which feedkeys can't drive headless (x leaves it, x! waits for keys)
  local function press(lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, "i")) do if m.lhs == lhs then return m.callback() end end
    error("no insert map " .. lhs)
  end
  press("<C-N>")
  press("<CR>")
  assert(vim.wait(1000, function() return picked ~= nil end, 10), "nothing picked")
  eq(picked, second)
  eq(vim.api.nvim_buf_is_valid(b), false, "picker still open")
end)


test(":Sepal resume picks the chat the next spec continues", function()
  local r = require("sepal.resume")
  local choose = r.choose
  local cwd = vim.fn.getcwd()
  vim.env.CLAUDE_CONFIG_DIR = claude_dir(cwd)
  r.choose = function(rows, _, on_choice) on_choice(vim.iter(rows):find(function(x) return x.id == "aaa" end)) end
  local got = notified(function() sepal.resume() end)
  r.choose = choose
  eq(msgs(got), { "the next spec continues ThreadPool shutdown" })
  reset()
  notified(function() send({ "Scope: x" }); idle() end)
  eq(vim.endswith(args()[1], "--resume aaa"), true, args()[1])
end)

print(("%d/%d passed"):format(n - fails, n))
vim.fn.delete(T, "rf")
os.exit(fails == 0 and 0 or 1)
