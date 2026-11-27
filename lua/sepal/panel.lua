-- sepal.panel — :Sepal panel, a board at the right that only shows: each task as a card with its
-- status, what the agent is doing right now and a short summary. It redraws with the inbox (and
-- while a task runs its icon spins and a light slides down its rail and over its status); o watches
-- the task under the cursor, q closes it. To act, :Sepal inbox.

local M = {}

local agent = require("sepal.agent")
local inbox = require("sepal.inbox")
local NS = vim.api.nvim_create_namespace("sepal.panel")
local ANIM = vim.api.nvim_create_namespace("sepal.panel.anim") -- the light on a working card, redrawn each tick
local WIDTH = 46 -- panel_width's default
-- the panel_width option in columns: a number of 1 or more is columns, a fraction (0.3) or "30%" a
-- share of the editor's width; anything else is the default. At least 20, and room for a window beside it
function M.width(o)
  o = o == nil and require("sepal").config().panel_width or o
  local pct = type(o) == "string" and tonumber(o:match("^%s*([%d.]+)%s*%%%s*$"))
  local n = pct and vim.o.columns * pct / 100 or type(o) == "number" and o > 0 and (o < 1 and vim.o.columns * o or o) or WIDTH
  return math.max(1, math.min(math.max(20, math.floor(n)), vim.o.columns - 20))
end
-- the header's counts, in this order: { label, statuses, hl }
local COUNTS = {
  { "running", { running = true, checking = true }, "SepalAccent" },
  { "queued", { queued = true }, "SepalDim" },
  { "need you", { needs = true, failed = true, error = true }, "SepalWarn" },
  { "ready", { ready = true }, "SepalOk" },
  { "answered", { answered = true }, "SepalOk" },
  { "planned", { planned = true }, "SepalOk" },
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
  planned = "s in :Sepal inbox starts its tasks",
  split = "its tasks are in the inbox",
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
local drawn -- true once drawn: the timer may move its spinners
local prev -- the last draw, for patching only the rows that changed
local anim_lit = false -- shimmer extmarks are set
local spun = {} -- { row, col } of each spinner drawn
local glows = {} -- a list of { row, col, end_col } of the "▎" of each drawn row, per card
local shines = {} -- { row, col, text } of each live status label drawn
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
  if not s:find("[^\32-\126]") then return #s end
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

-- the context window as text: 39149 -> "39.1k", 200000 -> "200k", 1000000 -> "1M"
local function fmt(n)
  if n < 1000 then return ("%d"):format(n) end
  if n < 1e6 then return ("%.1f"):format(n / 1e3):gsub("%.0$", "") .. "k" end
  return ("%.1f"):format(n / 1e6):gsub("%.0$", "") .. "M"
end
M.fmt = fmt
local function pct(u) return math.floor(u.used * 100 / u.limit + 0.5) end
M.pct = pct
-- p percent as 10 cells (filled, empty) and the highlight for the text after them
local function cells(p)
  local hl = p >= 90 and "SepalError" or p >= 70 and "SepalWarn" or "SepalAccent"
  local n = math.max(0, math.min(10, math.floor(p / 10 + 0.5)))
  return { ("█"):rep(n), hl }, { ("░"):rep(10 - n), "SepalDim" }, p < 70 and "SepalDim" or hl
end
-- a card's bar row chunks, 10 cells: 70% amber, 90% red (the user's thresholds). No limit is no
-- denominator — "in · out" like Devin's /usage, and it says why
local function bar(u, kind)
  if not u.limit then
    return { (u.out and fmt(u.used) .. " in · " .. fmt(u.out) .. " out" or fmt(u.used)) .. " · no limit: "
      .. (agent.AGENT_NAMES[kind] or "the agent") .. (kind == "devin" and " exposes none" or " reported none"), "SepalDim" }
  end
  local p = pct(u)
  local full, empty, hl = cells(p)
  return full, empty, { " " .. fmt(u.used) .. "/" .. fmt(u.limit) .. " · " .. p .. "%" .. (u.used > u.limit and " · over the limit" or ""), hl }
end

-- everything card reads of e, as a string: the cache key for its rows
local function card_sig(e, w, now, C, icons_sig, warns)
  local s, subs, u = e.stat, {}, e.usage
  for _, a in ipairs(e.subagents or {}) do subs[#subs + 1] = tostring(a.name) end
  if e.status == "planned" then
    for _, p in ipairs(e.plan or {}) do subs[#subs + 1] = tostring(p.model) .. "\2" .. tostring(p.title) end
  end
  return table.concat({ tostring(e.status), inbox.ago(e.time, now), tostring(e.title), w, tostring(e.attempts),
    tostring(e.check), tostring(e.checked), tostring(s and s.files), tostring(s and s.add), tostring(s and s.del),
    tostring(e.activity), table.concat(subs, "\1"), tostring(e.why), tostring(e.error), tostring(e.summary),
    tostring(not e.summary and e.task), #(e.assumptions or {}), tostring(e.model),
    tostring(u and u.used), tostring(u and u.limit), tostring(u and u.out), tostring(agent.kind(e)),
    tostring(e.agent and e.agent.cmd), tostring(require("sepal").icon(e.status, "?")),
    tostring(C.retries), tostring(C.sakura), tostring(e.vacuous), table.concat(warns, "\1"), icons_sig }, "\0")
end


-- chunks as one immutable row: byte columns for its marks, and a spinner slot blanked in text
local EMPTY_MARKS = {}
local EMPTY_ROW = { text = "", marks = EMPTY_MARKS }
local function same_row(a, b)
  if a == b then return true end
  if not a or not b or a.text ~= b.text or #a.marks ~= #b.marks then return false end
  if a.spin_col ~= b.spin_col or a.pulse_col ~= b.pulse_col or a.shimmer_col ~= b.shimmer_col or a.shimmer_text ~= b.shimmer_text then return false end
  for i = 1, #a.marks do
    local x, y = a.marks[i], b.marks[i]
    if x[1] ~= y[1] or x[2] ~= y[2] or x[3] ~= y[3] then return false end
  end
  return true
end
local function bake(chunks)
  if #chunks == 0 then return EMPTY_ROW end
  local parts, at, r = {}, 0, { marks = {} }
  for _, c in ipairs(chunks) do
    local text, hl = c[1], c[2]
    parts[#parts + 1] = text
    if hl and hl ~= "Normal" and #text > 0 then r.marks[#r.marks + 1] = { at, at + #text, hl } end
    if c.spin and not r.spin_col then r.spin_col = at end
    if c.pulse and not r.pulse_col then r.pulse_col = at end
    if c.shimmer and not r.shimmer_col then r.shimmer_col, r.shimmer_text = at, text end
    at = at + #text
  end
  local full = table.concat(parts)
  if r.spin_col then
    r.spin_prefix = full:sub(1, r.spin_col)
    r.spin_suffix = full:sub(r.spin_col + 4) -- every braille spinner is three bytes
    r.text = r.spin_prefix .. "\1" .. r.spin_suffix
  else
    r.text = full
  end
  if #r.marks == 0 then r.marks = EMPTY_MARKS end
  return r
end

-- a task as rows of { text, hl } chunks, behind a rail in its status's color (each row starts
-- with the " " margin chunk: rows are cached whole by card_sig)
local function card(e, w, now, C, icons_sig)
  local warns = inbox.warnings(e)
  local sig = card_sig(e, w, now, C, icons_sig, warns)
  local cached = card_c[sig]
  if cached then return cached end
  if memo_n > 4096 then memo_n, dw_c, wrap_c, card_c = 0, {}, {}, {} end
  local st = inbox.STATUS[e.status] or { "?", e.status, "Normal" }
  local live = inbox.LIVE[e.status]
  local icon = live and inbox.spin() or require("sepal").icon(e.status, st[1])
  local rail, age = { "▎ ", st[3], pulse = live or nil }, inbox.ago(e.time, now)
  local inner = w - 2
  local pad = { " ", "Normal" }
  local out = {
    { pad, rail, { icon .. " ", st[3], spin = live }, { inbox.fit(e.title or "", inner - dw(icon) - 2 - dw(age)), "SepalPanelTitle" },
      { " " .. age, "SepalDim" } },
  }
  local function row(...) out[#out + 1] = { pad, rail, ... } end
  -- who works on it, under its name: its model's provider logo, else its agent's logo row
  if e.model then
    local l, hl = logo(e.model)
    row({ l, hl }, { (inbox.fit(" " .. model(e.model), inner - dw(l)):gsub("%s+$", "")), "SepalDim" })
  else
    local kind = agent.kind(e)
    if kind == "devin" then row({ require("sepal").icon("devin", "❖"), "SepalDim" }, { " devin", "SepalDim" })
    elseif kind == "claude" then row({ require("sepal").icon("claude", "✻"), "SepalClaude" }, { " claude", "SepalDim" }) end
  end
  -- status · try · check
  local meta = { { st[2], st[3], shimmer = live } }
  if HINT[e.status] then meta[#meta + 1] = { "  " .. HINT[e.status], "SepalDim" } end
  local function add(t, hl) meta[#meta + 1] = { " · ", "SepalDim" }; meta[#meta + 1] = { t, hl or "SepalDim" } end
  if (e.attempts or 0) > 0 then add(("try %d/%d"):format(e.attempts + 1, (C.retries or 0) + 1)) end
  if e.check then
    add(e.check .. (e.checked == true and " ✔" or e.checked == false and " ✘" or ""),
      e.checked == true and "SepalOk" or e.checked == false and "SepalError" or "SepalDim")
  end
  row(unpack(meta))
  if e.usage then row(bar(e.usage, agent.kind(e))) end -- its context window, kept after the run
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
  if e.status == "planned" then -- what s starts: each task with its model
    for i, p in ipairs(e.plan or {}) do
      local m = "[" .. (p.model or "default") .. "] "
      row({ i .. ". ", "SepalDim" }, { m, "SepalAccent" }, { (inbox.fit(p.title, math.max(inner - dw(i .. ". " .. m), 1)):gsub("%s+$", "")), "Normal" })
    end
  end
  if e.why then para(e.why, "SepalWarn", "", 3) end
  for _, warn in ipairs(warns) do para(warn, "SepalWarn", "", 3) end
  if e.error then para(e.error, "SepalError", "", 3) end
  if e.summary then para(e.summary, "Normal", "", 3)
  elseif not inbox.LIVE[e.status] and e.status ~= "queued" then -- nothing said yet: what was asked
    para(vim.trim((e.task or ""):gsub("^%s*Goal:%s*", ""):gsub("\n.*", "")), "SepalDim", "", 2)
  end
  local n = #(e.assumptions or {})
  if n > 0 then row({ ("· %d decision%s to read"):format(n, n == 1 and "" or "s"), "SepalDim" }) end
  local baked = {}
  for i, r in ipairs(out) do baked[i] = bake(r) end
  card_c[sig], memo_n = baked, memo_n + 1
  return baked
end

-- the light on a working card: only highlights, redrawn every tick — never the text, so the rows stay put
local function animate(b)
  vim.api.nvim_buf_clear_namespace(b, ANIM, 0, -1)
  local t = inbox.tick()
  local aopts = { hl_group = "SepalShimmer", priority = 4200 }
  local lit = false
  for _, g in ipairs(glows) do -- a light two rows tall slides down the card's rail, then rests
    local h = t % (#g + 4) + 1
    local r = g[h - 1]
    if r then
      aopts.end_col = r[3]
      vim.api.nvim_buf_set_extmark(b, ANIM, r[1], r[2], aopts)
      lit = true
    end
    r = g[h]
    if r then
      aopts.end_col = r[3]
      vim.api.nvim_buf_set_extmark(b, ANIM, r[1], r[2], aopts)
      lit = true
    end
  end
  for _, s in ipairs(shines) do -- and a glint three chars wide sweeps its status label off both ends
    local h = t % (#s[3] + 6) - 1
    for k = math.max(0, h - 1), math.min(#s[3] - 1, h + 1) do
      aopts.end_col = s[2] + k + 1
      vim.api.nvim_buf_set_extmark(b, ANIM, s[1], s[2] + k, aopts)
      lit = true
    end
  end
  anim_lit = lit
end


-- returns whether a task it shows is running, for the inbox's spinner timer
function M.render()
  local w = win()
  if not w then drawn, prev = nil, nil; return false end -- stale once hidden: no tick may touch it
  local b = buf()
  local root = vim.b[b].sepal_panel
  local list = inbox.list(root)
  local width = vim.api.nvim_win_get_width(w) - 1
  local now, C = os.time(), require("sepal").config()
  local icons_sig = ""
  if next(C.icons or {}) then
    local names = {}
    for k in pairs(C.icons) do names[#names + 1] = k end
    table.sort(names)
    local parts = {}
    for _, k in ipairs(names) do parts[#parts + 1] = k .. "=" .. C.icons[k] end
    icons_sig = table.concat(parts, "\1")
  end
  local header = { { { " ", "Normal" }, { require("sepal").icon("landed", "◆") .. " sepal", "SepalTitle" },
    { "  " .. vim.fs.basename(root), "SepalDim" } } }
  local counts = { { " ", "Normal" } }
  local by = {}
  for _, e in ipairs(list) do by[e.status] = (by[e.status] or 0) + 1 end
  for _, c in ipairs(COUNTS) do
    local k = 0
    for st in pairs(c[2]) do k = k + (by[st] or 0) end
    if k > 0 then
      if #counts > 1 then counts[#counts + 1] = { " · ", "SepalDim" } end
      counts[#counts + 1] = { k .. " " .. c[1], c[3] }
    end
  end
  header[#header + 1] = counts
  local fullest, n = nil, 0 -- the fullest context window among the running tasks: it can't hide in a card
  for _, e in ipairs(list) do
    if e.status == "running" and e.usage and e.usage.limit then
      n = n + 1
      if not fullest or pct(e.usage) > pct(fullest.usage) then fullest = e end
    end
  end
  if fullest then
    local p = pct(fullest.usage)
    local full, empty, hl = cells(p)
    -- say which task and why that one: with several, it's the closest to its limit (short: 46 columns
    -- must leave room for the title)
    local text = " " .. p .. (n > 1 and "% · fullest of " .. n .. ": " or "% context · ")
    header[#header + 1] = { { " ", "Normal" }, full, empty,
      { (text .. inbox.fit(fullest.title or "", width - dw(" ") - 10 - dw(text))):gsub("%s+$", ""), hl } }
  end
  header[#header + 1] = { { " ", "Normal" }, { "o watch · q close", "SepalDim" } }
  header[#header + 1] = { { " " .. string.rep("─", width - 2), "SepalDim" } }
  local all_rows = {}
  for i, r in ipairs(header) do all_rows[i] = bake(r) end
  local new_rows = {}
  if #list == 0 then -- the empty state: centered under the divider, saying how to start
    all_rows[#all_rows + 1] = EMPTY_ROW
    for _, l in ipairs({ { "◇", "SepalDim" }, {}, { "no tasks yet", "SepalPanelTitle" }, { "start one with :Sepal task", "SepalDim" } }) do
      all_rows[#all_rows + 1] = l[1] and bake({ { string.rep(" ", math.max(0, math.floor((width - dw(l[1])) / 2))) .. l[1], l[2] } }) or EMPTY_ROW
    end
  end
  for _, e in ipairs(list) do
    all_rows[#all_rows + 1] = EMPTY_ROW
    for _, r in ipairs(card(e, width - 1, now, C, icons_sig)) do
      all_rows[#all_rows + 1] = r
      new_rows[#all_rows] = e.id
    end
  end
  rows = new_rows
  local cur_spin = inbox.spin()
  local lines, spins = {}, {}
  local glow, shine, last = {}, {}, nil -- this draw's rail groups and status labels
  local same = prev and prev.buf == b and prev.win == w and prev.root == root and prev.width == width
  local unchanged = same and #all_rows == #prev.rows
  for i, r in ipairs(all_rows) do
    if r.spin_col then
      lines[i] = r.spin_prefix .. cur_spin .. r.spin_suffix
      spins[#spins + 1] = { i - 1, r.spin_col }
    else
      lines[i] = r.text
    end
    if r.pulse_col then -- the "▎" of a live card's row; the pulse is per card, so group by task
      if last ~= rows[i] then glow[#glow + 1], last = {}, rows[i] end
      local g = glow[#glow]
      g[#g + 1] = { i - 1, r.pulse_col, r.pulse_col + #"▎" }
    end
    if r.shimmer_col then shine[#shine + 1] = { i - 1, r.shimmer_col, r.shimmer_text } end -- the status label
    if unchanged and (rows[i] ~= prev.task_rows[i] or not same_row(r, prev.rows[i])) then unchanged = false end
  end
  spun, glows, shines = spins, glow, shine
  if unchanged then M.spin(); return #spins > 0 end
  drawn = true
  local mopts = {}
  local function set_row_marks(i, r)
    for _, m in ipairs(r.marks) do
      mopts.end_col, mopts.hl_group = m[2], m[3]
      vim.api.nvim_buf_set_extmark(b, NS, i - 1, m[1], mopts)
    end
  end
  local function row_matches(i, j)
    return same_row(all_rows[i], prev.rows[j]) and (not all_rows[i].spin_col or cur_spin == prev.spin)
  end
  if same and #lines == #prev.lines then
    vim.bo[b].modifiable = true
    for i = 1, #lines do
      if not row_matches(i, i) then
        vim.api.nvim_buf_set_lines(b, i - 1, i, false, { lines[i] })
        vim.api.nvim_buf_clear_namespace(b, NS, i - 1, i)
        set_row_marks(i, all_rows[i])
      end
    end
    vim.bo[b].modifiable, vim.bo[b].modified = false, false
  elseif same then
    local lo, hi_new, hi_old = 1, #lines, #prev.lines
    local n = math.min(hi_new, hi_old)
    while lo <= n and row_matches(lo, lo) do lo = lo + 1 end
    while hi_new >= lo and hi_old >= lo and row_matches(hi_new, hi_old) do
      hi_new, hi_old = hi_new - 1, hi_old - 1
    end
    local repl = {}
    for i = lo, hi_new do repl[#repl + 1] = lines[i] end
    vim.bo[b].modifiable = true
    if hi_old >= lo then vim.api.nvim_buf_clear_namespace(b, NS, lo - 1, hi_old) end
    vim.api.nvim_buf_set_lines(b, lo - 1, hi_old, false, repl)
    vim.bo[b].modifiable, vim.bo[b].modified = false, false
    for i = lo, hi_new do set_row_marks(i, all_rows[i]) end
  else
    vim.bo[b].modifiable = true
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    vim.bo[b].modifiable, vim.bo[b].modified = false, false
    vim.api.nvim_buf_clear_namespace(b, NS, 0, -1)
    for i, r in ipairs(all_rows) do set_row_marks(i, r) end
  end
  prev = { buf = b, win = w, root = root, lines = lines, rows = all_rows, task_rows = rows, width = width, spin = cur_spin }
  if #glows > 0 or #shines > 0 or anim_lit then animate(b) end -- the lines changed, so its marks may have moved
  return #spins > 0
end

-- only the spinners moved (each frame is 3 bytes): rewrite just them, in what render drew last
function M.spin()
  local b = buf()
  if not (drawn and b) then return end
  local w = vim.fn.bufwinid(b)
  if w == -1 then return end
  local f = inbox.spin()
  if #spun > 0 then
    local fs = { f }
    vim.bo[b].modifiable = true
    for _, s in ipairs(spun) do vim.api.nvim_buf_set_text(b, s[1], s[2], s[1], s[2] + #f, fs) end
    if prev and prev.buf == b then prev.spin = f end
    vim.bo[b].modifiable, vim.bo[b].modified = false, false
  end
  if #glows > 0 or #shines > 0 or anim_lit then animate(b) end
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
    local g = vim.api.nvim_create_augroup("sepal.panel", {})
    vim.api.nvim_create_autocmd("WinResized", { group = g, callback = function()
      local pw = win()
      if pw and vim.api.nvim_win_get_width(pw) - 1 ~= (prev and prev.width) then M.render() end
    end })
    vim.api.nvim_create_autocmd("VimResized", { group = g, callback = function() -- "30%" follows the editor's width
      local pw = win()
      if pw then vim.api.nvim_win_set_width(pw, M.width()) end
    end })
  end
  vim.b[b].sepal_panel = root
  -- focus stays where you are: it's for looking at
  w = vim.api.nvim_open_win(b, false, { split = "right", win = -1, width = M.width() })
  vim.wo[w].wrap, vim.wo[w].cursorline, vim.wo[w].winfixwidth = false, false, true
  vim.wo[w].number, vim.wo[w].relativenumber, vim.wo[w].signcolumn, vim.wo[w].foldcolumn = false, false, "no", "0"
  vim.wo[w].list, vim.wo[w].spell, vim.wo[w].fillchars = false, false, "eob: "
  inbox.render() -- starts the spinner
  require("sepal").fidget()
end

return M
