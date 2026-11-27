-- sepal.inbox — every task of a repo and where it stands, kept in a JSON file per repo (so it
-- survives a restart), and :Sepal inbox, a buffer that lists them with keys to act on each.

local M = {}

local cache = {} -- root -> list of entries, newest first
local roots_version = 0

local function cfg() return require("sepal").config() end
local keys = {}
function M.key(root)
  if not keys[root] then keys[root] = vim.fn.sha256(root) end
  return keys[root]
end
local function file(root) return vim.fs.joinpath(cfg().worktrees, M.key(root) .. ".json") end

function M.list(root)
  if cache[root] then return cache[root] end
  local list = {}
  local f = io.open(file(root))
  local legacy = not f
  if legacy then f = io.open(vim.fs.joinpath(cfg().worktrees, (root:gsub("[^%w]", "-")) .. ".json")) end
  if f then
    local ok, data = pcall(vim.json.decode, f:read("a"), { luanil = { object = true, array = true } })
    f:close()
    if ok and type(data) == "table" then
      list = legacy and vim.tbl_filter(function(e) return type(e) == "table" and e.root == root end, data) or data
    end
  end
  for _, e in ipairs(list) do
    -- nvim quit while it ran: the agent was stopped with it
    if e.status == "running" or e.status == "checking" or e.status == "queued" then e.status = "interrupted" end
    e.task, e.spec = e.task or e.spec or "", nil -- older inboxes saved the task as spec
    if e.status == "split" then e.status, e.swarm, e.split = "swarmed", e.split, nil end -- older inboxes: split was renamed swarmed
  end
  cache[root] = list
  roots_version = roots_version + 1
  return list
end

local batching, pending = 0, { roots = {}, render = false } -- >0: saves and renders wait (see M.batch)

local function save(root)
  if batching > 0 then pending.roots[root] = true return end
  local list = M.list(root)
  local keep = {}
  for i = 1, #list do
    local e = list[i]
    if e.activity == nil and e.subagents == nil and e.reply == nil then keep[i] = e
    else
      local c = {}
      for k, v in pairs(e) do if k ~= "activity" and k ~= "subagents" and k ~= "reply" then c[k] = v end end -- reply: older inboxes had it
      keep[i] = c
    end
  end
  local f = io.open(file(root), "w")
  if not f then
    vim.fn.mkdir(cfg().worktrees, "p")
    f = io.open(file(root), "w")
  end
  if f then f:write(vim.json.encode(keep)); f:close() end
end

M.save = save

-- what the statusline shows (sepal.status): tasks running, ready to land, needing you
local COUNTS = { running = 1, checking = 1, queued = 1, ready = 2, planned = 2, needs = 3, failed = 3, error = 3 }
function M.counts_raw(root)
  local n1, n2, n3 = 0, 0, 0
  for _, e in ipairs(cache[root] or {}) do
    local i = COUNTS[e.status]
    if i == 1 then n1 = n1 + 1
    elseif i == 2 then n2 = n2 + 1
    elseif i == 3 then n3 = n3 + 1 end
  end
  return n1, n2, n3
end
function M.counts(root) return { M.counts_raw(root) } end
function M.roots_ver() return roots_version end
M.cache = cache

local draw -- below
local counted -- the counts at the last render: User SepalChanged fires only when they move
local function render() -- in a batch only flagged, drawn once at its end
  if batching > 0 then pending.render = true return end
  draw()
  -- render runs on every tool call of every running task; the counts move a few times a task
  local sig = {}
  for root in pairs(cache) do
    local n1, n2, n3 = M.counts_raw(root)
    sig[#sig + 1] = root .. n1 .. "," .. n2 .. "," .. n3
  end
  if #sig > 1 then table.sort(sig) end
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
  landed = { "✔", "landed", "SepalOk" },
  ready = { "●", "ready", "SepalOk" },
  nochange = { "○", "no changes", "SepalDim" },
  failed = { "✘", "check failed", "SepalError" },
  error = { "✘", "failed", "SepalError" },
  needs = { "▲", "needs you", "SepalWarn" },
  stopped = { "○", "stopped", "SepalDim" },
  interrupted = { "○", "interrupted", "SepalDim" },
  undone = { "↺", "undone", "SepalDim" },
  answered = { "◆", "answered", "SepalOk" }, -- a btw
  planned = { "◇", "planned", "SepalOk" }, -- an orchestrate: its plan waits for s
  swarmed = { "⇉", "swarmed", "SepalDim" }, -- an orchestrate whose tasks were made
}
M.STATUS = STATUS
M.LIVE = { running = true, checking = true } -- these spin in the inbox and the panel
local SPIN, frame, timer, ticks = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }, 1, nil, 0
function M.spin() return SPIN[frame] end
function M.tick() return ticks end
local function cfg_icon(...) return require("sepal").icon(...) end
local NS = vim.api.nvim_create_namespace("sepal.inbox")
local HELP = "<CR> diff  L land  U undo  :w apply  u revert  r reply  c continue  o watch/chat  x stop  s swarm  m model  C clean  za fold  q close"
-- an orchestrate's plan item under it: "    2. [sonnet] title"; edit the model in it (or dd it) and :w
local PLAN = "^%s+(%d+)%.%s*%[([^%]]*)%]"
local function plan_line(i, p) return ("%d. [%s] %s"):format(i, p.model or "default", p.title) end

local function strwidth(s) return not s:find("[^\32-\126]") and #s or vim.api.nvim_strwidth(s) end
M.strwidth = strwidth
local function ago(t, now)
  local n = now or os.time()
  local s = n - (t or n)
  if s >= 86400 then return math.floor(s / 86400) .. "d" end
  if s >= 3600 then return math.floor(s / 3600) .. "h" end
  if s >= 60 then return math.floor(s / 60) .. "m" end
  return "now"
end
-- the next unix time at which ago(t) changes: the 1 s tick redraws only then
local function next_age_change(t, now)
  local n = now or os.time()
  t = t or n
  local s = n - t
  if s < 0 then return t + 60 end
  if s >= 86400 then return t + (math.floor(s / 86400) + 1) * 86400 end
  if s >= 3600 then return t + (math.floor(s / 3600) + 1) * 3600 end
  if s >= 60 then return t + (math.floor(s / 60) + 1) * 60 end
  return t + 60
end
local fit_c, fit_n = {}, 0 -- render calls it per entry per column: memoized by w.."\0"..s
local function fit(s, w)
  local k = w .. "\0" .. s
  local v = fit_c[k]
  if not v then
    if fit_n > 4096 then fit_c, fit_n = {}, 0 end
    if not s:find("[^\32-\126]") then
      if #s > w then v = w >= 1 and (s:sub(1, w - 1) .. "…") or "…"
      else v = s .. string.rep(" ", w - #s) end
    else
      local sw = vim.api.nvim_strwidth(s)
      if sw > w then
        s = vim.fn.strcharpart(s, 0, w - 1) .. "…"
        sw = vim.api.nvim_strwidth(s)
      end
      v = s .. string.rep(" ", math.max(0, w - sw))
    end
    fit_c[k], fit_n = v, fit_n + 1
  end
  return v
end

M.ago, M.fit = ago, fit

-- the facts after the title as columns: { "3 files", "+42", "−8", "make test ✔" }
local function facts(e)
  local s, f = e.stat and e.stat.files > 0 and e.stat, {}
  if e.check then
    local mark = e.checked == true and " ✔" or e.checked == false and " ✘" or ""
    f[#f + 1] = e.check .. mark
  end
  if e.status == "running" and e.activity then f[#f + 1] = e.activity end
  if e.status == "running" and e.subagents and #e.subagents > 0 then f[#f + 1] = ("↳ %d subagent%s"):format(#e.subagents, #e.subagents == 1 and "" or "s") end
  return { s and ("%d file%s"):format(s.files, s.files == 1 and "" or "s") or "", s and "+" .. s.add or "",
    s and "−" .. s.del or "", table.concat(f, "  ") }
end

local function is_test(path)
  local l = "/" .. path:lower()
  return l:find("/tests?/") or l:find("/specs?/") or l:find("/__tests__/")
    or l:find("[/_%.%-]tests?[_%.%-]") or l:find("[/_%.%-]specs?[_%.%-]")
    or l:find("[/_%.%-]tests?$") or l:find("[/_%.%-]specs?$")
    or path:find("Tests?%.") or path:find("Specs?%.")
end

-- what should make you suspicious of a green check: one green before the agent proves nothing,
-- and changing existing tests can move the goalposts (new ones are fine)
function M.warnings(e)
  local w = {}
  if e.vacuous then w[#w + 1] = "▲ the check already passed before the agent started: it proves nothing" end
  local t = {}
  for _, p in ipairs(e.stat and e.stat.paths or {}) do
    if is_test(p) and not (e.stat.new and e.stat.new[p]) then t[#t + 1] = p end
  end
  if #t > 0 then w[#w + 1] = "▲ it changed tests: " .. table.concat(t, ", ") end
  return w
end

-- the lines under an entry: what you should read
local function details(e)
  local d = {}
  if e.why then d[#d + 1] = e.why end
  for _, w in ipairs(M.warnings(e)) do d[#d + 1] = w end
  if e.error then d[#d + 1] = e.error end
  if e.status == "running" then
    for _, a in ipairs(e.subagents or {}) do d[#d + 1] = "↳ " .. a.name end
  end
  if e.status == "failed" and e.check_out then
    for _, l in ipairs(vim.list_slice(vim.split(vim.trim(e.check_out), "\n"), 1, 3)) do d[#d + 1] = "│ " .. l end
  end
  if e.status == "swarmed" then d[#d + 1] = ("→ swarmed into %d task%s, above in the inbox"):format(#(e.swarm or {}), #(e.swarm or {}) == 1 and "" or "s") end
  if e.status == "planned" or e.status == "swarmed" then
    for i, p in ipairs(e.plan or {}) do d[#d + 1] = plan_line(i, p) end
  end
  for _, a in ipairs(e.assumptions or {}) do d[#d + 1] = "· " .. a end
  for _, c in ipairs(e.conflicts or {}) do d[#d + 1] = "conflict markers in " .. c end
  for _, f in ipairs(e.stat and e.stat.list or {}) do d[#d + 1] = "  " .. f end
  return d
end

local opened = {} -- task id -> true when you opened its fold: tasks start folded
local heads = {} -- row -> true for each task's first line, where its fold starts
local drawn -- true once drawn: the timer may move its spinners
local next_age, last_now = math.huge, 0 -- when the first shown age rolls over, and when the draw happened
local spun = {} -- the rows drawn with a spinner
local prev_inbox -- the last draw's rows, for patching only those that changed
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
  if #spun == 0 then return end
  local f = SPIN[frame]
  local fs = { f }
  quiet(b, function()
    for _, row in ipairs(spun) do
      vim.api.nvim_buf_set_text(b, row - 1, 0, row - 1, #f, fs)
      if prev_inbox and prev_inbox.buf == b and prev_inbox.lines[row] then
        prev_inbox.lines[row] = f .. prev_inbox.lines[row]:sub(#f + 1)
      end
    end
  end)
end

local function same_marks(a, b)
  if a == b then return true end
  if not a or not b or #a ~= #b then return false end
  for i = 1, #a do
    local x, y = a[i], b[i]
    if x[1] ~= y[1] or x[2] ~= y[2] or x[3] ~= y[3] or (x[4] == true) ~= (y[4] == true) then return false end
  end
  return true
end

draw = function()
  local now = os.time()
  last_now = now
  local panel = package.loaded["sepal.panel"] -- the side panel shows the same tasks: it redraws with the inbox
  local live = panel and panel.render() or false
  local b = buf()
  local w = b and vim.fn.win_findbuf(b)[1]
  local root = w and vim.b[b].sepal_inbox
  local list = w and M.list(root) or {}
  for _, e in ipairs(list) do
    if M.LIVE[e.status] then live = true break end
  end
  next_age = math.huge
  if live then -- integer arithmetic over the cache: any age either view shows rolls over on time
    for _, l in pairs(cache) do
      for _, e in ipairs(l) do
        local n = next_age_change(e.time, now)
        if n < next_age then next_age = n end
      end
    end
  end
  -- one timer spins both while a task they show runs, and stops when none does
  if live and not timer then
    timer = assert(vim.uv.new_timer())
    timer:start(100, 100, vim.schedule_wrap(function()
      frame, ticks = frame % #SPIN + 1, ticks + 1
      -- every change redraws at once, so a tick only moves the spinners; once a turn (1s) a whole
      -- redraw moves the ages — only when one actually rolled over since the last draw
      if frame == 1 then
        local n = os.time()
        if n < last_now or n >= next_age then return render() end
      end
      if package.loaded["sepal.panel"] then package.loaded["sepal.panel"].spin() end
      local b = buf()
      if drawn and b and vim.fn.win_findbuf(b)[1] and not vim.bo[b].modified then spin(b) end
    end))
  elseif not live and timer then
    timer:stop(); timer:close(); timer = nil
  end
  -- hidden, it stays loaded: skip it (every tool call of every task redraws); M.open redraws when shown
  if not w then drawn, prev_inbox = nil, nil; return end -- what it showed is stale now: no tick may touch it
  if vim.bo[b].modified then prev_inbox = nil; return end -- your edits wait for :w (or u): a redraw would throw them away
  local lines, rows, marks, spins, agents, plans, warns = { HELP, "" }, {}, {}, {}, {}, {}, {}
  local row_marks, fold_ranges, spin_rows = {}, {}, {}
  local function mark(row, col, end_col, hl)
    local m = row_marks[row]
    if not m then m = {}; row_marks[row] = m end
    m[#m + 1] = { col, end_col, hl }
  end
  local function line_mark(row, hl)
    local m = row_marks[row]
    if not m then m = {}; row_marks[row] = m end
    m[#m + 1] = { 0, -1, hl, true }
  end
  mark(1, 0, #HELP, "SepalDim")
  if #list == 0 then lines[#lines + 1] = "no tasks yet: :Sepal task" end
  -- every column padded to its widest value in the list, so every line is the same width
  local cols, wid = {}, { 0, 0, 0, 0 }
  for i, e in ipairs(list) do
    cols[i] = facts(e)
    for c = 1, 4 do wid[c] = math.max(wid[c], strwidth(cols[i][c])) end
  end
  local new_heads = {}
  for i, e in ipairs(list) do
    local st = STATUS[e.status] or { "?", e.status, "Normal" }
    local head = ("%s %s "):format(M.LIVE[e.status] and SPIN[frame] or cfg_icon(e.status, st[1]), fit(st[2], 12))
    local pre = ("%s%s  %s  "):format(head, fit(ago(e.time, now), 3), fit(e.title or "", 34))
    local c = cols[i]
    local f = wid[1] > 0 and ("%s %s %s"):format(fit(c[1], wid[1]), fit(c[2], wid[2]), fit(c[3], wid[3])) or ""
    f = f .. (wid[1] > 0 and wid[4] > 0 and "  " or "") .. fit(c[4], wid[4])
    lines[#lines + 1] = pre .. f
    local hrow = #lines
    if M.LIVE[e.status] then spins[#spins + 1] = hrow; spin_rows[hrow] = true end
    rows[hrow], marks[hrow], new_heads[hrow] = e.id, { st[3], #head - 1 }, true
    mark(hrow, 0, #head - 1, st[3])
    -- the age dimmed, the diff counts colored like a diff
    mark(hrow, #head, #head + 3, "SepalDim")
    if f:find("+", 1, true) then for a, z in f:gmatch("()%+%d+()") do mark(hrow, #pre + a - 1, #pre + z - 1, "SepalAdded") end end
    if f:find("−", 1, true) then for a, z in f:gmatch("()−%d+()") do mark(hrow, #pre + a - 1, #pre + z - 1, "SepalRemoved") end end
    if f:find("✔", 1, true) then for a, z in f:gmatch("()✔()") do mark(hrow, #pre + a - 1, #pre + z - 1, "SepalOk") end end
    if f:find("✘", 1, true) then for a, z in f:gmatch("()✘()") do mark(hrow, #pre + a - 1, #pre + z - 1, "SepalError") end end
    if f:find("↳ ", 1, true) then for a, z in f:gmatch("()↳ %d+ subagents?()") do mark(hrow, #pre + a - 1, #pre + z - 1, "SepalAgent") end end
    for _, d in ipairs(details(e)) do
      lines[#lines + 1] = "    " .. d; rows[#lines] = e.id
      if d:match("^↳ ") then agents[#lines] = true -- not dimmed: these are what's running
      elseif d:match("^▲ ") then warns[#lines] = true -- nor a warning: amber, not dimmed
      elseif d:match("^· ") then -- nor a decision: what you read, plain text after an accent bullet
        plans[#lines] = true
        mark(#lines, 4, 4 + #"·", "SepalAccent")
      elseif d:match("^  ") then -- a file: dimmed, its counts colored like a diff
        for a, z in d:gmatch("()%+%d+()") do mark(#lines, 3 + a, 3 + z, "SepalAdded") end
        for a, z in d:gmatch("()−%d+()") do mark(#lines, 3 + a, 3 + z, "SepalRemoved") end
      elseif e.status == "planned" and lines[#lines]:match(PLAN) then -- nor these: what s makes, the model to edit in color
        plans[#lines] = true
        local aa, zz = lines[#lines]:find("%[[^%]]*%]")
        mark(#lines, aa - 1, zz, "SepalAccent")
      end
    end
    if #lines > hrow then fold_ranges[#fold_ranges + 1] = { hrow, #lines, e.id } end
  end
  for row = 3, #lines do
    if agents[row] then line_mark(row, "SepalAgent")
    elseif warns[row] then line_mark(row, "SepalWarn")
    elseif not marks[row] and not plans[row] and lines[row]:sub(1, 4) == "    " then line_mark(row, "SepalDim") end
  end
  spun = spins
  drawn = true
  local same = prev_inbox and prev_inbox.buf == b and prev_inbox.win == w and prev_inbox.root == root
    and #lines == #prev_inbox.lines
  local unchanged = same
  if same then
    for row = 1, #lines do
      if rows[row] ~= prev_inbox.rows[row] or (new_heads[row] == true) ~= (prev_inbox.heads[row] == true) then same, unchanged = false, false break end
      if unchanged then
        local line_same
        if spin_rows[row] then
          line_same = lines[row]:sub(#SPIN[frame] + 1) == prev_inbox.lines[row]:sub(#SPIN[frame] + 1)
        else
          line_same = lines[row] == prev_inbox.lines[row]
        end
        if not line_same or not same_marks(row_marks[row], prev_inbox.row_marks[row]) then unchanged = false end
      end
    end
  end
  if unchanged then return spin(b) end -- only the spinners moved: every frame is 3 bytes, so the other marks and folds stay put
  local function set_marks(row)
    for _, m in ipairs(row_marks[row] or {}) do
      if m[4] then vim.api.nvim_buf_set_extmark(b, NS, row - 1, 0, { line_hl_group = m[3] })
      else vim.api.nvim_buf_set_extmark(b, NS, row - 1, m[1], { end_col = m[2], hl_group = m[3] }) end
    end
  end
  if same then
    quiet(b, function()
      for row = 1, #lines do
        local line_same = lines[row] == prev_inbox.lines[row]
        if not line_same or not same_marks(row_marks[row], prev_inbox.row_marks[row]) then
          vim.api.nvim_buf_set_lines(b, row - 1, row, false, { lines[row] })
          vim.api.nvim_buf_clear_namespace(b, NS, row - 1, row)
          set_marks(row)
        end
      end
    end)
    ids = {}
    for row, id in pairs(rows) do
      if marks[row] then local k = tkey(lines[row]); ids[k] = ids[k] or {}; table.insert(ids[k], id) end
    end
    vim.b[b].sepal_rows = rows
    heads = new_heads
    prev_inbox = { buf = b, win = w, root = root, lines = lines, rows = rows, heads = heads, row_marks = row_marks }
    return
  end
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
  for row = 1, #lines do set_marks(row) end
  vim.b[b].sepal_rows = rows
  heads = new_heads
  prev_inbox = { buf = b, win = w, root = root, lines = lines, rows = rows, heads = heads, row_marks = row_marks }
  vim.api.nvim_win_call(w, function()
    local cmds = { "silent! normal! zE" }
    for _, fr in ipairs(fold_ranges) do
      cmds[#cmds + 1] = ("%d,%dfold"):format(fr[1], fr[2])
      local o = opened[fr[3]]
      if o or (o == nil and planned[fr[3]]) then cmds[#cmds + 1] = fr[1] .. "foldopen" end
    end
    vim.cmd(table.concat(cmds, "\n"))
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

-- the copies of a :w, in order, as drafts one at a time (sepal.task holds one): the next opens
-- once the open draft (also one you had before the :w) is sent or discarded. An answered btw
-- copies into an implement draft, its question and answer as context
local function drafts(queue)
  local d = require("sepal").draft()
  if d then
    return vim.api.nvim_create_autocmd("BufWipeout", { buffer = d, once = true,
      callback = function() vim.schedule(function() drafts(queue) end) end })
  end
  local e = table.remove(queue, 1)
  if not e then return end
  local sepal = require("sepal")
  if e.kind == "btw" and e.answer then sepal.implement(e) else sepal.task(nil, vim.split(e.task, "\n"), e.kind, e.agent) end
  if queue[1] then drafts(queue) end
end

-- :w in the inbox: a task whose line is gone is dropped, a line put twice (yyp) opens a new task
-- with that task's text, to add to and send (an answered btw: an implement draft, see sepal.implement). Under a planned orchestrate, its plan is what its
-- plan lines say now: the [model] in each, their order, and a deleted line drops that task. An
-- edited · decision (as many as before, some text changed) goes to the task's chat to redo
function M.write(b)
  local root, seen, copies = vim.b[b].sepal_inbox, {}, {}
  local cur, plans, decs = nil, {}, {} -- the task the lines are under; id -> { { item, model } } read under it; id -> its · texts
  for _, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
    local k = tkey(l)
    if ids[k] then
      seen[k] = (seen[k] or 0) + 1
      if seen[k] > #ids[k] then copies[#copies + 1], cur = ids[k][1], nil
      else cur = ids[k][seen[k]]; plans[cur], decs[cur] = plans[cur] or {}, decs[cur] or {} end
    else
      local i, m = l:match(PLAN)
      local d = l:match("^%s*· (.*)$")
      if cur and i then table.insert(plans[cur], { tonumber(i), m })
      elseif cur and d then table.insert(decs[cur], d) end
    end
  end
  local by = {}
  for _, e in ipairs(M.list(root)) do by[e.id] = e end
  local agent = require("sepal.agent")
  for id, got in pairs(plans) do
    local e = by[id]
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
  for _, id in ipairs(gone) do local e = by[id]; if e then dropping[#dropping + 1] = e end end
  agent.drop_many(dropping) -- a running one stays
  drawn, prev_inbox = nil, nil
  render()
  local notify = require("sepal").notify
  for id, got in pairs(decs) do
    local e, was = by[id], by[id] and by[id].assumptions or {}
    local msg = {}
    if e and #got == #was then -- one deleted or added: the counts differ, nothing to redo
      for i, a in ipairs(was) do
        if got[i] ~= a then msg[#msg + 1] = ("- was: %s\n  now: %s"):format(a, got[i]) end
      end
    end
    if #msg > 0 then
      if agent.running(e) then notify(e.title .. ": it's running, x first")
      elseif not e.session then notify(e.title .. ": no chat to continue")
      elseif vim.tbl_contains({ "ready", "landed", "failed", "needs", "stopped" }, e.status) then
        e.assumptions = got
        agent.continue(e, "Change these decisions, keep everything else:\n" .. table.concat(msg, "\n"))
      end
    end
  end
  local queue = {}
  for _, id in ipairs(copies) do queue[#queue + 1] = M.find(root, id) end
  -- scheduled: :w puts you back in the inbox after BufWriteCmd, the draft should keep focus
  if queue[1] then vim.schedule(function() drafts(queue) end) end
  if #queue > 1 then require("sepal").notify(#queue .. " copies: each opens its draft once the one before is sent or discarded") end
end

-- m: on a planned orchestrate, the model of the plan item under the cursor (on its own line: of all
-- of them); on any other task, the model its next run uses (a queued one starts on it)
function M.pick_model()
  local b, e = vim.api.nvim_get_current_buf(), M.current()
  local notify = require("sepal").notify
  if not e then return end
  if vim.bo[b].modified then return notify("your edits come first: :w (or u)") end
  local sepal = require("sepal")
  if e.status == "planned" then
    local i = tonumber(vim.api.nvim_get_current_line():match(PLAN) or nil)
    local which = {}
    for k in ipairs(e.plan) do if not i or k == i then which[#which + 1] = k end end
    if #which == 0 then return end
    local cur = false
    if i then cur = e.plan[i].model end
    return sepal.pick_model((i and ("task %d"):format(i) or "every task") .. " model", cur, function(m)
      m = require("sepal.agent").model_of(m)
      for _, k in ipairs(which) do e.plan[k].model = m end
      M.changed(e)
    end)
  end
  sepal.pick_model(e.title .. " model", e.agent and e.agent.model, function(m)
    local a = vim.deepcopy(e.agent or {})
    a.model = m
    e.agent = a
    M.changed(e)
    notify(("%s: %s · %s"):format(e.title, m or "default",
      e.status == "queued" and "it starts on it" or "its next run (r, c) uses it"))
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
    vim.keymap.set("n", "s", on(agent.swarm), o("Swarm a planned orchestrate into its tasks"))
    vim.keymap.set("n", "m", M.pick_model, o("Pick the model of the task's next run"))
    vim.keymap.set("n", "C", function() require("sepal").clean() end, o("Drop the tasks that are over"))
    vim.keymap.set("n", "q", function() require("sepal").close() end, o("Close the inbox"))
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

M._t = { reset = function() cache, drawn, ids, prev_inbox = {}, nil, {}, nil; roots_version = roots_version + 1 end }

return M
