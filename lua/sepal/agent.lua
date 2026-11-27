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
-- e's agent argv: the one picked for it (agents option), else cmd
local function base(e)
  local c = e and e.agent and e.agent.cmd or C().cmd
  return vim.list_extend({}, type(c) == "string" and { c } or c)
end
-- the two supported agents, by the executable's basename
local function raw_cmd(e)
  local c = e and e.agent and e.agent.cmd or C().cmd
  return type(c) == "string" and c or type(c) == "table" and c[1] or ""
end
M.AGENT_NAMES = { claude = "Claude Code", devin = "Devin" }
local kind_cache = {} -- executable string -> claude/devin/false: the panel asks once per card per render
-- e's agent kind ("claude" | "devin"), nil when unsupported. e may be nil (then cmd)
-- or a pseudo-entry { agent = { cmd = c } }, for setup/health
function M.kind(e)
  local c = raw_cmd(e)
  local k = kind_cache[c]
  if k == nil then
    local b = vim.fs.basename(c)
    k = b:match("^claude") and "claude" or b:match("^devin") and "devin" or false
    kind_cache[c] = k
  end
  return k or nil
end
local function claude(e) return M.kind(e) == "claude" end
local function devin(e) return M.kind(e) == "devin" end
-- added to each run: the agent's own args; the args option is Claude Code's
local function args(e) return e.agent and e.agent.args or claude(e) and C().args or {} end
-- cmd plus extra: with auto_mode, Claude Code's auto mode instead of the --permission-mode in args;
-- mode: that permission mode instead of either (a btw's read-only "plan")
local function cmd(extra, mode, e)
  local a = vim.list_extend({}, extra)
  mode = mode or C().auto_mode and "auto"
  if mode then
    for i = #a - 1, 1, -1 do if a[i] == "--permission-mode" then table.remove(a, i); table.remove(a, i) end end
    vim.list_extend(a, { "--permission-mode", mode })
  end
  return vim.list_extend(base(e), a)
end
-- the model for e's kind (models option), after args: it wins over a --model there
local function model(e)
  local m = e.agent and e.agent.model or (C().models or {})[e.kind or "implement"]
  return m and { "--model", m } or {}
end
-- a btw (a question) and an orchestrate (a plan) read your repo itself and change nothing
local function readonly(kind) return kind == "btw" or kind == "orchestrate" end
-- reading your repo itself: Claude Code's plan mode, so it can't change a file
local function mode(e) return readonly(e.kind) and "plan" or nil end

-- running work per entry id: { job (the agent, check or prepare), buf (the agent's terminal), stopped, done, update }
local jobs = {}
local queue = {} -- { e, prompt, from } waiting for a free slot (max_running), oldest first
local landing = {} -- id -> "being landed"/"being taken back": its plan runs off the main loop
-- every slot taken: a read-only run doesn't take one (no worktree)
local function full()
  local n = 0
  for _, j in pairs(jobs) do if not j.btw then n = n + 1 end end
  return C().max_running and n >= C().max_running
end
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
  local l
  if type(s) == "string" then
    for x in s:gmatch("[^\n]+") do
      x = vim.trim(x)
      if x ~= "" then l = x; break end
    end
  end
  if l and vim.fn.strchars(l) > n then l = vim.fn.strcharpart(l, 0, n - 1) .. "…" end
  return l
end
local function plural(n, word) return ("%d %s%s"):format(n, word, n == 1 and "" or "s") end
local function tail(s, n)
  s = vim.trim(s or "")
  for i = #s, 1, -1 do
    if s:byte(i) == 10 then
      n = n - 1
      if n == 0 then return s:sub(i + 1) end
    end
  end
  return s
end
local function lastline(b)
  local hi = vim.api.nvim_buf_line_count(b)
  while hi > 0 do
    local lo = math.max(hi - 200, 0)
    local ls = vim.api.nvim_buf_get_lines(b, lo, hi, false)
    for i = #ls, 1, -1 do
      local l = ls[i]
      if vim.trim(l) ~= "" and not l:match("^%[Process exited") then return l end
    end
    hi = lo
  end
end

local function ref(e, what) return "refs/sepal/" .. e.id .. "/" .. what end
local function wtdir(e)
  local dir = vim.fs.joinpath(C().worktrees, inbox.key(e.root), e.id)
  local legacy = vim.fs.joinpath(C().worktrees, (e.root:gsub("[^%w]", "-")), e.id)
  return not vim.uv.fs_stat(dir) and vim.uv.fs_stat(legacy) and legacy or dir
end

-- the task's check ("Done when: make test") and title (Goal, else its first line)
local FIELDS = { { "Done when", "^%s*Done when:%s*(.-)%s*$" }, { "Goal", "^%s*Goal:%s*(.-)%s*$" } }
function M.parse(text)
  local f = {}
  for l in (text .. "\n"):gmatch("([^\n]*)\n") do
    for _, k in ipairs(FIELDS) do
      local v = l:match(k[2])
      if v and v ~= "" and not f[k[1]] then f[k[1]] = v end
    end
  end
  return f["Done when"], first(f.Goal or text, 40) or "task"
end

-- what sepal tells the agent besides the task; again: its chat already has them (a reply, a resume)
local function notes(e, again)
  if again then return "\n---\n(from sepal: same rules as before, and end the same way)" end
  if e.kind == "btw" then
    return table.concat({ "", "---", "How to answer this (from sepal, not part of the question):",
      "- A question, not a change: answer from the code as it is now. Read what you need; don't edit files or ask to." }, "\n")
  end
  if e.kind == "orchestrate" then
    local models = sepal().plan_models()
    return table.concat({ "", "---", "How to plan this (from sepal, not part of the task):",
      "- Change nothing: read the code and plan the work as tasks for other agents. Each runs alone in its own git worktree, in parallel,"
        .. " blind to the others' changes: each must stand on its own.",
      "- As few tasks as the work needs: split only into independent parts (other files or areas).",
      "- Each task's model: the cheapest that will do it well" .. (#models > 0
        and (", only from these: %s (or default: the agent's own)"):format(table.concat(models, ", ")) or "") .. ".",
      "- Each task: what to change and where (Goal), a shell command proving it (Done when"
        .. (e.check and (", `%s` if nothing narrower fits"):format(e.check) or "") .. "), its files.",
      "- End with the plan in exactly this form, then the decisions a reviewer should know:",
      "Plan:", "1. [model] short title", "   Goal: ...", "   Done when: <command>", "   Files:", "   - @path",
      "2. [model] short title", "   ...", "", "Assumptions:\n- <one per line>\n(or \"Assumptions: none\")" }, "\n")
  end
  local n = { "", "---", "How to work on this (from sepal, not part of the task):",
    "- You're in a git worktree: edit here, decide instead of asking. Don't commit, push or switch branches.",
    "- Your shell starts in the worktree: never `cd` to its path." }
  if e.check then n[#n + 1] = ("- Done when `%s` passes. sepal runs it when you end and sends you its failures:"
    .. " don't run it yourself (its output costs tokens); to try your change, run only the narrowest test of it."):format(e.check) end
  n[#n + 1] = "- End with only what the user must know, no summary:"
  n[#n + 1] = "Not done:\n- <left undone or unchecked; drop if nothing>"
  n[#n + 1] = "Assumptions:\n- <a decision the task left open, one per line; end it with (path:line) when it is about one line>\n(or \"Assumptions: none\")"
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

-- the (path:line) an assumption ends with: path, lnum
function M.where(a)
  local p, l = a:match("%(([^%s():]+):(%d+)%)%s*$")
  return p, tonumber(l)
end

-- a model as written in a plan line: "" and "default" are the agent's own (nil)
function M.model_of(s)
  s = vim.trim(s or "")
  return s ~= "" and s:lower() ~= "default" and s or nil
end

-- the "Plan:" list at the end of an orchestrate's reply, in order: { { title, model, task } }.
-- An item is "1. [model] title" (or "- [model] title"), the lines indented under it are its task
function M.plan(reply)
  if type(reply) ~= "string" then return {} end
  local lines, at = vim.split(reply, "\n"), nil
  for i, l in ipairs(lines) do if l:match("^[%s%*#_]*Plan[%*_]*:[%*_]*%s*$") then at = i end end
  if not at then return {} end
  local items, cur = {}, nil
  for i = at + 1, #lines do
    local l = lines[i]
    local ind = #l:match("^%s*")
    local m, title = l:match("^%s*%d+[.)]%s+%[([^%]]*)%]%s*(.-)%s*$")
    if not m then m, title = l:match("^%s*[-*]%s+%[([^%]]*)%]%s*(.-)%s*$") end
    if m and (not cur or ind <= cur.ind) then
      cur = { model = M.model_of(m), title = (title:gsub("^%*%*(.-)%*%*$", "%1")), body = {}, ind = ind }
      items[#items + 1] = cur
    elseif cur and (vim.trim(l) == "" or ind > cur.ind) then cur.body[#cur.body + 1] = l
    elseif cur then break end -- past the plan: Assumptions:
  end
  return vim.tbl_map(function(it)
    while #it.body > 0 and vim.trim(it.body[#it.body]) == "" do it.body[#it.body] = nil end
    local cut = math.huge
    for _, l in ipairs(it.body) do if vim.trim(l) ~= "" then cut = math.min(cut, #l:match("^%s*")) end end
    local body = vim.tbl_map(function(l)
      l = l:sub(cut + 1)
      return (l:gsub("^(%s*Done when:%s*)`(.-)`%s*$", "%1%2")) -- run by sh: backticks would be a substitution
    end, it.body)
    local task = table.concat(body, "\n")
    if not task:match("^%s*Goal:") and not task:match("\n%s*Goal:") then task = "Goal: " .. it.title .. (task ~= "" and "\n" .. task or "") end
    return { title = it.title ~= "" and it.title or (first(task:gsub("^%s*Goal:%s*", ""), 40) or "task"), model = it.model, task = task }
  end, items)
end

-- "3 tasks: 2 opus, 1 sonnet"
local function plan_summary(plan)
  local n, order = {}, {}
  for _, p in ipairs(plan) do
    local m = p.model or "default"
    if not n[m] then order[#order + 1] = m end
    n[m] = (n[m] or 0) + 1
  end
  return plural(#plan, "task") .. ": " .. table.concat(vim.tbl_map(function(m) return n[m] .. " " .. m end, order), ", ")
end
M.plan_summary = plan_summary

-- the task that item i of e's plan becomes: its own text, e's check when it has none, and the
-- plan's other tasks, so it sticks to its part
function M.subtask(e, i)
  local plan = e.plan
  local t = plan[i].task
  if e.check and not ("\n" .. t):match("\n%s*Done when:") then t = t .. "\n\nDone when: " .. e.check end
  if #plan > 1 then
    local o = { "", ("Part of a plan, task %d of %d (the others run in parallel: do only this one):"):format(i, #plan) }
    for k, p in ipairs(plan) do o[#o + 1] = ("%d. %s"):format(k, p.title) end
    t = t .. "\n" .. table.concat(o, "\n")
  end
  return t
end

-- what a tool call is about, for the spinner: "Edit src/pool.cpp", "Bash make test"
local TOOL_ARG = { "command", "pattern", "url", "description" }
local function about(tool, wt)
  local i = type(tool.input) == "table" and tool.input or {}
  local p = type(i.file_path) == "string" and i.file_path or type(i.path) == "string" and i.path or nil
  if p and vim.startswith(p, wt .. "/") then p = p:sub(#wt + 2) end
  local arg = p
  for _, k in ipairs(TOOL_ARG) do
    if not arg and type(i[k]) == "string" then arg = i[k] end
  end
  return tostring(tool.name) .. (arg and " " .. first(arg, 50) or "")
end

local function bufs_by_name()
  local by = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then by[name] = by[name] or b end
    end
  end
  return by
end
-- reload the buffers of files that changed on disk (:checktime alone skips hidden buffers)
local function reload(changes, bufs)
  for _, c in ipairs(changes) do
    local b = bufs[c.path]
    if b then vim.api.nvim_buf_call(b, function() pcall(vim.cmd, "silent! checktime") end) end
  end
end

local function facts(e)
  local f = {}
  if e.stat and e.stat.files > 0 then f[#f + 1] = ("%s +%d −%d"):format(plural(e.stat.files, "file"), e.stat.add, e.stat.del) end
  if e.check and e.checked ~= nil then f[#f + 1] = e.check .. (e.checked and " ✔" or " ✘") end
  if e.vacuous then f[#f + 1] = "▲ the check passed before the agent" end
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
  if wt and wt ~= e.root then git.remove_worktree(e.root, wt) end -- a btw runs in your repo: never that
  e.status, e.activity, e.subagents = status, nil, nil -- usage stays: the card shows what the run used
  for k, v in pairs(extra or {}) do e[k] = v end
  inbox.changed(e)
  if j and j.done then j.done(true) end
  if status == "stopped" then notify("stopped: " .. e.title)
  elseif status == "error" then notify("✘ " .. e.title .. ": " .. tostring(e.error) .. " · :Sepal inbox", ERROR)
  elseif status == "failed" then
    local tries = (e.attempts or 0) + 1
    notify(("✘ %s: `%s` still fails after %d %s · :Sepal inbox"):format(e.title, e.check, tries, tries == 1 and "try" or "tries"), WARN)
  elseif status == "nochange" then notify("no changes: " .. e.title .. (e.summary and ": " .. e.summary or ""))
  elseif status == "answered" then notify("● " .. e.title .. ": " .. tostring(e.summary) .. " · <CR> in :Sepal inbox reads it")
  elseif status == "planned" then
    notify(("◇ plan ready: %s · %s · s in :Sepal inbox makes the tasks, m sets a model"):format(e.title, plan_summary(e.plan)))
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
    agent(e, ("`%s` failed (exit %d):\n```\n%s\n```\nFix it so it passes; same rules as before, and end the same way.")
      :format(e.check, out.code, e.check_out), wt)
  end))
  if not ok then return finish(e, wt, "error", { error = "could not run the check: " .. tostring(job):match("[^\n]*") }) end
  jobs[e.id].job = job
end

-- Claude Code reports back through hooks: each one appends its input (a JSON line) to $SEPAL_EVENTS
local HOOK = { { hooks = { { type = "command", command = [[{ tr -d '\n'; echo; } >> "$SEPAL_EVENTS"]] } } } }
-- allow: rules that would otherwise stop the turn for approval (read-only git, the check behind a `cd`);
-- statusLine appends its stdin JSON to the same file: it carries the context window
local function settings(allow)
  return vim.json.encode({ permissions = { allow = allow }, statusLine = { type = "command", command = HOOK[1].hooks[1].command },
    hooks = { SessionStart = HOOK, PreToolUse = { { matcher = "*", hooks = HOOK[1].hooks } },
    Notification = HOOK, Stop = HOOK, SubagentStart = HOOK, SubagentStop = HOOK } })
end

-- Devin reads hooks and permissions from its config file only: yours plus sepal's hooks and allow rules, at path
-- shortcut: a config.json with comments (JSONC) doesn't decode and is replaced, not merged; strip them if that bites
local function devin_config(path, allow)
  local dir = vim.env.XDG_CONFIG_HOME or vim.fs.joinpath(vim.uv.os_homedir(), ".config")
  local f = io.open(vim.fs.joinpath(dir, "devin", "config.json"))
  local ok, c = pcall(vim.json.decode, f and f:read("a") or "{}")
  if f then f:close() end
  c = ok and type(c) == "table" and c or {}
  c.hooks = vim.tbl_extend("force", type(c.hooks) == "table" and c.hooks or {}, { SessionStart = HOOK,
    PreToolUse = { { matcher = "*", hooks = HOOK[1].hooks } }, Notification = HOOK, PermissionRequest = HOOK, Stop = HOOK })
  c.permissions = type(c.permissions) == "table" and c.permissions or {}
  c.permissions.allow = vim.list_extend(type(c.permissions.allow) == "table" and c.permissions.allow or {}, allow)
  local w = assert(io.open(path, "w"))
  w:write(vim.json.encode(c))
  w:close()
end

-- Devin says nothing live about its context window: its transcript's final_metrics has the totals
-- (what /usage shows as "in · out"). Read only its tail (a transcript can be MBs), and only when it
-- changed; st is per-run { size, mtime }. Returns { used, out } (nil with no match yet) and the
-- number of bytes read.
local function dvpath(session)
  local dir = vim.env.XDG_DATA_HOME or vim.fs.joinpath(vim.uv.os_homedir(), ".local", "share")
  return vim.fs.joinpath(dir, "devin", "cli", "transcripts", session .. ".json")
end
local function devin_usage(path, st)
  local s = vim.uv.fs_stat(path)
  if not s or (st.size == s.size and st.mtime and st.mtime.sec == s.mtime.sec and st.mtime.nsec == s.mtime.nsec) then
    return nil, 0
  end
  local f = io.open(path)
  if not f then return nil, 0 end
  local off = math.max(s.size - 4096, 0)
  f:seek("set", off)
  local tail = f:read("a") or ""
  f:close()
  st.size, st.mtime = s.size, s.mtime
  local prompt = tail:match('"total_prompt_tokens"%s*:%s*(%d+)')
  if not prompt then return nil, s.size - off end
  local completion = tail:match('"total_completion_tokens"%s*:%s*(%d+)')
  return { used = tonumber(prompt), out = tonumber(completion) }, s.size - off
end

-- the agent's last reply: from the Stop hook, else the end of its transcript (read backwards:
-- a transcript can be MBs of tool output, the reply is its last assistant line with text)
local function reply_of(ev)
  if type(ev.last_assistant_message) == "string" then return ev.last_assistant_message end
  local f = type(ev.transcript_path) == "string" and io.open(ev.transcript_path)
  if not f then return nil end
  local size = f:seek("end") or 0
  local chunk, hi, carry = 65536, size, ""
  while hi > 0 do
    local off = math.max(hi - chunk, 0)
    f:seek("set", off)
    local data = (f:read(hi - off) or "") .. carry
    local parse = data
    if off > 0 then
      local nl = data:find("\n", 1, true)
      if nl then carry, parse = data:sub(1, nl - 1), data:sub(nl + 1)
      else carry, parse = data, "" end -- the first line continues into bytes not read yet
    else carry = "" end
    local upto = #parse + 1
    for i = #parse, 0, -1 do
      if i == 0 or parse:byte(i) == 10 then
        local l = parse:sub(i + 1, upto - 1)
        upto = i
        if l ~= "" then
          -- decode only the agent's lines: a transcript can be MBs of tool output
          local ok, t = false, nil
          if l:find('"assistant"', 1, true) then ok, t = pcall(vim.json.decode, l, { luanil = { object = true, array = true } }) end
          local c = ok and type(t) == "table" and t.type == "assistant" and type(t.message) == "table" and t.message.content
          local text = {}
          for _, x in ipairs(type(c) == "table" and c or {}) do
            if type(x) == "table" and x.type == "text" and type(x.text) == "string" then text[#text + 1] = x.text end
          end
          if #text > 0 then f:close() return table.concat(text, "\n") end
        end
      end
    end
    if off == 0 then break end
    hi = off
    chunk = math.min(chunk * 2, hi) -- not found yet: a bigger share of what remains, up to all of it
  end
  f:close()
  return nil
end


-- the whole editor: the agent's terminal is this size from its start to every :Sepal open
local function screen()
  return { relative = "editor", row = 0, col = 0, style = "minimal", zindex = 1, -- under notifications
    width = vim.o.columns, height = math.max(vim.o.lines - vim.o.cmdheight, 1) }
end
-- no line numbers on an agent's window, whatever the buffer shown there before had
local function termwin(w) vim.wo[w].number, vim.wo[w].relativenumber = false, false end

-- the position after the last newline of s, like s:match(".*\n()"), without pattern matching
local function last_nl(s)
  for i = #s, 1, -1 do
    if s:byte(i) == 10 then return i + 1 end
  end
end

-- the agent: Claude Code itself, in a hidden terminal buffer (:Sepal open shows it). Its turn is over
-- at the Stop hook; then it's closed, and sepal checks and lands what it did
agent = function(e, prompt, wt)
  local j = jobs[e.id]
  if not M.kind(e) then -- before anything: only claude or devin run
    return finish(e, wt, "error", { error = "unsupported agent " .. tostring(base(e)[1]) .. ": sepal runs claude or devin" })
  end
  local events = wtdir(e) .. ".events" -- beside its worktree: a btw has none, and runs in your repo
  os.remove(events)
  local dv, conf, dvst = devin(e), events .. ".config.json", {} -- dvst: its transcript as last read
  local dv_sid, dv_path -- session -> transcript path: joining it every tick allocates
  local function devin_transcript()
    if e.session ~= dv_sid then
      dv_sid = e.session
      dv_path = type(e.session) == "string" and e.session:match("^[%w-]+$") and dvpath(e.session) or nil
    end
    return dv_path
  end
  -- it has to run the check; files from outside the repo (<c-c><c-p>'s pasted images): read-only access to just those
  local allow = e.check and { (dv and "Exec(%s)" or "Bash(%s)"):format(e.check) } or {}
  for l in vim.gsplit(e.task, "\n") do
    local f = l:match("^%s*%- @(/.-)%s*$")
    if f then allow[#allow + 1] = "Read(" .. (dv and "" or "/") .. f .. ")" end -- Claude Code's "//" is an absolute path
  end
  local argv
  if dv then
    devin_config(conf, allow)
    local a = vim.list_extend({}, args(e))
    -- its modes: auto (read-only tools), accept-edits (and edits), smart (and what a fast model judges safe)
    local m = readonly(e.kind) and "auto" or C().auto_mode and "smart" or not vim.tbl_contains(a, "--permission-mode") and "accept-edits"
    if m then
      for i = #a - 1, 1, -1 do if a[i] == "--permission-mode" then table.remove(a, i); table.remove(a, i) end end
      vim.list_extend(a, { "--permission-mode", m })
    end
    -- the trust prompt would hold up each new worktree
    argv = vim.list_extend(vim.list_extend(base(e), a), { "--config", conf, "--respect-workspace-trust", "false" })
    vim.list_extend(argv, model(e))
  else
    argv = vim.list_extend(cmd(args(e), mode(e), e), model(e))
    for _, r in ipairs(allow) do vim.list_extend(argv, { "--allowedTools", r }) end
  end
  local asked -- the --model it runs with: Devin's SessionStart names a fusion's lead model only, so it keeps that
  for i, a in ipairs(argv) do if a == "--model" and argv[i + 1] then e.model, asked = argv[i + 1], dv end end -- till SessionStart says
  if e.session then vim.list_extend(argv, { dv and "-r" or "--resume", e.session }) end
  vim.list_extend(argv, dv and { "--", prompt } or { "--settings", settings(vim.list_extend({ "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)" },
    e.check and wt and { ("Bash(cd %s && %s)"):format(wt, e.check) } or {})), prompt })
  local b = vim.api.nvim_create_buf(false, true)
  local started, over, timer = false, false, vim.uv.new_timer()
  local fs_event
  local function close()
    over = true
    timer:stop(); timer:close()
    if fs_event then fs_event:stop(); fs_event:close(); fs_event = nil end
    os.remove(events)
    os.remove(conf)
    if not vim.api.nvim_buf_is_valid(b) then return end
    local last = lastline(b)
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
        return last
      end
    end
    for _, w in ipairs(vim.fn.win_findbuf(b)) do pcall(vim.api.nvim_win_close, w, true) end
    pcall(vim.api.nvim_buf_delete, b, { force = true }) -- ends claude too
    return last
  end
  local function stopped(ev) -- the turn is over: what it did is kept even when its check fails
    close()
    if dv then -- Devin writes its transcript as it exits: its totals come after the turn, read them for 10 s
      local t, n = vim.uv.new_timer(), 0
      t:start(200, 200, vim.schedule_wrap(function()
        n = n + 1
        local path = devin_transcript()
        local u = path and devin_usage(path, dvst)
        if u or n >= 50 then t:stop(); t:close() end
        if u and not vim.deep_equal(u, e.usage) then e.usage = u; inbox.changed(e) end
      end))
    end
    local reply = reply_of(ev)
    if readonly(e.kind) then -- its answer is what it did: kept whole, nothing to land
      e.answer, e.summary = reply or e.answer, first(reply, 100) or e.summary
      local status = j.stopped and "stopped" or reply and "answered" or "error"
      local extra = not reply and not j.stopped and { error = "the agent ended its turn without an answer" } or nil
      if e.kind == "orchestrate" and status == "answered" then -- a plan: its tasks, to swarm it into
        e.assumptions = M.assumptions(reply)
        local plan = M.plan(reply)
        if #plan > 0 then e.plan, status = plan, "planned"
        else status, extra = "error", { error = "its reply has no Plan: list · <CR> reads it, r asks again" } end
      end
      return finish(e, wt, status, extra)
    end
    git.result(e.root, wt, e.base, ref(e, "result"), e.exclude, function(result)
      e.result = result or e.result
      local function rest()
        e.summary = first(reply, 100) -- the reply itself isn't kept: only its summary and assumptions are shown
        local seen = {}
        for _, a in ipairs(e.assumptions or {}) do seen[a] = true end
        for _, a in ipairs(M.assumptions(reply)) do -- a retry adds to them
          if not seen[a] then e.assumptions = e.assumptions or {}; e.assumptions[#e.assumptions + 1] = a end
        end
        if j.stopped then return finish(e, wt, "stopped") end -- x while its result was saved
        if e.check then return check(e, wt) end
        done(e, wt)
      end
      if e.result then return git.stat_bg(e.root, e.base, e.result, function(st) e.stat = st; rest() end) end
      rest()
    end)
  end
  local transcript, toff = nil, 0
  -- an Esc in Claude Code ends the turn without a Stop hook: its transcript says so
  local function interrupted()
    local st = transcript and vim.uv.fs_stat(transcript) -- polled 10 times a second: open it only when it grew
    local f = st and st.size > toff and io.open(transcript)
    if not f then return end
    f:seek("set", toff)
    local s = f:read("a")
    f:close()
    local cut = last_nl(s)
    if not cut then return end
    toff = toff + cut - 1
    if not s:find("[Request interrupted by user", 1, true) then return end
    for l in s:sub(1, cut - 1):gmatch("[^\n]+") do
      local ok, t = false, nil
      if l:find("[Request interrupted by user", 1, true) then ok, t = pcall(vim.json.decode, l, { luanil = { object = true, array = true } }) end
      local c = ok and type(t) == "table" and t.type == "user" and type(t.message) == "table" and t.message.content
      local b = type(c) == "table" and c[1]
      -- its own text block, not a tool's output that happens to quote it
      if type(b) == "table" and b.type == "text" and type(b.text) == "string" and vim.startswith(b.text, "[Request interrupted by user") then
        return true
      end
    end
  end
  local off, dirty = 0, false -- dirty: an event changed what the inbox shows; poll renders once
  local function event(line)
    local ok, ev = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if over or not ok or type(ev) ~= "table" then return end
    -- a statusLine line (no hook_event_name, a context_window table): the context window only,
    -- and not an event — it must not end the trust-prompt detection
    if not ev.hook_event_name and type(ev.context_window) == "table" then
      local u = ev.context_window.current_usage
      if type(u) == "table" then
        local usage = { used = (u.input_tokens or 0) + (u.cache_creation_input_tokens or 0) + (u.cache_read_input_tokens or 0),
          limit = type(ev.context_window.context_window_size) == "number" and ev.context_window.context_window_size or nil }
        if not vim.deep_equal(usage, e.usage) then e.usage, dirty = usage, true end
      end
      return
    end
    started = true
    if not transcript and type(ev.transcript_path) == "string" then -- a resumed chat's old turns don't count
      transcript = ev.transcript_path
      local st = vim.uv.fs_stat(transcript)
      toff = st and st.size or 0
    end
    if type(ev.session_id) == "string" and ev.session_id ~= e.session then
      e.session = ev.session_id
      inbox.save(e.root) -- now, not when it finishes: a quit mid-run keeps the chat for o and r
    end
    if not asked and type(ev.model) == "string" and ev.model ~= e.model then e.model = ev.model; dirty = true end -- SessionStart says it
    local name = ev.hook_event_name
    if name == "PreToolUse" then
      e.activity = about({ name = ev.tool_name, input = ev.tool_input }, wt)
      j.update(e.title .. ": " .. e.activity)
      dirty = true
    elseif name == "Notification" or name == "PermissionRequest" then -- Devin asks for a tool with the latter
      e.activity = "needs you"
      dirty = true
      local msg = ev.message or name == "PermissionRequest" and "asks to run " .. about({ name = ev.tool_name, input = ev.tool_input }, wt)
      notify("▲ " .. e.title .. ": " .. tostring(msg or "it needs you") .. " · :Sepal open", WARN)
    elseif name == "SubagentStart" then -- running subagents, in the order they started
      e.subagents = e.subagents or {}
      table.insert(e.subagents, { id = ev.agent_id, name = tostring(ev.agent_type or "agent") })
      dirty = true
    elseif name == "SubagentStop" then
      for i, a in ipairs(e.subagents or {}) do
        if a.id == ev.agent_id then table.remove(e.subagents, i); break end
      end
      dirty = true
    elseif name == "Stop" then
      stopped(ev)
    end
  end
  local function poll()
    local st = vim.uv.fs_stat(events)
    local f = st and st.size > off and io.open(events)
    if not f then return end
    f:seek("set", off)
    local s = f:read("a")
    f:close()
    local cut = last_nl(s)
    if not cut then return end
    off = off + cut - 1
    for l in s:sub(1, cut - 1):gmatch("[^\n]+") do event(l) end
    if dirty then dirty = false; if not over then inbox.render() end end -- one render per read, not per line
  end
  local events_base = vim.fs.basename(events)
  local poll_scheduled = false
  local ok, handle = pcall(vim.uv.new_fs_event)
  if ok and handle then
    local started_watch, res = pcall(function()
      return handle:start(vim.fs.dirname(events), {}, function(_, fname)
        if (fname == nil or fname == events_base) and not poll_scheduled then
          poll_scheduled = true
          vim.schedule(function()
            poll_scheduled = false
            if not over then poll() end
          end)
        end
      end)
    end)
    if started_watch and res ~= nil then fs_event = handle else pcall(handle.close, handle) end
  end
  local function exited(_, code)
    if over then return end
    poll()
    if over then return end
    if j.stopped then return stopped({ transcript_path = transcript }) end -- x: what it did so far is kept, as with Esc
    local last = close()
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
  if dv then
    -- an interrupt (ctrl-c) runs no hook: Devin's state escape goes from working to idle (a finished turn says done)
    local busy = false
    vim.api.nvim_create_autocmd("TermRequest", { buffer = b, callback = function(ev)
      local st = type(ev.data) == "table" and tostring(ev.data.sequence or ""):match("^\27%]7501;state=(%a+)")
      if st == "working" or st == "done" then busy = st == "working" end
      if st ~= "idle" or not busy then return end
      vim.schedule(function()
        if over then return end
        poll() -- a Stop the timer hasn't read yet wins
        if over then return end
        j.stopped = true -- what it did so far is kept, as with x
        stopped({})
      end)
    end })
  end
  local term_name = vim.api.nvim_buf_get_name(b)
  pcall(vim.api.nvim_buf_set_name, b, "sepal://" .. e.id)
  for _, x in ipairs(vim.api.nvim_list_bufs()) do -- a rename keeps the old name as a buffer of its own: one per run
    if x ~= b and vim.api.nvim_buf_get_name(x) == term_name then pcall(vim.api.nvim_buf_delete, x, { force = true }) end
  end
  vim.keymap.set("n", "q", function() sepal().close() end, { buffer = b, desc = "Hide the agent (it keeps working)" })
  j.buf, j.job = b, { kill = function() vim.fn.jobstop(chan) end }
  if watching(j) then show(b, j.watch.win) end -- a retry, watched
  j.watch = nil
  local asked, btick -- Claude Code asks to trust each new folder before it starts (no hook runs before that)
  timer:start(100, 100, vim.schedule_wrap(function()
    if over then return end
    poll()
    local path = dv and devin_transcript() -- it goes in a path
    if path then
      local u = devin_usage(path, dvst)
      if u and not vim.deep_equal(u, e.usage) then e.usage = u; inbox.render() end
    end
    if not over and interrupted() then
      j.stopped = true -- what it did so far is kept, as with x
      return stopped({ transcript_path = transcript })
    end
    if started or asked or not vim.api.nvim_buf_is_valid(b) then return end
    -- the prompt is on the first screen: no need to join the scrollback, and it's read
    -- only when something was printed since last time, not every tick
    local t = vim.api.nvim_buf_get_changedtick(b)
    if t == btick then return end
    btick = t
    if table.concat(vim.api.nvim_buf_get_lines(b, 0, vim.o.lines, false), " "):find("Quick safety check", 1, true) then
      asked, e.activity = true, "needs you"
      inbox.render()
      notify("▲ " .. e.title .. ": Claude Code asks to trust the worktree · :Sepal open", WARN)
    end
  end))
end

-- no spinner while a task runs: finish notifies when it's over
local function quiet() end

-- a fresh worktree of `from` for e, prepared (C.prepare), then the agent on prompt;
-- with max_running tasks already running it waits in the queue
local function launch(e, prompt, from)
  if readonly(e.kind) then -- a question or a plan: in your repo, read-only, at once; no worktree, prepare or slot
    jobs[e.id] = { update = quiet, btw = true }
    e.status = "running"
    inbox.changed(e)
    vim.fn.mkdir(vim.fs.dirname(wtdir(e)), "p") -- for its events file
    return agent(e, prompt, e.root)
  end
  if full() then
    e.status = "queued"
    queue[#queue + 1] = { e, prompt, from }
    return inbox.changed(e)
  end
  local wt = wtdir(e)
  if vim.uv.fs_stat(wt) then git.remove_worktree(e.root, wt) end
  jobs[e.id] = { update = quiet } -- from here it counts as running: x stops it, max_running counts it
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
  e.exclude = nil -- on e, not the job: c salvages a worktree left by a quit after a restart
  local function go()
    if e.check and not e.result then
      update(e.title .. ": checking the base")
      local cok, job = pcall(vim.system, { "sh", "-c", e.check }, { cwd = wt, text = true }, vim.schedule_wrap(function(out)
        local j = jobs[e.id]
        if not j or j.stopped then return finish(e, wt, "stopped") end
        if out.code == 0 then
          e.vacuous = true
          inbox.changed(e)
          notify("▲ " .. e.title .. ": the check already passes · x stops it, r gives a better check", WARN)
        end
        agent(e, prompt, wt)
      end))
      if not cok then return agent(e, prompt, wt) end
      jobs[e.id].job = job
      return
    end
    agent(e, prompt, wt)
  end
  if not prepare then return go() end
  update(e.title .. ": preparing")
  local pok, job = pcall(vim.system, { "sh", "-c", prepare }, { cwd = wt, text = true, env = { SEPAL_ROOT = e.root } }, vim.schedule_wrap(function(out)
    local j = jobs[e.id]
    if not j or j.stopped then return finish(e, wt, "stopped") end
    if out.code ~= 0 then
      return finish(e, wt, "error", { error = "prepare failed: " .. (first((out.stderr or "") .. "\n" .. (out.stdout or ""), 200) or ("exit " .. out.code)) })
    end
    -- whatever prepare made (node_modules links, builds…) isn't the agent's work
    git.status_bg(wt, function(st)
      local j = jobs[e.id]
      if not j or j.stopped then return finish(e, wt, "stopped") end
      e.exclude = {}
      for entry in st:gmatch("[^%z]+") do e.exclude[#e.exclude + 1] = entry:sub(4) end
      go()
    end)
  end))
  if not pok then return finish(e, wt, "error", { error = "could not run prepare: " .. tostring(job):match("[^\n]*") }) end
  jobs[e.id].job = job
end

-- a slot is free: the oldest queued task starts
function M._next()
  if full() then return end
  local q = table.remove(queue, 1)
  if q then launch(q[1], q[2], q[3]) end
end
local function queued(e)
  for i, q in ipairs(queue) do if q[1].id == e.id then return i end end
end

-- a new entry for text in root's inbox (see M.start for the rest)
local function entry(text, root, land, kind, agent)
  local check, title = M.parse(text)
  local btw = kind == "btw"
  -- a question has nothing to check (nor the check option); a plan's is its tasks'
  local e = { id = os.date("%Y%m%d-%H%M%S") .. ("-%04x"):format(vim.uv.hrtime() % 0x10000), root = root, title = title,
    task = text, check = not btw and (check or C().check) or nil, time = os.time(),
    status = not readonly(kind) and full() and "queued" or "running",
    attempts = 0, land = land, kind = (btw or kind == "orchestrate") and kind or nil }
  while inbox.find(root, e.id) do e.id = e.id:sub(1, -5) .. ("%04x"):format((tonumber(e.id:sub(-4), 16) + 1) % 0x10000) end -- several at once
  agent = agent or (C().agents or {})[1]
  if agent then e.agent = { cmd = agent.cmd, model = agent.model, args = agent.args } end -- kept with the task: r and c use it again
  inbox.add(e)
  return e
end

-- es are new tasks of root (jobs[e.id] = {} while saving): your work tree is saved once for all of
-- them, each keeps it at its base ref, then they start (or wait their turn) in order. on_fail(why)
-- if saving fails: they're gone from the inbox then
local function snapshot_for(es, root, on_fail)
  local function fail()
    inbox.batch(function() for _, e in ipairs(es) do jobs[e.id] = nil; inbox.remove(e) end end)
    M._next()
    return (on_fail or function(why) notify(why, ERROR) end)("could not save your work tree (git add / write-tree failed)")
  end
  local refs = vim.tbl_map(function(e) return ref(e, "base") end, es)
  git.snapshot(root, refs, function(base)
    if not base then return fail() end
    inbox.batch(function()
      for _, e in ipairs(es) do
        local j = jobs[e.id]
        jobs[e.id] = nil
        e.base, e.base0 = base, base
        if j.stopped then
          e.status = "stopped"
          inbox.changed(e)
          notify("stopped: " .. e.title)
        else
          queue[#queue + 1] = { e, e.task .. "\n" .. notes(e), base } -- behind the tasks queued before it
        end
      end
      for _ = 1, #es do M._next() end
      for _, e in ipairs(es) do
        if queued(e) and e.status ~= "queued" then e.status = "queued"; inbox.changed(e) end
      end
    end)
  end)
end

-- run a new task from cwd; nil, why when it can't. Your work tree is saved in the background, then
-- it starts (or waits its turn); on_fail(why) if saving fails (the task is gone from the inbox then)
-- land: "auto" / "manual" for this task, nil: the land option
-- kind: "btw" for a question, "orchestrate" for a plan of tasks (see sepal.task), nil/"implement" for a change
-- agent: { cmd, model } from the agents option (nil: its first, or cmd and models when it's not set)
function M.start(text, cwd, land, on_fail, kind, agent)
  local root = git.root(cwd)
  if not root then return nil, "not in a git repository: a task runs in a git worktree" end
  local e = entry(text, root, land, kind, agent)
  if readonly(kind) then launch(e, text .. "\n" .. notes(e)); return e end -- reads your repo as it is: no snapshot
  jobs[e.id] = {} -- from here it counts as running: x stops it, :Sepal open says it's starting
  snapshot_for({ e }, root, on_fail)
  return e
end

-- run several new tasks from cwd at once: specs = { { text, agent } }, the first one starts first;
-- your work tree is saved once for all of them. The list of entries, or nil, why
function M.start_many(specs, cwd, land, on_fail)
  local root = git.root(cwd)
  if not root then return nil, "not in a git repository: a task runs in a git worktree" end
  if #specs == 0 then return nil, "no tasks to start" end
  local es = {}
  inbox.batch(function()
    for i = #specs, 1, -1 do -- the inbox is newest first: the first task on top
      es[i] = entry(specs[i].text, root, land, nil, specs[i].agent)
      jobs[es[i].id] = {}
    end
  end)
  snapshot_for(es, root, on_fail)
  return es
end

-- :Sepal qf: the quickfix list as a planned orchestrate, one task per file (siblings never collide
-- when landing), no planner. The entry, or nil, why
function M.plan_from_qf(cwd)
  local root = git.root(cwd)
  if not root then return nil, "not in a git repository: a task runs in a git worktree" end
  local by, order = {}, {}
  for _, it in ipairs(vim.fn.getqflist()) do
    if it.bufnr > 0 and vim.api.nvim_buf_is_valid(it.bufnr) then
      local name = vim.api.nvim_buf_get_name(it.bufnr)
      local rel = vim.fs.relpath(root, name) or name
      if not by[rel] then by[rel] = {}; order[#order + 1] = rel end
      table.insert(by[rel], ("%d: %s"):format(it.lnum, vim.trim(it.text)))
    end
  end
  if #order == 0 then return nil, "the quickfix list is empty" end
  local items = vim.tbl_map(function(rel)
    local l = by[rel]
    return { title = ("fix %s: %s"):format(rel, plural(#l, "item")), model = nil,
      task = "Goal: fix these in " .. rel .. "\n" .. table.concat(l, "\n") .. "\nFiles:\n- @" .. rel }
  end, order)
  local e = entry(("Fix the quickfix list (%d files)"):format(#order), root, nil, "orchestrate")
  e.plan, e.status, e.check = items, "planned", C().check or (sepal().find_check(root))
  inbox.changed(e)
  notify(("◇ plan ready: %s · %s · s in :Sepal inbox makes the tasks, m sets a model"):format(e.title, plan_summary(e.plan)))
  return e
end

-- s: a planned orchestrate becomes its tasks, one per item of its plan, each run by the agent with
-- the item's model (agents option), else by the orchestrate's agent with that model; they land like the orchestrate was sent (<c-c><c-c> by themselves, <c-c><c-w> on L)
function M.swarm(e)
  if e.kind ~= "orchestrate" then return notify("only an orchestrate task swarms into tasks") end
  if M.running(e) then return notify("it's still planning") end
  if e.status == "swarmed" then return notify("already swarmed: its tasks are in the inbox") end
  if e.status ~= "planned" or #(e.plan or {}) == 0 then return notify("it has no plan to swarm: r asks for one") end
  local specs = {}
  for i, p in ipairs(e.plan) do
    local a
    for _, x in ipairs(p.model and C().agents or {}) do if x.model == p.model then a = vim.deepcopy(x); break end end
    a = a or vim.tbl_extend("force", e.agent or {}, { model = p.model }) -- no model: the agent's, else models.implement
    specs[i] = { text = M.subtask(e, i), agent = next(a) and a or nil }
  end
  local es, why = M.start_many(specs, e.root, e.land, function(why)
    e.status, e.swarm = "planned", nil
    inbox.changed(e)
    notify(why, ERROR)
  end)
  if not es then return notify(why, ERROR) end
  e.status, e.swarm = "swarmed", vim.tbl_map(function(x) return x.id end, es)
  inbox.changed(e)
  notify(("swarm: %s · %s started"):format(e.title, plan_summary(e.plan)))
end

-- reply to e: the agent continues its chat, from what it did last, then check and land again
function M.continue(e, text)
  if M.running(e) then return notify("it's still running") end
  endchat(e) -- the agent goes on with the same chat
  e.attempts, e.checked, e.why, e.error, e.check_out = 0
  e.time = os.time()
  launch(e, text .. "\n" .. notes(e, e.session), e.result or e.base)
end

-- c: an agent cut short (nvim quit, x, Esc, it crashed) goes on where it was. A quit leaves its
-- worktree behind: what's in it is saved as the result first. One that never started starts over
function M.resume(e)
  if M.running(e) then return notify("it's still running") end
  if not vim.tbl_contains({ "interrupted", "stopped", "error" }, e.status) then
    return notify("it wasn't cut short: r replies to it")
  end
  if not e.base and not readonly(e.kind) then return notify("it never started (your work tree wasn't saved): send it again") end
  local function go()
    M.continue(e, e.session and "You were interrupted. Carry on from where you left off." or e.task)
  end
  local wt = wtdir(e)
  -- no session: quit before the agent started, the checkout may be half made (it'd read as deletions);
  -- a read-only run has no worktree to save
  if readonly(e.kind) or not (e.session and vim.uv.fs_stat(wt)) then return go() end
  jobs[e.id] = {} -- saving it: counts as running, x stops it
  git.result(e.root, wt, e.base, ref(e, "result"), e.exclude, function(result)
    local j = jobs[e.id] -- kept through the stat: a stop in between is caught, the slot stays taken
    local function rest()
      jobs[e.id] = nil
      if j.stopped then e.status = "stopped"; inbox.changed(e); M._next(); return notify("stopped: " .. e.title) end
      go()
    end
    if result then
      e.result = result
      return git.stat_bg(e.root, e.base, result, function(st) e.stat = st; rest() end)
    end
    rest()
  end)
end

-- land e in your work tree as unstaged changes: a three-way merge per file, so what you changed
-- since the task started stays. auto: only when it's clean (no conflicts, no unsaved buffers)
function M.land(e, auto)
  if M.running(e) then return notify("it's still running") end
  if e.status == "landed" then return notify("already landed: u takes it back") end
  if not e.result then return notify("nothing to land") end
  if landing[e.id] then return notify("a moment: it's " .. landing[e.id]) end
  local a, z = e.base, e.result
  landing[e.id] = "being landed"
  local done_ = sepal().progress(e.title .. ": landing")
  git.plan_bg(e.root, a, z, function(changes)
    landing[e.id] = nil
    done_(true)
    if not changes then return notify("not landed: " .. e.title .. ": your files kept changing · L tries again", WARN) end
    if e.base ~= a or e.result ~= z or e.status == "landed" or M.running(e) then
      return notify("not landed: " .. e.title .. ": it changed meanwhile", WARN)
    end
    local bufs = bufs_by_name()
    local unsaved, conflicts = {}, {}
    for _, c in ipairs(changes) do
      local b = bufs[c.path]
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
    reload(changes, bufs)
    e.landed, e.base = { from = e.base, to = e.result }, e.result -- a reply lands only what's new
    e.status, e.why, e.conflicts = "landed", nil, #conflicts > 0 and conflicts or nil
    inbox.changed(e)
    local msg = with_assumptions("landed: " .. e.title .. facts(e), e)
    if #conflicts > 0 then
      return notify(msg .. "\nconflict markers in " .. table.concat(conflicts, ", "), WARN)
    end
    notify(msg, vim.log.levels.INFO, { icon = { require("sepal").icon("landed", "✔"), "SepalOk" } })
  end)
end

-- take a landed task back out of your work tree (again a merge: your edits since stay)
function M.undo(e)
  if not e.landed then return notify("only a landed task can be taken back") end
  if landing[e.id] then return notify("a moment: it's " .. landing[e.id]) end
  local l = e.landed
  landing[e.id] = "being taken back"
  local done_ = sepal().progress(e.title .. ": taking back")
  git.plan_bg(e.root, l.to, l.from, function(changes)
    landing[e.id] = nil
    done_(true)
    if not changes then return notify("not taken back: " .. e.title .. ": your files kept changing · U tries again", WARN) end
    if e.landed ~= l or M.running(e) then return notify("not taken back: " .. e.title .. ": it changed meanwhile", WARN) end
    local bufs = bufs_by_name()
    local unsaved, conflicts = {}, {}
    for _, c in ipairs(changes) do
      local b = bufs[c.path]
      if b and vim.bo[b].modified then unsaved[#unsaved + 1] = c.rel end
      if c.conflict then conflicts[#conflicts + 1] = c.rel end
    end
    if #unsaved > 0 then return notify("save these first: " .. table.concat(unsaved, ", "), WARN) end
    git.apply(changes)
    reload(changes, bufs)
    e.base, e.landed, e.status = e.landed.from, nil, "undone"
    e.conflicts = #conflicts > 0 and conflicts or nil
    inbox.changed(e)
    notify("took back: " .. e.title .. (#conflicts > 0 and "\nconflict markers in " .. table.concat(conflicts, ", ") or ""),
      #conflicts > 0 and WARN or vim.log.levels.INFO)
  end)
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

-- images pasted into tasks (<c-c><c-p>): each stays while its task is in the inbox (r may reread it)
M.PASTES = vim.fs.joinpath(vim.fn.stdpath("cache"), "sepal")

-- delete pasted images no inbox lists that are over a day old: discarded drafts' (a day spares an open one's)
function M.sweep_pastes()
  local stale = {}
  if vim.uv.fs_stat(M.PASTES) then
    for name in vim.fs.dir(M.PASTES) do
      local p = vim.fs.joinpath(M.PASTES, name)
      local st = name:match("^paste%-%d+%.png$") and vim.uv.fs_stat(p)
      if st and os.time() - st.mtime.sec > 86400 then stale[name] = p end
    end
  end
  if not next(stale) then return end
  for name in vim.fs.dir(C().worktrees) do
    local f = name:match("%.json$") and io.open(vim.fs.joinpath(C().worktrees, name))
    if f then
      local content = f:read("a")
      f:close()
      for paste in pairs(stale) do
        if content:find(paste, 1, true) then stale[paste] = nil end
      end
      if not next(stale) then return end
    end
  end
  for _, path in pairs(stale) do os.remove(path) end
end


-- Claude Code's record of each chat: <config>/projects/<cwd>/<session>.jsonl, and a <session>/ dir
-- beside it; one pass of the project dirs for all ids, an fs_stat per id in each
local function rm_sessions(ids)
  local want = {}
  for _, id in pairs(ids) do if id and id:match("^[%w-]+$") then want[id .. ".jsonl"] = id end end -- it goes in a path
  if not next(want) then return end
  local dir = vim.fs.joinpath(vim.env.CLAUDE_CONFIG_DIR or vim.fs.joinpath(vim.uv.os_homedir(), ".claude"), "projects")
  if not vim.uv.fs_stat(dir) then return end
  for name, t in vim.fs.dir(dir) do
    if t == "directory" or t == nil then
      local p = dir .. "/" .. name
      for fname, id in pairs(want) do
        local transcript = p .. "/" .. fname
        if vim.uv.fs_stat(transcript) then
          os.remove(transcript)
          local sub = p .. "/" .. id
          if vim.uv.fs_stat(sub) then vim.fn.delete(sub, "rf") end
          vim.uv.fs_rmdir(p) -- a worktree's project dir, now empty; fails (kept) if not
        end
      end
    end
  end
end


-- forget each entry of list: what drop does per task, but the git work is batched — one
-- for-each-ref + update-ref per repo for all its dropped tasks, one pass for all chats,
-- and one inbox save + render at the end
function M.drop_many(list)
  local dropped = {}
  local pastes = "@(" .. vim.pesc(M.PASTES) .. "/paste%-%d+%.png)"
  inbox.batch(function()
    for _, e in ipairs(list) do
      if M.running(e) then notify("it's running: x stops it first")
      elseif landing[e.id] then notify("a moment: it's " .. landing[e.id]) -- dropping deletes the refs its plan reads
      else
        endchat(e)
        local wt = wtdir(e)
        if vim.uv.fs_stat(wt) then git.remove_worktree(e.root, wt) end
        dropped[#dropped + 1] = e
        if e.task:find(M.PASTES, 1, true) then for p in e.task:gmatch(pastes) do os.remove(p) end end
        inbox.remove(e)
      end
    end
  end)
  local by_root = {}
  for _, e in ipairs(dropped) do
    by_root[e.root] = by_root[e.root] or {}
    table.insert(by_root[e.root], "refs/sepal/" .. e.id)
  end
  for root, prefixes in pairs(by_root) do git.delete_refs_bg(root, prefixes) end
  rm_sessions(vim.tbl_map(function(e) return e.session end, dropped))
end

-- forget e: its commits, its chat, its pasted images and its line in the inbox
function M.drop(e) M.drop_many({ e }) end

-- a read-only scratch buffer with lines; q closes the tab it's in
local function scratch(lines, name, ft)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
  if name then pcall(vim.api.nvim_buf_set_name, b, name) end -- taken: the same task in another tab
  if ft then vim.bo[b].filetype = ft end
  vim.keymap.set("n", "q", function() if not pcall(vim.cmd.tabclose) then sepal().close() end end, { buffer = b, desc = "Close it" })
  return b
end

-- everything the task changed, in a new tab: the file before | after in diff mode, all its files in
-- the after window's location list (]q [q or ]l [l next file, ]c next change, gf the file in your
-- work tree). A btw's answer, an orchestrate's reply with its plan
function M.show(e)
  local btw = readonly(e.kind)
  if btw and not e.answer then return notify("no answer yet") end
  if not btw and not e.result then return notify("no changes yet") end
  if btw then
    vim.cmd.tabnew()
    return vim.api.nvim_win_set_buf(0, scratch(vim.split(e.answer, "\n"), nil, "markdown"))
  end
  local a, z = e.base0 or e.base, e.result
  -- the two diffs run concurrently; once the file list is in, one cat-file starts for every
  -- file's before and after contents, overlapping the -U0 diff and the window setup below
  local spec_idx = { {}, {} } -- rev side (after, before) -> file index -> batch index; binaries aren't read
  local st, first, cat = git.review(e.root, a, z, function(s)
    local specs = {}
    for side, rev in ipairs({ z, a }) do
      for i, p in ipairs(s.paths) do
        if s.list[i]:sub(-7) == " binary" then spec_idx[side][i] = false
        else
          specs[#specs + 1] = rev .. ":" .. p
          spec_idx[side][i] = #specs
        end
      end
    end
    return git.files_start(e.root, specs)
  end)
  if st.files == 0 then return notify("no changes") end
  vim.cmd.tabnew()
  local tab, new = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
  vim.cmd("leftabove vsplit")
  local old = vim.api.nvim_get_current_win()
  local function gf() -- the same line: off a bit if you edited it since, or on the before side
    local rel, l = vim.b.sepal_path, vim.fn.line(".")
    local p = vim.fs.joinpath(e.root, rel)
    if not vim.uv.fs_stat(p) then return notify(rel .. " isn't in your work tree", WARN) end
    vim.cmd("tab drop " .. vim.fn.fnameescape(p))
    pcall(vim.api.nvim_win_set_cursor, 0, { l, 0 })
  end
  local function keys(b) -- the list is the after window's: from the before side too
    vim.keymap.set("n", "gf", gf, { buffer = b, desc = "The file in your work tree" })
    for k, d in pairs({ ["]q"] = "lnext", ["[q"] = "lprevious" }) do
      vim.keymap.set("n", k, function() vim.api.nvim_win_call(new, function() pcall(vim.cmd, vim.v.count1 .. d) end) end, { buffer = b })
    end
  end
  local all = git.files_wait(cat) -- a missing side reads as ""
  local function content(rev, i)
    if st.list[i]:match(" binary$") then return { "binary file" } end
    local idx = spec_idx[rev == a and 2 or 1][i]
    return vim.split(((idx and all[idx] or ""):gsub("\n$", "")), "\n")
  end
  -- the after side of each file, for the quickfix list to point at. Filled now: filling it later
  -- would move the list's line numbers; the before buffers are made lazily, from the same batch
  local group = vim.api.nvim_create_augroup("sepal.review." .. tab, { clear = true })
  local after, idx, busy = {}, {}, false
  for i, path in ipairs(st.paths) do
    local b = scratch(content(z, i), ("sepal://%s/after/%s"):format(e.id, path))
    vim.bo[b].bufhidden, vim.b[b].sepal_path = "hide", path
    keys(b)
    after[i], idx[b] = b, i
  end
  local dns, at = vim.api.nvim_create_namespace("sepal.decisions"), {}
  for i, p in ipairs(st.paths) do at[p] = i end
  for _, d in ipairs(e.assumptions or {}) do -- each decision above the line it's about
    local p, l = M.where(d)
    local b = p and after[at[p]]
    if b then
      l = math.max(1, math.min(l, vim.api.nvim_buf_line_count(b)))
      vim.api.nvim_buf_set_extmark(b, dns, l - 1, 0, { virt_lines_above = true, virt_lines = { { { "· " .. d, "SepalAccent" } } } })
    end
  end
  vim.api.nvim_create_autocmd("BufWinEnter", { group = group, callback = function(ev)
    local i = idx[ev.buf]
    if not i then return end
    local b, path = ev.buf, st.paths[i]
    if busy or not (vim.api.nvim_win_is_valid(old) and vim.api.nvim_win_is_valid(new)) then return end
    busy = true -- setting the windows' buffers below fires this again
    if vim.bo[b].filetype == "" then vim.bo[b].filetype = vim.filetype.match({ filename = path }) or "" end -- once shown: it may start a parser
    local w = vim.api.nvim_get_current_win()
    local before = scratch(content(a, i), ("sepal://%s/before/%s"):format(e.id, path), vim.bo[b].filetype)
    vim.b[before].sepal_path = path
    keys(before)
    -- after on the right, before on the left, whichever window the quickfix list opened it in
    for _, s in ipairs({ { old, before, "before" }, { new, b, "after" } }) do
      vim.api.nvim_win_call(s[1], function() vim.cmd("diffoff"); vim.api.nvim_win_set_buf(s[1], s[2]); vim.cmd("diffthis") end)
      vim.wo[s[1]].winbar = s[3] .. ": " .. path
    end
    if w == old then vim.api.nvim_set_current_win(new) end
    busy = false
  end })
  -- a hidden buffer stays in the diff (unless 'diffopt' has hiddenoff): every line would look changed
  vim.api.nvim_create_autocmd("BufWinLeave", { group = group, callback = function(ev)
    if not idx[ev.buf] then return end
    for _, w in ipairs(vim.fn.win_findbuf(ev.buf)) do vim.api.nvim_win_call(w, function() vim.cmd("diffoff") end) end
  end })
  vim.api.nvim_create_autocmd("TabClosed", { callback = function()
    if vim.api.nvim_tabpage_is_valid(tab) then return end
    for _, b in ipairs(after) do pcall(vim.api.nvim_buf_delete, b, { force = true }) end
    pcall(vim.api.nvim_del_augroup_by_id, group)
    return true
  end })
  local items = {}
  for i, b in ipairs(after) do items[i] = { bufnr = b, lnum = first[st.paths[i]] or 1 } end
  vim.fn.setloclist(new, {}, " ", { title = ("%s · +%d −%d · %s"):format(e.title or e.id, st.add, st.del, plural(st.files, "file")),
    items = items, quickfixtextfunc = function(info)
      local lines = {}
      for i = info.start_idx, info.end_idx do lines[#lines + 1] = st.list[i] end
      return lines
    end })
  vim.api.nvim_win_call(new, function() vim.cmd("botright lopen " .. math.min(st.files, 10)) end)
  local qb, ns = vim.fn.getloclist(new, { qfbufnr = 1 }).qfbufnr, vim.api.nvim_create_namespace("sepal.review")
  vim.api.nvim_buf_clear_namespace(qb, ns, 0, -1)
  for i, l in ipairs(st.list) do
    for c, d in l:gmatch("()%+%d+()") do vim.api.nvim_buf_set_extmark(qb, ns, i - 1, c - 1, { end_col = d - 1, hl_group = "SepalAdded" }) end
    for c, d in l:gmatch("()−%d+()") do vim.api.nvim_buf_set_extmark(qb, ns, i - 1, c - 1, { end_col = d - 1, hl_group = "SepalRemoved" }) end
  end
  vim.api.nvim_set_current_win(new)
  vim.cmd.lfirst()
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
    local argv = devin(e) and vim.list_extend(vim.list_extend(vim.list_extend(base(e), args(e)), model(e)), { "-r", e.session })
      or vim.list_extend(vim.list_extend(cmd({}, mode(e), e), model(e)), { "--resume", e.session })
    return vim.fn.jobstart(argv, { term = true, cwd = e.root,
      env = { CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN = "1" } })
  end)
  pcall(vim.api.nvim_win_close, hidden, true)
  if not ok or chan <= 0 then
    pcall(vim.api.nvim_buf_delete, b, { force = true })
    return notify("could not run " .. tostring(base(e)[1]) .. (ok and "" or ": " .. tostring(chan):match("[^\n]*")), WARN)
  end
  chats[e.id] = b
  vim.b[b].sepal_agent = true
  vim.keymap.set("n", "q", function() sepal().close() end, { buffer = b, desc = "Hide the chat (it keeps going)" })
  -- meanwhile a spinner in the float it'll show in (or the screen kept there); leaving that (q,
  -- :Sepal open…) leaves it loading hidden
  local l, lw
  if kept then l, lw = vim.api.nvim_win_get_buf(w), w else l, lw = loading(w, "Loading agent") end
  -- printed: 200ms without output once there's text (its longest pause mid-chat is ~160ms); 3s at most
  local tick, quiet, t0, asked, printed, timer = -1, 0, vim.uv.now(), false, nil, vim.uv.new_timer()
  local dv = devin(e)
  timer:start(50, 50, vim.schedule_wrap(function()
    local gone = not vim.api.nvim_win_is_valid(lw) or vim.api.nvim_win_get_buf(lw) ~= l
    if gone or not vim.api.nvim_buf_is_valid(b) then
      timer:stop(); timer:close()
      return pcall(vim.api.nvim_win_close, lw, true)
    end
    local t = vim.api.nvim_buf_get_changedtick(b)
    if t ~= tick then
      tick, quiet = t, 0
      -- the buffer is only read when it changed (not every 50ms while it's quiet), and only
      -- until it printed — after that it's the pause and the clock that matter
      if not printed or (dv and not asked) then
        local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false))
        if dv and not asked and text:find("Resume this session from which directory?", 1, true) then
          -- devin asks where to resume (its worktree is gone): here, this once
          asked, tick, quiet, t0 = true, -1, 0, vim.uv.now()
          vim.api.nvim_chan_send(chan, "2\r")
          return
        end
        printed = (dv and text:gsub("Resume this session from which directory%?", "") or text):find("%S")
      end
    else quiet = quiet + 50 end
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
  local w = vim.api.nvim_open_win(b, true, { split = "above", win = -1, height = 6 })
  vim.wo[w].wrap, vim.wo[w].cursorline = true, false -- not the inbox's nowrap (a split copies them)
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

M._t = { jobs = jobs, queue = queue, landing = landing, reply_of = reply_of, about = about, devin_usage = devin_usage }

return M
