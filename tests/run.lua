-- nvim -l tests/run.lua  (from the repo root)
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.cmd.runtime("plugin/sepal.lua")

local sepal = require("sepal")
local agent = require("sepal.agent")
local inbox = require("sepal.inbox")

-- everything runs in a fresh git repo; worktrees and the inbox go to a temp dir too
local T = vim.fn.tempname()
local work = vim.fs.joinpath(T, "work")
vim.fn.mkdir(work, "p")
vim.fn.chdir(work)
local function sh(cmd) return vim.system({ "sh", "-c", cmd }, { cwd = work, text = true }):wait() end
sh("git init -q && printf 'one\\ntwo\\nthree\\n' > a.txt && git add a.txt && git -c user.name=t -c user.email=t@t commit -qm init")
vim.env.SEPAL_T = T

-- a headless agent: logs where it runs, its arguments and stdin, runs $SEPAL_EDIT ($SEPAL_FIX when it
-- continues a chat), prints stream-json ending in a reply with assumptions.
-- $SEPAL_FAIL=start: dies before starting; =result: ends with an error; $SEPAL_DENY: permission_denials
local fake = [[
prompt=$(cat)
pwd >> "$SEPAL_T/cwd"
printf '%s\n' "$*" >> "$SEPAL_T/args"
printf '%s\n--\n' "$prompt" >> "$SEPAL_T/prompts"
case "$*" in *--resume*) resumed=1;; esac
if [ "$SEPAL_FAIL" = start ]; then echo "boom" >&2; exit 1; fi
printf '{"type":"system","subtype":"init","session_id":"s1"}\n'
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s/a.txt"}}]}}\n' "$PWD"
if [ -n "$SEPAL_SLEEP" ]; then sleep "$SEPAL_SLEEP"; fi
if [ -n "$resumed" ] && [ -n "$SEPAL_FIX" ]; then sh -c "$SEPAL_FIX"; elif [ -n "$SEPAL_EDIT" ]; then sh -c "$SEPAL_EDIT"; fi
if [ "$SEPAL_FAIL" = result ]; then printf '{"type":"result","is_error":true,"result":"API error: overloaded","session_id":"s1"}\n'; exit 1; fi
printf '{"type":"result","subtype":"success","is_error":false,"result":"Did it.\\n\\nAssumptions:\\n- kept the old API\\n- no new deps","session_id":"s1","permission_denials":%s}' "${SEPAL_DENY:-[]}"]]
sepal.setup({ cmd = { "sh", "-c", fake, "sh" }, worktrees = vim.fs.joinpath(T, "state") })

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
local function reset()
  for _, f in ipairs({ "args", "prompts", "cwd" }) do os.remove(T .. "/" .. f) end
  for _, k in ipairs({ "SEPAL_EDIT", "SEPAL_FIX", "SEPAL_SLEEP", "SEPAL_FAIL", "SEPAL_DENY" }) do vim.env[k] = nil end
end
local function idle()
  assert(vim.wait(10000, function() return next(agent._t.jobs) == nil end, 10), "the spec never finished")
  vim.wait(30)
end
-- notifications while fn runs: { msg, level }
local function notified(fn)
  local got, notify = {}, vim.notify
  vim.notify = function(msg, lvl)
    if not msg:match("^spec: <c%-c><c%-c> sends it") then got[#got + 1] = { msg, lvl or vim.log.levels.INFO } end -- the keys hint
  end
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
-- send a spec and wait for it; the notifications it made
local function run(lines) return msgs(notified(function() send(lines); idle() end)) end
local function file(p) return read(vim.fs.joinpath(work, p)) end
local function put(p, s) local f = assert(io.open(vim.fs.joinpath(work, p), "w")); f:write(s); f:close() end
local function newest() return inbox.list(work)[1] end
local function clean() -- back to the first commit, nothing in the inbox
  sh("git checkout -q -- . && git clean -qfd")
  for _, e in ipairs(vim.list_slice(inbox.list(work), 1)) do agent.drop(e) end
end

test("a spec runs in a worktree and lands as unstaged changes, with what the agent assumed", function()
  reset()
  vim.env.SEPAL_EDIT = [[printf 'one\nTWO\nthree\n' > a.txt; printf 'new\n' > b.txt]]
  local got = run({ "Scope: a.txt", "Goal: shout two", "", "Constraints:", "- ", "", "Done when: ", "", "Files:", "- @a.txt" })
  eq(got, { "working on it: shout two", "landed: shout two · 2 files +2 −1\n· kept the old API\n· no new deps" })
  eq(file("a.txt"), "one\nTWO\nthree\n")
  eq(file("b.txt"), "new\n")
  eq(sh("git diff --cached --name-only").stdout, "", "something was staged")
  local cwd = vim.trim(read(T .. "/cwd"))
  assert(cwd ~= work and vim.startswith(cwd, vim.fs.joinpath(T, "state")), "the agent ran in " .. cwd)
  eq(vim.uv.fs_stat(cwd), nil, "the worktree was left behind")
  eq(args(), { "-p --output-format stream-json --verbose --permission-mode acceptEdits" })
  local p = prompts()
  assert(p:find("Scope: a.txt\nGoal: shout two\n\nConstraints:\n\n\nFiles:\n- @a.txt\n\n---\n", 1, true), p) -- no empty bullet or Done when:
  assert(p:find("Assumptions:", 1, true), "no assumptions asked for")
  local e = newest()
  eq({ e.status, e.session, e.assumptions }, { "landed", "s1", { "kept the old API", "no new deps" } })
end)

test("your edits since the spec started are kept; u takes the spec back out", function()
  clean(); reset()
  vim.env.SEPAL_SLEEP, vim.env.SEPAL_EDIT = "0.5", [[printf 'one\ntwo\nTHREE\n' > a.txt]]
  notified(function()
    send({ "Goal: shout three" })
    vim.wait(200)
    put("a.txt", "ONE\ntwo\nthree\n") -- you, meanwhile
    idle()
  end)
  eq(file("a.txt"), "ONE\ntwo\nTHREE\n")
  eq(msgs(notified(function() vim.cmd("Sepal undo") end)), { "took back: shout three" })
  eq(file("a.txt"), "ONE\ntwo\nthree\n")
  eq(newest().status, "undone")
end)

test("sepal runs the check itself; when it fails the agent gets the output and tries again", function()
  clean(); reset()
  vim.env.SEPAL_EDIT, vim.env.SEPAL_FIX = [[echo broken > a.txt]], [[echo fixed > a.txt]]
  local got = run({ "Goal: fix it", "Done when: grep -q fixed a.txt" })
  eq(got[#got], "landed: fix it · 1 file +1 −3 · grep -q fixed a.txt ✓\n· kept the old API\n· no new deps")
  local a = args()
  eq(a[1], "-p --output-format stream-json --verbose --permission-mode acceptEdits --allowedTools Bash(grep -q fixed a.txt)")
  eq(vim.endswith(a[2], "--resume s1"), true, a[2])
  assert(prompts():find("`grep -q fixed a.txt` failed (exit 1)", 1, true), "the agent never got the failure")
  eq(file("a.txt"), "fixed\n")
end)

test("a spec whose check keeps failing doesn't land", function()
  clean(); reset()
  vim.env.SEPAL_EDIT = [[echo broken > a.txt]]
  local got = notified(function() send({ "Goal: never", "Done when: echo nope; exit 1" }); idle() end)
  eq(got[#got], { "✗ never: `echo nope; exit 1` still fails after 2 tries · :Sepal inbox", vim.log.levels.WARN })
  eq(file("a.txt"), "one\ntwo\nthree\n")
  local e = newest()
  eq({ e.status, e.checked, vim.trim(e.check_out) }, { "failed", false, "nope" })
  eq(#args(), 2)
end)

test("check: the default for specs without Done when:", function()
  clean(); reset()
  sepal.setup({ check = "true" })
  vim.env.SEPAL_EDIT = [[echo x > a.txt]]
  local got = run({ "Goal: default check" })
  sepal.config().check = nil
  eq(got[1], "working on it: default check · done when `true` passes")
  eq(newest().checked, true)
end)

test("a spec that overlaps your edits waits for you; L lands it with conflict markers", function()
  clean(); reset()
  vim.env.SEPAL_SLEEP, vim.env.SEPAL_EDIT = "0.5", [[printf 'one\nAGENT\nthree\n' > a.txt]]
  local got = notified(function()
    send({ "Goal: overlap" })
    vim.wait(200)
    put("a.txt", "one\nMINE\nthree\n")
    idle()
  end)
  eq(got[#got][2], vim.log.levels.WARN)
  assert(got[#got][1]:find("it overlaps your edits in a.txt", 1, true), got[#got][1])
  eq(file("a.txt"), "one\nMINE\nthree\n")
  eq(newest().status, "needs")
  notified(function() vim.cmd("Sepal land") end)
  assert(file("a.txt"):find("<<<<<<< yours\nMINE\n=======\nAGENT\n>>>>>>> sepal", 1, true), file("a.txt"))
  eq(newest().conflicts, { "a.txt" })
end)

test("a file with unsaved changes in a buffer isn't landed on", function()
  clean(); reset()
  vim.cmd.edit("a.txt")
  vim.api.nvim_buf_set_lines(0, 0, 1, false, { "unsaved" })
  vim.env.SEPAL_EDIT = [[echo agent > a.txt]]
  local got = run({ "Goal: unsaved" })
  assert(got[#got]:find("unsaved changes in a.txt", 1, true), got[#got])
  eq(file("a.txt"), "one\ntwo\nthree\n")
  vim.cmd("silent edit!")
  notified(function() vim.cmd("Sepal land") end)
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "agent" }, "the buffer wasn't reloaded")
  vim.cmd("bwipeout!")
end)

test("land = manual: a spec waits in the inbox until :Sepal land", function()
  clean(); reset()
  sepal.setup({ land = "manual" })
  vim.env.SEPAL_EDIT = [[echo manual > a.txt]]
  local got = run({ "Goal: by hand" })
  sepal.setup({ land = "auto" })
  eq(got[#got], "● ready to land: by hand · 1 file +1 −3 · :Sepal inbox\n· kept the old API\n· no new deps")
  eq(file("a.txt"), "one\ntwo\nthree\n")
  notified(function() vim.cmd("Sepal land") end)
  eq(file("a.txt"), "manual\n")
end)

test("a reply continues the spec's chat from what it did, and lands only what's new", function()
  local e = newest()
  reset()
  vim.env.SEPAL_FIX = [[printf 'manual\nmore\n' > a.txt]]
  put("a.txt", "manual\n")
  local got = notified(function() agent.continue(e, "add a line"); idle() end)
  eq(vim.endswith(args()[1], "--resume s1"), true)
  assert(vim.startswith(prompts(), "add a line\n"), prompts())
  eq(file("a.txt"), "manual\nmore\n")
  eq(msgs(got)[1]:match("^landed"), "landed")
end)

test("no changes, a failed agent, one that never started, and tools it wasn't allowed", function()
  clean(); reset()
  eq(run({ "Goal: nothing" }), { "working on it: nothing", "no changes: nothing: Did it." })
  vim.env.SEPAL_FAIL = "result"
  local got = notified(function() send({ "Goal: fails" }); idle() end)
  eq(got[2], { "✗ fails: the agent failed: API error: overloaded · :Sepal inbox", vim.log.levels.ERROR })
  vim.env.SEPAL_FAIL = "start"
  got = notified(function() send({ "Goal: no start" }); idle() end)
  eq(got[2], { "✗ no start: the agent didn't start: boom · :Sepal inbox", vim.log.levels.ERROR })
  vim.env.SEPAL_FAIL = nil
  vim.env.SEPAL_DENY = '[{"tool_name":"Bash","tool_input":{"command":"make test"}},{"tool_name":"Bash","tool_input":{"command":"make test"}}]'
  got = notified(function() send({ "Goal: denied" }); idle() end)
  eq(got[#got], { "the agent was not allowed: Bash(make test)\nallow tools with --allowedTools in args, see :h sepal-args", vim.log.levels.WARN })
end)

test("outside a git repo the spec comes back in its buffer", function()
  local other = vim.fs.joinpath(T, "plain")
  vim.fn.mkdir(other, "p")
  vim.fn.chdir(other)
  local got = notified(function() send({ "Goal: no repo" }) end)
  vim.fn.chdir(work)
  eq(got, { { "not in a git repository: a spec runs in a git worktree\nthe spec is back in its buffer", vim.log.levels.ERROR } })
  eq(vim.api.nvim_buf_get_lines(spec_buf(), 0, -1, false), { "Goal: no repo" })
  vim.api.nvim_buf_delete(spec_buf(), { force = true })
end)

test(":Sepal stop stops a running spec", function()
  clean(); reset()
  vim.env.SEPAL_SLEEP, vim.env.SEPAL_EDIT = "3", [[echo late > a.txt]]
  local got = notified(function()
    send({ "Goal: long" })
    vim.wait(300)
    vim.cmd("Sepal stop")
    idle()
  end)
  eq(msgs(got), { "working on it: long", "stopped: long" })
  eq(newest().status, "stopped")
  eq(file("a.txt"), "one\ntwo\nthree\n")
end)

test("the inbox lists the specs and survives a restart", function()
  clean(); reset()
  vim.env.SEPAL_EDIT = [[echo x > a.txt]]
  run({ "Goal: listed" })
  vim.cmd("Sepal inbox")
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  assert(lines[3]:match("^✓ landed%s+now%s+listed%s+1 file %+1 −3$"), lines[3])
  eq(vim.list_slice(lines, 4), { "    · kept the old API", "    · no new deps" })
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  eq(inbox.current().title, "listed")
  vim.cmd("close")
  newest().status = "running" -- as if nvim quit while it ran
  inbox.changed(newest())
  inbox._t.reset()
  eq(newest().status, "interrupted")
  eq(newest().title, "listed")
end)

test(":Sepal open opens the newest spec's chat", function()
  local got
  sepal.setup({ open = function(argv, cwd) got = { argv[#argv - 1], argv[#argv], cwd } end })
  vim.cmd("Sepal open")
  sepal.config().open = nil
  eq(got, { "--resume", "s1", work })
end)

test(":Sepal clean drops the specs that are over", function()
  notified(function() vim.cmd("Sepal clean") end)
  eq(inbox.list(work), {})
  eq(sh("git for-each-ref refs/sepal").stdout, "")
end)

test("assumptions are read from the end of a reply", function()
  eq(agent.assumptions("ok\n\n**Assumptions:**\n- a\n* b\n\nthe end"), { "a", "b" })
  eq(agent.assumptions("ok\nAssumptions: none"), {})
  eq(agent.assumptions("ok\nAssumptions: the cache is per user"), { "the cache is per user" })
  eq(agent.assumptions("no list"), {})
end)

test(":Sepal completes subcommands", function()
  eq(vim.fn.getcompletion("Sepal s", "cmdline"), { "spec", "stop" })
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

test("a spec shows its keys when it opens", function()
  local got, notify = {}, vim.notify
  vim.notify = function(msg) got[#got + 1] = msg end
  sepal.spec()
  sepal.config().spec_suggest = suggest
  sepal.spec() -- the draft again
  sepal.config().spec_suggest = nil
  vim.notify = notify
  vim.api.nvim_buf_delete(spec_buf(), { force = true })
  eq(got, { "spec: <c-c><c-c> sends it, <c-c><c-f> adds a file, <c-c><c-k> discards",
    "spec: <c-c><c-c> sends it, <c-c><c-s> writes it for you, <c-c><c-f> adds a file, <c-c><c-k> discards" })
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
    "Done when: ", "", "Selection: tests/pool.lua:2-3", "```lua", "local b = a", "-", "```", "", "Files:", "- @tests/pool.lua" })
end)

test("a selection joins the open draft, its file listed once", function()
  vim.cmd.wincmd("j")
  vim.cmd("4Sepal spec")
  local lines = vim.api.nvim_buf_get_lines(spec_buf(), 0, -1, false)
  eq(vim.list_slice(lines, 15), { "Selection: tests/pool.lua:4", "```lua", "return b", "```", "", "Files:", "- @tests/pool.lua" })
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

print(("%d/%d passed"):format(n - fails, n))
vim.fn.delete(T, "rf")
os.exit(fails == 0 and 0 or 1)
