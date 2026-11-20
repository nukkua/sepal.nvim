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

local function save(root)
  vim.fn.mkdir(cfg().worktrees, "p")
  local keep = vim.tbl_map(function(e) -- a shallow copy is enough: it's only encoded
    local c = {}
    for k, v in pairs(e) do if k ~= "activity" and k ~= "reply" then c[k] = v end end -- reply: older inboxes had it
    return c
  end, M.list(root))
  local f = io.open(file(root), "w")
  if f then f:write(vim.json.encode(keep)); f:close() end
end

M.save = save

local render -- below

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
}
M.STATUS = STATUS
M.LIVE = { running = true, checking = true } -- these spin in the inbox and the panel
local SPIN, frame, timer = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }, 1, nil
function M.spin() return SPIN[frame] end
local function cfg_icon(...) return require("sepal").icon(...) end
local NS = vim.api.nvim_create_namespace("sepal.inbox")
local HELP = "<CR> diff  L land  u undo  r reply  c continue  o watch/chat  x stop  D drop  C clean  za fold  q close"

local function ago(t)
  local s = os.time() - (t or os.time())
  for _, u in ipairs({ { 86400, "d" }, { 3600, "h" }, { 60, "m" } }) do
    if s >= u[1] then return math.floor(s / u[1]) .. u[2] end
  end
  return "now"
end
local function fit(s, w)
  if vim.fn.strdisplaywidth(s) > w then s = vim.fn.strcharpart(s, 0, w - 1) .. "…" end
  return s .. string.rep(" ", w - vim.fn.strdisplaywidth(s))
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
  return { s and ("%d file%s"):format(s.files, s.files == 1 and "" or "s") or "", s and "+" .. s.add or "",
    s and "−" .. s.del or "", table.concat(f, "  ") }
end

-- the lines under an entry: what you should read
local function details(e)
  local d = {}
  if e.why then d[#d + 1] = e.why end
  if e.error then d[#d + 1] = e.error end
  if e.status == "failed" and e.check_out then
    for _, l in ipairs(vim.list_slice(vim.split(vim.trim(e.check_out), "\n"), 1, 3)) do d[#d + 1] = "│ " .. l end
  end
  for _, a in ipairs(e.assumptions or {}) do d[#d + 1] = "· " .. a end
  for _, c in ipairs(e.conflicts or {}) do d[#d + 1] = "conflict markers in " .. c end
  for _, f in ipairs(e.stat and e.stat.list or {}) do d[#d + 1] = "  " .. f end
  return d
end

local opened = {} -- task id -> true when you opened its fold: tasks start folded
local heads = {} -- row -> true for each task's first line, so j/k can skip its details
local inbox_buf -- kept, not searched for: render runs on every tool call of every running task
local function buf() return inbox_buf and vim.api.nvim_buf_is_valid(inbox_buf) and inbox_buf or nil end

render = function()
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
    timer:start(100, 100, vim.schedule_wrap(function() frame = frame % #SPIN + 1; render() end))
  elseif not live and timer then
    timer:stop(); timer:close(); timer = nil
  end
  -- hidden, it stays loaded: skip it (every tool call of every task redraws); M.open redraws when shown
  if not w then return end
  -- each task is a fold (za/zc/zo/zM/zR); the lines change on every redraw, so its state is kept by task
  local old = vim.b[b].sepal_rows or {}
  vim.api.nvim_win_call(w, function()
    for row in pairs(heads) do
      if heads[row] and old[row] then opened[old[row]] = vim.fn.foldclosed(row) == -1 or nil end
    end
  end)
  local lines, rows, marks, spans = { HELP, "" }, {}, {}, {}
  if #list == 0 then lines[#lines + 1] = "no tasks yet: :Sepal task" end
  -- every column padded to its widest value in the list, so every line is the same width
  local cols, wid = {}, { 0, 0, 0, 0 }
  for i, e in ipairs(list) do
    cols[i] = facts(e)
    for c = 1, 4 do wid[c] = math.max(wid[c], vim.fn.strdisplaywidth(cols[i][c])) end
  end
  for i, e in ipairs(list) do
    local st = STATUS[e.status] or { "?", e.status, "Normal" }
    local head = ("%s %s "):format(M.LIVE[e.status] and SPIN[frame] or cfg_icon(e.status, st[1]), fit(st[2], 12))
    local pre = ("%s%s  %s  "):format(head, fit(ago(e.time), 3), fit(e.title or "", 34))
    local c = cols[i]
    local f = wid[1] > 0 and ("%s %s %s"):format(fit(c[1], wid[1]), fit(c[2], wid[2]), fit(c[3], wid[3])) or ""
    f = f .. (wid[1] > 0 and wid[4] > 0 and "  " or "") .. fit(c[4], wid[4])
    lines[#lines + 1] = pre .. f
    rows[#lines], marks[#lines] = e.id, { st[3], #head - 1 }
    -- the age dimmed, the diff counts colored like a diff
    spans[#spans + 1] = { #lines, #head, #head + 3, "SepalDim" }
    for a, z in f:gmatch("()%+%d+()") do spans[#spans + 1] = { #lines, #pre + a - 1, #pre + z - 1, "SepalAdded" } end
    for a, z in f:gmatch("()−%d+()") do spans[#spans + 1] = { #lines, #pre + a - 1, #pre + z - 1, "SepalRemoved" } end
    for _, d in ipairs(details(e)) do lines[#lines + 1] = "    " .. d; rows[#lines] = e.id end
  end
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable, vim.bo[b].modified = false, false
  vim.api.nvim_buf_clear_namespace(b, NS, 0, -1)
  vim.api.nvim_buf_set_extmark(b, NS, 0, 0, { end_row = 0, end_col = #HELP, hl_group = "SepalDim" })
  for row, m in pairs(marks) do vim.api.nvim_buf_set_extmark(b, NS, row - 1, 0, { end_col = m[2], hl_group = m[1] }) end
  for _, sp in ipairs(spans) do vim.api.nvim_buf_set_extmark(b, NS, sp[1] - 1, sp[2], { end_col = sp[3], hl_group = sp[4] }) end
  for row = 3, #lines do
    if not marks[row] and lines[row]:match("^    ") then vim.api.nvim_buf_set_extmark(b, NS, row - 1, 0, { line_hl_group = "SepalDim" }) end
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
        if opened[rows[row]] then vim.cmd(row .. "foldopen") end
      end
    end
  end)
end
M.render = function() render() end

-- the entry under the cursor in the inbox
function M.current()
  local b = vim.api.nvim_get_current_buf()
  local id = (vim.b[b].sepal_rows or {})[vim.api.nvim_win_get_cursor(0)[1]]
  return id and M.find(vim.b[b].sepal_inbox, id)
end

function M.open(root)
  local b = buf()
  if not b then
    b = vim.api.nvim_create_buf(false, true)
    inbox_buf = b
    vim.bo[b].bufhidden = "hide"
    vim.bo[b].filetype = "sepal-inbox"
    vim.api.nvim_buf_set_name(b, "sepal://inbox")
    local agent = require("sepal.agent")
    local function on(f) return function() local e = M.current(); if e then f(e) end end end
    local o = function(desc) return { buffer = b, desc = desc, nowait = true } end
    vim.keymap.set("n", "<CR>", on(agent.show), o("Show what the task changed"))
    vim.keymap.set("n", "L", on(agent.land), o("Land it in your work tree"))
    vim.keymap.set("n", "u", on(agent.undo), o("Take a landed task back out"))
    vim.keymap.set("n", "r", on(agent.reply), o("Reply: the agent continues this task"))
    vim.keymap.set("n", "c", on(agent.resume), o("Continue a task that was cut short (quit, stopped, crashed)"))
    vim.keymap.set("n", "o", on(agent.open), o("Watch the agent, or open the task's chat"))
    vim.keymap.set("n", "x", on(agent.stop), o("Stop it"))
    vim.keymap.set("n", "D", on(agent.drop), o("Drop it"))
    vim.keymap.set("n", "C", function() require("sepal").clean() end, o("Drop the tasks that are over"))
    vim.keymap.set("n", "q", function() require("sepal").close() end, o("Close the inbox"))
    -- j/k go task to task, past the detail lines under each
    local function step(dir)
      return function()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        for _ = 1, vim.v.count1 do
          local r = row + dir
          while r >= 1 and r <= #heads and not heads[r] do r = r + dir end
          if not heads[r] then break end
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

M._t = { reset = function() cache = {} end }

return M
