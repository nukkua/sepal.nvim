-- sepal.agent — a task's life: a worktree of what you see, the agent working there alone
-- (Claude Code in a hidden terminal: :Sepal open shows it), sepal running the task's check itself
-- (`Done when:`), one more try for the agent if the check fails, then landing the result in your
-- work tree as unstaged changes (on its own with land = "auto"). You're pulled in only when
-- something needs you. At most max_running tasks run at once, the rest wait in a queue.

local M = {}
local git = require("sepal.git")
local inbox = require("sepal.inbox")

local function sepal() return require("sepal") end
local function C() return require("sepal").config() end
local function notify(...) return sepal().notify(...) end
local WARN, ERROR = vim.log.levels.WARN, vim.log.levels.ERROR
-- cmd plus extra: with auto_mode, Claude Code's auto mode instead of the --permission-mode in args
local function cmd(extra)
  local a = vim.list_extend({}, extra)
  if C().auto_mode then
    for i = #a - 1, 1, -1 do if a[i] == "--permission-mode" then table.remove(a, i); table.remove(a, i) end end
    vim.list_extend(a, { "--permission-mode", "auto" })
  end
  return vim.list_extend(vim.list_extend({}, C().cmd), a)
end

-- running work per entry id: { job (the agent, check or prepare), buf (the agent's terminal), stopped, done, update, exclude }
local jobs = {}
local queue = {} -- { e, prompt, from } waiting for a free slot (max_running), oldest first
local chats = {} -- task id → its chat's terminal (claude --resume): hidden, it goes on until stopped
-- e's chat, while claude runs in it
local function chat(e)
  local b = chats[e.id]
  return b and vim.api.nvim_buf_is_valid(b) and vim.fn.jobwait({ vim.bo[b].channel }, 0)[1] == -1 and b or nil
end
local function endchat(e)
  local b = chats[e.id]
  chats[e.id] = nil
  if b then pcall(vim.api.nvim_buf_delete, b, { force = true }) end -- ends claude
end

-- the first non-empty line of s, cut to n characters
local function first(s, n)
  local l = type(s) == "string" and vim.iter(vim.split(s, "\n")):map(vim.trim):find(function(x) return x ~= "" end) or nil
  if l and vim.fn.strchars(l) > n then l = vim.fn.strcharpart(l, 0, n - 1) .. "…" end
  return l
end
local function plural(n, word) return ("%d %s%s"):format(n, word, n == 1 and "" or "s") end
local function tail(s, n)
  local l = vim.split(vim.trim(s or ""), "\n")
  return table.concat(vim.list_slice(l, math.max(1, #l - n + 1)), "\n")
end

local function ref(e, what) return "refs/sepal/" .. e.id .. "/" .. what end
local function wtdir(e) return vim.fs.joinpath(C().worktrees, inbox.key(e.root), e.id) end

-- the task's check ("Done when: make test") and title (Goal, else its first line)
function M.parse(text)
  local f = {}
  for l in (text .. "\n"):gmatch("([^\n]*)\n") do
    for _, k in ipairs({ "Done when", "Goal" }) do
      local v = l:match("^%s*" .. k .. ":%s*(.-)%s*$")
      if v and v ~= "" and not f[k] then f[k] = v end
    end
  end
  return f["Done when"], first(f.Goal or text, 40) or "task"
end

-- what sepal tells the agent besides the task
local function notes(e)
  local n = { "", "---", "How to work on this (from sepal, not part of the task):",
    "- You're in a git worktree of the project. Work on your own: decide instead of asking questions."
      .. " Edit the files here. Don't commit, push or switch branches." }
  if e.check then n[#n + 1] = ("- Done when `%s` passes: run exactly that command (nothing added to it, it is the only one allowed), and keep fixing until it passes."):format(e.check) end
  n[#n + 1] = "- Decide what the task leaves open. End your reply with the decisions a reviewer should know:"
  n[#n + 1] = "Assumptions:\n- <one per line>\n(or \"Assumptions: none\")"
  return table.concat(n, "\n")
end

-- the "Assumptions:" list at the end of a reply
function M.assumptions(reply)
  if type(reply) ~= "string" then return {} end
  local lines, at = vim.split(reply, "\n"), nil
  for i, l in ipairs(lines) do if l:match("^[%s%*#_]*Assumptions[%*_]*:") then at = i end end
  if not at then return {} end
  local out = {}
  local inline = vim.trim((lines[at]:gsub("^[%s%*#_]*Assumptions[%*_]*:[%*_]*", "")))
  if inline ~= "" and not inline:lower():match("^none") then out[#out + 1] = inline end
  for i = at + 1, #lines do
    local b = lines[i]:match("^%s*[-*•]%s+(.+)$")
    if b then out[#out + 1] = vim.trim(b) elseif vim.trim(lines[i]) ~= "" then break end
  end
  return out
end

-- what a tool call is about, for the spinner: "Edit src/pool.cpp", "Bash make test"
local function about(tool, wt)
  local i = type(tool.input) == "table" and tool.input or {}
  local p = type(i.file_path) == "string" and i.file_path or type(i.path) == "string" and i.path or nil
  if p and vim.startswith(p, wt .. "/") then p = p:sub(#wt + 2) end
  local arg = p or vim.iter({ i.command, i.pattern, i.url, i.description }):find(function(v) return type(v) == "string" end)
  return tostring(tool.name) .. (arg and " " .. first(arg, 50) or "")
end

local function bufof(path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == path then return b end
  end
end
-- reload the buffers of files that changed on disk (:checktime alone skips hidden buffers)
local function reload(changes)
  for _, c in ipairs(changes) do
    local b = bufof(c.path)
    if b then vim.api.nvim_buf_call(b, function() pcall(vim.cmd, "silent! checktime") end) end
  end
end

local function facts(e)
  local f = {}
  if e.stat and e.stat.files > 0 then f[#f + 1] = ("%s +%d −%d"):format(plural(e.stat.files, "file"), e.stat.add, e.stat.del) end
  if e.check and e.checked ~= nil then f[#f + 1] = e.check .. (e.checked and " ✓" or " ✗") end
  return #f > 0 and " · " .. table.concat(f, " · ") or ""
end
local function with_assumptions(msg, e)
  for _, a in ipairs(e.assumptions or {}) do msg = msg .. "\n· " .. a end
  return msg
end

-- the float j's spinner is in, while you're still in it and it still shows that spinner
local function watching(j)
  local w = j.watch and j.watch.win
  return w and vim.api.nvim_win_is_valid(w) and vim.api.nvim_get_current_win() == w
    and vim.api.nvim_win_get_buf(w) == j.watch.buf and w or nil
end

-- the run is over: the worktree goes (its result is a commit), the entry gets its status
local function finish(e, wt, status, extra)
  local j = jobs[e.id]
  jobs[e.id] = nil
  if wt then git.remove_worktree(e.root, wt) end
  e.status, e.activity = status, nil
  for k, v in pairs(extra or {}) do e[k] = v end
  inbox.changed(e)
  if j and j.done then j.done(true) end
  if status == "stopped" then notify("stopped: " .. e.title)
  elseif status == "error" then notify("✗ " .. e.title .. ": " .. tostring(e.error) .. " · :Sepal inbox", ERROR)
  elseif status == "failed" then
    local tries = (e.attempts or 0) + 1
    notify(("✗ %s: `%s` still fails after %d %s · :Sepal inbox"):format(e.title, e.check, tries, tries == 1 and "try" or "tries"), WARN)
  elseif status == "nochange" then notify("no changes: " .. e.title .. (e.summary and ": " .. e.summary or ""))
  end
  -- watched to its end: its chat in the same float (or the float goes, with nothing to show)
  local w = j and watching(j)
  if w then
    if e.session then M.open(e, w, j.watch.kept) else pcall(vim.api.nvim_win_close, w, true) end
  end
  vim.schedule(M._next)
end

local agent, show, loading -- below

local function done(e, wt)
  if not e.stat or e.stat.files == 0 then return finish(e, wt, "nochange") end
  finish(e, wt, "ready")
  if (e.land or C().land) == "auto" then return M.land(e, true) end
  notify(with_assumptions("● ready to land: " .. e.title .. facts(e) .. " · :Sepal inbox", e))
end

-- sepal runs the check itself; on a failure the agent gets the output and `retries` more tries
local function check(e, wt)
  e.status = "checking"
  inbox.changed(e)
  jobs[e.id].update(e.title .. ": " .. e.check)
  local ok, job = pcall(vim.system, { "sh", "-c", e.check }, { cwd = wt, text = true }, vim.schedule_wrap(function(out)
    if not jobs[e.id] or jobs[e.id].stopped then return finish(e, wt, "stopped") end
    e.checked = out.code == 0
    if e.checked then e.check_out = nil; return done(e, wt) end
    e.check_out = tail((out.stdout or "") .. "\n" .. (out.stderr or ""), 40)
    if (e.attempts or 0) >= (C().retries or 0) then return finish(e, wt, "failed") end
    e.attempts = (e.attempts or 0) + 1
    e.status = "running"
    inbox.changed(e)
    agent(e, ("`%s` failed (exit %d):\n```\n%s\n```\nFix it so it passes. Same rules as before, and end with Assumptions: again.")
      :format(e.check, out.code, e.check_out), wt)
  end))
  if not ok then return finish(e, wt, "error", { error = "could not run the check: " .. tostring(job):match("[^\n]*") }) end
  jobs[e.id].job = job
end

-- Claude Code reports back through hooks: each one appends its input (a JSON line) to $SEPAL_EVENTS
local HOOK = { { hooks = { { type = "command", command = [[{ tr -d '\n'; echo; } >> "$SEPAL_EVENTS"]] } } } }
local SETTINGS = vim.json.encode({ hooks = { SessionStart = HOOK, PreToolUse = { { matcher = "*", hooks = HOOK[1].hooks } },
  Notification = HOOK, Stop = HOOK } })

-- the agent's last reply: from the Stop hook, else the end of its transcript
local function reply_of(ev)
  if type(ev.last_assistant_message) == "string" then return ev.last_assistant_message end
  local f = type(ev.transcript_path) == "string" and io.open(ev.transcript_path)
  if not f then return nil end
  local last
  for l in f:lines() do
    -- decode only the agent's lines: a transcript can be MBs of tool output
    local ok, t = false, nil
    if l:find('"assistant"', 1, true) then ok, t = pcall(vim.json.decode, l, { luanil = { object = true, array = true } }) end
    local c = ok and type(t) == "table" and t.type == "assistant" and type(t.message) == "table" and t.message.content
    local text = {}
    for _, b in ipairs(type(c) == "table" and c or {}) do
      if type(b) == "table" and b.type == "text" and type(b.text) == "string" then text[#text + 1] = b.text end
    end
    if #text > 0 then last = table.concat(text, "\n") end
  end
  f:close()
  return last
end

-- the whole editor: the agent's terminal is this size from its start to every :Sepal open
local function screen()
  return { relative = "editor", row = 0, col = 0, style = "minimal", zindex = 1, -- under notifications
    width = vim.o.columns, height = math.max(vim.o.lines - vim.o.cmdheight, 1) }
end
-- no line numbers on an agent's window, whatever the buffer shown there before had
local function termwin(w) vim.wo[w].number, vim.wo[w].relativenumber = false, false end

-- the agent: Claude Code itself, in a hidden terminal buffer (:Sepal open shows it). Its turn is over
-- at the Stop hook; then it's closed, and sepal checks and lands what it did
agent = function(e, prompt, wt)
  local j = jobs[e.id]
  local events = wt .. ".events"
  os.remove(events)
  local argv = cmd(C().args or {})
  if e.check then vim.list_extend(argv, { "--allowedTools", "Bash(" .. e.check .. ")" }) end -- it has to run the check
  -- files from outside the repo (<c-c><c-i>'s images): read-only access to just those ("//" is an absolute path)
  for l in vim.gsplit(e.task, "\n") do
    local f = l:match("^%s*%- @(/.-)%s*$")
    if f then vim.list_extend(argv, { "--allowedTools", "Read(/" .. f .. ")" }) end
  end
  if e.session then vim.list_extend(argv, { "--resume", e.session }) end
  vim.list_extend(argv, { "--settings", SETTINGS, prompt })
  local b = vim.api.nvim_create_buf(false, true)
  local started, over, timer = false, false, vim.uv.new_timer()
  local function close()
    over = true
    timer:stop(); timer:close()
    os.remove(events)
    if not vim.api.nvim_buf_is_valid(b) then return end
    local lines = vim.tbl_filter(function(l) return vim.trim(l) ~= "" and not l:match("^%[Process exited") end, vim.api.nvim_buf_get_lines(b, 0, -1, false))
    -- watched: you stay in its float. The check gets a spinner; else its last screen stays (claude
    -- stopped) until its chat replaces it, and it's wiped then
    if vim.api.nvim_get_current_buf() == b then
      local w = vim.api.nvim_get_current_win()
      if e.check then
        local l = loading(w, "Running the check")
        j.watch = { buf = l, win = w }
      else
        vim.cmd.stopinsert() -- a key in an exited terminal closes it
        vim.bo[b].bufhidden = "wipe"
        pcall(vim.fn.jobstop, vim.bo[b].channel)
        j.watch = { buf = b, win = w, kept = true }
        return lines[#lines]
      end
    end
    for _, w in ipairs(vim.fn.win_findbuf(b)) do pcall(vim.api.nvim_win_close, w, true) end
    pcall(vim.api.nvim_buf_delete, b, { force = true }) -- ends claude too
    return lines[#lines]
  end
  local function stopped(ev) -- the turn is over: what it did is kept even when its check fails
    close()
    e.result = git.result(e.root, wt, e.base, ref(e, "result"), j.exclude) or e.result
    e.stat = e.result and git.stat(e.root, e.base, e.result) or e.stat
    local reply = reply_of(ev)
    e.summary = first(reply, 100) -- the reply itself isn't kept: only its summary and assumptions are shown
    local seen = {}
    for _, a in ipairs(e.assumptions or {}) do seen[a] = true end
    for _, a in ipairs(M.assumptions(reply)) do -- a retry adds to them
      if not seen[a] then e.assumptions = e.assumptions or {}; e.assumptions[#e.assumptions + 1] = a end
    end
    if e.check then return check(e, wt) end
    done(e, wt)
  end
  local function event(line)
    local ok, ev = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if over or not ok or type(ev) ~= "table" then return end
    started = true
    if type(ev.session_id) == "string" and ev.session_id ~= e.session then
      e.session = ev.session_id
      inbox.save(e.root) -- now, not when it finishes: a quit mid-run keeps the chat for o and r
    end
    local name = ev.hook_event_name
    if name == "PreToolUse" then
      e.activity = about({ name = ev.tool_name, input = ev.tool_input }, wt)
      j.update(e.title .. ": " .. e.activity)
      inbox.render()
    elseif name == "Notification" then
      e.activity = "needs you"
      inbox.render()
      notify("▲ " .. e.title .. ": " .. tostring(ev.message or "it needs you") .. " · :Sepal open", WARN)
    elseif name == "Stop" then
      stopped(ev)
    end
  end
  local off = 0
  local function poll()
    local f = io.open(events)
    if not f then return end
    f:seek("set", off)
    local s = f:read("a")
    f:close()
    local cut = s:match(".*\n()")
    if not cut then return end
    off = off + cut - 1
    for l in s:sub(1, cut - 1):gmatch("[^\n]+") do event(l) end
  end
  local function exited(_, code)
    if over then return end
    poll()
    if over then return end
    local last = close()
    if j.stopped then return finish(e, wt, "stopped") end
    finish(e, wt, "error", { error = started and "the agent quit before it was done (exit " .. code .. ")"
      or "the agent didn't start: " .. (first(last, 200) or ("exit " .. code)) })
  end
  -- started in a hidden window the size of the float M.open shows it in: a resize makes Claude Code
  -- redraw everything (slow, and it leaves old frames above the new one)
  local win = vim.api.nvim_open_win(b, false, vim.tbl_extend("force", screen(), { hide = true, focusable = false }))
  termwin(win)
  local ok, chan = pcall(vim.api.nvim_win_call, win, function()
    return vim.fn.jobstart(argv, { term = true, cwd = wt, env = { SEPAL_EVENTS = events, CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN = "1" }, on_exit = vim.schedule_wrap(exited) })
  end)
  pcall(vim.api.nvim_win_close, win, true)
  if not ok or chan <= 0 then
    close()
    return finish(e, wt, "error", { error = "could not run " .. tostring(argv[1]) .. (ok and "" or ": " .. tostring(chan):match("[^\n]*")) })
  end
  vim.bo[b].bufhidden, vim.bo[b].scrollback = "hide", 10000
  vim.b[b].sepal_agent = true -- :Sepal open from here leaves it
  local term_name = vim.api.nvim_buf_get_name(b)
  pcall(vim.api.nvim_buf_set_name, b, "sepal://" .. e.id)
  for _, x in ipairs(vim.api.nvim_list_bufs()) do -- a rename keeps the old name as a buffer of its own: one per run
    if x ~= b and vim.api.nvim_buf_get_name(x) == term_name then pcall(vim.api.nvim_buf_delete, x, { force = true }) end
  end
  vim.keymap.set("n", "q", function() sepal().close() end, { buffer = b, desc = "Hide the agent (it keeps working)" })
  j.buf, j.job = b, { kill = function() vim.fn.jobstop(chan) end }
  if watching(j) then show(b, j.watch.win) end -- a retry, watched
  j.watch = nil
  local asked -- Claude Code asks to trust each new folder before it starts (no hook runs before that)
  timer:start(100, 100, vim.schedule_wrap(function()
    if over then return end
    poll()
    if started or asked or not vim.api.nvim_buf_is_valid(b) then return end
    -- the prompt is on the first screen: no need to join the scrollback
    if table.concat(vim.api.nvim_buf_get_lines(b, 0, vim.o.lines, false), " "):find("Quick safety check", 1, true) then
      asked, e.activity = true, "needs you"
      inbox.render()
      notify("▲ " .. e.title .. ": Claude Code asks to trust the worktree · :Sepal open", WARN)
    end
  end))
end

-- a fresh worktree of `from` for e, prepared (C.prepare), then the agent on prompt;
-- with max_running tasks already running it waits in the queue
local function launch(e, prompt, from)
  if C().max_running and vim.tbl_count(jobs) >= C().max_running then
    e.status = "queued"
    queue[#queue + 1] = { e, prompt, from }
    return inbox.changed(e)
  end
  local wt = wtdir(e)
  if vim.uv.fs_stat(wt) then git.remove_worktree(e.root, wt) end
  local done_, update = sepal().progress(e.title .. ": working")
  jobs[e.id] = { done = done_, update = update } -- from here it counts as running: x stops it, max_running counts it
  e.status = "running"
  inbox.changed(e)
  local ok, job = pcall(git.add_worktree, e.root, wt, from, function(made, err)
    local j = jobs[e.id]
    -- stopped mid-checkout or failed: finish removes whatever half of it is there
    if not j or j.stopped then return finish(e, wt, "stopped") end
    if not made then return finish(e, wt, "error", { error = "could not make a worktree: " .. err }) end
    M._prepare(e, prompt, wt)
  end)
  if not ok then return finish(e, nil, "error", { error = "could not make a worktree: " .. tostring(job):match("[^\n]*") }) end
  jobs[e.id].job = job
end

-- C.prepare in the new worktree (if set), then the agent
function M._prepare(e, prompt, wt)
  local update = jobs[e.id].update
  local prepare = C().prepare
  if not prepare then return agent(e, prompt, wt) end
  update(e.title .. ": preparing")
  local pok, job = pcall(vim.system, { "sh", "-c", prepare }, { cwd = wt, text = true, env = { SEPAL_ROOT = e.root } }, vim.schedule_wrap(function(out)
    local j = jobs[e.id]
    if not j or j.stopped then return finish(e, wt, "stopped") end
    if out.code ~= 0 then
      return finish(e, wt, "error", { error = "prepare failed: " .. (first((out.stderr or "") .. "\n" .. (out.stdout or ""), 200) or ("exit " .. out.code)) })
    end
    -- whatever prepare made (node_modules links, builds…) isn't the agent's work
    local st = git.run(wt, { "status", "--porcelain=v1", "-z", "--untracked-files=normal" }).stdout or ""
    j.exclude = {}
    for entry in st:gmatch("[^%z]+") do j.exclude[#j.exclude + 1] = entry:sub(4) end
    agent(e, prompt, wt)
  end))
  if not pok then return finish(e, wt, "error", { error = "could not run prepare: " .. tostring(job):match("[^\n]*") }) end
  jobs[e.id].job = job
end

-- a slot is free: the oldest queued task starts
function M._next()
  if C().max_running and vim.tbl_count(jobs) >= C().max_running then return end
  local q = table.remove(queue, 1)
  if q then launch(q[1], q[2], q[3]) end
end
local function queued(e)
  for i, q in ipairs(queue) do if q[1].id == e.id then return i end end
end

-- run a new task from cwd; nil, why when it can't
-- land: "auto" / "manual" for this task, nil: the land option
function M.start(text, cwd, land)
  local root = git.root(cwd)
  if not root then return nil, "not in a git repository: a task runs in a git worktree" end
  local check, title = M.parse(text)
  local e = { id = os.date("%Y%m%d-%H%M%S") .. ("-%04x"):format(vim.uv.hrtime() % 0x10000), root = root, title = title,
    task = text, check = check or C().check, time = os.time(), status = "running", attempts = 0, land = land }
  e.base = git.snapshot(root, ref(e, "base"))
  if not e.base then return nil, "could not save your work tree (git add / write-tree failed)" end
  e.base0 = e.base
  inbox.add(e)
  launch(e, text .. "\n" .. notes(e), e.base)
  return e
end

-- reply to e: the agent continues its chat, from what it did last, then check and land again
function M.continue(e, text)
  if M.running(e) then return notify("it's still running") end
  endchat(e) -- the agent goes on with the same chat
  e.attempts, e.checked, e.why, e.error, e.check_out = 0, nil, nil, nil, nil
  e.time = os.time()
  launch(e, text .. "\n" .. notes(e), e.result or e.base)
end

-- land e in your work tree as unstaged changes: a three-way merge per file, so what you changed
-- since the task started stays. auto: only when it's clean (no conflicts, no unsaved buffers)
function M.land(e, auto)
  if M.running(e) then return notify("it's still running") end
  if e.status == "landed" then return notify("already landed: u takes it back") end
  if not e.result then return notify("nothing to land") end
  local changes = git.plan(e.root, e.base, e.result)
  local unsaved, conflicts = {}, {}
  for _, c in ipairs(changes) do
    local b = bufof(c.path)
    if b and vim.bo[b].modified then unsaved[#unsaved + 1] = c.rel end
    if c.conflict then conflicts[#conflicts + 1] = c.rel end
  end
  if #unsaved > 0 or (auto and #conflicts > 0) then
    e.status = "needs"
    e.why = #unsaved > 0 and "unsaved changes in " .. table.concat(unsaved, ", ") .. ": save them, then L in :Sepal inbox"
      or "it overlaps your edits in " .. table.concat(conflicts, ", ") .. ": L lands it with conflict markers"
    inbox.changed(e)
    return notify(with_assumptions("▲ not landed: " .. e.title .. facts(e) .. "\n" .. e.why, e), WARN)
  end
  git.apply(changes)
  reload(changes)
  e.landed, e.base = { from = e.base, to = e.result }, e.result -- a reply lands only what's new
  e.status, e.why, e.conflicts = "landed", nil, #conflicts > 0 and conflicts or nil
  inbox.changed(e)
  local msg = with_assumptions("landed: " .. e.title .. facts(e), e)
  if #conflicts > 0 then
    return notify(msg .. "\nconflict markers in " .. table.concat(conflicts, ", "), WARN)
  end
  notify(msg, vim.log.levels.INFO, { icon = { require("sepal").icon("landed", "✓"), "SepalOk" } })
end

-- take a landed task back out of your work tree (again a merge: your edits since stay)
function M.undo(e)
  if not e.landed then return notify("only a landed task can be taken back") end
  local changes = git.plan(e.root, e.landed.to, e.landed.from)
  local unsaved, conflicts = {}, {}
  for _, c in ipairs(changes) do
    local b = bufof(c.path)
    if b and vim.bo[b].modified then unsaved[#unsaved + 1] = c.rel end
    if c.conflict then conflicts[#conflicts + 1] = c.rel end
  end
  if #unsaved > 0 then return notify("save these first: " .. table.concat(unsaved, ", "), WARN) end
  git.apply(changes)
  reload(changes)
  e.base, e.landed, e.status = e.landed.from, nil, "undone"
  e.conflicts = #conflicts > 0 and conflicts or nil
  inbox.changed(e)
  notify("took back: " .. e.title .. (#conflicts > 0 and "\nconflict markers in " .. table.concat(conflicts, ", ") or ""),
    #conflicts > 0 and WARN or vim.log.levels.INFO)
end

function M.stop(e)
  if chat(e) then
    endchat(e)
    return notify("closed the chat: " .. e.title)
  end
  local i = queued(e)
  if i then
    table.remove(queue, i)
    e.status = "stopped"
    inbox.changed(e)
    return notify("stopped: " .. e.title)
  end
  local j = jobs[e.id]
  if not j then return notify("it isn't running") end
  j.stopped = true
  if j.job then pcall(j.job.kill, j.job, 15) end
end

function M.running(e) return jobs[e.id] ~= nil or queued(e) ~= nil end
function M.chatting(e) return chat(e) ~= nil end

-- forget e: its commits and its line in the inbox
function M.drop(e)
  if M.running(e) then return notify("it's running: x stops it first") end
  endchat(e)
  if vim.uv.fs_stat(wtdir(e)) then git.remove_worktree(e.root, wtdir(e)) end
  git.delete_refs(e.root, "refs/sepal/" .. e.id)
  inbox.remove(e)
end

-- everything the task changed, as a diff in a new tab
function M.show(e)
  if not e.result then return notify("no changes yet") end
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(git.diff(e.root, e.base0 or e.base, e.result), "\n"))
  vim.bo[b].modifiable, vim.bo[b].filetype = false, "diff"
  vim.cmd.tabnew()
  vim.api.nvim_win_set_buf(0, b)
  vim.keymap.set("n", "q", function() sepal().close() end, { buffer = b, desc = "Close the diff" })
end

-- b in a full-screen float, the size its terminal started at whatever tabs, splits or statusline there
-- are: no resize, no redraw. Leaving it (<c-w>w…) hides it. w: the loading float to show it in
show = function(b, w)
  if w then vim.api.nvim_set_current_win(w); vim.api.nvim_win_set_buf(w, b) else w = vim.fn.bufwinid(b) end
  if w ~= -1 then vim.api.nvim_set_current_win(w) else
    w = vim.api.nvim_open_win(b, true, screen())
    vim.api.nvim_create_autocmd("WinLeave", { callback = function()
      if not vim.api.nvim_win_is_valid(w) then return true end -- closed with q: done
      if vim.api.nvim_get_current_win() ~= w then return end
      vim.schedule(function() pcall(vim.api.nvim_win_close, w, true) end)
      return true
    end })
  end
  termwin(w) -- after the buffer: a window takes a buffer's options from where it was last shown
  -- a terminal window follows the output only with the cursor on its last line; a new one starts at the top
  vim.api.nvim_win_set_cursor(w, { vim.api.nvim_buf_line_count(b), 0 })
  vim.cmd.startinsert()
end

-- a spinner in a full-screen float (w, else a new one) until something else is shown in it
loading = function(w, label)
  local l = vim.api.nvim_create_buf(false, true)
  vim.bo[l].bufhidden, vim.b[l].sepal_agent = "wipe", true
  vim.keymap.set("n", "q", function() sepal().close() end, { buffer = l, desc = "Hide it (it keeps going)" })
  if w then
    vim.api.nvim_win_set_buf(w, l)
  else
    show(l)
    w = vim.api.nvim_get_current_win()
  end
  vim.cmd.stopinsert() -- show's insert is for a terminal
  vim.wo[w].number = false
  local spin = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  local ns = vim.api.nvim_create_namespace("sepal.loading")
  -- centred: an accent spinner, a short label, a dim hint under it
  local function frame(i)
    local s, hint = spin[i % #spin + 1], "q to hide"
    local function center(t) return (" "):rep(math.max(math.floor((vim.o.columns - vim.fn.strdisplaywidth(t)) / 2), 0)) end
    local main = center(s .. "  " .. label) .. s .. "  " .. label
    local lines = {}
    for _ = 1, math.floor(vim.api.nvim_win_get_height(w) / 2) - 1 do lines[#lines + 1] = "" end
    local row = #lines
    vim.list_extend(lines, { main, "", center(hint) .. hint })
    vim.api.nvim_buf_set_lines(l, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(l, ns, 0, -1)
    local at = #main - #label - 2 - #s
    vim.api.nvim_buf_set_extmark(l, ns, row, at, { end_col = at + #s, hl_group = "SepalAccent" })
    vim.api.nvim_buf_set_extmark(l, ns, row, #main - #label, { end_col = #main, hl_group = "SepalTitle" })
    vim.api.nvim_buf_set_extmark(l, ns, row + 2, 0, { end_col = #lines[row + 3], hl_group = "SepalDim" })
  end
  frame(0)
  local n, timer = 0, vim.uv.new_timer()
  timer:start(100, 100, vim.schedule_wrap(function()
    if not vim.api.nvim_buf_is_valid(l) or not vim.api.nvim_win_is_valid(w) or vim.api.nvim_win_get_buf(w) ~= l then
      timer:stop(); timer:close()
      return
    end
    n = n + 1
    frame(n)
  end))
  return l, w
end

-- the task in Claude Code itself: while it runs, the agent at work (type to it if you like; q in normal
-- mode hides it, it keeps going), after that its chat (claude --resume)
function M.open(e, w, kept)
  local j = jobs[e.id]
  if j and j.buf and vim.api.nvim_buf_is_valid(j.buf) then return show(j.buf) end -- its terminal is gone once its turn is over (sepal checks)
  if queued(e) then return notify("it's queued, it starts when a running task is done") end
  if j then return notify(j.buf and "the agent is done, sepal is " .. e.status or "it's starting: making its worktree") end
  if not e.session then return notify("this task has no chat yet") end
  if chat(e) then return show(chats[e.id]) end
  endchat(e) -- quit (/exit): a new one
  -- started hidden and shown once it's printed the chat: claude --resume prints all of it at once,
  -- and a terminal on screen scrolls down through every line
  local b = vim.api.nvim_create_buf(false, true)
  local hidden = vim.api.nvim_open_win(b, false, vim.tbl_extend("force", screen(), { hide = true, focusable = false }))
  termwin(hidden)
  local ok, chan = pcall(vim.api.nvim_win_call, hidden, function()
    return vim.fn.jobstart(vim.list_extend(cmd({}), { "--resume", e.session }), { term = true, cwd = e.root,
      env = { CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN = "1" } })
  end)
  pcall(vim.api.nvim_win_close, hidden, true)
  if not ok or chan <= 0 then
    pcall(vim.api.nvim_buf_delete, b, { force = true })
    return notify("could not run " .. tostring(C().cmd[1]) .. (ok and "" or ": " .. tostring(chan):match("[^\n]*")), WARN)
  end
  chats[e.id] = b
  vim.b[b].sepal_agent = true
  vim.keymap.set("n", "q", function() sepal().close() end, { buffer = b, desc = "Hide the chat (it keeps going)" })
  -- meanwhile a spinner in the float it'll show in (or the screen kept there); leaving that (q,
  -- :Sepal open…) leaves it loading hidden
  local l, lw
  if kept then l, lw = vim.api.nvim_win_get_buf(w), w else l, lw = loading(w, "Loading agent") end
  -- printed: 200ms without output once there's text (its longest pause mid-chat is ~160ms); 3s at most
  local tick, quiet, t0, timer = -1, 0, vim.uv.now(), vim.uv.new_timer()
  timer:start(50, 50, vim.schedule_wrap(function()
    local gone = not vim.api.nvim_win_is_valid(lw) or vim.api.nvim_win_get_buf(lw) ~= l
    if gone or not vim.api.nvim_buf_is_valid(b) then
      timer:stop(); timer:close()
      return pcall(vim.api.nvim_win_close, lw, true)
    end
    local t = vim.api.nvim_buf_get_changedtick(b)
    if t ~= tick then tick, quiet = t, 0 else quiet = quiet + 50 end
    local printed = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false)):find("%S")
    if not (printed and quiet >= 200) and vim.uv.now() - t0 < 3000 then return end
    timer:stop(); timer:close()
    show(b, lw)
  end))
end

-- a small buffer to write the reply in: <c-c><c-c> sends it, <c-c><c-k> discards it
function M.reply(e)
  if M.running(e) then return notify("it's still running") end
  if not e.session then return notify("this task has no chat to continue") end
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype, vim.bo[b].bufhidden = "markdown", "wipe"
  vim.b[b].sepal_reply = e.id
  vim.api.nvim_open_win(b, true, { split = "above", win = -1, height = 6 })
  local ns = vim.api.nvim_create_namespace("sepal.reply")
  local function hint()
    vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
    if vim.api.nvim_buf_line_count(b) == 1 and vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] == "" then
      vim.api.nvim_buf_set_extmark(b, ns, 0, 0, { virt_text = { { "reply to " .. e.title .. ": <c-c><c-c> sends, <c-c><c-k> discards", "SepalDim" } }, virt_text_pos = "overlay" })
    end
  end
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = b, callback = hint })
  hint()
  vim.keymap.set({ "n", "i" }, "<c-c><c-c>", function()
    local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"))
    if text == "" then return notify("the reply is empty", WARN) end
    vim.cmd.stopinsert()
    vim.api.nvim_buf_delete(b, { force = true })
    M.continue(e, text)
  end, { buffer = b, desc = "Send the reply" })
  vim.keymap.set({ "n", "i" }, "<c-c><c-k>", function()
    vim.cmd.stopinsert()
    vim.api.nvim_buf_delete(b, { force = true })
  end, { buffer = b, desc = "Discard the reply" })
  vim.schedule(function() vim.cmd.startinsert() end)
end

vim.api.nvim_create_autocmd("VimLeavePre", { group = vim.api.nvim_create_augroup("sepal.agent", {}), callback = function()
  for _, j in pairs(jobs) do if j.job then pcall(j.job.kill, j.job, 15) end end
end })

M._t = { jobs = jobs, queue = queue }

return M
