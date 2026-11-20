-- sepal.panel — :Sepal panel, a board at the right that only shows: each task as a card with its
-- status, what the agent is doing right now and a short summary. It redraws with the inbox (and
-- spins while a task runs); <CR> watches the task under the cursor, q closes it. To act, :Sepal inbox.

local M = {}

local inbox = require("sepal.inbox")
local NS = vim.api.nvim_create_namespace("sepal.panel")
local WIDTH = 46
local SPIN = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local LIVE = { running = true, checking = true }
-- the header's counts, in this order: { label, statuses, hl }
local COUNTS = {
  { "running", { running = true, checking = true }, "SepalAccent" },
  { "queued", { queued = true }, "SepalDim" },
  { "need you", { needs = true, failed = true, error = true }, "SepalWarn" },
  { "ready", { ready = true }, "SepalOk" },
  { "landed", { landed = true }, "SepalOk" },
}

local panel_buf, timer, frame = nil, nil, 1
local rows = {} -- row -> task id
local function buf() return panel_buf and vim.api.nvim_buf_is_valid(panel_buf) and panel_buf or nil end
local function win()
  local b = buf()
  local w = b and vim.fn.bufwinid(b) or -1
  return w ~= -1 and w or nil
end

local function dw(s) return vim.fn.strdisplaywidth(s) end
local function wrap(s, w)
  local out, line = {}, ""
  for word in s:gmatch("%S+") do
    local cand = line == "" and word or line .. " " .. word
    if dw(cand) > w and line ~= "" then out[#out + 1], line = line, word else line = cand end
  end
  if line ~= "" then out[#out + 1] = line end
  return out
end

-- a task as rows of { text, hl } chunks, behind a rail in its status's color
local function card(e, w)
  local st = inbox.STATUS[e.status] or { "?", e.status, "Normal" }
  local icon = LIVE[e.status] and SPIN[frame] or require("sepal").icon(e.status, st[1])
  local rail, age = { "▎ ", st[3] }, inbox.ago(e.time)
  local inner = w - 2
  local out = {
    { rail, { icon .. " ", st[3] }, { inbox.fit(e.title or "", inner - dw(icon) - 2 - dw(age)), "SepalPanelTitle" },
      { " " .. age, "SepalDim" } },
  }
  local function row(...) out[#out + 1] = { rail, ... } end
  -- status · try · check
  local meta = { { st[2], st[3] } }
  local function add(t, hl) meta[#meta + 1] = { " · ", "SepalDim" }; meta[#meta + 1] = { t, hl or "SepalDim" } end
  if (e.attempts or 0) > 0 then add(("try %d/%d"):format(e.attempts + 1, (require("sepal").config().retries or 0) + 1)) end
  if e.check then
    add(e.check .. (e.checked == true and " ✓" or e.checked == false and " ✗" or ""),
      e.checked == true and "SepalOk" or e.checked == false and "SepalError" or "SepalDim")
  end
  row(unpack(meta))
  local s = e.stat
  if s and s.files > 0 then
    row({ ("%d file%s "):format(s.files, s.files == 1 and "" or "s"), "SepalDim" }, { "+" .. s.add, "SepalAdded" },
      { " ", "SepalDim" }, { "−" .. s.del, "SepalRemoved" })
  end
  local function para(text, hl, lead, max)
    for i, l in ipairs(wrap(text, inner - dw(lead))) do
      if i > max then break end
      row({ i == 1 and lead or string.rep(" ", dw(lead)), hl }, { l, hl })
    end
  end
  if e.status == "running" and e.activity then para(e.activity, "SepalInfo", "→ ", 2) end
  if e.why then para(e.why, "SepalWarn", "", 3) end
  if e.error then para(e.error, "SepalError", "", 3) end
  if e.summary then para(e.summary, "Normal", "", 3)
  elseif not LIVE[e.status] and e.status ~= "queued" then -- nothing said yet: what was asked
    para(vim.trim((e.task or ""):gsub("^%s*Goal:%s*", ""):gsub("\n.*", "")), "SepalDim", "", 2)
  end
  local n = #(e.assumptions or {})
  if n > 0 then row({ ("· %d decision%s to read"):format(n, n == 1 and "" or "s"), "SepalDim" }) end
  return out
end

function M.render()
  local w = win()
  local list = w and inbox.list(vim.b[buf()].sepal_panel) or {}
  local live = vim.iter(list):any(function(e) return LIVE[e.status] end)
  if live and not timer then
    timer = assert(vim.uv.new_timer())
    timer:start(100, 100, vim.schedule_wrap(function() frame = frame % #SPIN + 1; M.render() end))
  elseif not live and timer then
    timer:stop(); timer:close(); timer = nil
  end
  if not w then return end
  local width = vim.api.nvim_win_get_width(w) - 1
  local root = vim.b[buf()].sepal_panel
  local out = { { { " " .. require("sepal").icon("landed", "◆") .. " sepal", "SepalTitle" }, { "  " .. vim.fs.basename(root), "SepalDim" } } }
  local counts = { { " ", "SepalDim" } }
  for _, c in ipairs(COUNTS) do
    local k = #vim.tbl_filter(function(e) return c[2][e.status] end, list)
    if k > 0 then
      if #counts > 1 then counts[#counts + 1] = { " · ", "SepalDim" } end
      counts[#counts + 1] = { k .. " " .. c[1], c[3] }
    end
  end
  out[#out + 1] = #counts > 1 and counts or { { " nothing yet: :Sepal task", "SepalDim" } }
  out[#out + 1] = { { " " .. string.rep("─", width - 2), "SepalDim" } }
  rows = {}
  for _, e in ipairs(list) do
    out[#out + 1] = {}
    for _, r in ipairs(card(e, width - 1)) do
      table.insert(r, 1, { " ", "Normal" })
      out[#out + 1] = r
      rows[#out] = e.id
    end
  end
  local lines, marks = {}, {}
  for i, r in ipairs(out) do
    local text = ""
    for _, c in ipairs(r) do
      marks[#marks + 1] = { i - 1, #text, #text + #c[1], c[2] }
      text = text .. c[1]
    end
    lines[i] = text
  end
  local b = buf()
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable, vim.bo[b].modified = false, false
  vim.api.nvim_buf_clear_namespace(b, NS, 0, -1)
  for _, m in ipairs(marks) do vim.api.nvim_buf_set_extmark(b, NS, m[1], m[2], { end_col = m[3], hl_group = m[4] }) end
end

-- :Sepal panel: shows the board of root's tasks at the right, or hides it
function M.toggle(root)
  local w = win()
  if w then
    if not pcall(vim.api.nvim_win_close, w, false) then require("sepal").close() end -- the last window
    return M.render() -- stops the spinner
  end
  local b = buf()
  if not b then
    b = vim.api.nvim_create_buf(false, true)
    panel_buf = b
    vim.bo[b].bufhidden, vim.bo[b].filetype = "hide", "sepal-panel"
    vim.api.nvim_buf_set_name(b, "sepal://panel")
    local o = function(desc) return { buffer = b, desc = desc, nowait = true } end
    vim.keymap.set("n", "q", function() M.toggle() end, o("Close the panel"))
    vim.keymap.set("n", "<CR>", function()
      local id = rows[vim.api.nvim_win_get_cursor(0)[1]]
      local e = id and inbox.find(vim.b[b].sepal_panel, id)
      if e then require("sepal.agent").open(e) end
    end, o("Watch the agent, or open the task's chat"))
    vim.api.nvim_create_autocmd("WinResized", { group = vim.api.nvim_create_augroup("sepal.panel", {}), callback = function() M.render() end })
  end
  vim.b[b].sepal_panel = root
  -- focus stays where you are: it's for looking at
  w = vim.api.nvim_open_win(b, false, { split = "right", win = -1, width = WIDTH })
  vim.wo[w].wrap, vim.wo[w].cursorline, vim.wo[w].winfixwidth = false, false, true
  vim.wo[w].number, vim.wo[w].relativenumber, vim.wo[w].signcolumn, vim.wo[w].foldcolumn = false, false, "no", "0"
  vim.wo[w].list, vim.wo[w].spell, vim.wo[w].fillchars = false, false, "eob: "
  M.render()
end

M._t = { rows = function() return rows end }

return M
