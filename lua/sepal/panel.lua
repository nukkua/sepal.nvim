-- sepal.panel — :Sepal panel, a board at the right that only shows: each task as a card with its
-- status, what the agent is doing right now and a short summary. It redraws with the inbox (and
-- spins while a task runs); o watches the task under the cursor, q closes it. To act, :Sepal inbox.

local M = {}

local inbox = require("sepal.inbox")
local NS = vim.api.nvim_create_namespace("sepal.panel")
local WIDTH = 46
-- the header's counts, in this order: { label, statuses, hl }
local COUNTS = {
  { "running", { running = true, checking = true }, "SepalAccent" },
  { "queued", { queued = true }, "SepalDim" },
  { "need you", { needs = true, failed = true, error = true }, "SepalWarn" },
  { "ready", { ready = true }, "SepalOk" },
  { "answered", { answered = true }, "SepalOk" },
  { "landed", { landed = true }, "SepalOk" },
}

-- what each status means for you, next to it: the label alone didn't say what to do
local HINT = {
  queued = "waits for a free agent",
  running = "working · o to watch",
  checking = "running the check",
  ready = "done · review and L in :Sepal inbox",
  landed = "in your work tree",
  nochange = "done, nothing changed",
  failed = "r in :Sepal inbox to fix it",
  error = "c in :Sepal inbox to retry",
  needs = "waiting on you · o to answer",
  stopped = "c in :Sepal inbox to continue",
  interrupted = "c in :Sepal inbox to continue",
  undone = "taken back out",
  answered = "<CR> in :Sepal inbox reads it",
}
-- the provider's logo, by what its model is called; icons = { claude = "…", … } in setup changes them
local PROVIDERS = {
  { "devin", "❖", { "fusion", "devin", "swe" } }, -- first: fusion names contain "claude"/"opus"
  { "claude", "✻", { "claude", "opus", "sonnet", "haiku", "fable" } },
  { "openai", "֎", { "gpt", "chatgpt", "codex", "openai", "^o%d" } },
  { "gemini", "✦", { "gemini" } },
  { "opencode", "⌬", { "opencode" } },
}
-- the logo and its color: claude's in its orange
local function logo(m)
  m = m:lower()
  for _, p in ipairs(PROVIDERS) do
    for _, k in ipairs(p[3]) do
      if m:find(k) then return require("sepal").icon(p[1], p[2]), p[1] == "claude" and "SepalClaude" or "SepalDim" end
    end
  end
  return "◇", "SepalDim"
end
-- "claude-opus-5-5[1m]" -> "opus 5.5", "claude-sonnet-4-5-20250929" -> "sonnet 4.5", "openai/gpt-5" -> "gpt-5",
-- "fusion-claude-opus-5-5-medium-sidekick-swe-2-high" -> "opus 5.5 medium + swe 2 high"
local function model(m)
  local lead, sidekick = m:match("^fusion%-(.-)%-sidekick%-(.+)$")
  if lead then
    local function part(s) return (s:gsub("^claude%-", ""):gsub("(%d+)%-(%d+)", "%1.%2"):gsub("%-", " ")) end
    return part(lead) .. " + " .. part(sidekick)
  end
  m = m:gsub("%[.-%]$", ""):gsub("^.*/", ""):gsub("^claude%-", ""):gsub("%-%d%d%d%d%d%d%d%d$", "")
  return (m:gsub("%-(%d+)%-(%d+)$", " %1.%2"):gsub("%-(%d+)$", " %1"))
end
M.logo, M.model = logo, model -- :Sepal task's picker and draft show them too

local panel_buf
local drawn -- what it shows, spinners blanked: see render
local spun = {} -- { row, col } of each spinner drawn
local rows = {} -- row -> task id
local function buf() return panel_buf and vim.api.nvim_buf_is_valid(panel_buf) and panel_buf or nil end
local function win()
  local b = buf()
  local w = b and vim.fn.bufwinid(b) or -1
  return w ~= -1 and w or nil
end

function M.shown() return win() ~= nil end -- sepal.fidget checks on every BufEnter/WinClosed

local memo_n, dw_c, wrap_c, card_c = 0, {}, {}, {} -- card() measures a lot of text per redraw: memoized
local function dw(s)
  local v = dw_c[s]
  if not v then
    if memo_n > 4096 then memo_n, dw_c, wrap_c, card_c = 0, {}, {}, {} end
    dw_c[s], memo_n = vim.api.nvim_strwidth(s), memo_n + 1
    v = dw_c[s]
  end
  return v
end
local function wrap(s, w)
  local k = w .. "\0" .. s
  local out = wrap_c[k]
  if out then return out end
  if memo_n > 4096 then memo_n, dw_c, wrap_c, card_c = 0, {}, {}, {} end
  out, memo_n = {}, memo_n + 1
  local line = ""
  for word in s:gmatch("%S+") do
    local cand = line == "" and word or line .. " " .. word
    if dw(cand) > w and line ~= "" then out[#out + 1], line = line, word else line = cand end
  end
  if line ~= "" then out[#out + 1] = line end
  wrap_c[k] = out
  return out
end

-- everything card reads of e, as a string: the cache key for its rows
local function card_sig(e, w)
  local s, subs, C = e.stat, {}, require("sepal").config()
  for _, a in ipairs(e.subagents or {}) do subs[#subs + 1] = tostring(a.name) end
  return table.concat({ tostring(e.status), inbox.ago(e.time), tostring(e.title), w, tostring(e.attempts),
    tostring(e.check), tostring(e.checked), tostring(s and s.files), tostring(s and s.add), tostring(s and s.del),
    tostring(e.activity), table.concat(subs, "\1"), tostring(e.why), tostring(e.error), tostring(e.summary),
    tostring(not e.summary and e.task), #(e.assumptions or {}), tostring(e.model),
    tostring(e.agent and e.agent.cmd), tostring(require("sepal").icon(e.status, "?")),
    tostring(C.retries), tostring(C.sakura), tostring(e.race), tostring(e.racers), tostring(e.won), tostring(e.lost),
    tostring(inbox.LIVE[e.status] and inbox.spin()) }, "\0")
end

-- a task as rows of { text, hl } chunks, behind a rail in its status's color (each row starts
-- with the " " margin chunk: rows are cached whole by card_sig)
local function card(e, w)
  -- with custom icons the sig can't tell a provider's logo apart: don't cache then
  local sig = not next(require("sepal").config().icons or {}) and card_sig(e, w)
  local cached = sig and card_c[sig]
  if cached then return cached end
  if memo_n > 4096 then memo_n, dw_c, wrap_c, card_c = 0, {}, {}, {} end
  local st = inbox.STATUS[e.status] or { "?", e.status, "Normal" }
  local live = inbox.LIVE[e.status]
  local icon = live and inbox.spin() or require("sepal").icon(e.status, st[1])
  local rail, age = { "▎ ", st[3] }, inbox.ago(e.time)
  local inner = w - 2
  local pad = { " ", "Normal" }
  local out = {
    { pad, rail, { icon .. " ", st[3], spin = live }, { inbox.fit(e.title or "", inner - dw(icon) - 2 - dw(age)), "SepalPanelTitle" },
      { " " .. age, "SepalDim" } },
  }
  local function row(...) out[#out + 1] = { pad, rail, ... } end
  -- who works on it, under its name: its model's provider logo, else ❖ for a devin agent
  if e.model then
    local l, hl = logo(e.model)
    row({ l, hl }, { (inbox.fit(" " .. model(e.model), inner - dw(l)):gsub("%s+$", "")), "SepalDim" })
  elseif e.agent then
    local c = e.agent.cmd
    if vim.fs.basename((type(c) == "string" and c:match("^%S+") or c and c[1] or "")):match("^devin") then
      local l = require("sepal").icon("devin", "❖")
      row({ l, "SepalDim" }, { " devin", "SepalDim" })
    end
  end
  -- status · try · check
  local meta = { { st[2]:upper(), st[3] } }
  if HINT[e.status] then meta[#meta + 1] = { "  " .. HINT[e.status], "SepalDim" } end
  local function add(t, hl) meta[#meta + 1] = { " · ", "SepalDim" }; meta[#meta + 1] = { t, hl or "SepalDim" } end
  if (e.attempts or 0) > 0 then add(("try %d/%d"):format(e.attempts + 1, (require("sepal").config().retries or 0) + 1)) end
  if e.check then
    add(e.check .. (e.checked == true and " ✓" or e.checked == false and " ✗" or ""),
      e.checked == true and "SepalOk" or e.checked == false and "SepalError" or "SepalDim")
  end
  if e.race and (inbox.LIVE[e.status] or e.status == "queued") then add("⚑ race", "SepalAccent") end
  if e.won then add("⚑ won", "SepalAccent") end
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
  local subs = e.status == "running" and e.subagents or {}
  if #subs > 0 then -- in their own color: work fanned out is easy to miss among the dim rows
    local t = ("↳ %d subagent%s: %s"):format(#subs, #subs == 1 and "" or "s",
      table.concat(vim.tbl_map(function(a) return a.name end, subs), ", "))
    row({ (inbox.fit(t, inner):gsub("%s+$", "")), "SepalAgent" })
  end
  if e.why then para(e.why, "SepalWarn", "", 3) end
  if e.error then para(e.error, "SepalError", "", 3) end
  if e.summary then para(e.summary, "Normal", "", 3)
  elseif not inbox.LIVE[e.status] and e.status ~= "queued" then -- nothing said yet: what was asked
    para(vim.trim((e.task or ""):gsub("^%s*Goal:%s*", ""):gsub("\n.*", "")), "SepalDim", "", 2)
  end
  local n = #(e.assumptions or {})
  if n > 0 then row({ ("· %d decision%s to read"):format(n, n == 1 and "" or "s"), "SepalDim" }) end
  if sig then card_c[sig], memo_n = out, memo_n + 1 end
  return out
end

-- returns whether a task it shows is running, for the inbox's spinner timer
function M.render()
  local w = win()
  if not w then drawn = nil; return false end -- stale once hidden: no tick may touch it
  local list = inbox.list(vim.b[buf()].sepal_panel)
  local width = vim.api.nvim_win_get_width(w) - 1
  local root = vim.b[buf()].sepal_panel
  local out = { { { " ", "Normal" }, { require("sepal").icon("landed", "◆") .. " sepal", "SepalTitle" },
    { "  " .. vim.fs.basename(root), "SepalDim" } } }
  local counts = { { " ", "Normal" } }
  for _, c in ipairs(COUNTS) do
    local k = #vim.tbl_filter(function(e) return c[2][e.status] end, list)
    if k > 0 then
      if #counts > 1 then counts[#counts + 1] = { " · ", "SepalDim" } end
      counts[#counts + 1] = { k .. " " .. c[1], c[3] }
    end
  end
  out[#out + 1] = counts
  out[#out + 1] = { { " ", "Normal" }, { "o watch · q close", "SepalDim" } }
  out[#out + 1] = { { " " .. string.rep("─", width - 2), "SepalDim" } }
  rows = {}
  if #list == 0 then -- the empty state: centered under the divider, saying how to start
    out[#out + 1] = {}
    for _, l in ipairs({ { "◇", "SepalDim" }, {}, { "no tasks yet", "SepalPanelTitle" }, { "start one with :Sepal task", "SepalDim" } }) do
      out[#out + 1] = l[1] and { { string.rep(" ", math.max(0, math.floor((width - dw(l[1])) / 2))) .. l[1], l[2] } } or {}
    end
  end
  for _, e in ipairs(list) do
    out[#out + 1] = {}
    for _, r in ipairs(card(e, width - 1)) do -- its margin chunk is part of the row: never mutated, card may return it cached
      out[#out + 1] = r
      rows[#out] = e.id
    end
  end
  local lines, marks, spins, key = {}, {}, {}, { w, root }
  for i, r in ipairs(out) do
    local text, k = "", tostring(rows[i])
    for _, c in ipairs(r) do
      marks[#marks + 1] = { i - 1, #text, #text + #c[1], c[2] }
      if c.spin then spins[#spins + 1] = { i - 1, #text } end
      k = k .. "\0" .. (c.spin and "\1" .. c[1]:sub(#inbox.spin() + 1) or c[1])
      text = text .. c[1]
    end
    lines[i], key[#key + 1] = text, k
  end
  key = table.concat(key, "\n")
  spun = spins
  if key == drawn then M.spin(); return #spins > 0 end
  drawn = key
  local b = buf()
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable, vim.bo[b].modified = false, false
  vim.api.nvim_buf_clear_namespace(b, NS, 0, -1)
  for _, m in ipairs(marks) do vim.api.nvim_buf_set_extmark(b, NS, m[1], m[2], { end_col = m[3], hl_group = m[4] }) end
  return #spins > 0
end

-- only the spinners moved (each frame is 3 bytes): rewrite just them, in what render drew last
function M.spin()
  local b = buf()
  if not (drawn and win()) then return end
  local f = inbox.spin()
  vim.bo[b].modifiable = true
  for _, s in ipairs(spun) do vim.api.nvim_buf_set_text(b, s[1], s[2], s[1], s[2] + #f, { f }) end
  vim.bo[b].modifiable, vim.bo[b].modified = false, false
end

-- :Sepal panel: shows the board of root's tasks at the right, or hides it
function M.toggle(root)
  local w = win()
  if w then
    if not pcall(vim.api.nvim_win_close, w, false) then require("sepal").close() end -- the last window
    inbox.render() -- stops the spinner
    return require("sepal").fidget()
  end
  local b = buf()
  if not b then
    b = vim.api.nvim_create_buf(false, true)
    panel_buf = b
    vim.bo[b].bufhidden, vim.bo[b].filetype = "hide", "sepal-panel"
    vim.api.nvim_buf_set_name(b, "sepal://panel")
    local o = function(desc) return { buffer = b, desc = desc, nowait = true } end
    vim.keymap.set("n", "q", function() M.toggle() end, o("Close the panel"))
    vim.keymap.set("n", "o", function()
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
  inbox.render() -- starts the spinner
  require("sepal").fidget()
end

M._t = { rows = function() return rows end }

return M
