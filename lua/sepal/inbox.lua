-- sepal.inbox — every spec of a repo and where it stands, kept in a JSON file per repo (so it
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
  end
  cache[root] = list
  return list
end

local function save(root)
  vim.fn.mkdir(cfg().worktrees, "p")
  local keep = vim.tbl_map(function(e)
    local c = vim.deepcopy(e)
    c.activity = nil
    return c
  end, M.list(root))
  local f = io.open(file(root), "w")
  if f then f:write(vim.json.encode(keep)); f:close() end
end

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
  queued = { "…", "queued", "Comment" },
  running = { "⋯", "running", "DiagnosticInfo" },
  checking = { "⋯", "checking", "DiagnosticInfo" },
  landed = { "✓", "landed", "DiagnosticOk" },
  ready = { "●", "ready", "DiagnosticOk" },
  nochange = { "○", "no changes", "Comment" },
  failed = { "✗", "check failed", "DiagnosticError" },
  error = { "✗", "failed", "DiagnosticError" },
  needs = { "▲", "needs you", "DiagnosticWarn" },
  stopped = { "○", "stopped", "Comment" },
  interrupted = { "○", "interrupted", "Comment" },
  undone = { "↺", "undone", "Comment" },
}
M.STATUS = STATUS
local NS = vim.api.nvim_create_namespace("sepal.inbox")
local HELP = "<CR> diff  L land  u undo  r reply  o watch/chat  x stop  D drop  q close"

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

-- the facts after the title: "3 files +42 −8  make test ✓"
local function facts(e)
  local f = {}
  if e.stat and e.stat.files > 0 then f[#f + 1] = ("%d file%s +%d −%d"):format(e.stat.files, e.stat.files == 1 and "" or "s", e.stat.add, e.stat.del) end
  if e.check then
    local mark = e.checked == true and " ✓" or e.checked == false and " ✗" or ""
    f[#f + 1] = e.check .. mark
  end
  if e.status == "running" and e.activity then f[#f + 1] = e.activity end
  return table.concat(f, "  ")
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
  return d
end

local function buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do if vim.b[b].sepal_inbox then return b end end
end

render = function()
  local b = buf()
  if not b or not vim.api.nvim_buf_is_valid(b) then return end
  local root = vim.b[b].sepal_inbox
  local lines, rows, marks = { HELP, "" }, {}, {}
  local list = M.list(root)
  if #list == 0 then lines[#lines + 1] = "no specs yet: :Sepal spec" end
  for _, e in ipairs(list) do
    local st = STATUS[e.status] or { "?", e.status, "Normal" }
    lines[#lines + 1] = ("%s %s %s  %s  %s"):format(st[1], fit(st[2], 12), fit(ago(e.time), 3), fit(e.title or "", 34), facts(e))
    rows[#lines], marks[#lines] = e.id, { st[3], #st[1] + 1 + #fit(st[2], 12) }
    for _, d in ipairs(details(e)) do lines[#lines + 1] = "    " .. d; rows[#lines] = e.id end
  end
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable, vim.bo[b].modified = false, false
  vim.api.nvim_buf_clear_namespace(b, NS, 0, -1)
  vim.api.nvim_buf_set_extmark(b, NS, 0, 0, { end_row = 0, end_col = #HELP, hl_group = "Comment" })
  for row, m in pairs(marks) do vim.api.nvim_buf_set_extmark(b, NS, row - 1, 0, { end_col = m[2], hl_group = m[1] }) end
  for row = 3, #lines do
    if not marks[row] and lines[row]:match("^    ") then vim.api.nvim_buf_set_extmark(b, NS, row - 1, 0, { line_hl_group = "Comment" }) end
  end
  vim.b[b].sepal_rows = rows
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
    vim.bo[b].bufhidden = "hide"
    vim.bo[b].filetype = "sepal-inbox"
    vim.api.nvim_buf_set_name(b, "sepal://inbox")
    local agent = require("sepal.agent")
    local function on(f) return function() local e = M.current(); if e then f(e) end end end
    local o = function(desc) return { buffer = b, desc = desc, nowait = true } end
    vim.keymap.set("n", "<CR>", on(agent.show), o("Show what the spec changed"))
    vim.keymap.set("n", "L", on(agent.land), o("Land it in your work tree"))
    vim.keymap.set("n", "u", on(agent.undo), o("Take a landed spec back out"))
    vim.keymap.set("n", "r", on(agent.reply), o("Reply: the agent continues this spec"))
    vim.keymap.set("n", "o", on(agent.open), o("Watch the agent, or open the spec's chat"))
    vim.keymap.set("n", "x", on(agent.stop), o("Stop it"))
    vim.keymap.set("n", "D", on(agent.drop), o("Drop it"))
    vim.keymap.set("n", "q", "<cmd>close<cr>", o("Close the inbox"))
  end
  vim.b[b].sepal_inbox = root
  local w = vim.fn.bufwinid(b)
  if w == -1 then w = vim.api.nvim_open_win(b, true, { split = "below", win = -1, height = 12 }) end
  vim.api.nvim_set_current_win(w)
  vim.wo[w].wrap, vim.wo[w].cursorline = false, true
  render()
  if vim.api.nvim_buf_line_count(b) >= 3 then vim.api.nvim_win_set_cursor(w, { 3, 0 }) end
end

M._t = { reset = function() cache = {} end }

return M
