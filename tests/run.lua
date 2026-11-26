-- nvim -l tests/run.lua  (from the repo root)
local FIXTURES = vim.fn.getcwd() .. "/tests/fixtures" -- real sessions, recorded; read, never written
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.cmd.runtime("plugin/sepal.lua")

local sepal = require("sepal")
local agent = require("sepal.agent")
local inbox = require("sepal.inbox")

-- everything runs in a fresh git repo; worktrees and the inbox go to a temp dir too
local T = vim.fn.tempname()
local work = vim.fs.joinpath(T, "work")
vim.fn.mkdir(work, "p")
vim.fn.mkdir(T .. "/bin", "p")
vim.fn.chdir(work)
local function sh(cmd) return vim.system({ "sh", "-c", cmd }, { cwd = work, text = true }):wait() end
sh("git init -q && printf 'one\\ntwo\\nthree\\n' > a.txt && git add a.txt && git -c user.name=t -c user.email=t@t commit -qm init")
vim.env.SEPAL_T = T
vim.env.CLAUDE_CONFIG_DIR = vim.fs.joinpath(T, "claude") -- drop deletes chats from there

-- replay FILE, shared by the fakes: the fixture's lines to $SEPAL_EVENTS, /tmp/sepal-rec/<dir>
-- rewritten to the run's $PWD and transcript_path to the fake's transcript; after a line number in
-- the space-separated $SEPAL_PAUSE it waits for $SEPAL_T/go (a test's go()), then removes it
local replay = vim.fs.joinpath(T, "replay.sh")
local f = assert(io.open(replay, "w"))
f:write([[
replay() {
  n=0
  while IFS= read -r l; do
    n=$((n+1))
    l=$(printf '%s\n' "$l" | sed -e "s|/tmp/sepal-rec/[^\"/]*|$PWD|g" \
      -e "s|\"transcript_path\":\"[^\"]*\"|\"transcript_path\":\"$SEPAL_EVENTS.jsonl\"|g")
    printf '%s\n' "$l" >> "$SEPAL_EVENTS"
    case " $SEPAL_PAUSE " in
      *" $n "*) while [ ! -f "$SEPAL_T/go" ]; do sleep 0.05; done; rm "$SEPAL_T/go";;
    esac
  done < "$1"
}
]])
f:close()

local function exe(name, body) -- a fake CLI: a real executable, its basename is its agent
  local p = vim.fs.joinpath(T, "bin", name)
  local w = assert(io.open(p, "w"))
  w:write("#!/bin/sh\n. \"$SEPAL_T/replay.sh\"\n" .. body)
  w:close()
  vim.uv.fs_chmod(p, 493) -- 0755
  return p
end

-- a fake Claude Code: logs where it runs, its arguments (without --settings and the prompt) and the
-- prompt (its last argument), reports through the hooks ($SEPAL_EVENTS), runs $SEPAL_EDIT ($SEPAL_FIX
-- when it continues a chat), ends its turn with a reply with assumptions, and stays open like claude.
-- $SEPAL_FAIL=start: dies before starting; =quit: quits mid-turn. $SEPAL_ASK: asks for permission.
-- $SEPAL_REPLY: a file with the transcript line of its reply instead of the usual one.
-- $SEPAL_REPLAY=file: runs $SEPAL_EDIT, then replays that file instead of the usual events
local claude = exe("claude", [[
n=$#; i=0; logged=; skip=
for a; do
  i=$((i+1))
  if [ $i -eq $n ]; then prompt=$a
  elif [ -n "$skip" ]; then skip=; printf '%s' "$a" > "$SEPAL_T/settings"
  elif [ "$a" = --settings ]; then skip=1
  else logged="$logged${logged:+ }$a"; fi
done
pwd >> "$SEPAL_T/cwd"
printf '%s\n' "$logged" >> "$SEPAL_T/args"
printf '%s\n--\n' "$prompt" >> "$SEPAL_T/prompts"
case "$logged" in *--resume*) resumed=1; echo "the chat so far";; esac
if [ "$SEPAL_FAIL" = start ]; then echo boom; exit 1; fi
if [ -n "$SEPAL_TRUST" ]; then echo "Quick safety check: Is this a project you trust?"; read _; fi
ev() { printf '%s\n' "$1" >> "$SEPAL_EVENTS"; }
t="$SEPAL_EVENTS.jsonl"
: > "$t"
if [ -n "$SEPAL_REPLAY" ]; then
  if [ -n "$SEPAL_EDIT" ]; then sh -c "$SEPAL_EDIT"; fi
  replay "$SEPAL_REPLAY"
  while :; do sleep 1; done
fi
ev "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"s1\",\"model\":\"claude-opus-5-5[1m]\",\"transcript_path\":\"$t\"}"
ev "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"s1\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$PWD/a.txt\"}}"
if [ -n "$SEPAL_SUB" ]; then
  ev '{"hook_event_name":"SubagentStart","session_id":"s1","agent_id":"a1","agent_type":"Explore"}'
  ev '{"hook_event_name":"SubagentStart","session_id":"s1","agent_id":"a2","agent_type":"Plan"}'
  ev '{"hook_event_name":"SubagentStop","session_id":"s1","agent_id":"a1","agent_type":"Explore"}'
  ev '{"hook_event_name":"SubagentStart","session_id":"s1","agent_id":"a3","agent_type":"general-purpose"}'
fi
if [ -n "$SEPAL_SLEEP" ]; then sleep "$SEPAL_SLEEP"; fi
if [ -n "$resumed" ] && [ -n "$SEPAL_FIX" ]; then sh -c "$SEPAL_FIX"; elif [ -n "$SEPAL_EDIT" ]; then sh -c "$SEPAL_EDIT"; fi
if [ "$SEPAL_FAIL" = quit ]; then exit 1; fi
if [ -n "$SEPAL_INTERRUPT" ]; then # Esc: no Stop hook, it waits at its prompt
  sleep 0.2
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","content":"[Request interrupted by user"}]}}' >> "$t"
  sleep 0.3
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}' >> "$t"
  while :; do sleep 1; done
fi
if [ -n "$SEPAL_ASK" ]; then ev '{"hook_event_name":"Notification","session_id":"s1","message":"Claude needs your permission to use Bash"}'; fi
if [ -n "$SEPAL_REPLY" ]; then { printf '%s\n' '{"type":"user","message":{"content":"go"}}'; cat "$SEPAL_REPLY"; } > "$t"
else printf '%s\n' '{"type":"user","message":{"content":"go"}}' '{"type":"assistant","message":{"content":[{"type":"text","text":"Did it.\n\nAssumptions:\n- kept the old API\n- no new deps"}]}}' > "$t"; fi
ev "{\"hook_event_name\":\"Stop\",\"session_id\":\"s1\",\"transcript_path\":\"$t\"}"
while :; do sleep 1; done]])

-- a fake Devin CLI: logs its arguments (without the config path and the prompt), keeps the config,
-- reports through the hooks, edits, ends its turn and stays open. $SEPAL_INTERRUPT: ctrl-c (state
-- escapes only). $SEPAL_REPLAY=file: $SEPAL_EDIT, then that file's lines as its hooks
local dv = exe("devin", [[
logged=; skip=; resumed=
for a; do
  if [ -n "$skip" ]; then skip=; cp "$a" "$SEPAL_T/devin.json"
  elif [ "$a" = --config ]; then skip=1
  elif [ "$a" = -- ]; then break
  elif [ "$a" = -r ]; then resumed=1; logged="$logged${logged:+ }$a"
  else logged="$logged${logged:+ }$a"; fi
done
printf '%s\n' "$logged" >> "$SEPAL_T/args"
if [ -n "$resumed" ]; then
  printf 'Resume this session from which directory?\n'
  read ans
  printf '%s\n' "$ans" >> "$SEPAL_T/resume_answer"
  printf 'the chat so far\n'
  while :; do sleep 1; done
fi
ev() { printf '%s\n' "$1" >> "$SEPAL_EVENTS"; }
if [ -n "$SEPAL_REPLAY" ]; then
  if [ -n "$SEPAL_EDIT" ]; then sh -c "$SEPAL_EDIT"; fi
  replay "$SEPAL_REPLAY"
  while :; do sleep 1; done
fi
ev '{"hook_event_name":"SessionStart","source":"startup","session_id":"dv1","model":"claude-opus-5-5"}'
printf '\033]7501;state=working:app=devin\007'
if [ -n "$SEPAL_INTERRUPT" ]; then sleep 0.2; printf '\033]7501;state=idle:app=devin\007'; while :; do sleep 1; done; fi
ev "{\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"exec\",\"tool_input\":{\"command\":\"rm -rf x\"},\"session_id\":\"dv1\"}"
if [ -n "$SEPAL_EDIT" ]; then sh -c "$SEPAL_EDIT"; fi
ev '{"hook_event_name":"Stop","last_assistant_message":"Did it.\n\nAssumptions:\n- used devin","session_id":"dv1"}'
printf '\033]7501;state=done:app=devin\007'
while :; do sleep 1; done]])

sepal.setup({ cmd = { claude }, worktrees = vim.fs.joinpath(T, "state") })

local fails, n = 0, 0
local function test(name, fn)
  if vim.env.SEPAL_TEST and not name:find(vim.env.SEPAL_TEST, 1, true) then return end -- SEPAL_TEST=<part of a name>: just those
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
  for _, f in ipairs({ "args", "prompts", "cwd", "go" }) do os.remove(T .. "/" .. f) end
  for _, k in ipairs({ "SEPAL_EDIT", "SEPAL_FIX", "SEPAL_SLEEP", "SEPAL_FAIL", "SEPAL_ASK", "SEPAL_TRUST", "SEPAL_INTERRUPT", "SEPAL_SUB",
    "SEPAL_REPLY", "SEPAL_REPLAY", "SEPAL_PAUSE" }) do vim.env[k] = nil end
end
-- a paused fake goes on: touch T/go and wait until it consumed it
local function go()
  local w = assert(io.open(T .. "/go", "w"))
  w:close()
  assert(vim.wait(10000, function() return vim.uv.fs_stat(T .. "/go") == nil end, 10), "the fake never went")
end
local function idle()
  assert(vim.wait(10000, function() return next(agent._t.jobs) == nil and #agent._t.queue == 0 and next(agent._t.landing) == nil end, 10), "the task never finished")
  vim.wait(30)
end
-- an explicit land/undo finishes: its plan ran off the main loop
local function settled() assert(vim.wait(10000, function() return next(agent._t.landing) == nil end, 10), "never landed") end
-- notifications while fn runs: { msg, level }
local function notified(fn)
  local got, notify = {}, vim.notify
  vim.notify = function(msg, lvl)
    if not msg:match("^task: <c%-c><c%-c> sends it") then got[#got + 1] = { msg, lvl or vim.log.levels.INFO } end -- the keys hint
  end
  local ok, err = pcall(fn)
  vim.notify = notify
  if not ok then error(err, 0) end
  return got
end
local function msgs(got) return vim.tbl_map(function(g) return g[1] end, got) end
-- the key :Sepal task's picker reads (getcharstr reads stdin under nvim -l)
local function key(...)
  local ks, g = { ... }, vim.fn.getcharstr
  vim.fn.getcharstr = function() local k = table.remove(ks, 1); if #ks == 0 then vim.fn.getcharstr = g end; return k end
end
-- the floating picker while it waits for each key in keys (a function key errors, like <c-c>)
local function picker_shots(keys)
  local shots, ks, g = {}, vim.list_extend({}, keys), vim.fn.getcharstr
  vim.fn.getcharstr = function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.b[b].sepal_choose then
        local cfg, all, marks = vim.api.nvim_win_get_config(w), vim.api.nvim_buf_get_lines(b, 0, -1, false), {}
        -- rows past the header line and its blank one, as the items
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, -1, 0, -1, { details = true })) do
          marks[#marks + 1] = { m[2] - 2, m[3], m[4].end_col, m[4].hl_group }
        end
        shots[#shots + 1] = { win = w, buf = b, config = cfg, wrap = vim.wo[w].wrap, title = all[1],
          width = vim.api.nvim_win_get_width(w), height = vim.api.nvim_win_get_height(w),
          lines = vim.list_slice(all, 3), marks = marks }
      end
    end
    local k = table.remove(ks, 1)
    if #ks == 0 then vim.fn.getcharstr = g end
    if type(k) == "function" then return k() end
    return k
  end
  return shots
end
local function marked_texts(shot, row, hl)
  local out = {}
  for _, m in ipairs(shot.marks) do
    if m[1] == row and (not hl or m[4] == hl) then out[#out + 1] = shot.lines[row + 1]:sub(m[2] + 1, m[3]) end
  end
  return out
end
local function picker_closed(shot)
  eq({ vim.api.nvim_win_is_valid(shot.win), vim.api.nvim_buf_is_valid(shot.buf) }, { false, false })
end
local function task_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do if vim.b[b].sepal_task then return b end end
end
-- write a task and send it with <c-c><c-c> (or key)
local function send(lines, key)
  sepal.task()
  vim.api.nvim_buf_set_lines(task_buf(), 0, -1, false, lines)
  vim.api.nvim_feedkeys(vim.keycode(key or "<c-c><c-c>"), "tx", false)
end
-- send a task and wait for it; the notifications it made
local function run(lines, key) return msgs(notified(function() send(lines, key); idle() end)) end
local function file(p) return read(vim.fs.joinpath(work, p)) end
local function put(p, s) local f = assert(io.open(vim.fs.joinpath(work, p), "w")); f:write(s); f:close() end
local function newest() return inbox.list(work)[1] end
-- what a -> b would change, from the async plan_bg
local function plan(root, a, b)
  local done, out
  require("sepal.git").plan_bg(root, a, b, function(c) done, out = true, c end)
  assert(vim.wait(10000, function() return done end, 10), "plan never came back")
  return out
end
local function clean() -- back to the first commit, nothing in the inbox
  sh("git checkout -q -- . && git clean -qfd")
  for _, e in ipairs(vim.list_slice(inbox.list(work), 1)) do agent.drop(e) end
end

test("/name in a task sends the skill along: from a SKILL.md path (no frontmatter) or its text", function()
  reset()
  local skill = vim.fs.joinpath(T, "SKILL.md")
  local f = assert(io.open(skill, "w")); f:write("---\nname: how\n---\n\n# How\nExplore it.\n"); f:close()
  sepal.setup({ skills = { how = skill, why = "Ask why." } })
  run({ "Goal: /how does a.txt load", "", "Files:", "- @src/how" })
  sepal.setup({ skills = {} })
  local p = prompts()
  assert(p:find("Skill /how:\n# How\nExplore it.", 1, true), p)
  assert(not p:find("name: how", 1, true) and not p:find("Ask why.", 1, true), p)
end)

test("a task runs in a worktree and lands as unstaged changes, with what the agent assumed", function()
  reset()
  vim.env.SEPAL_EDIT = [[printf 'one\nTWO\nthree\n' > a.txt; printf 'new\n' > b.txt]]
  local got = run({ "Goal: shout two", "", "Constraints:", "- ", "", "Done when: ", "", "Files:", "- @a.txt" })
  eq(got, { "working on it: shout two · :Sepal open watches", "landed: shout two · 2 files +2 −1\n· kept the old API\n· no new deps" })
  eq(file("a.txt"), "one\nTWO\nthree\n")
  eq(file("b.txt"), "new\n")
  eq(sh("git diff --cached --name-only").stdout, "", "something was staged")
  local cwd = vim.trim(read(T .. "/cwd"))
  assert(cwd ~= work and vim.startswith(cwd, vim.fs.joinpath(T, "state")), "the agent ran in " .. cwd)
  eq(vim.uv.fs_stat(cwd), nil, "the worktree was left behind")
  eq(args(), { "--permission-mode acceptEdits" })
  local p = prompts()
  assert(p:find("Goal: shout two\n\nFiles:\n- @a.txt\n\n---\n", 1, true), p) -- no empty Constraints: or Done when:
  assert(p:find("Assumptions:", 1, true), "no assumptions asked for")
  local e = newest()
  eq({ e.status, e.session, e.assumptions }, { "landed", "s1", { "kept the old API", "no new deps" } })
end)

test("<CR> shows the file before | after in diff mode, its files in a location list; ]q next, gf the real one", function()
  local e = newest() -- the one above: a.txt changed, b.txt added
  agent.show(e)
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local function names() return vim.tbl_map(function(w) return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):match("[^/]+/[^/]+$") or vim.bo[vim.api.nvim_win_get_buf(w)].buftype end, wins) end
  eq(names(), { "before/a.txt", "after/a.txt", "quickfix" })
  eq({ #vim.fn.getqflist(), #vim.fn.getloclist(wins[2]) }, { 0, 2 }) -- the global list is left alone
  eq(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(wins[3]), 0, -1, false), { "a.txt +1 −1", "b.txt +1 −0" })
  eq({ vim.wo[wins[1]].diff, vim.wo[wins[2]].diff }, { true, true })
  eq({ vim.api.nvim_get_current_win(), vim.fn.line(".") }, { wins[2], 2 }) -- at the first change
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "one", "TWO", "three" })
  vim.api.nvim_set_current_win(wins[1])
  vim.api.nvim_feedkeys("]q", "x", false) -- from the before side too
  eq(names(), { "before/b.txt", "after/b.txt", "quickfix" })
  eq(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(wins[1]), 0, -1, false), { "" }) -- added: nothing before
  vim.api.nvim_feedkeys("[q", "x", false)
  eq(names(), { "before/a.txt", "after/a.txt", "quickfix" })
  local review, tabs = vim.api.nvim_get_current_tabpage(), vim.fn.tabpagenr("$")
  vim.api.nvim_set_current_win(wins[2])
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.api.nvim_feedkeys("gf", "x", false)
  eq({ vim.api.nvim_buf_get_name(0), vim.fn.line(".") }, { vim.fs.joinpath(work, "a.txt"), 2 })
  vim.cmd.tabclose()
  vim.api.nvim_set_current_tabpage(review)
  vim.api.nvim_feedkeys("q", "x", false)
  eq(vim.fn.tabpagenr("$"), tabs - 1)
  eq(#vim.tbl_filter(function(b) return vim.api.nvim_buf_get_name(b):match("^sepal://.*/after/") end, vim.api.nvim_list_bufs()), 0, "after buffers left")
end)

test("review preserves non-ASCII and escaped filenames and their first changed lines", function()
  clean(); reset()
  local git = require("sepal.git")
  local paths = { "日本語.txt", 'quote"tab\tback\\slash.txt', "with space.txt", "a\nnewline.txt" }
  local before, after = {}, {}
  for i, path in ipairs(paths) do
    before[path], after[path] = "one\nbefore " .. i .. "\n", "one\nafter " .. i .. "\n"
    put(path, before[path])
  end
  local base
  git.snapshot(work, nil, function(c) base = c end)
  assert(vim.wait(10000, function() return base ~= nil end, 10))
  for _, path in ipairs(paths) do put(path, after[path]) end
  local result
  git.snapshot(work, nil, function(c) result = c end)
  assert(vim.wait(10000, function() return result ~= nil end, 10))
  local st, first = git.review(work, base, result, function() end)
  eq(st.files, #paths)
  local e = { id = "quoted", root = work, title = "quoted", task = "Goal: quoted", status = "ready", base = base, result = result, stat = st }
  inbox.add(e)
  inbox.open(work)
  assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("a\\nnewline.txt", 1, true))
  vim.cmd.close()
  for _, path in ipairs(paths) do
    assert(vim.tbl_contains(st.paths, path), "quoted path in review: " .. vim.inspect(st.paths))
    eq(first[path], 2)
    eq(git.files(work, { result .. ":" .. path })[1], after[path])
  end
  local contents = git.files(work, { result .. ":missing\nfile", result .. ":" .. paths[4], result .. ":" .. paths[1] })
  eq(contents[1], nil)
  eq(contents[2], after[paths[4]])
  eq(contents[3], after[paths[1]])
  local async
  git.stat_bg(work, base, result, function(s) async = s end)
  assert(vim.wait(10000, function() return async ~= nil end, 10))
  eq(async, st)
  local empty = git.review(work, base, base, function() end)
  eq(empty.files, 0)
  local missing = git.review(work, "refs/sepal/missing", result, function() end)
  eq(missing.files, 0)
  agent.show(e)
  for i = 1, #paths do
    local path = vim.b.sepal_path
    eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), vim.split(vim.trim(after[path]), "\n"))
    local wins = vim.api.nvim_tabpage_list_wins(0)
    eq(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(wins[1]), 0, -1, false), vim.split(vim.trim(before[path]), "\n"))
    if i < #paths then vim.cmd.lnext() end
  end
  vim.cmd.tabclose()
end)

test("manual landing and undo preserve executable modes", function()
  clean(); reset()
  put("script.sh", "#!/bin/sh\necho old\n")
  vim.env.SEPAL_EDIT = [[chmod +x script.sh; printf '#!/bin/sh\necho new\n' > added.sh; chmod +x added.sh]]
  run({ "Goal: executable scripts" }, "<c-c><c-w>")
  local e = newest()
  notified(function() agent.land(e); settled() end)
  eq(vim.fn.executable(work .. "/script.sh"), 1, "mode-only change was lost")
  eq(vim.fn.executable(work .. "/added.sh"), 1, "new executable mode was lost")
  eq(file("added.sh"), "#!/bin/sh\necho new\n")
  eq(plan(work, e.base, e.result), {})
  notified(function() agent.undo(e); settled() end)
  eq(vim.fn.executable(work .. "/script.sh"), 0)
  eq(file("added.sh"), nil)
end)

test("manual landing and undo create, change and delete links without touching targets", function()
  clean(); reset()
  put("target", "original\n")
  put("regular", "regular\n")
  assert(vim.uv.fs_symlink("target", work .. "/link"))
  assert(vim.uv.fs_symlink("target", work .. "/removed"))
  assert(vim.uv.fs_symlink("target", work .. "/to-file"))
  vim.env.SEPAL_EDIT = [[rm link removed to-file regular; ln -s elsewhere link; ln -s target added; ln -s target regular; printf 'plain\n' > to-file]]
  run({ "Goal: update links" }, "<c-c><c-w>")
  local e = newest()
  notified(function() agent.land(e); settled() end)
  eq(vim.uv.fs_readlink(work .. "/link"), "elsewhere", "link was not landed as a link")
  eq(vim.uv.fs_readlink(work .. "/added"), "target")
  eq(vim.uv.fs_readlink(work .. "/regular"), "target")
  eq(vim.uv.fs_lstat(work .. "/removed"), nil)
  eq(vim.uv.fs_lstat(work .. "/to-file").type, "file")
  eq(file("to-file"), "plain\n")
  eq(file("target"), "original\n")
  notified(function() agent.undo(e); settled() end)
  eq(vim.uv.fs_readlink(work .. "/link"), "target")
  eq(vim.uv.fs_readlink(work .. "/removed"), "target")
  eq(vim.uv.fs_readlink(work .. "/to-file"), "target")
  eq(vim.uv.fs_lstat(work .. "/added"), nil)
  eq(file("regular"), "regular\n")
  eq(file("target"), "original\n")
end)

test("a conflicting symlink is reported and left untouched on manual land", function()
  clean(); reset()
  put("target", "original\n")
  put("mine", "my target\n")
  assert(vim.uv.fs_symlink("target", work .. "/link"))
  vim.env.SEPAL_EDIT = [[rm link; ln -s elsewhere link]]
  run({ "Goal: conflicting link" }, "<c-c><c-w>")
  assert(vim.uv.fs_unlink(work .. "/link"))
  assert(vim.uv.fs_symlink("mine", work .. "/link"))
  local e = newest()
  notified(function() agent.land(e); settled() end)
  eq(file("mine"), "my target\n", "land wrote through the conflicting symlink")
  eq(file("target"), "original\n")
  eq(vim.uv.fs_readlink(work .. "/link"), "mine")
  eq(e.conflicts, { "link" })
end)

test("manual landing never writes through a symlinked parent directory", function()
  clean(); reset()
  vim.fn.mkdir(work .. "/dir", "p")
  vim.fn.mkdir(work .. "/mine", "p")
  put("dir/file", "original\n")
  put("mine/file", "original\n")
  vim.env.SEPAL_EDIT = [[printf 'agent\n' > dir/file]]
  run({ "Goal: edit nested file" }, "<c-c><c-w>")
  vim.fn.delete(work .. "/dir", "rf")
  assert(vim.uv.fs_symlink("mine", work .. "/dir"))
  local e = newest()
  notified(function() agent.land(e); settled() end)
  eq(file("mine/file"), "original\n", "land wrote through a parent symlink")
  eq(vim.uv.fs_readlink(work .. "/dir"), "mine")
  eq(e.conflicts, { "dir/file" })
end)

test("landing runs off the main loop: the file is yours until the plan is checked fresh", function()
  clean(); reset()
  vim.env.SEPAL_EDIT = [[echo landed-async > a.txt]]
  run({ "Goal: async" }, "<c-c><c-w>")
  local e = newest()
  notified(function() agent.land(e) end)
  eq(agent._t.landing[e.id], "being landed")
  eq(file("a.txt"), "one\ntwo\nthree\n", "land wrote before its plan came back")
  settled()
  eq(file("a.txt"), "landed-async\n")
  eq(e.status, "landed")
end)

test("a second land, or a drop, while landing is told to wait and doesn't run", function()
  clean(); reset()
  vim.env.SEPAL_EDIT = [[echo once > a.txt]]
  run({ "Goal: once" }, "<c-c><c-w>")
  local e = newest()
  local got = notified(function()
    agent.land(e)
    agent.land(e) -- already planning: told, not run again
    agent.drop(e) -- dropping deletes the refs the plan reads
    settled()
  end)
  eq(msgs(got), { "a moment: it's being landed", "a moment: it's being landed",
    "landed: once · 1 file +1 −3\n· kept the old API\n· no new deps" })
  eq(newest().status, "landed")
  eq(#inbox.list(work), 1)
end)

test("an edit made while landing is kept: the freshness check re-plans instead of overwriting", function()
  clean(); reset()
  put("a.txt", "one\ntwo\nthree\nfour\nfive\n")
  vim.env.SEPAL_EDIT = [[printf 'one\ntwo\nthree\nfour\nAGENT\n' > a.txt]]
  run({ "Goal: merge race" }, "<c-c><c-w>")
  put("a.txt", "ONE\ntwo\nthree\nfour\nfive\n") -- your line 1 meanwhile: landing needs a merge
  local e = newest()
  local system, fired = vim.system, false
  vim.system = function(argv, o, cb)
    if not fired and vim.tbl_contains(argv, "merge-file") then
      fired = true
      put("a.txt", "ONE\ntwo\nTWO\nfour\nfive\n") -- your line 3 too, while the merge runs
    end
    return system(argv, o, cb)
  end
  notified(function() agent.land(e); settled() end)
  vim.system = system
  eq(file("a.txt"), "ONE\ntwo\nTWO\nfour\nAGENT\n") -- your lines 1 and 3, its line 5
  eq(e.status, "landed")
end)

test("undoing runs off the main loop too", function()
  clean(); reset()
  vim.env.SEPAL_EDIT = [[echo landed > a.txt]]
  run({ "Goal: async undo" })
  local e = newest()
  eq(e.status, "landed")
  notified(function() agent.undo(e) end)
  eq(agent._t.landing[e.id], "being taken back")
  eq(file("a.txt"), "landed\n", "undo wrote before its plan came back")
  settled()
  eq(file("a.txt"), "one\ntwo\nthree\n")
  eq(e.status, "undone")
end)

test("your edits since the task started are kept; u takes the task back out", function()
  clean(); reset()
  vim.env.SEPAL_SLEEP, vim.env.SEPAL_EDIT = "0.5", [[printf 'one\ntwo\nTHREE\n' > a.txt]]
  notified(function()
    send({ "Goal: shout three" })
    vim.wait(200)
    put("a.txt", "ONE\ntwo\nthree\n") -- you, meanwhile
    idle()
  end)
  eq(file("a.txt"), "ONE\ntwo\nTHREE\n")
  eq(msgs(notified(function() vim.cmd("Sepal undo"); settled() end)), { "took back: shout three" })
  eq(file("a.txt"), "ONE\ntwo\nthree\n")
  eq(newest().status, "undone")
end)

test("sepal runs the check itself; when it fails the agent gets the output and tries again", function()
  clean(); reset()
  vim.env.SEPAL_EDIT, vim.env.SEPAL_FIX = [[echo broken > a.txt]], [[echo fixed > a.txt]]
  local got = run({ "Goal: fix it", "Done when: grep -q fixed a.txt" })
  eq(got[#got], "landed: fix it · 1 file +1 −3 · grep -q fixed a.txt ✔\n· kept the old API\n· no new deps")
  local a = args()
  eq(a[1], "--permission-mode acceptEdits --allowedTools Bash(grep -q fixed a.txt)")
  local allow = vim.json.decode(read(T .. "/settings")).permissions.allow
  eq({ allow[1], allow[#allow]:match("^Bash%(cd .+ && grep %-q fixed a%.txt%)$") ~= nil }, { "Bash(git status:*)", true })
  assert(prompts():find("never `cd` to its path", 1, true), prompts())
  eq(vim.endswith(a[2], "--resume s1"), true, a[2])
  assert(prompts():find("`grep -q fixed a.txt` failed (exit 1)", 1, true), "the agent never got the failure")
  eq(file("a.txt"), "fixed\n")
end)

test("a task whose check keeps failing doesn't land", function()
  clean(); reset()
  vim.env.SEPAL_EDIT = [[echo broken > a.txt]]
  local got = notified(function() send({ "Goal: never", "Done when: echo nope; exit 1" }); idle() end)
  eq(got[#got], { "✘ never: `echo nope; exit 1` still fails after 2 tries · :Sepal inbox", vim.log.levels.WARN })
  eq(file("a.txt"), "one\ntwo\nthree\n")
  local e = newest()
  eq({ e.status, e.checked, vim.trim(e.check_out) }, { "failed", false, "nope" })
  eq(#args(), 2)
end)

test("check: the default for tasks without Done when:", function()
  clean(); reset()
  sepal.setup({ check = "true" })
  vim.env.SEPAL_EDIT = [[echo x > a.txt]]
  local got = run({ "Goal: default check" })
  sepal.config().check = nil
  eq(got[1], "working on it: default check · done when `true` passes · :Sepal open watches")
  eq(newest().checked, true)
end)

test("a task that overlaps your edits waits for you; L lands it with conflict markers", function()
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
  notified(function() vim.cmd("Sepal land"); settled() end)
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
  notified(function() vim.cmd("Sepal land"); settled() end)
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "agent" }, "the buffer wasn't reloaded")
  vim.cmd("bwipeout!")
end)

test("land = manual: a task started without a choice waits in the inbox until :Sepal land", function()
  clean(); reset()
  sepal.setup({ land = "manual" })
  vim.env.SEPAL_EDIT = [[echo manual > a.txt]]
  local got = msgs(notified(function() agent.start("Goal: by hand", work); idle() end))
  sepal.setup({ land = "auto" })
  eq(got[#got], "● ready to land: by hand · 1 file +1 −3 · :Sepal inbox\n· kept the old API\n· no new deps")
  eq(file("a.txt"), "one\ntwo\nthree\n")
  notified(function() vim.cmd("Sepal land"); settled() end)
  eq(file("a.txt"), "manual\n")
end)

test("a reply continues the task's chat from what it did, and lands only what's new", function()
  local e = newest()
  reset()
  vim.env.SEPAL_FIX = [[printf 'manual\nmore\n' > a.txt]]
  put("a.txt", "manual\n")
  local got = notified(function() agent.continue(e, "add a line"); idle() end)
  eq(vim.endswith(args()[1], "--resume s1"), true)
  assert(vim.startswith(prompts(), "add a line\n"), prompts())
  assert(prompts():find("same rules as before", 1, true) and not prompts():find("How to work on this", 1, true), prompts()) -- its chat has them
  eq(file("a.txt"), "manual\nmore\n")
  eq(msgs(got)[1]:match("^landed"), "landed")
end)

test("<c-c><c-w> sends a task that waits in the inbox; <c-c><c-c> lands even with land = manual", function()
  clean(); reset()
  vim.env.SEPAL_EDIT = [[echo waits > a.txt]]
  local got = run({ "Goal: wait" }, "<c-c><c-w>")
  eq(got[#got], "● ready to land: wait · 1 file +1 −3 · :Sepal inbox\n· kept the old API\n· no new deps")
  eq(file("a.txt"), "one\ntwo\nthree\n")
  clean(); reset()
  sepal.setup({ land = "manual" })
  vim.env.SEPAL_EDIT = [[echo now > a.txt]]
  got = run({ "Goal: now" })
  sepal.setup({ land = "auto" })
  eq(file("a.txt"), "now\n")
end)

test("no changes, an agent that quits, one that never started, and one that asks for something", function()
  clean(); reset()
  eq(run({ "Goal: nothing" }), { "working on it: nothing · :Sepal open watches", "no changes: nothing: Did it." })
  vim.env.SEPAL_FAIL = "quit"
  local got = notified(function() send({ "Goal: quits" }); idle() end)
  eq(got[2], { "✘ quits: the agent quit before it was done (exit 1) · :Sepal inbox", vim.log.levels.ERROR })
  vim.env.SEPAL_FAIL = "start"
  got = notified(function() send({ "Goal: no start" }); idle() end)
  eq(got[2], { "✘ no start: the agent didn't start: boom · :Sepal inbox", vim.log.levels.ERROR })
  vim.env.SEPAL_FAIL, vim.env.SEPAL_ASK = nil, "1"
  got = notified(function() send({ "Goal: asks" }); idle() end)
  eq(got[2], { "▲ asks: Claude needs your permission to use Bash · :Sepal open", vim.log.levels.WARN })
end)

test("a task waiting on Claude Code's trust prompt says so; answering it in :Sepal open lets it go on", function()
  clean(); reset()
  vim.env.SEPAL_TRUST = "1"
  local got = notified(function()
    send({ "Goal: trust" })
    vim.wait(2000, function() return newest().activity == "needs you" end)
    vim.cmd("Sepal open")
    vim.api.nvim_chan_send(vim.bo.channel, "\r")
    vim.cmd.stopinsert()
    idle()
    vim.cmd("Sepal open") -- watched to its end, so its chat is up in the float: leave it
  end)
  eq(got[2], { "▲ trust: Claude Code asks to trust the worktree · :Sepal open", vim.log.levels.WARN })
  eq(newest().status, "nochange")
end)

test("max_running: the tasks past it wait in a queue and start when one is done", function()
  clean(); reset()
  sepal.setup({ max_running = 1 })
  vim.env.SEPAL_SLEEP, vim.env.SEPAL_EDIT = "0.3", [[echo x > "$(basename "$PWD").txt"]]
  local got = msgs(notified(function()
    send({ "Goal: first" })
    send({ "Goal: second" })
    eq(newest().status, "queued")
    idle()
  end))
  sepal.setup({ max_running = 2 })
  eq(vim.list_slice(got, 1, 2), { "working on it: first · :Sepal open watches", "queued: second · it starts when a running task is done" })
  eq({ inbox.list(work)[1].status, inbox.list(work)[2].status }, { "landed", "landed" })
end)

test("outside a git repo the task comes back in its buffer", function()
  local other = vim.fs.joinpath(T, "plain")
  vim.fn.mkdir(other, "p")
  vim.fn.chdir(other)
  local got = notified(function() send({ "Goal: no repo" }) end)
  vim.fn.chdir(work)
  eq(got, { { "not in a git repository: a task runs in a git worktree\nthe task is back in its buffer", vim.log.levels.ERROR } })
  eq(vim.api.nvim_buf_get_lines(task_buf(), 0, -1, false), { "Goal: no repo" })
  vim.api.nvim_buf_delete(task_buf(), { force = true })
end)

test("a work tree that can't be saved: the task leaves the inbox and comes back in its buffer", function()
  local before = #inbox.list(work)
  sh("printf x > locked.txt && chmod 000 locked.txt") -- git add -A can't read it
  local got = notified(function() send({ "Goal: unreadable" }); idle() end)
  sh("rm -f locked.txt")
  eq(got[#got], { "could not save your work tree (git add / write-tree failed)\nthe task is back in its buffer", vim.log.levels.ERROR })
  eq(#inbox.list(work), before)
  eq(vim.api.nvim_buf_get_lines(task_buf(), 0, -1, false), { "Goal: unreadable" })
  vim.api.nvim_buf_delete(task_buf(), { force = true })
end)

test(":Sepal stop stops a running task", function()
  clean(); reset()
  vim.env.SEPAL_SLEEP, vim.env.SEPAL_EDIT = "3", [[echo late > a.txt]]
  local got = notified(function()
    send({ "Goal: long" })
    vim.wait(300)
    vim.cmd("Sepal stop")
    idle()
  end)
  eq(msgs(got), { "working on it: long · :Sepal open watches", "stopped: long" })
  eq(newest().status, "stopped")
  eq(file("a.txt"), "one\ntwo\nthree\n")
end)

test("Esc in the agent (no Stop hook) stops the task and keeps what it did", function()
  clean(); reset()
  vim.env.SEPAL_INTERRUPT, vim.env.SEPAL_EDIT = "1", [[echo half > a.txt]]
  local got
  got = notified(function()
    send({ "Goal: esc" })
    vim.wait(400)
    eq(newest().status, "running", "a tool's output quoting the interrupt counted")
    idle()
  end)
  eq(msgs(got), { "working on it: esc · :Sepal open watches", "stopped: esc" })
  local e = newest()
  eq(e.status, "stopped")
  assert(e.stat and e.stat.files == 1, "what it did was lost")
end)

test("the inbox lists the tasks and survives a restart", function()
  clean(); reset()
  vim.env.SEPAL_EDIT = [[echo x > a.txt]]
  run({ "Goal: listed" })
  vim.cmd("Sepal inbox")
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  assert(lines[3]:match("^✔ landed%s+now%s+listed%s+1 file %+1 −3$"), lines[3])
  eq(vim.list_slice(lines, 4), { "    · kept the old API", "    · no new deps", "      a.txt +1 −3" })
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  eq(inbox.current().title, "listed")
  vim.cmd("close")
  newest().status = "running" -- as if nvim quit while it ran
  inbox.changed(newest())
  inbox._t.reset()
  eq(newest().status, "interrupted")
  eq(newest().title, "listed")
end)

test("inbox keys isolate roots and read only their own legacy entries", function()
  local a, b = T .. "/foo-bar", T .. "/foo_bar"
  local state = sepal.config().worktrees
  local legacy = vim.fs.joinpath(state, (a:gsub("[^%w]", "-")) .. ".json")
  local f = assert(io.open(legacy, "w"))
  f:write(vim.json.encode({
    { id = "legacy-a", root = a, status = "ready", spec = "Goal: legacy A" },
    { id = "legacy-b", root = b, status = "ready", task = "Goal: legacy B" },
  }))
  f:close()
  eq(#inbox.list(a), 1, "legacy entries leaked across roots")
  eq(inbox.list(a)[1].task, "Goal: legacy A")
  eq(inbox.list(b)[1].task, "Goal: legacy B")
  assert(inbox.key(a) ~= inbox.key(b), "storage keys collide")
  inbox.add({ id = "new-a", root = a, status = "ready", task = "Goal: new A" })
  inbox.save(b)
  inbox._t.reset()
  eq(#inbox.list(a), 2)
  eq(#inbox.list(b), 1)
  eq(inbox.list(b)[1].id, "legacy-b")
  local fresh = T .. "/missing-inbox"
  eq(inbox.list(fresh), {})
  put("../state/" .. inbox.key(fresh) .. ".json", "invalid JSON")
  inbox._t.reset()
  eq(inbox.list(fresh), {})
end)

test("a task saved by an older inbox (as spec) can still be dropped", function()
  clean(); reset()
  vim.env.SEPAL_EDIT = [[echo x > a.txt]]
  run({ "Goal: old" })
  local e = newest()
  e.spec, e.task = e.task, nil
  inbox.save(work)
  inbox._t.reset()
  eq(newest().task, e.spec)
  sepal.clean()
  eq(#inbox.list(work), 0)
end)

test("every task line in the inbox is the same width", function()
  clean(); reset()
  vim.env.SEPAL_EDIT = [[echo x > a.txt]]
  run({ "Goal: one" })
  local e = newest()
  inbox.add(vim.tbl_extend("force", e, { id = "b", title = "many", stat = { files = 12, add = 100, del = 2 } }))
  inbox.add(vim.tbl_extend("force", e, { id = "c", title = "none", stat = { files = 0, add = 0, del = 0 } }))
  vim.cmd("Sepal inbox")
  local w = {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if not l:match("^    ") and l:find("now") then w[#w + 1] = vim.fn.strdisplaywidth(l) end
  end
  eq({ #w, w[1], w[1] }, { 3, w[2], w[3] })
  vim.cmd("close")
end)

test(":Sepal panel with no tasks shows an empty state that says how to start", function()
  clean(); reset()
  vim.cmd("Sepal panel")
  local lines = vim.api.nvim_buf_get_lines(vim.fn.bufnr("sepal://panel"), 0, -1, false)
  eq(vim.trim(lines[8]), "no tasks yet")
  eq(vim.trim(lines[9]), "start one with :Sepal task")
  assert(lines[8]:match("^%s%s%s+no"), lines[8]) -- centered
  vim.cmd("Sepal panel")
end)

test("panel_width: the panel's width in columns, or a percent of the editor's that follows it", function()
  clean(); reset()
  local cols = vim.o.columns
  vim.o.columns = 200
  local function width()
    vim.cmd("Sepal panel")
    return vim.api.nvim_win_get_width(vim.fn.bufwinid("sepal://panel"))
  end
  eq(width(), 46) -- the default
  vim.cmd("Sepal panel")
  sepal.setup({ panel_width = 60 })
  eq(width(), 60)
  vim.cmd("Sepal panel")
  sepal.setup({ panel_width = "40%" })
  eq(width(), 80)
  vim.o.columns = 150
  vim.api.nvim_exec_autocmds("VimResized", {})
  eq(vim.api.nvim_win_get_width(vim.fn.bufwinid("sepal://panel")), 60) -- follows the editor
  vim.cmd("Sepal panel")
  sepal.setup({ panel_width = 0.5 })
  eq(width(), 75)
  vim.cmd("Sepal panel")
  local panel = require("sepal.panel")
  eq({ panel.width(5), panel.width("nope"), panel.width(1000) }, { 20, 46, 130 }) -- at least 20, room beside it
  sepal.setup({ panel_width = 46 })
  vim.o.columns = cols
end)

test(":Sepal panel shows each task as a card at the right, and redraws with the inbox", function()
  clean(); reset()
  vim.env.SEPAL_EDIT = [[echo x > a.txt]]
  run({ "Goal: carded" })
  local cur = vim.api.nvim_get_current_win()
  vim.cmd("Sepal panel")
  eq(vim.api.nvim_get_current_win(), cur) -- it's for looking at: the cursor stays
  local b = vim.fn.bufnr("sepal://panel")
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(lines[2]:match("1 landed"), lines[2])
  assert(not lines[1]:find("▐", 1, true) and lines[1]:match("^ %S+ sepal"), lines[1]) -- no mascot: the title at the cards' indent
  assert(lines[6]:match("^ ▎ ✔ carded%s+now$"), lines[6])
  eq(lines[7], " ▎ ✻ opus 5.5") -- the model and its provider's logo, between the name and the status
  eq(lines[8], " ▎ landed  in your work tree")
  eq(lines[9], " ▎ 1 file +1 −3")
  eq(lines[10], " ▎ Did it.")
  eq(lines[11], " ▎ · 2 decisions to read")
  local e = newest()
  local m0, a0 = e.model, e.agent
  e.model = "fusion-claude-opus-5-5-medium-sidekick-swe-2-high" -- devin's logo, lead + sidekick
  inbox.changed(e)
  lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  eq(lines[7], " ▎ ❖ opus 5.5 medium + swe 2 high")
  e.model, e.agent = nil, { cmd = "devin" } -- devin reports no model: its agent's logo instead
  inbox.changed(e)
  lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  eq(lines[7], " ▎ ❖ devin")
  e.model, e.agent = m0, a0
  inbox.changed(e)
  e.status, e.activity, e.summary = "running", "Edit a.txt", nil
  inbox.changed(e)
  lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(lines[2]:match("1 running"), lines[2])
  assert(vim.tbl_contains(lines, " ▎ → Edit a.txt"), vim.inspect(lines))
  assert(lines[6]:match("^ ▎ ⠋ carded"), lines[6]) -- it spins, and so does the inbox
  vim.wait(350, function() return not vim.api.nvim_buf_get_lines(b, 5, 6, false)[1]:match("⠋") end)
  assert(not vim.api.nvim_buf_get_lines(b, 5, 6, false)[1]:match("⠋"), "the panel's spinner moves on its own")
  assert(vim.api.nvim_buf_get_lines(b, 5, 6, false)[1]:match("^ ▎ %S+ carded%s+now$"), "a tick rewrites only the spinner")
  local anim = vim.api.nvim_create_namespace("sepal.panel.anim")
  local function lit() return vim.inspect(vim.tbl_map(function(m) return { m[2], m[3] } end, vim.api.nvim_buf_get_extmarks(b, anim, 0, -1, {}))) end
  vim.wait(1500, function() return lit() ~= "{}" end)
  local l0 = lit()
  assert(l0 ~= "{}", "its rail and label light up while it runs")
  vim.wait(350, function() return lit() ~= l0 end)
  assert(lit() ~= l0, "and the light moves")
  vim.cmd("Sepal inbox")
  local ib = vim.api.nvim_get_current_buf()
  local f0 = inbox.spin()
  assert(vim.api.nvim_buf_get_lines(ib, 2, 3, false)[1]:match("^" .. f0 .. " running"))
  vim.wait(350, function() return not vim.startswith(vim.api.nvim_buf_get_lines(ib, 2, 3, false)[1], f0) end)
  assert(not vim.startswith(vim.api.nvim_buf_get_lines(ib, 2, 3, false)[1], f0), "the inbox's spinner moves")
  assert(vim.api.nvim_buf_get_lines(ib, 2, 3, false)[1]:match("^%S+ running%s+now  carded"), "a tick rewrites only the spinner")
  vim.cmd("close")
  e.status = "landed"; inbox.changed(e)
  eq(lit(), "{}") -- done: the light is off
  vim.cmd("Sepal panel") -- a toggle
  eq(vim.fn.bufwinid(b), -1)
end)

test("j/k in the inbox go task to task, past the lines under each", function()
  clean(); reset()
  vim.env.SEPAL_EDIT = [[echo x > a.txt]]
  run({ "Goal: first" })
  run({ "Goal: second" })
  vim.cmd("Sepal inbox")
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.cmd("normal j")
  eq(vim.api.nvim_win_get_cursor(0)[1], 6) -- rows 4-5 are second's assumptions
  eq(inbox.current().title, "first")
  vim.cmd("normal j") -- the last task: stays
  eq(vim.api.nvim_win_get_cursor(0)[1], 6)
  vim.cmd("normal k")
  eq(vim.api.nvim_win_get_cursor(0)[1], 3)
  eq(vim.fn.foldclosed(3), 3) -- tasks start folded
  eq(vim.fn.foldclosedend(3), 5)
  vim.cmd("normal za") -- unfolds second's lines, and that stays through a redraw
  eq(vim.fn.foldclosed(3), -1)
  inbox.render()
  eq(vim.fn.foldclosed(3), -1)
  eq(vim.fn.foldclosed(6), 6)
  vim.cmd("normal j")
  eq(inbox.current().title, "first")
  vim.cmd("normal kza")
  eq(vim.fn.foldclosed(3), 3)
  vim.cmd("close")
end)

test("the inbox is edited like oil: dd drops on :w, u takes it back, yyp opens a copy to add to", function()
  clean(); reset()
  vim.env.SEPAL_EDIT = [[echo x > a.txt]]
  run({ "Goal: first" })
  run({ "Goal: second" })
  vim.cmd("Sepal inbox")
  local b = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.cmd("normal dd") -- second's closed fold: its line and the lines under it
  assert(vim.bo[b].modified)
  vim.cmd("normal u")
  eq(vim.bo[b].modified, false)
  eq(vim.api.nvim_win_get_cursor(0)[1], 3)
  vim.cmd("normal dd")
  eq(inbox.current().title, "first") -- rows moved: still the task under the cursor
  vim.cmd("write")
  eq(vim.tbl_map(function(e) return e.title end, inbox.list(work)), { "first" })
  eq(vim.bo[b].modified, false)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.cmd("normal yyp")
  vim.cmd("write")
  assert(vim.wait(1000, function() return task_buf() ~= nil end, 10), "no draft opened")
  eq(#inbox.list(work), 1) -- the copy is a draft, not a task yet
  eq(vim.api.nvim_buf_get_lines(task_buf(), 0, -1, false), vim.split(newest().task, "\n"))
  eq(vim.api.nvim_get_current_buf(), task_buf()) -- focused, to change it
  eq(vim.wo.wrap, true) -- not the inbox's nowrap: a long line would scroll sideways as you type
  vim.o.splitbelow = true -- closing the draft would focus the window above, not the inbox
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-k>"), "x", false) -- discard it
  vim.o.splitbelow = false
  assert(vim.wait(1000, function() return vim.api.nvim_get_current_buf() == b end, 10), "the inbox lost focus")
  vim.cmd("close")
end)

test("a task's chat is saved as soon as it starts: o and r still work after a quit mid-run", function()
  clean(); reset()
  vim.env.SEPAL_SLEEP = "3"
  notified(function()
    send({ "Goal: cut short" })
    assert(vim.wait(2000, function() return newest().activity ~= nil end, 20), "the agent never started")
    inbox._t.reset() -- as if nvim quit now: read back what's on disk
    eq({ newest().status, newest().session }, { "interrupted", "s1" })
    vim.cmd("Sepal stop")
    idle()
  end)
  inbox._t.reset()
end)

test("the panel and the inbox show the running subagents: their count, and their names unfolded", function()
  clean(); reset()
  vim.env.SEPAL_SLEEP, vim.env.SEPAL_SUB = "1", "1"
  notified(function()
    send({ "Goal: with helpers" })
    assert(vim.wait(2000, function() return #(newest().subagents or {}) == 2 end, 20), "no subagents seen")
    eq(vim.tbl_map(function(a) return a.name end, newest().subagents), { "Plan", "general-purpose" })
    vim.cmd("Sepal panel")
    local pl = vim.api.nvim_buf_get_lines(vim.fn.bufnr("sepal://panel"), 0, -1, false)
    assert(vim.tbl_contains(pl, " ▎ ↳ 2 subagents: Plan, general-purpose"), vim.inspect(pl))
    vim.cmd("Sepal panel")
    vim.cmd("Sepal inbox")
    local il = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert(il[3]:match("↳ 2 subagents"), il[3])
    local hl = vim.tbl_map(function(m) return m[4].line_hl_group or m[4].hl_group end,
      vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true }))
    assert(vim.tbl_contains(hl, "SepalAgent"), vim.inspect(hl))
    assert(vim.tbl_contains(il, "    ↳ Plan") and vim.tbl_contains(il, "    ↳ general-purpose"), vim.inspect(il))
    vim.cmd("close")
    idle()
  end)
  eq(newest().subagents, nil) -- gone when the run is over
end)

test("q in the agent's last window shows another buffer instead of E444, and the agent keeps working", function()
  clean(); reset()
  vim.env.SEPAL_SLEEP = "1"
  notified(function()
    send({ "Goal: last window" })
    vim.wait(200)
    vim.cmd("silent! tabonly | silent! only")
    vim.cmd("Sepal open")
    vim.cmd.stopinsert()
    local agent_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_feedkeys("q", "tx", false)
    eq(vim.api.nvim_get_current_buf() ~= agent_buf, true, "q left the agent shown")
    eq(newest().status, "running")
    vim.cmd("Sepal open") -- a toggle: back in, then out again
    eq(vim.api.nvim_get_current_buf(), agent_buf)
    vim.cmd.stopinsert()
    vim.cmd("Sepal open")
    eq(vim.api.nvim_get_current_buf() ~= agent_buf, true, ":Sepal open didn't leave the agent")
    idle()
  end)
end)

test(":Sepal open toggles the agent and its chat when it's the only window of a fresh nvim", function()
  clean(); reset()
  local function fresh() -- one tab, one window, one empty buffer
    vim.cmd("silent! tabonly | silent! only | enew")
  end
  local function toggled(what)
    vim.cmd.stopinsert()
    local shown = vim.api.nvim_get_current_buf()
    eq(vim.b[shown].sepal_agent, true, what .. ": not shown")
    local ok, err = pcall(vim.cmd, "Sepal open")
    eq(ok, true, what .. ": leaving failed: " .. tostring(err))
    eq(vim.b.sepal_agent == true, false, what .. ": still shown after the toggle")
    vim.cmd("Sepal open")
    vim.wait(1000, function() return vim.b.sepal_agent == true end) -- a chat shows once it's printed
    eq(vim.b.sepal_agent, true, what .. ": not shown again")
    vim.cmd.stopinsert()
  end
  vim.env.SEPAL_SLEEP = "1"
  notified(function()
    send({ "Goal: toggled" })
    vim.wait(200)
    fresh()
    vim.cmd("Sepal open")
    toggled("running agent")
    vim.cmd("Sepal open") -- hidden: it finishes on its own
    idle()
  end)
  fresh()
  vim.cmd("Sepal open") -- done: its chat, a spinner until it's printed
  eq({ vim.b.sepal_agent, vim.bo.buftype }, { true, "nofile" }, "no loading float")
  vim.wait(1000, function() return vim.bo.buftype == "terminal" end)
  local chat = vim.api.nvim_get_current_buf()
  eq(vim.bo.buftype, "terminal", "the chat didn't show")
  toggled("chat")
  eq(vim.api.nvim_get_current_buf(), chat, "toggling the chat started another one")
  vim.cmd("enew!") -- hidden any other way, it keeps going too
  vim.wait(50)
  eq(vim.api.nvim_buf_is_valid(chat), true, "hiding the chat ended it")
  notified(function() vim.cmd("Sepal stop") end) -- only stopping ends it
  eq(vim.api.nvim_buf_is_valid(chat), false, ":Sepal stop left the chat running")
  local leaked = vim.tbl_filter(function(b) return vim.api.nvim_buf_get_name(b):match("^term://.*/state/") end, vim.api.nvim_list_bufs())
  eq(#leaked, 0, "renamed agent terminals left their old names behind")
end)

test("while its worktree is being made, :Sepal open says so and :Sepal stop stops it cleanly", function()
  clean(); reset()
  vim.env.SEPAL_EDIT = [[echo late > a.txt]]
  local got = notified(function()
    send({ "Goal: early" }) -- the worktree is made in the background: nothing has run yet
    eq(newest().status, "running")
    vim.cmd("Sepal open")
    vim.cmd("Sepal stop")
    idle()
  end)
  eq(msgs(got), { "working on it: early · :Sepal open watches", "it's starting: making its worktree", "stopped: early" })
  eq(newest().status, "stopped")
  eq(file("a.txt"), "one\ntwo\nthree\n")
  eq(vim.fn.glob(vim.fs.joinpath(T, "state", inbox.key(work), newest().id)), "", "its worktree was left behind")
  eq(read(T .. "/prompts"), nil, "the agent ran")
end)

test(":Sepal open shows the agent at work, and the chat once it's done", function()
  clean(); reset()
  vim.env.SEPAL_SLEEP = "0.5"
  notified(function()
    send({ "Goal: watched" })
    vim.wait(200)
    vim.cmd("Sepal open")
    eq({ vim.bo.buftype, vim.api.nvim_buf_get_name(0) }, { "terminal", "sepal://" .. newest().id })
    eq(vim.wo.number, false, "line numbers on the agent")
    vim.cmd.stopinsert()
    idle()
  end)
  eq(#vim.api.nvim_list_tabpages(), 1, "the agent's tab stayed open")
  eq(vim.b.sepal_agent, true, "watching it to its end took you out of it") -- its chat comes up in the same float
  eq(vim.bo.buftype, "terminal", "a spinner instead of the agent's last screen")
  local id = newest().id
  vim.wait(4000, function() return #args() == 2 and vim.api.nvim_buf_get_name(0) ~= "sepal://" .. id end)
  eq({ vim.bo.buftype, args()[2], vim.split(vim.trim(read(T .. "/cwd")), "\n")[2] }, { "terminal", "--resume", work })
  eq(vim.wo.number, false, "line numbers on the chat")
  vim.cmd.stopinsert()
  vim.cmd("bwipeout!")
end)

test("a task that ends while you're elsewhere doesn't open its chat", function()
  clean(); reset()
  vim.env.SEPAL_SLEEP = "0.3"
  notified(function()
    send({ "Goal: unseen" })
    idle()
  end)
  eq(vim.b.sepal_agent == true, false, "never opened, its chat opened")
  notified(function()
    send({ "Goal: left", "Done when: sleep 0.5" })
    vim.wait(100)
    vim.cmd("Sepal open")
    vim.cmd.stopinsert()
    vim.wait(2000, function() return newest().status == "checking" end)
    vim.cmd("enew") -- left the spinner during the check, still in its float
    idle()
  end)
  eq(vim.b.sepal_agent == true, false, "left during the check, its chat opened")
  vim.cmd("silent! only")
end)

test(":Sepal clean drops the tasks that are over", function()
  notified(function() vim.cmd("Sepal clean") end)
  eq(inbox.list(work), {})
  -- the refs go with a background for-each-ref + update-ref
  assert(vim.wait(10000, function() return sh("git for-each-ref refs/sepal").stdout == "" end, 20), "refs left behind")
end)

test("assumptions are read from the end of a reply", function()
  eq(agent.assumptions("ok\n\n**Assumptions:**\n- a\n* b\n\nthe end"), { "a", "b" })
  eq(agent.assumptions("ok\nAssumptions: none"), {})
  eq(agent.assumptions("ok\nAssumptions: the cache is per user"), { "the cache is per user" })
  eq(agent.assumptions("no list"), {})
end)

test("a reply is read from the transcript's end, past a line that spans a read chunk", function()
  local reply_of = agent._t.reply_of
  local early = '{"type":"assistant","message":{"content":[{"type":"text","text":"early"}]}}'
  local function user() return '{"type":"user","message":{"content":"' .. string.rep("u", 1024) .. '"}}' end
  local function tr(lines)
    local p = vim.fn.tempname()
    local f = assert(io.open(p, "w"))
    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
    return p
  end
  local big = string.rep("b", 100 * 1024) -- wider than a read chunk: it takes a retry to see it whole
  local lines = { early }
  for _ = 1, 200 do lines[#lines + 1] = user() end
  lines[#lines + 1] = '{"type":"assistant","message":{"content":[{"type":"text","text":"' .. big .. '"}]}}'
  lines[#lines + 1] = user()
  eq(reply_of({ transcript_path = tr(lines) }), big)
  table.remove(lines, #lines - 1) -- only the early assistant line, ~200KB of user lines before the end
  table.remove(lines, #lines)
  eq(reply_of({ transcript_path = tr(lines) }), "early")
  eq(reply_of({ last_assistant_message = "from the hook", transcript_path = tr(lines) }), "from the hook")
end)

test("a tool call's activity is its name and first string field: a Bash command counts", function()
  local about = agent._t.about
  eq(about({ name = "Bash", input = { command = "make test", description = "run tests" } }, work), "Bash make test")
  eq(about({ name = "Task", input = { description = "explore" } }, work), "Task explore")
  eq(about({ name = "Edit", input = { file_path = work .. "/a.txt" } }, work), "Edit a.txt")
  eq(about({ name = "Read", input = {} }, work), "Read")
end)

test("a removed worktree's path is free at once; the checkout and git's record of it go in the background", function()
  local git, wt = require("sepal.git"), vim.fs.joinpath(T, "wt-rm")
  local made
  git.add_worktree(work, wt, "HEAD", function(ok) made = ok end)
  assert(vim.wait(10000, function() return made ~= nil end, 10) and made, "no worktree")
  git.remove_worktree(work, wt)
  eq(vim.uv.fs_stat(wt), nil)
  assert(vim.wait(5000, function()
    return #vim.fn.glob(wt .. ".old-*", true, true) == 0 and not sh("git worktree list").stdout:find("wt-rm", 1, true) and true
  end, 20), "the old checkout or its record is still there")
end)

test(":Sepal completes subcommands", function()
  eq(vim.fn.getcompletion("Sepal s", "cmdline"), { "stop" })
end)

test("checkhealth runs", function() require("sepal.health").check() end)

local suggest = { "sh", "-c", [[sleep 0.2; printf '```\nScope: from the idea\n'; sed 's/^/- got: /'; printf '```\n']] }

test("with task_sharpen a short feat keeps its fields; a large feat starts as the idea", function()
  sepal.setup({ task_sharpen = suggest })
  sepal.task()
  eq(vim.api.nvim_buf_get_lines(task_buf(), 0, 3, false), { "Goal: ", "", "Done when: " })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-k>"), "tx", false)
  sepal.task(nil, nil, "orchestrate")
  local b = task_buf()
  eq(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "", "", "Files:" })
  vim.api.nvim_buf_set_lines(b, 0, 1, false, { "graceful shutdown" })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-s>"), "tx", false)
  assert(vim.wait(5000, function() return vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] == "Scope: from the idea" end, 20), "task not written")
  -- the idea went as written: no sharpen prompt for a large feat
  eq(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "Scope: from the idea", "- got: graceful shutdown", "- got: ", "- got: Files:" })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-k>"), "tx", false)
end)

test("<c-c><c-s> shows a spinner in the task's keys while it sharpens", function()
  local function top(b)
    local m = vim.api.nvim_buf_get_extmarks(b, -1, 0, 0, { details = true, type = "virt_lines" })[1]
    return table.concat(vim.tbl_map(function(c) return c[1] end, m[4].virt_lines[1]))
  end
  sepal.task(nil, { "Goal: retry flaky uploads", "", "Constraints:", "- ", "", "Done when: ", "", "Files:", "- @a.lua" })
  local b = task_buf()
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-s>"), "tx", false)
  assert(top(b):find("sharpening the task…", 1, true), top(b))
  local first = top(b)
  assert(vim.wait(1000, function() return top(b) ~= first end, 20), "the spinner doesn't turn")
  assert(vim.wait(5000, function() return vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] == "Scope: from the idea" end, 20), "not sharpened")
  assert(not top(b):find("sharpening", 1, true), top(b))
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-k>"), "tx", false)
end)

test("<c-c><c-s> sharpens a short feat's filled-in fields; a large feat's goes as written", function()
  sepal.task(nil, { "Goal: retry flaky uploads", "", "Constraints:", "- ", "", "Done when: ", "", "Files:", "- @a.lua" })
  local b = task_buf()
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-s>"), "tx", false)
  assert(vim.wait(5000, function() return vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] == "Scope: from the idea" end, 20), "not sharpened")
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  eq(vim.list_slice(got, #got - 4), { "- got: keeping Done when: and Files: unless wrong; no code fences, no filler. The task:",
    "- got: Goal: retry flaky uploads", "- got: ", "- got: Files:" , "- got: - @a.lua" })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-k>"), "tx", false)
  sepal.task(nil, { "big idea", "", "Files:" }, "orchestrate")
  b = task_buf()
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-s>"), "tx", false)
  assert(vim.wait(5000, function() return vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] == "Scope: from the idea" end, 20), "not written")
  eq(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "Scope: from the idea", "- got: big idea", "- got: ", "- got: Files:" })
  vim.api.nvim_buf_delete(b, { force = true })
end)

test("an empty idea line shows a hint that goes away when you type", function()
  local ns = vim.api.nvim_create_namespace("sepal.hint")
  local function marks(b) return #vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, {}) end
  sepal.task() -- a short feat keeps its fields: no hint, and "Goal: " is not the idea line
  eq(marks(task_buf()), 0)
  eq(vim.api.nvim_buf_get_lines(task_buf(), 0, 1, false), { "Goal: " })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-k>"), "tx", false)
  sepal.task(nil, nil, "orchestrate")
  local b = task_buf()
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
  sepal.config().task_sharpen = nil -- setup({ task_sharpen = nil }) is a no-op: nil keys vanish
  sepal.task()
  eq(marks(task_buf()), 0)
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-k>"), "tx", false)
  sepal.setup({ task_sharpen = suggest })
end)

test("<c-c><c-s> keeps what you typed while it was writing", function()
  sepal.task()
  local b = task_buf()
  vim.api.nvim_buf_set_lines(b, 0, 1, false, { "Goal: idea" })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-s>"), "tx", false)
  vim.api.nvim_buf_set_lines(b, 0, 1, false, { "Goal: idea, edited" })
  vim.wait(1500)
  eq(vim.api.nvim_buf_get_lines(b, 0, 1, false), { "Goal: idea, edited" })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-k>"), "tx", false)
end)

test("<c-c><c-s> with a failing task_sharpen leaves the buffer as it was", function()
  sepal.setup({ task_sharpen = { "sh", "-c", "echo boom >&2; exit 3" } })
  sepal.task()
  local b = task_buf()
  vim.api.nvim_buf_set_lines(b, 0, 1, false, { "Goal: idea" })
  local got = {}
  local notify = vim.notify
  vim.notify = function(msg) got[#got + 1] = msg end
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-s>"), "tx", false)
  local ok = vim.wait(3000, function() return #got > 0 end, 20)
  vim.notify = notify
  assert(ok, "no error")
  eq(got, { "task_sharpen failed (exit 3)\nboom" })
  eq(vim.api.nvim_buf_get_lines(b, 0, 1, false), { "Goal: idea" })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-k>"), "tx", false)
  sepal.config().task_sharpen = nil -- setup({ task_sharpen = nil }) is a no-op: nil keys vanish
end)

test("task <c-c><c-k> discards it", function()
  sepal.task()
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-k>"), "tx", false)
  eq(task_buf(), nil)
end)

test("fidget's window hides while the panel is open: the panel shows the same", function()
  local got = {}
  package.loaded["fidget.notification"] = { suppress = function(v) got[#got + 1] = v end }
  vim.cmd("Sepal panel")
  vim.cmd("Sepal panel")
  package.loaded["fidget.notification"] = nil
  eq(got, { true, false })
end)

test("fidget's window hides inside the inbox", function()
  local got = {}
  package.loaded["fidget.notification"] = { suppress = function(v) got[#got + 1] = v end }
  vim.cmd("Sepal inbox")
  require("sepal").fidget()
  vim.cmd("enew")
  require("sepal").fidget()
  package.loaded["fidget.notification"] = nil
  eq(got, { true, false })
end)

test("notify: info goes to fidget, warnings to vim.notify", function()
  local got = {}
  package.loaded.fidget = { notify = function(msg, lvl, o) got[#got + 1] = { "fidget", msg, lvl, o.annote } end }
  local notify = vim.notify
  vim.notify = function(msg, lvl, o) got[#got + 1] = { "notify", msg, lvl, o.title } end -- a notifier plugin
  sepal.notify("task sent")
  sepal.notify("the task is empty", vim.log.levels.WARN)
  vim.notify, package.loaded.fidget = notify, nil
  eq(got, { { "fidget", "task sent", vim.log.levels.INFO, "sepal" }, { "notify", "the task is empty", vim.log.levels.WARN, "sepal" } })
end)

test("auto_mode: every run in Claude Code's auto mode, instead of args' permission mode", function()
  clean(); reset()
  sepal.config().auto_mode = true
  run({ "Goal: shout two" })
  sepal.config().auto_mode = false
  eq(args(), { "--permission-mode auto" })
end)

test("notify: held while in the agent, shown once you leave it", function()
  local got, notify = {}, vim.notify
  vim.notify = function(msg) got[#got + 1] = msg end -- a notifier plugin
  local back = vim.api.nvim_get_current_buf()
  local b = vim.api.nvim_create_buf(false, true)
  vim.b[b].sepal_agent = true
  vim.api.nvim_set_current_buf(b)
  sepal.notify("one")
  sepal.notify("two", vim.log.levels.WARN)
  eq(got, {})
  vim.api.nvim_set_current_buf(back)
  vim.notify = notify
  vim.api.nvim_buf_delete(b, { force = true })
  eq(got, { "one", "two" })
end)

test("notify: the builtin vim.notify gets a colored echo", function()
  vim.cmd.messages("clear")
  sepal.notify("the agent is the only window", vim.log.levels.WARN)
  eq(vim.trim(vim.fn.execute("messages")), "▲ sepal the agent is the only window")
end)

test("a task shows its keys on top, like the inbox", function()
  local function help() -- the wrapped lines joined back, from the first key (past who works on it)
    local m = vim.api.nvim_buf_get_extmarks(0, -1, 0, 0, { details = true, type = "virt_lines" })[1]
    local text = table.concat(vim.tbl_map(function(l)
      return table.concat(vim.tbl_map(function(c) return c[1] end, l))
    end, vim.tbl_filter(function(l) return l[1][1] ~= "" end, m[4].virt_lines)), "  ")
    return { m[2], text:match("<c%-c>.*"), vim.fn.winsaveview().topfill == #m[4].virt_lines }
  end
  sepal.task()
  local a = help()
  sepal.config().task_sharpen = suggest
  sepal.task() -- the draft again
  local b = help()
  sepal.config().task_sharpen = nil
  vim.api.nvim_buf_delete(task_buf(), { force = true })
  eq({ a, b }, { { 0, "<c-c><c-c> send  <c-c><c-w> wait  <c-c><c-o> model  <c-c><c-f> file  <c-c><c-p> image  <c-c><c-k> discard", true },
    { 0, "<c-c><c-c> send  <c-c><c-w> wait  <c-c><c-s> sharpen  <c-c><c-o> model  <c-c><c-f> file  <c-c><c-p> image  <c-c><c-k> discard", true } })
end)

test("a draft in a narrow window wraps its keys into lines that fit", function()
  sepal.config().task_sharpen = suggest
  sepal.task()
  local b = task_buf()
  vim.cmd("vsplit")
  vim.api.nvim_win_set_width(0, 40)
  vim.api.nvim_exec_autocmds("WinResized", {})
  local m = vim.api.nvim_buf_get_extmarks(b, -1, 0, 0, { details = true, type = "virt_lines" })[1]
  local lines = vim.tbl_map(function(l)
    return table.concat(vim.tbl_map(function(c) return c[1] end, l))
  end, vim.tbl_filter(function(l) return l[1][1] ~= "" end, m[4].virt_lines))
  local width = math.huge -- the narrowest window's text width, as keys() measures it
  for _, w in ipairs(vim.fn.win_findbuf(b)) do
    width = math.min(width, vim.api.nvim_win_get_width(w) - vim.fn.getwininfo(w)[1].textoff)
  end
  assert(#lines > 1, "the keys did not wrap")
  for _, s in ipairs(lines) do assert(vim.fn.strdisplaywidth(s) <= width, s) end
  local joined = table.concat(lines, "  ")
  for _, k in ipairs({ "<c-c><c-c> send", "<c-c><c-w> wait", "<c-c><c-s> sharpen",
    "<c-c><c-o> model", "<c-c><c-f> file", "<c-c><c-p> image", "<c-c><c-k> discard" }) do
    assert(joined:find(k, 1, true), k .. " was cut off")
  end
  eq(vim.fn.winsaveview().topfill, #m[4].virt_lines)
  vim.api.nvim_buf_delete(b, { force = true })
  vim.cmd("silent! only")
  sepal.config().task_sharpen = nil
end)

test("<c-c><c-o> picks the model a draft runs on, from the list or typed", function()
  clean(); reset()
  sepal.setup({ models = {} })
  sepal.task()
  local function who()
    local m = vim.api.nvim_buf_get_extmarks(task_buf(), -1, 0, 0, { details = true, type = "virt_lines" })[1]
    local l = m[4].virt_lines[1]
    return { l[1][1], l[1][2], l[2][1] }
  end
  local shots = picker_shots({ "1" })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-o>"), "tx", false)
  eq(#shots, 1)
  eq(shots[1].lines, { "  1  ✻ sonnet", "", "  d    default  ●", "  o    other…" })
  eq(shots[1].title, "sepal · short feat model")
  picker_closed(shots[1])
  eq(who(), { "✻", "SepalClaude", " sonnet" })
  vim.env.SEPAL_EDIT = [[echo x > a.txt]]
  vim.api.nvim_buf_set_lines(task_buf(), 0, -1, false, { "Goal: modelled" })
  notified(function()
    vim.api.nvim_feedkeys(vim.keycode("<c-c><c-c>"), "tx", false)
    idle()
  end)
  assert(args()[1]:find("--model sonnet", 1, true), args()[1])
  eq(newest().agent.model, "sonnet")
  sepal.task()
  shots = picker_shots({ "o" })
  local input = vim.ui.input
  vim.ui.input = function(opts, cb)
    eq(opts.prompt, "model: ")
    cb("haiku")
  end
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-o>"), "tx", false)
  vim.ui.input = input
  eq(who()[3], " haiku")
  vim.api.nvim_buf_delete(task_buf(), { force = true })
end)

test("<c-c><c-p> pastes the clipboard's image, the agent may read just that", function()
  clean(); reset()
  local bin = vim.fs.joinpath(T, "bin")
  vim.fn.mkdir(bin, "p")
  vim.fn.writefile({ "#!/bin/sh", "printf png" }, vim.fs.joinpath(bin, "wl-paste"))
  vim.fn.setfperm(vim.fs.joinpath(bin, "wl-paste"), "rwxr-xr-x")
  local path, wl = vim.env.PATH, vim.env.WAYLAND_DISPLAY
  vim.env.PATH, vim.env.WAYLAND_DISPLAY = bin .. ":" .. path, "t"
  sepal.task()
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-p>"), "tx", false)
  vim.env.PATH, vim.env.WAYLAND_DISPLAY = path, wl
  local lines = vim.api.nvim_buf_get_lines(task_buf(), 0, -1, false)
  local img = lines[#lines]:match("^%- @(.*paste%-%d+%.png)$")
  assert(img, lines[#lines])
  eq(vim.fn.readfile(img, "b"), { "png" })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-k>"), "tx", false)
  run({ "Goal: match the mockup", "", "Files:", "- @" .. img, "- @a.txt" })
  eq(args()[1], "--permission-mode acceptEdits --allowedTools Read(/" .. img .. ")")
  -- a discarded draft's image, over a day old, goes on the next paste; the task's stays until it's dropped
  local old = vim.fs.joinpath(agent.PASTES, "paste-1.png")
  vim.fn.writefile({ "png" }, old)
  vim.uv.fs_utime(old, os.time() - 2 * 86400, os.time() - 2 * 86400)
  vim.uv.fs_utime(img, os.time() - 2 * 86400, os.time() - 2 * 86400)
  agent.sweep_pastes()
  eq({ vim.uv.fs_stat(old) == nil, vim.uv.fs_stat(img) ~= nil }, { true, true })
  -- and its chat in Claude Code's folder, with the project dir it leaves empty; another chat stays
  local proj = vim.fs.joinpath(vim.env.CLAUDE_CONFIG_DIR, "projects", "-wt")
  vim.fn.mkdir(vim.fs.joinpath(proj, newest().session, "subagents"), "p")
  vim.fn.writefile({}, vim.fs.joinpath(proj, newest().session .. ".jsonl"))
  local other = vim.fs.joinpath(vim.env.CLAUDE_CONFIG_DIR, "projects", "-repo", "other.jsonl")
  vim.fn.mkdir(vim.fs.dirname(other), "p"); vim.fn.writefile({}, other)
  agent.drop(newest())
  eq(vim.uv.fs_stat(img), nil)
  eq({ vim.uv.fs_stat(proj) == nil, vim.uv.fs_stat(other) ~= nil }, { true, true })
end)

test("task opens the template above, <c-c><c-f> adds files with fff", function()
  sepal.task()
  local b = task_buf()
  eq(vim.api.nvim_get_current_buf(), b)
  eq(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "Goal: ", "", "Done when: ", "", "Files:" })
  package.loaded.fff = { find_files = function(o) o.on_submit({}, { relative_path = "src/pool.cpp" }) end }
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-f>"), "tx", false)
  package.loaded.fff.find_files = function(o) o.on_submit({}, { relative_path = "src/pool.h" }) end
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-f>"), "tx", false)
  package.loaded.fff = nil
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  eq(vim.list_slice(lines, #lines - 2), { "Files:", "- @src/pool.cpp", "- @src/pool.h" })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-k>"), "tx", false)
end)

test("a new task's Done when: is the project's test command, found and said so; dd sends no check", function()
  put("AGENTS.md", "# x\n\n- Tests: `grep -q one a.txt` from the repo root\n")
  sepal.task()
  local b = task_buf()
  eq(vim.api.nvim_buf_get_lines(b, 2, 3, false), { "Done when: grep -q one a.txt" })
  local hint = vim.api.nvim_buf_get_extmarks(b, vim.api.nvim_create_namespace("sepal.check"), 0, -1, { details = true })[1]
  local text = table.concat(vim.tbl_map(function(c) return c[1] end, hint[4].virt_text))
  eq({ hint[2], text }, { 2, "  ✔ green lands  ✘ red goes back to the agent  · found in AGENTS.md, dd: no check" })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-k>"), "tx", false)
  os.remove(vim.fs.joinpath(work, "AGENTS.md"))
  put("Makefile", "all:\n\ttrue\ntest:\n\ttrue\n")
  eq({ sepal.find_check(work) }, { "make test", "Makefile" })
  os.remove(vim.fs.joinpath(work, "Makefile"))
  eq(sepal.find_check(work), nil)
  reset()
  local got = run({ "Goal: no check", "" }) -- the line deleted
  eq(newest().check, nil)
  eq(got[1], "working on it: no check · :Sepal open watches")
  clean()
end)

test("status: what's running, ready and needs you, for the statusline; User SepalChanged only when it moves", function()
  reset()
  clean()
  eq(sepal.status(), "")
  local renders, events = 0, 0
  local panel = require("sepal.panel")
  local prender = panel.render
  panel.render = function(...) renders = renders + 1; return prender(...) end -- draw calls it each render
  local au = vim.api.nvim_create_autocmd("User", { pattern = "SepalChanged", callback = function() events = events + 1 end })
  vim.env.SEPAL_SUB, vim.env.SEPAL_SLEEP = "1", "0.3"
  vim.env.SEPAL_EDIT = [[printf 'one\nTWO\nthree\n' > a.txt]]
  local seen = {}
  notified(function()
    send({ "Goal: count me" }, "<c-c><c-w>")
    vim.wait(5000, function() seen[sepal.status()] = true; return next(agent._t.jobs) == nil end, 5)
    idle()
  end)
  vim.api.nvim_del_autocmd(au)
  panel.render = prender
  eq(seen["~1"], true, vim.inspect(seen))
  eq(sepal.status(), "●1")
  print(("  measured: %d renders, %d SepalChanged"):format(renders, events))
  assert(events < renders and events <= 4, events .. " events for " .. renders .. " renders")
  newest().status = "needs"
  inbox.changed(newest())
  eq(sepal.status(), "▲1")
  clean()
  eq(sepal.status(), "")
end)

test(":'<,'>Sepal task puts the selected lines in the task and lists the file", function()
  sepal.config().task_sharpen = nil
  vim.cmd.edit("tests/pool.lua")
  vim.bo.filetype = "lua"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local a = 1", "local b = a", "-", "return b" })
  key("s")
  vim.cmd("2,3Sepal task")
  local b = task_buf()
  eq(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "Goal: ", "", "Done when: ", "",
    "Selection: tests/pool.lua:2-3", "```lua", "local b = a", "-", "```", "", "Files:", "- @tests/pool.lua" })
end)

test("a selection joins the open draft, its file listed once", function()
  vim.cmd.wincmd("j")
  vim.cmd("4Sepal task")
  local lines = vim.api.nvim_buf_get_lines(task_buf(), 0, -1, false)
  eq(vim.list_slice(lines, 11), { "Selection: tests/pool.lua:4", "```lua", "return b", "```", "", "Files:", "- @tests/pool.lua" })
end)

test("code in a selection is sent as it is, even a line that is just -", function()
  reset()
  vim.api.nvim_set_current_win(vim.fn.bufwinid(task_buf()))
  vim.api.nvim_buf_set_lines(task_buf(), 0, 1, false, { "Goal: keep the code" })
  notified(function() vim.api.nvim_feedkeys(vim.keycode("<c-c><c-c>"), "tx", false); idle() end)
  local got = vim.split(prompts(), "\n")
  eq(vim.tbl_contains(got, "-"), true, "the - code line was dropped")
  eq(vim.tbl_contains(got, "- "), false, "the empty bullet was sent")
  vim.cmd("bwipeout! tests/pool.lua")
end)

test("<c-c><c-c> sends nothing and says so when the goal or the whole task is empty", function()
  for _, want in ipairs({ "the goal is empty, nothing sent", "the task is empty, nothing sent" }) do
    sepal.task()
    if want:find("goal") then vim.api.nvim_buf_set_lines(task_buf(), 0, -1, false, { "Goal: ", "", "Constraints:", "- small" }) end
    local got = notified(function() vim.api.nvim_feedkeys(vim.keycode("<c-c><c-c>"), "tx", false) end)
    eq(msgs(got), { want })
    assert(task_buf(), "the task buffer was closed")
    vim.api.nvim_buf_delete(task_buf(), { force = true })
  end
  eq(sepal.tidy({ "Goal:", "fix it", "", "Files:" }), { "Goal:", "fix it" }) -- text under a field counts
end)

test("closing the task window drops the draft: :Sepal task starts a new one", function()
  sepal.task()
  vim.api.nvim_buf_set_lines(task_buf(), 0, 1, false, { "Goal: old" })
  vim.cmd.close()
  eq(task_buf(), nil)
  sepal.task()
  eq(vim.api.nvim_buf_get_lines(task_buf(), 0, 1, false), { "Goal: " })
  vim.api.nvim_buf_delete(task_buf(), { force = true })
end)

test("colors: sakura pinks or your theme's links, the highlights option over both; icons", function()
  local function hl(n) return vim.api.nvim_get_hl(0, { name = n }) end
  vim.o.background = "dark"
  eq(hl("SepalTitle").fg, 0xffb6c1)
  eq({ hl("SepalOk").fg, hl("SepalError").fg }, { 0x7ed491, 0xf2777a }) -- states: green and red, whatever the theme
  vim.o.background = "light"
  eq(hl("SepalTitle").fg, 0xc2185b)
  eq(hl("SepalOk").fg, 0x1e8e3e)
  sepal.setup({ sakura = false, highlights = { SepalDim = { fg = "#123456" } }, icons = { running = "~" } })
  eq(hl("SepalTitle").link, "Title")
  eq({ hl("SepalOk").fg, hl("SepalWarn").fg }, { 0x1e8e3e, 0xb26a00 })
  eq(hl("SepalDim").fg, 0x123456)
  eq({ sepal.icon("running", "⋯"), sepal.icon("landed", "✔") }, { "~", "✔" })
  vim.api.nvim_set_hl(0, "SepalTitle", { fg = "#abcdef" }) -- as a colorscheme would
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  sepal.setup({ sakura = false }) -- a setup() after the colorscheme doesn't undo it
  vim.o.background = "light"
  eq(hl("SepalTitle").fg, 0xabcdef)
  vim.o.background = "dark"
  sepal.setup({ sakura = true, highlights = {}, icons = {} })
  eq(sepal.icon("landed", "✔"), "✔")
end)

test("c continues a task nvim quit on: what its worktree had is kept, the agent resumes its chat", function()
  clean(); reset()
  run({ "Goal: quit on" }, "<c-c><c-w>")
  local e = newest()
  -- as after a quit mid-run: interrupted, its worktree left with the agent's half-done work in it
  e.status = "interrupted"
  local wt = vim.fs.joinpath(T, "state", inbox.key(work), e.id)
  sh(("git worktree add -q --detach %q %s && printf 'half\\n' > %q/c.txt"):format(wt, e.base, wt))
  reset()
  local got = msgs(notified(function() agent.resume(e); idle() end))
  eq(vim.endswith(args()[1], "--resume s1"), true)
  assert(vim.startswith(prompts(), "You were interrupted."), prompts())
  eq(e.status, "ready")
  eq(vim.tbl_contains(e.stat.list, "c.txt +1 −0"), true, vim.inspect(e.stat.list))
  eq(got[#got]:match("^● ready"), "● ready")
  eq(msgs(notified(function() agent.resume(e) end)), { "it wasn't cut short: r replies to it" })
end)

test("c preserves unfinished work from a legacy storage directory", function()
  clean(); reset()
  run({ "Goal: legacy worktree" }, "<c-c><c-w>")
  local e = newest()
  e.status = "interrupted"
  local wt = vim.fs.joinpath(T, "state", (work:gsub("[^%w]", "-")), e.id)
  assert(sh(("git worktree add -q --detach %q %s && printf 'half\\n' > %q/c.txt"):format(wt, e.base, wt)).code == 0)
  reset()
  notified(function() agent.resume(e); idle() end)
  eq(e.status, "ready")
  assert(vim.tbl_contains(e.stat.list, "c.txt +1 −0"), "legacy unfinished work was lost")
  eq(vim.uv.fs_stat(wt), nil)
end)

test("c starts over a task that never got its agent going; x keeps what the agent did", function()
  clean(); reset()
  vim.env.SEPAL_FAIL = "start"
  run({ "Goal: never went" })
  local e = newest()
  eq({ e.status, e.session }, { "error", nil })
  reset()
  vim.env.SEPAL_SLEEP = "1"
  notified(function()
    agent.resume(e)
    assert(vim.wait(2000, function() return e.activity ~= nil end, 20), "the agent never started")
    vim.fn.writefile({ "so far" }, vim.fs.joinpath(T, "state", inbox.key(work), e.id, "d.txt")) -- in its worktree, mid-turn
    agent.stop(e)
    idle()
  end)
  eq(vim.endswith(args()[1], "--resume s1"), false)
  assert(vim.startswith(prompts(), "Goal: never went\n"), prompts())
  assert(prompts():find("How to work on this", 1, true), prompts()) -- a new chat: the rules in full
  eq({ e.status, e.stat and e.stat.list }, { "stopped", { "d.txt +1 −0" } })
end)

test(":Sepal task picks the kind: b asks a btw in your repo, read-only, with its model; i implements", function()
  clean(); reset()
  sepal.setup({ max_running = 1 })
  vim.env.SEPAL_SLEEP = "0.5"
  send({ "Goal: hogs the slot" }) -- a btw doesn't wait for it
  vim.env.SEPAL_SLEEP = nil
  local got = msgs(notified(function()
    key("b")
    sepal.pick()
    local b = task_buf()
    eq(vim.b[b].sepal_kind, "btw")
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "how does landing work?" })
    vim.api.nvim_feedkeys(vim.keycode("<c-c><c-c>"), "tx", false)
    idle()
  end))
  local e = newest()
  eq({ e.kind, e.status, e.answer, e.check }, { "btw", "answered", "Did it.\n\nAssumptions:\n- kept the old API\n- no new deps", nil })
  eq(got[1], "asking: how does landing work? · :Sepal open watches")
  assert(vim.tbl_contains(got, "● how does landing work?: Did it. · <CR> in :Sepal inbox reads it"), vim.inspect(got))
  -- plan: Claude Code's read-only mode; it started first: the other was still making its worktree
  eq(args()[1], "--permission-mode plan --model sonnet")
  eq(vim.split(vim.trim(read(T .. "/cwd")), "\n")[1], work) -- your repo itself, no worktree
  eq(vim.uv.fs_stat(work) ~= nil and file("a.txt"), "one\ntwo\nthree\n")
  sepal.setup({ max_running = 2 })
  assert(prompts():find("not a change", 1, true), prompts())
  agent.show(e)
  eq({ vim.bo.filetype, vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] }, { "markdown", "Did it." })
  vim.cmd("tabclose")
  -- yyp + :w: the answer becomes the context of an implement draft; copying a task too opens its
  -- draft once that one is discarded
  vim.cmd("Sepal inbox")
  local ib = vim.api.nvim_get_current_buf()
  local function copy(id)
    for r = 1, vim.api.nvim_buf_line_count(ib) do
      vim.api.nvim_win_set_cursor(0, { r, 0 })
      if (inbox.current() or {}).id == id then break end
    end
    eq(inbox.current().id, id)
    vim.cmd("normal yyp")
  end
  local hog = vim.iter(inbox.list(work)):find(function(x) return x.task == "Goal: hogs the slot" end)
  copy(e.id)
  copy(hog.id)
  eq(msgs(notified(function() vim.cmd("write") end))[1], "2 copies: each opens its draft once the one before is sent or discarded")
  assert(vim.wait(1000, function() return task_buf() ~= nil end, 10), "no draft opened")
  local d = task_buf()
  eq(vim.b[d].sepal_kind, "implement")
  local l = vim.api.nvim_buf_get_lines(d, 0, -1, false)
  eq({ l[1], l[5], l[6], l[8], l[9], l[#l] }, { "Goal: ", "Asked:", "how does landing work?", "Answer:", "Did it.", "Files:" })
  picker_shots({ "1" })
  vim.api.nvim_feedkeys(vim.keycode("<c-c><c-o>"), "tx", false)
  local wm = vim.api.nvim_buf_get_extmarks(d, -1, 0, 0, { details = true, type = "virt_lines" })[1]
  eq(wm[4].virt_lines[1][2][1], " sonnet")
  vim.api.nvim_buf_delete(d, { force = true })
  assert(vim.wait(1000, function() return task_buf() ~= nil end, 10), "the second copy's draft never opened")
  eq(vim.api.nvim_buf_get_lines(task_buf(), 0, -1, false), { "Goal: hogs the slot" })
  vim.api.nvim_buf_delete(task_buf(), { force = true })
  clean(); reset()
  sepal.setup({ models = { implement = "opus" } })
  eq(sepal.config().models.btw, "sonnet") -- setting one keeps the other's default
  vim.env.SEPAL_EDIT = [[echo x > a.txt]]
  notified(function()
    key("s")
    sepal.pick()
    vim.api.nvim_buf_set_lines(task_buf(), 0, -1, false, { "Goal: implemented" })
    vim.api.nvim_feedkeys(vim.keycode("<c-c><c-c>"), "tx", false)
    idle()
  end)
  eq({ newest().status, args() }, { "landed", { "--permission-mode acceptEdits --model opus" } })
  sepal.setup({ models = {} })
  notified(function() key("x"); sepal.pick() end) -- any other key: no draft
  eq(task_buf(), nil)
end)

test("a plan is read from the end of an orchestrate's reply: each task, its model, its text", function()
  local plan = agent.plan(table.concat({ "Let me plan.", "", "**Plan:**", "1. [opus] **Shout two**", "   Goal: upper case line two",
    "   Done when: `grep -q TWO a.txt`", "", "   Files:", "   - @a.txt", "2. [default] add b", "- [ Haiku ] docs", "   Constraints:",
    "   - short", "", "Assumptions:", "- none really" }, "\n"))
  eq(plan, {
    { title = "Shout two", model = "opus", task = "Goal: upper case line two\nDone when: grep -q TWO a.txt\n\nFiles:\n- @a.txt" },
    { title = "add b", task = "Goal: add b" },
    { title = "docs", model = "Haiku", task = "Goal: docs\nConstraints:\n- short" },
  })
  eq(agent.plan("no plan here"), {})
  eq(agent.plan_summary(plan), "3 tasks: 1 opus, 1 default, 1 Haiku")
  local e = { check = "make test", plan = plan }
  eq(agent.subtask(e, 1), plan[1].task .. "\n\nPart of a plan, task 1 of 3 (the others run in parallel: do only this one):"
    .. "\n1. Shout two\n2. add b\n3. docs")
  eq(vim.split(agent.subtask(e, 2), "\n")[3], "Done when: make test") -- the orchestrate's check when it has none
end)

test("the orchestrate demo's self-check passes (tests/demo.lua, when it is there)", function()
  local root = vim.opt.rtp:get()[1] -- the repo root; cwd is a temp dir by now
  local demo = vim.fs.joinpath(root, "tests/demo.lua")
  if not vim.uv.fs_stat(demo) then
    print("skip: tests/demo.lua not found")
    return
  end
  local r = vim.system({ vim.v.progpath, "--headless", "-u", demo }, { cwd = root, env = { SEPAL_DEMO_CHECK = "1" }, text = true }):wait(60000)
  assert(r.code == 0, ("demo self-check exited %d\nstdout:\n%s\nstderr:\n%s"):format(r.code, r.stdout or "", r.stderr or ""))
end)

test("l (large feat) orchestrates: the agent plans the tasks and their models; edit them in the inbox, s starts each with its model", function()
  clean(); reset()
  local cmd = sepal.config().cmd
  sepal.config().agents = { { cmd = cmd, name = "claude" }, { cmd = cmd, model = "opus", name = "lead" },
    { cmd = cmd, model = "sonnet", name = "review" }, { cmd = cmd, model = "haiku" } }
  local reply = vim.fs.joinpath(T, "plan.jsonl")
  vim.fn.writefile({ vim.json.encode({ type = "assistant", message = { content = { { type = "text", text = table.concat({
    "Two parts.", "", "Plan:", "1. [opus] Shout two", "   Goal: upper case line two", "   Done when: `test -n ok`",
    "   Files:", "   - @a.txt", "2. [haiku] Add b", "   Goal: add b.txt", "", "Assumptions:", "- two tasks are enough" }, "\n") } } } }) }, reply)
  vim.env.SEPAL_REPLY = reply
  local got = msgs(notified(function()
    key("l", "1")
    sepal.pick()
    eq(vim.b[task_buf()].sepal_kind, "orchestrate")
    vim.api.nvim_buf_set_lines(task_buf(), 0, -1, false, { "Goal: shout and add", "", "Done when: true" })
    vim.api.nvim_feedkeys(vim.keycode("<c-c><c-c>"), "tx", false)
    idle()
  end))
  local e = newest()
  eq(got, { "planning: shout and add · its tasks wait in :Sepal inbox, s starts them",
    "◇ plan ready: shout and add · 2 tasks: 1 opus, 1 haiku · s in :Sepal inbox makes the tasks, m sets a model" })
  eq({ e.kind, e.status, e.check, e.assumptions }, { "orchestrate", "planned", "true", { "two tasks are enough" } })
  eq(vim.tbl_map(function(p) return { p.title, p.model } end, e.plan), { { "Shout two", "opus" }, { "Add b", "haiku" } })
  eq(args(), { "--permission-mode plan --allowedTools Bash(true)" }) -- read-only, in your repo
  eq(vim.split(vim.trim(read(T .. "/cwd")), "\n")[1], work)
  assert(prompts():find("only from these: opus, sonnet, haiku (or default", 1, true), prompts())
  eq(sepal.status(), "●1") -- waits for you, like a task ready to land
  vim.cmd("Sepal panel")
  local pl = vim.api.nvim_buf_get_lines(vim.fn.bufnr("sepal://panel"), 0, -1, false)
  assert(vim.tbl_contains(pl, " ▎ 1. [opus] Shout two") and vim.tbl_contains(pl, " ▎ 2. [haiku] Add b"), vim.inspect(pl))
  vim.cmd("Sepal panel")
  -- the inbox: the plan unfolded under it; the [model] edited in place and :w, or m
  vim.cmd("Sepal inbox")
  local b = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(lines[3]:match("^◇ planned%s+now%s+shout and add"), lines[3])
  eq(vim.list_slice(lines, 4, 5), { "    1. [opus] Shout two", "    2. [haiku] Add b" })
  eq(vim.fn.foldclosed(3), -1)
  vim.api.nvim_buf_set_lines(b, 4, 5, false, { "    2. [sonnet] Add b" })
  vim.cmd("write")
  eq(e.plan[2].model, "sonnet")
  eq(vim.api.nvim_buf_get_lines(b, 4, 5, false), { "    2. [sonnet] Add b" })
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  local shots = picker_shots({ "q" })
  vim.cmd("normal m")
  eq(#shots, 1)
  eq(shots[1].lines, { "  1  ✻ lead     opus  ●", "  2  ✻ review   sonnet", "  3  ✻ haiku", "", "  d    default", "  o    other…" })
  eq({ shots[1].title, shots[1].config.relative }, { "sepal · task 1 model", "" })
  eq(shots[1].wrap, false)
  eq(vim.tbl_contains(marked_texts(shots[1], 0, "SepalAccent"), "1"), true)
  eq(vim.tbl_contains(marked_texts(shots[1], 0, "SepalDim"), "opus"), true)
  eq(#marked_texts(shots[1], 3), 0) -- the separator has no highlights
  picker_closed(shots[1])
  eq({ vim.api.nvim_get_current_buf(), e.plan[1].model }, { b, "opus" }) -- cancelled
  picker_shots({ "d" })
  vim.cmd("normal m")
  eq(vim.api.nvim_get_current_buf(), b)
  eq(e.plan[1].model, nil)
  eq(vim.api.nvim_buf_get_lines(b, 3, 4, false), { "    1. [default] Shout two" })
  shots = picker_shots({ "q" })
  vim.cmd("normal m")
  eq(shots[1].lines[1], "  1  ✻ lead     opus")
  eq(shots[1].lines[5], "  d    default  ●")
  picker_closed(shots[1])
  -- s: one task per item, each with its model, one snapshot of your work tree for all of them
  reset()
  vim.env.SEPAL_EDIT = [[echo x > "$(basename "$PWD").txt"]]
  got = msgs(notified(function()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.cmd("normal s")
    idle()
  end))
  vim.cmd("close")
  eq(got[1], "swarm: shout and add · 2 tasks: 1 default, 1 sonnet started")
  eq({ e.status, #e.swarm }, { "swarmed", 2 })
  local l = inbox.list(work)
  eq(vim.tbl_map(function(x) return { x.title, x.status, x.check } end, vim.list_slice(l, 1, 2)),
    { { "upper case line two", "landed", "test -n ok" }, { "add b.txt", "landed", "true" } })
  eq(l[1].base0, l[2].base0) -- one snapshot (base moves on when a task lands)
  local a = args()
  table.sort(a)
  eq(a, { "--permission-mode acceptEdits --allowedTools Bash(test -n ok)", "--permission-mode acceptEdits --model sonnet --allowedTools Bash(true)" })
  assert(prompts():find("Part of a plan, task 2 of 2", 1, true), prompts())
  eq(msgs(notified(function() agent.swarm(e) end)), { "already swarmed: its tasks are in the inbox" })
  sepal.clean()
  eq(#inbox.list(work), 0) -- a swarmed orchestrate is over
  sepal.config().agents = nil
  clean()
end)

test("a plan's models are your agents': m offers them, a task with one runs on its agent", function()
  local C = sepal.config()
  eq(sepal.plan_models(), {}) -- no agents: the tasks run on the default model
  C.agents = { { cmd = "claude" }, { cmd = "claude", model = "opus" }, { cmd = "devin", model = "fusion-x" }, { cmd = "claude", model = "opus" } }
  eq(sepal.plan_models(), { "opus", "fusion-x" })
  C.agents = nil
end)

test("m on a queued task sets the model it starts on", function()
  clean(); reset()
  local slots = sepal.config().max_running
  sepal.setup({ max_running = 1 })
  vim.env.SEPAL_SLEEP = "1"
  send({ "Goal: first" })
  assert(vim.wait(4000, function() return (read(T .. "/args") or "") ~= "" end, 10), "the first task never started")
  vim.env.SEPAL_SLEEP = nil -- only the first one sleeps; it was already started
  send({ "Goal: queued" })
  vim.cmd("Sepal inbox")
  local row
  for r = 1, vim.api.nvim_buf_line_count(0) do
    vim.api.nvim_win_set_cursor(0, { r, 0 })
    if (inbox.current() or {}).title == "queued" then row = r break end
  end
  assert(row, "the queued task is not in the inbox")
  local q = inbox.current()
  picker_shots({ "1" })
  local got = msgs(notified(function() vim.cmd("normal m") end))
  assert(vim.tbl_contains(got, "queued: sonnet · it starts on it"), vim.inspect(got))
  eq(q.agent.model, "sonnet")
  vim.cmd("close")
  idle()
  eq(args()[2], "--permission-mode acceptEdits --model sonnet")
  sepal.setup({ max_running = slots })
end)

test(":Sepal task shows who works on it: each kind's or agent's provider logo and model, then the draft's", function()
  clean(); reset()
  local function draft()
    local m = vim.api.nvim_buf_get_extmarks(task_buf(), -1, 0, 0, { details = true, type = "virt_lines" })[1]
    local l = m[4].virt_lines[1]
    vim.api.nvim_buf_delete(task_buf(), { force = true })
    return { l[1][1], l[1][2], l[2][1] }
  end
  sepal.setup({ models = { implement = "claude-opus-5-5" } })
  local shots = picker_shots({ "b" })
  sepal.pick()
  local btw = draft()
  eq(#shots, 1)
  eq(shots[1].lines, { "  l  large feat  ✻ claude", "  s  short feat  ✻ opus 5.5",
    "  b  btw" .. (" "):rep(9) .. "✻ sonnet" })
  eq({ shots[1].title, shots[1].config.relative }, { "sepal", "" })
  eq(shots[1].wrap, false)
  eq(vim.tbl_contains(marked_texts(shots[1], 0, "SepalAccent"), "l"), true)
  eq(vim.tbl_contains(marked_texts(shots[1], 0, "SepalClaude"), "✻"), true)
  eq(vim.tbl_contains(marked_texts(shots[1], 0, "SepalDim"), "claude"), true)
  picker_closed(shots[1])
  sepal.setup({ agents = { { cmd = "claude", name = "claude" },
    { cmd = "devin", model = "fusion-claude-opus-5-5-medium-sidekick-swe-2-high", name = "fusion review" },
    { cmd = "devin", model = "gpt-5", key = "t" }, { cmd = "devin" }, { cmd = "devin", model = "opus", name = "opus" } } })
  local columns = vim.o.columns
  vim.o.columns = 40 -- long rows are cut, never wrapped
  shots = picker_shots({ "s", "t" })
  local ok, err = pcall(sepal.pick)
  vim.o.columns = columns
  if not ok then error(err, 0) end
  local gpt = draft()
  sepal.setup({ models = {}, agents = nil })
  eq(#shots, 2)
  eq(shots[1].lines, { "  l  large feat", "  s  short feat", "  b  btw" })
  eq(shots[2].lines, { "  1  ✻ claude", "  2  ❖ fusion review  opus 5.5 medium + swe 2 high",
    "  t  ֎ devin" .. (" "):rep(10) .. "gpt 5", "  4  ❖ devin", "  5  ✻ opus" })
  eq(shots[2].title, "sepal · short feat")
  eq({ shots[2].width, shots[2].height, shots[2].wrap }, { 40, 7, false })
  local function detail_col(line, detail)
    return vim.fn.strdisplaywidth(line:sub(1, assert(line:find(detail, 1, true)) - 1))
  end
  eq(detail_col(shots[2].lines[2], "opus 5.5 medium"), detail_col(shots[2].lines[3], "gpt 5"))
  eq(shots[2].lines[5]:find("opus  opus", 1, true), nil) -- a custom name equal to the model isn't repeated
  eq(vim.tbl_contains(marked_texts(shots[2], 1, "SepalDim"), "opus 5.5 medium + swe 2 high"), true)
  picker_closed(shots[2])
  eq({ btw, gpt }, { { "✻", "SepalClaude", " sonnet" }, { "֎", "SepalDim", " gpt 5" } })
end)

test("the picker closes its split and buffer when getcharstr is interrupted", function()
  local shots = picker_shots({ function() error("interrupt", 0) end })
  eq(sepal.choose({ { key = "x", label = "thing" } }, { title = "interrupted" }), nil)
  eq(#shots, 1)
  picker_closed(shots[1])
end)

test(":Sepal task asks which agent with agents set: devin runs with sepal's hooks in its config; ctrl-c is caught", function()
  clean(); reset()
  sepal.setup({ agents = { { cmd = { claude }, name = "claude" }, { cmd = { dv }, model = "fusion-x", args = { "--sandbox" } } } })
  vim.env.SEPAL_EDIT = [[echo dv > a.txt]]
  local got = msgs(notified(function()
    key("s")
    local g = vim.fn.getcharstr
    vim.fn.getcharstr = function() vim.fn.getcharstr = g; key("2"); return "s" end
    sepal.pick()
    vim.api.nvim_buf_set_lines(task_buf(), 0, -1, false, { "Goal: by devin", "", "Done when: true" })
    vim.api.nvim_feedkeys(vim.keycode("<c-c><c-c>"), "tx", false)
    idle()
  end))
  local e = newest()
  eq({ e.status, e.session, e.model, e.agent, file("a.txt") },
    { "landed", "dv1", "fusion-x", { cmd = { dv }, model = "fusion-x", args = { "--sandbox" } }, "dv\n" })
  eq(args(), { "--sandbox --permission-mode accept-edits --respect-workspace-trust false --model fusion-x" })
  local c = vim.json.decode(read(T .. "/devin.json"))
  eq({ c.permissions.allow, c.hooks.Stop ~= nil, c.hooks.PermissionRequest ~= nil }, { { "Exec(true)" }, true, true })
  assert(vim.tbl_contains(got, "▲ by devin: asks to run exec rm -rf x · :Sepal open"), vim.inspect(got))
  assert(vim.tbl_contains(got, "landed: by devin · 1 file +1 −3 · true ✔\n· used devin"), vim.inspect(got))
  -- its chat: devin's "resume where?" prompt (the worktree's gone) is answered: here, this once
  vim.cmd("Sepal open")
  vim.wait(4000, function() return vim.uv.fs_stat(T .. "/resume_answer") ~= nil end)
  eq(vim.trim(read(T .. "/resume_answer") or ""), "2")
  vim.wait(4000, function() return vim.bo.buftype == "terminal" end)
  eq(vim.bo.buftype, "terminal", "the chat didn't show")
  local chat = vim.api.nvim_get_current_buf()
  vim.wait(4000, function()
    return table.concat(vim.api.nvim_buf_get_lines(chat, 0, -1, false)):find("the chat so far", 1, true) ~= nil
  end)
  assert(table.concat(vim.api.nvim_buf_get_lines(chat, 0, -1, false)):find("the chat so far", 1, true), "no chat text")
  vim.cmd.stopinsert()
  vim.cmd("bwipeout!")
  clean(); reset()
  vim.env.SEPAL_INTERRUPT = "1"
  notified(function() agent.start("Goal: cut short", work, "auto", nil, nil, { cmd = { dv } }); idle() end)
  eq(newest().status, "stopped")
  sepal.setup({ agents = false })
end)

-- the context bar, from the recorded sessions: what each CLI emitted, and what it printed for it
local function lines_of(p) return vim.split(vim.trim(assert(read(p), p)), "\n") end
local function panel_lines()
  return vim.api.nvim_buf_get_lines(vim.fn.bufnr("sepal://panel"), 0, -1, false)
end
local function hl_on(text) -- the highlight groups on the panel line that is text
  local b = vim.fn.bufnr("sepal://panel")
  local row
  for i, l in ipairs(panel_lines()) do if l == text then row = i - 1 end end
  assert(row, text .. " not in " .. vim.inspect(panel_lines()))
  local hls = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, vim.api.nvim_create_namespace("sepal.panel"), { row, 0 }, { row, -1 }, { details = true })) do
    hls[#hls + 1] = m[4].hl_group
  end
  return hls
end
local function has_bar() -- a bar row of a card: cells or a "no limit"
  for _, l in ipairs(panel_lines()) do if vim.startswith(l, " ▎ █") or vim.startswith(l, " ▎ ░") or l:find("no limit", 1, true) then return l end end
end

test("the card's context bar is Claude Code's statusLine: none yet, its numbers, over the limit, a reset; the header shows the fullest", function()
  clean(); reset()
  local ev, sl = lines_of(FIXTURES .. "/claude/events.jsonl"), lines_of(FIXTURES .. "/claude/statusline.jsonl")
  local four = vim.json.decode(sl[4])
  local u = four.context_window.current_usage
  local function sized(sum, size) -- line 4, its cache reads making the sum, in a window of size
    local d = vim.deepcopy(four)
    d.context_window.current_usage.cache_read_input_tokens = sum - u.input_tokens - u.cache_creation_input_tokens
    d.context_window.context_window_size = size
    return vim.json.encode(d)
  end
  local feed = vim.fs.joinpath(T, "claude-feed.jsonl")
  local w = assert(io.open(feed, "w"))
  w:write(table.concat({ ev[1], sl[1], ev[3], ev[5], sl[2], sl[3], sl[4], sized(1100000, 1000000), sized(150000, 200000), ev[7] }, "\n") .. "\n")
  w:close()
  vim.env.SEPAL_REPLAY, vim.env.SEPAL_PAUSE, vim.env.SEPAL_EDIT = feed, "2 7 8 9", [[echo x > a.txt]]
  vim.cmd("Sepal panel")
  notified(function()
    send({ "Goal: fed" })
    local e = newest()
    assert(vim.wait(5000, function() return e.session ~= nil end, 10), "no SessionStart")
    vim.wait(300)
    eq({ e.usage, has_bar() }, { nil, nil }) -- statusLine's first line has no current_usage yet
    go()
    assert(vim.wait(5000, function() return e.usage and e.usage.used == 39149 end, 10), vim.inspect(e.usage))
    eq(e.usage, { used = 39149, limit = four.context_window.context_window_size })
    eq(require("sepal.panel").pct(e.usage), four.context_window.used_percentage) -- Claude Code's own percent
    eq(has_bar(), " ▎ ░░░░░░░░░░ 39.1k/1M · 4%")
    eq(panel_lines()[3], " ░░░░░░░░░░ 4% context · fed")
    go()
    assert(vim.wait(5000, function() return e.usage.used == 1100000 end, 10), vim.inspect(e.usage))
    eq(has_bar(), " ▎ ██████████ 1.1M/1M · 110% · over the limit") -- the card's cache refreshed
    assert(vim.tbl_contains(hl_on(has_bar()), "SepalError"), vim.inspect(hl_on(has_bar())))
    eq(panel_lines()[3], " ██████████ 110% context · fed")
    go()
    assert(vim.wait(5000, function() return e.usage.limit == 200000 end, 10), vim.inspect(e.usage))
    eq(has_bar(), " ▎ ████████░░ 150k/200k · 75%")
    assert(vim.tbl_contains(hl_on(has_bar()), "SepalWarn"), vim.inspect(hl_on(has_bar())))
    go()
    idle()
  end)
  local e = newest()
  eq({ e.status, e.usage, has_bar() }, { "landed", { used = 150000, limit = 200000 }, " ▎ ████████░░ 150k/200k · 75%" }) -- kept after the run
  assert(not panel_lines()[3]:find("% context", 1, true), panel_lines()[3])
  vim.cmd("Sepal panel")
  local s = vim.json.decode(read(T .. "/settings") or "{}")
  eq(s.statusLine and s.statusLine.type, "command")
end)

test("with several running tasks the header names the fullest and says it's the fullest", function()
  clean(); reset()
  vim.cmd("Sepal panel")
  local l = inbox.list(work)
  table.insert(l, 1, { id = "h1", root = work, title = "small", status = "running", time = os.time(), usage = { used = 20000, limit = 200000 } })
  table.insert(l, 1, { id = "h2", root = work, title = "big", status = "running", time = os.time(), usage = { used = 160000, limit = 200000 } })
  require("sepal.panel").render()
  local line = panel_lines()[3]
  table.remove(l, 1); table.remove(l, 1)
  vim.cmd("Sepal panel")
  eq(line, " ████████░░ 80% · fullest of 2: big")
end)

test("a Devin card's bar is its transcript's totals, like its /usage; it exposes no limit, so none is shown", function()
  clean(); reset()
  local data = vim.env.XDG_DATA_HOME
  vim.env.XDG_DATA_HOME = vim.fs.joinpath(T, "data")
  vim.env.SEPAL_REPLAY, vim.env.SEPAL_PAUSE, vim.env.SEPAL_EDIT = FIXTURES .. "/devin/events.jsonl", "1", [[echo dv > a.txt]]
  vim.cmd("Sepal panel")
  local ok, err = pcall(notified, function()
    agent.start("Goal: devin's tokens", work, "auto", nil, nil, { cmd = { dv } })
    local e = newest()
    assert(vim.wait(5000, function() return e.session == "quiver-snapper" end, 10), "no SessionStart")
    vim.wait(300)
    eq({ e.usage, has_bar() }, { nil, nil }) -- no transcript yet
    local dir = vim.fs.joinpath(T, "data", "devin", "cli", "transcripts")
    vim.fn.mkdir(dir, "p")
    vim.uv.fs_copyfile(FIXTURES .. "/devin/transcript.json", vim.fs.joinpath(dir, "quiver-snapper.json"))
    assert(vim.wait(5000, function() return e.usage ~= nil end, 10), "the transcript was never read")
    eq(e.usage, { used = 37846, out = 252 })
    local k, out = read(FIXTURES .. "/devin/usage.txt"):match("Tokens%s+(%d+)k in · (%d+) out") -- what its /usage printed
    eq({ math.floor(e.usage.used / 1000 + 0.5), e.usage.out }, { tonumber(k), tonumber(out) })
    eq(has_bar(), " ▎ 37.8k in · 252 out · no limit: Devin exposes none")
    assert(not panel_lines()[3]:find("% context", 1, true), "no limit: not in the header")
    go()
    idle()
  end)
  vim.env.XDG_DATA_HOME = data
  vim.cmd("Sepal panel")
  assert(ok, err)
  eq({ newest().status, file("a.txt") }, { "landed", "dv\n" })
end)

test("Devin writes its transcript as it exits: the totals read after the turn stay on the card, and are saved", function()
  clean(); reset()
  local data = vim.env.XDG_DATA_HOME
  vim.env.XDG_DATA_HOME = vim.fs.joinpath(T, "data")
  vim.env.SEPAL_REPLAY, vim.env.SEPAL_PAUSE, vim.env.SEPAL_EDIT = FIXTURES .. "/devin/events.jsonl", "1", [[echo dv > a.txt]]
  vim.cmd("Sepal panel")
  local dir = vim.fs.joinpath(T, "data", "devin", "cli", "transcripts")
  os.remove(vim.fs.joinpath(dir, "quiver-snapper.json")) -- the test before left one
  local ok, err = pcall(notified, function()
    agent.start("Goal: devin's late tokens", work, "auto", nil, nil, { cmd = { dv } })
    local e = newest()
    assert(vim.wait(5000, function() return e.session == "quiver-snapper" end, 10), "no SessionStart")
    go()
    idle()
    eq({ e.status, e.usage }, { "landed", nil })
    vim.fn.mkdir(dir, "p")
    vim.uv.fs_copyfile(FIXTURES .. "/devin/transcript.json", vim.fs.joinpath(dir, "quiver-snapper.json"))
    assert(vim.wait(5000, function() return e.usage ~= nil end, 10), "the transcript was never read after the turn")
    eq(has_bar(), " ▎ 37.8k in · 252 out · no limit: Devin exposes none")
    inbox._t.reset() -- a restart reads it back
    eq(newest().usage, { used = 37846, out = 252 })
  end)
  vim.env.XDG_DATA_HOME = data
  vim.cmd("Sepal panel")
  assert(ok, err)
end)

test("reading Devin's usage from a multi-MB transcript costs one 4 KiB tail read, and none when it's unchanged", function()
  local fixture = read(FIXTURES .. "/devin/transcript.json")
  local tail = fixture:sub(fixture:find('"final_metrics"', 1, true) - 4)
  local p = vim.fs.joinpath(T, "big.json")
  local w = assert(io.open(p, "w"))
  w:write('{\n  "steps": [\n')
  local step = '    { "source": "agent", "message": "' .. ("x"):rep(1000) .. '" },\n'
  for _ = 1, 5000 do w:write(step) end
  w:write('    {}\n  ],\n' .. tail)
  w:close()
  local size = vim.uv.fs_stat(p).size
  assert(size > 5e6, size)
  local st = {}
  local t0 = vim.uv.hrtime()
  local u, bytes = agent._t.devin_usage(p, st)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  eq(u, { used = 37846, out = 252 })
  assert(bytes <= 4096, bytes)
  assert(ms < 20, ms .. " ms")
  print(("  devin usage: %.1f MB transcript, read %d bytes in %.2f ms"):format(size / 1e6, bytes, ms))
  eq({ agent._t.devin_usage(p, st) }, { nil, 0 }) -- unchanged: not even opened
  w = assert(io.open(p, "w"))
  w:write('{ "pad": "' .. ("y"):rep(6e6) .. '",\n' .. tail:gsub("37846", "40000"))
  w:close()
  u, bytes = agent._t.devin_usage(p, st)
  eq(u, { used = 40000, out = 252 })
  assert(bytes <= 4096, bytes)
end)

test("a cmd that isn't claude or devin fails clearly: in setup, when it runs, in checkhealth", function()
  clean(); reset()
  local got = notified(function() sepal.setup({ cmd = { "sh" } }) end)
  eq(got, { { 'cmd { "sh" } isn\'t a supported agent: sepal runs claude or devin', vim.log.levels.ERROR } })
  got = msgs(notified(function() agent.start("Goal: by sh", work, "auto"); idle() end))
  local e = newest()
  eq(e.status, "error")
  assert(e.error:find("unsupported agent sh", 1, true), e.error)
  require("sepal.health").check()
  sepal.setup({ cmd = { claude } })
end)

print(("%d/%d passed"):format(n - fails, n))
vim.fn.delete(T, "rf")
os.exit(fails == 0 and 0 or 1)
