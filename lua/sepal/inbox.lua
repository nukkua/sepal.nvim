-- sepal.inbox — every task of a repo and where it stands, kept in a JSON file per repo (so it
-- survives a restart), and :Sepal inbox, a buffer that lists them with keys to act on each.

local M = {}

local cache = {} -- root -> list of entries, newest first

local function cfg() return require("sepal").config() end
function M.key(root) return (root:gsub("[^%w]", "-")) end
local function file(root) return vim.fs.joinpath(cfg().worktrees, M.key(root) .. ".json") end

function M.list(root)
  if cache[root] then return cache[root] end
  local list = {}
  local f = io.open(file(root))
  if f then
    local ok, data = pcall(vim.json.decode, f:read("a"), { luanil = { object = true, array = true } })
    f:close()
    if ok and type(data) == "table" then list = data end
  end
  for _, e in ipairs(list) do
    -- nvim quit while it ran: the agent was stopped with it
    if e.status == "running" or e.status == "checking" or e.status == "queued" then e.status = "interrupted" end
    e.task, e.spec = e.task or e.spec or "", nil -- older inboxes saved the task as spec
  end
  cache[root] = list
  return list
end

local batching, pending = 0, { roots = {}, render = false } -- >0: saves and renders wait (see M.batch)

local function save(root)
  if batching > 0 then pending.roots[root] = true return end
  vim.fn.mkdir(cfg().worktrees, "p")
  local keep = vim.tbl_map(function(e) -- a shallow copy is enough: it's only encoded
    local c = {}
    for k, v in pairs(e) do if k ~= "activity" and k ~= "subagents" and k ~= "reply" then c[k] = v end end -- reply: older inboxes had it
    return c
  end, M.list(root))
  local f = io.open(file(root), "w")
  if f then f:write(vim.json.encode(keep)); f:close() end
end

M.save = save

-- what the statusline shows (sepal.status): tasks running, ready to land, needing you
local COUNTS = { running = 1, checking = 1, queued = 1, ready = 2, planned = 2, needs = 3, failed = 3, error = 3 }
function M.counts(root)
  local n = { 0, 0, 0 }
  for _, e in ipairs(cache[root] or {}) do local i = COUNTS[e.status]; if i then n[i] = n[i] + 1 end end
  return n
end
M.cache = cache

local draw -- below
local counted -- the counts at the last render: User SepalChanged fires only when they move
local function render() -- in a batch only flagged, drawn once at its end
  if batching > 0 then pending.render = true return end
  draw()
  -- render runs on every tool call of every running task; the counts move a few times a task
  local sig = {}
  for root in pairs(cache) do sig[#sig + 1] = root .. table.concat(M.counts(root), ",") end
  table.sort(sig)
  sig = table.concat(sig, ";")
  if sig == counted then return end
  counted = sig
  vim.api.nvim_exec_autocmds("User", { pattern = "SepalChanged", modeline = false })
  vim.cmd.redrawstatus({ bang = true })
end

-- run fn with saves and renders deferred: each pending root is saved once and the inbox redrawn
-- once, when the outermost batch ends (also when fn errors, before it's rethrown)
function M.batch(fn)
  batching = batching + 1
  local ok, err = pcall(fn)
  batching = batching - 1
  if batching == 0 then
    local p = pending
    pending = { roots = {}, render = false }
    for root in pairs(p.roots) do save(root) end
    if p.render then render() end
  end
  if not ok then error(err, 0) end
end

-- after any change to an entry: save, and redraw the inbox if it's open
function M.changed(e)
  if e.status ~= "running" or not e.activity then save(e.root) end
  render()
end

function M.add(e) table.insert(M.list(e.root), 1, e); M.changed(e) end

function M.remove(e)
  local l = M.list(e.root)
  for i, x in ipairs(l) do if x.id == e.id then table.remove(l, i) break end end
  save(e.root)
  render()
end

function M.find(root, id)
  for _, e in ipairs(M.list(root)) do if e.id == id then return e end end
end

-- the inbox buffer ---------------------------------------------------------------------------

local STATUS = {
  queued = { "…", "queued", "SepalDim" },
  running = { "⋯", "running", "SepalAccent" },
  checking = { "⋯", "checking", "SepalAccent" },
  landed = { "✓", "landed", "SepalOk" },
  ready = { "●", "ready", "SepalOk" },
  nochange = { "○", "no changes", "SepalDim" },
  failed = { "✗", "check failed", "SepalError" },
  error = { "✗", "failed", "SepalError" },
  needs = { "▲", "needs you", "SepalWarn" },
  stopped = { "○", "stopped", "SepalDim" },
  interrupted = { "○", "interrupted", "SepalDim" },
  undone = { "↺", "undone", "SepalDim" },
  answered = { "◆", "answered", "SepalOk" }, -- a btw
  planned = { "◇", "planned", "SepalOk" }, -- an orchestrate: its plan waits for s
  split = { "⇉", "split", "SepalDim" }, -- an orchestrate whose tasks were made
}
M.STATUS = STATUS
M.LIVE = { running = true, checking = true } -- these spin in the inbox and the panel
local SPIN, frame, timer = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }, 1, nil
function M.spin() return SPIN[frame] end
local function cfg_icon(...) return require("sepal").icon(...) end
local NS = vim.api.nvim_create_namespace("sepal.inbox")
local HELP = "<CR> diff  L land  U undo  :w apply  u revert  r reply  c continue  o watch/chat  x stop  s split  m model  C clean  za fold  q close"
-- an orchestrate's plan item under it: "    2. [sonnet] title"; edit the model in it (or dd it) and :w
local PLAN = "^%s+(%d+)%.%s*%[([^%]]*)%]"
local function plan_line(i, p) return ("%d. [%s] %s"):format(i, p.model or "default", p.title) end

local function ago(t)
  local s = os.time() - (t or os.time())
  for _, u in ipairs({ { 86400, "d" }, { 3600, "h" }, { 60, "m" } }) do
    if s >= u[1] then return math.floor(s / u[1]) .. u[2] end
  end
  return "now"
end
local fit_c, fit_n = {}, 0 -- render calls it per entry per column: memoized by w.."\0"..s
local function fit(s, w)
  local k = w .. "\0" .. s
  local v = fit_c[k]
  if not v then
    if fit_n > 4096 then fit_c, fit_n = {}, 0 end
    if vim.api.nvim_strwidth(s) > w then s = vim.fn.strcharpart(s, 0, w - 1) .. "…" end
    v = s .. string.rep(" ", w - vim.api.nvim_strwidth(s))
    fit_c[k], fit_n = v, fit_n + 1
  end
  return v
end

M.ago, M.fit = ago, fit

-- the facts after the title as columns: { "3 files", "+42", "−8", "make test ✓" }
local function facts(e)
  local s, f = e.stat and e.stat.files > 0 and e.stat, {}
  if e.check then
    local mark = e.checked == true and " ✓" or e.checked == false and " ✗" or ""
    f[#f + 1] = e.check .. mark
  end
  if e.status == "running" and e.activity then f[#f + 1] = e.activity end
  if e.status == "running" and e.subagents and #e.subagents > 0 then f[#f + 1] = ("↳ %d subagent%s"):format(#e.subagents, #e.subagents == 1 and "" or "s") end
  return { s and ("%d file%s"):format(s.files, s.files == 1 and "" or "s") or "", s and "+" .. s.add or "",
    s and "−" .. s.del or "", table.concat(f, "  ") }
end

-- the lines under an entry: what you should read
local function details(e)
  local d = {}
  if e.why then d[#d + 1] = e.why end
  if e.error then d[#d + 1] = e.error end
  if e.status == "running" then
    for _, a in ipairs(e.subagents or {}) do d[#d + 1] = "↳ " .. a.name end
  end
  if e.status == "failed" and e.check_out then
    for _, l in ipairs(vim.list_slice(vim.split(vim.trim(e.check_out), "\n"), 1, 3)) do d[#d + 1] = "│ " .. l end
  end
  if e.status == "split" then d[#d + 1] = ("→ split into %d task%s, above in the inbox"):format(#(e.split or {}), #(e.split or {}) == 1 and "" or "s") end
  if e.status == "planned" or e.status == "split" then
    for i, p in ipairs(e.plan or {}) do d[#d + 1] = plan_line(i, p) end
  end
  for _, a in ipairs(e.assumptions or {}) do d[#d + 1] = "· " .. a end
  for _, c in ipairs(e.conflicts or {}) do d[#d + 1] = "conflict markers in " .. c end
  for _, f in ipairs(e.stat and e.stat.list or {}) do d[#d + 1] = "  " .. f end
  return d
end

local opened = {} -- task id -> true when you opened its fold: tasks start folded
local heads = {} -- row -> true for each task's first line, where its fold starts
local drawn -- what the inbox shows, its spinners blanked: a redraw that only moves them rewrites just those
local clocked -- clock()'s value at the last draw: a tick redraws for the ages only when it moved
local spun = {} -- the rows drawn with a spinner
local inbox_buf -- kept, not searched for: render runs on every tool call of every running task
local function buf() return inbox_buf and vim.api.nvim_buf_is_valid(inbox_buf) and inbox_buf or nil end
-- the buffer is edited like oil: a task's line is known by its text past the status icon (which spins)
local ids = {} -- that text -> the ids of the tasks drawn with it (two tasks can read the same)
local function tkey(l) return l and l:match("^%S+ (.*)$") end
local function head(b, row) return ids[tkey(vim.api.nvim_buf_get_lines(b, row - 1, row, false)[1])] end
-- the inbox's own writes are no change of yours: u never undoes them
local function quiet(b, f)
  local ul = vim.bo[b].undolevels
  vim.bo[b].undolevels = -1
  f()
  vim.bo[b].undolevels, vim.bo[b].modified = ul, false
end

local function spin(b)
  quiet(b, function()
    for _, row in ipairs(spun) do vim.api.nvim_buf_set_text(b, row - 1, 0, row - 1, #SPIN[frame], { SPIN[frame] }) end
  end)
end

-- what the ages say now, all of them: changes to entries already redraw, so between redraws this
-- only moves when an age rolls over — that's when a tick still wants a full draw
local function clock()
  local t = {}
  for _, list in pairs(cache) do for _, e in ipairs(list) do t[#t + 1] = ago(e.time) end end
  return table.concat(t)
end

draw = function()
  clocked = clock() -- the ages as drawn (by the panel too): a tick redraws only when this moves
  local panel = package.loaded["sepal.panel"] -- the side panel shows the same tasks: it redraws with the inbox
  local live = panel and panel.render() or false
  local b = buf()
  local w = b and vim.fn.win_findbuf(b)[1]
  local root = w and vim.b[b].sepal_inbox
  local list = w and M.list(root) or {}
  live = live or vim.iter(list):any(function(e) return M.LIVE[e.status] end)
  -- one timer spins both while a task they show runs, and stops when none does
  if live and not timer then
    timer = assert(vim.uv.new_timer())
    timer:start(100, 100, vim.schedule_wrap(function()
      frame = frame % #SPIN + 1
      -- every change redraws at once, so a tick only moves the spinners; once a turn (1s) a whole
      -- redraw moves the ages — only when one actually rolled over since the last draw
      if frame == 1 and clock() ~= clocked then return render() end
      if package.loaded["sepal.panel"] then package.loaded["sepal.panel"].spin() end
      local b = buf()
      if drawn and b and vim.fn.win_findbuf(b)[1] and not vim.bo[b].modified then spin(b) end
    end))
  elseif not live and timer then
    timer:stop(); timer:close(); timer = nil
  end
  -- hidden, it stays loaded: skip it (every tool call of every task redraws); M.open redraws when shown
  if not w then drawn = nil; return end -- what it showed is stale now: no tick may touch it
  if vim.bo[b].modified then return end -- your edits wait for :w (or u): a redraw would throw them away
  local lines, rows, marks, spans, spins, agents, plans = { HELP, "" }, {}, {}, {}, {}, {}, {}
  if #list == 0 then lines[#lines + 1] = "no tasks yet: :Sepal task" end
  -- every column padded to its widest value in the list, so every line is the same width
  local cols, wid = {}, { 0, 0, 0, 0 }
  for i, e in ipairs(list) do
    cols[i] = facts(e)
    for c = 1, 4 do wid[c] = math.max(wid[c], vim.api.nvim_strwidth(cols[i][c])) end
  end
  for i, e in ipairs(list) do
    local st = STATUS[e.status] or { "?", e.status, "Normal" }
    local head = ("%s %s "):format(M.LIVE[e.status] and SPIN[frame] or cfg_icon(e.status, st[1]), fit(st[2], 12))
    local pre = ("%s%s  %s  "):format(head, fit(ago(e.time), 3), fit(e.title or "", 34))
    local c = cols[i]
    local f = wid[1] > 0 and ("%s %s %s"):format(fit(c[1], wid[1]), fit(c[2], wid[2]), fit(c[3], wid[3])) or ""
    f = f .. (wid[1] > 0 and wid[4] > 0 and "  " or "") .. fit(c[4], wid[4])
    lines[#lines + 1] = pre .. f
    if M.LIVE[e.status] then spins[#spins + 1] = #lines end
    rows[#lines], marks[#lines] = e.id, { st[3], #head - 1 }
    -- the age dimmed, the diff counts colored like a diff
    spans[#spans + 1] = { #lines, #head, #head + 3, "SepalDim" }
    for a, z in f:gmatch("()%+%d+()") do spans[#spans + 1] = { #lines, #pre + a - 1, #pre + z - 1, "SepalAdded" } end
    for a, z in f:gmatch("()−%d+()") do spans[#spans + 1] = { #lines, #pre + a - 1, #pre + z - 1, "SepalRemoved" } end
    for a, z in f:gmatch("()↳ %d+ subagents?()") do spans[#spans + 1] = { #lines, #pre + a - 1, #pre + z - 1, "SepalAgent" } end
    for _, d in ipairs(details(e)) do
      lines[#lines + 1] = "    " .. d; rows[#lines] = e.id
      if d:match("^↳ ") then agents[#lines] = true -- not dimmed: these are what's running
      elseif e.status == "planned" and lines[#lines]:match(PLAN) then -- nor these: what s makes, the model to edit in color
        plans[#lines] = true
        local a, z = lines[#lines]:find("%[[^%]]*%]")
        spans[#spans + 1] = { #lines, a - 1, z, "SepalAccent" }
      end
    end
  end
  local key = { w }
  for row, l in ipairs(lines) do key[#key + 1] = tostring(rows[row]) .. "\0" .. l end
  for _, row in ipairs(spins) do key[row + 1] = rows[row] .. "\0\1" .. lines[row]:sub(#SPIN[frame] + 1) end
  key = table.concat(key, "\n")
  spun = spins
  if key == drawn then return spin(b) end -- only the spinners moved: every frame is 3 bytes, so the other marks and folds stay put
  drawn = key
  -- each task is a fold (za/zc/zo/zM/zR); the lines change on every redraw, so its state is kept by task
  local old = vim.b[b].sepal_rows or {}
  vim.api.nvim_win_call(w, function()
    for row in pairs(heads) do
      if heads[row] and old[row] then opened[old[row]] = vim.fn.foldclosed(row) == -1 end
    end
  end)
  local planned = {} -- a plan starts unfolded: its tasks and their models are what you act on
  for _, e in ipairs(list) do planned[e.id] = e.status == "planned" end
  quiet(b, function() vim.api.nvim_buf_set_lines(b, 0, -1, false, lines) end)
  ids = {}
  for row, id in pairs(rows) do
    if marks[row] then local k = tkey(lines[row]); ids[k] = ids[k] or {}; table.insert(ids[k], id) end
  end
  vim.api.nvim_buf_clear_namespace(b, NS, 0, -1)
  vim.api.nvim_buf_set_extmark(b, NS, 0, 0, { end_row = 0, end_col = #HELP, hl_group = "SepalDim" })
  for row, m in pairs(marks) do vim.api.nvim_buf_set_extmark(b, NS, row - 1, 0, { end_col = m[2], hl_group = m[1] }) end
  for _, sp in ipairs(spans) do vim.api.nvim_buf_set_extmark(b, NS, sp[1] - 1, sp[2], { end_col = sp[3], hl_group = sp[4] }) end
  for row = 3, #lines do
    if agents[row] then vim.api.nvim_buf_set_extmark(b, NS, row - 1, 0, { line_hl_group = "SepalAgent" })
    elseif not marks[row] and not plans[row] and lines[row]:match("^    ") then vim.api.nvim_buf_set_extmark(b, NS, row - 1, 0, { line_hl_group = "SepalDim" }) end
  end
  vim.b[b].sepal_rows = rows
  heads = {}
  for row = 1, #lines do heads[row] = marks[row] ~= nil end
  vim.api.nvim_win_call(w, function()
    vim.cmd("silent! normal! zE")
    for row = 1, #lines do
      local last = row
      while heads[row] and rows[last + 1] == rows[row] do last = last + 1 end
      if last > row then
        vim.cmd(("%d,%dfold"):format(row, last))
        local o = opened[rows[row]]
        if o or (o == nil and planned[rows[row]]) then vim.cmd(row .. "foldopen") end
      end
    end
  end)
end
M.render = function() render() end

-- the entry under the cursor in the inbox
function M.current()
  local b = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local id = (vim.b[b].sepal_rows or {})[row]
  if vim.bo[b].modified then -- edited: rows moved, find the task line at or above the cursor
    id = nil
    for r = row, 1, -1 do if head(b, r) then id = head(b, r)[1] break end end
  end
  return id and M.find(vim.b[b].sepal_inbox, id)
end

-- :w in the inbox: a task whose line is gone is dropped, a line put twice (yyp) opens a new task
-- with that task's text, to add to and send. Under a planned orchestrate, its plan is what its
-- plan lines say now: the [model] in each, their order, and a deleted line drops that task
function M.write(b)
  local root, seen, copies = vim.b[b].sepal_inbox, {}, {}
  local cur, plans = nil, {} -- the task the lines are under; id -> { { item, model } } read under it
  for _, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
    local k = tkey(l)
    if ids[k] then
      seen[k] = (seen[k] or 0) + 1
      if seen[k] > #ids[k] then copies[#copies + 1], cur = ids[k][1], nil
      else cur = ids[k][seen[k]]; plans[cur] = plans[cur] or {} end
    else
      local i, m = l:match(PLAN)
      if cur and i then table.insert(plans[cur], { tonumber(i), m }) end
    end
  end
  local agent = require("sepal.agent")
  for id, got in pairs(plans) do
    local e = M.find(root, id)
    if e and e.status == "planned" and e.plan then
      local plan, used = {}, {}
      for _, g in ipairs(got) do
        local p = e.plan[g[1]]
        if p and not used[g[1]] then
          used[g[1]] = true
          p = vim.deepcopy(p)
          p.model = agent.model_of(g[2])
          plan[#plan + 1] = p
        end
      end
      if not vim.deep_equal(plan, e.plan) then e.plan = plan; save(root) end
    end
  end
  local gone = {}
  for k, list in pairs(ids) do
    for i = (seen[k] or 0) + 1, #list do gone[#gone + 1] = list[i] end
  end
  vim.bo[b].modified = false
  local dropping = {}
  for _, id in ipairs(gone) do local e = M.find(root, id); if e then dropping[#dropping + 1] = e end end
  agent.drop_many(dropping) -- a running one stays
  drawn = nil
  render()
  local e = copies[1] and M.find(root, copies[1])
  -- shortcut: one draft at a time (sepal.task), so only the first copy opens; more copies need a draft list
  -- scheduled: :w puts you back in the inbox after BufWriteCmd, the draft should keep focus
  if e then vim.schedule(function() require("sepal").task(nil, vim.split(e.task, "\n"), e.kind) end) end
  if #copies > 1 then require("sepal").notify("one task draft at a time: copied only " .. e.title) end
end

-- m: the model of the plan item under the cursor (on the orchestrate's own line: of all of them),
-- picked from your agents' models (agents option), "default" (the agent's own) or one you type
function M.pick_model()
  local b, e = vim.api.nvim_get_current_buf(), M.current()
  local notify = require("sepal").notify
  if not e then return end
  if e.status ~= "planned" then return notify("m sets the models of a planned orchestrate's tasks") end
  if vim.bo[b].modified then return notify("your edits come first: :w (or u)") end
  local i = tonumber(vim.api.nvim_get_current_line():match(PLAN) or nil)
  local which = {}
  for k in ipairs(e.plan) do if not i or k == i then which[#which + 1] = k end end
  if #which == 0 then return end
  local choices, cur = {}, i and e.plan[i].model
  local all = vim.list_extend({}, require("sepal").plan_models())
  if cur then all[#all + 1] = cur end
  vim.list_extend(all, { "default", "other…" })
  for _, m in ipairs(all) do
    if not vim.tbl_contains(choices, m) then choices[#choices + 1] = m end
  end
  local function set(m)
    if not m then return end
    for _, k in ipairs(which) do e.plan[k].model = require("sepal.agent").model_of(m) end
    M.changed(e)
  end
  vim.ui.select(choices, { prompt = i and ("model for task %d (%s): "):format(i, e.plan[i].title) or "model for every task: " }, function(c)
    if c ~= "other…" then return set(c) end
    vim.ui.input({ prompt = "model: " }, set)
  end)
end

function M.open(root)
  local b = buf()
  if not b then
    b = vim.api.nvim_create_buf(false, true)
    inbox_buf = b
    vim.bo[b].bufhidden = "hide"
    vim.bo[b].filetype, vim.bo[b].buftype = "sepal-inbox", "acwrite"
    vim.api.nvim_buf_set_name(b, "sepal://inbox")
    vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = b, callback = function() M.write(b) end })
    local agent = require("sepal.agent")
    local function on(f) return function() local e = M.current(); if e then f(e) end end end
    local o = function(desc) return { buffer = b, desc = desc, nowait = true } end
    vim.keymap.set("n", "<CR>", on(agent.show), o("Show what the task changed"))
    vim.keymap.set("n", "L", on(agent.land), o("Land it in your work tree"))
    vim.keymap.set("n", "U", on(agent.undo), o("Take a landed task back out")) -- u is vim's undo: the buffer is edited
    vim.keymap.set("n", "r", on(agent.reply), o("Reply: the agent continues this task"))
    vim.keymap.set("n", "c", on(agent.resume), o("Continue a task that was cut short (quit, stopped, crashed)"))
    vim.keymap.set("n", "o", on(agent.open), o("Watch the agent, or open the task's chat"))
    vim.keymap.set("n", "x", on(agent.stop), o("Stop it"))
    vim.keymap.set("n", "s", on(agent.split), o("Split a planned orchestrate into its tasks"))
    vim.keymap.set("n", "m", M.pick_model, o("Set the model of a planned task (all of them on the plan's line)"))
    vim.keymap.set("n", "C", function() require("sepal").clean() end, o("Drop the tasks that are over"))
    vim.keymap.set("n", "q", function() require("sepal").close() end, o("Close the inbox"))
    -- j/k go task to task, past the detail lines under each
    local function step(dir)
      return function()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        for _ = 1, vim.v.count1 do
          local r = row + dir
          local n = vim.api.nvim_buf_line_count(b)
          while r >= 1 and r <= n and not head(b, r) do r = r + dir end
          if r < 1 or r > n then break end
          row = r
        end
        vim.api.nvim_win_set_cursor(0, { row, 0 })
      end
    end
    vim.keymap.set("n", "j", step(1), o("Next task"))
    vim.keymap.set("n", "k", step(-1), o("Previous task"))
  end
  vim.b[b].sepal_inbox = root
  local w = vim.fn.bufwinid(b)
  if w == -1 then w = vim.api.nvim_open_win(b, true, { split = "below", win = -1, height = 12 }) end
  vim.api.nvim_set_current_win(w)
  vim.wo[w].wrap, vim.wo[w].cursorline = false, true
  vim.wo[w].foldmethod, vim.wo[w].foldenable, vim.wo[w].foldtext = "manual", true, "" -- foldtext "": a closed task shows as its own line
  -- a list, not code: no gutter, no fold dots, no Folded band over closed tasks
  vim.wo[w].number, vim.wo[w].relativenumber, vim.wo[w].signcolumn, vim.wo[w].foldcolumn = false, false, "no", "0"
  vim.wo[w].fillchars, vim.wo[w].winhighlight = "fold: ,eob: ", "Folded:SepalInboxFolded"
  render()
  if vim.api.nvim_buf_line_count(b) >= 3 then vim.api.nvim_win_set_cursor(w, { 3, 0 }) end
  vim.fn.winrestview({ topline = 1 }) -- keep the key help in view
end

M._t = { reset = function() cache, drawn, ids = {}, nil, {} end }

return M
