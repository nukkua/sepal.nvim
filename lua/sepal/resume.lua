-- :Sepal resume — find a Claude Code conversation of this directory by what you wrote in it
-- Claude Code keeps each one in <config>/projects/<cwd, non-alphanumerics as ->/<session id>.jsonl:
-- one JSON record per line; an "ai-title"/"custom-title" record names it, "user" records with string
-- content are what you typed. ponytail: that's Claude Code's internal format, not an API; if it
-- changes, rows lose their titles or messages, `claude -r <id>` still resumes

local M = {}

local function dir(cwd)
  local root = vim.env.CLAUDE_CONFIG_DIR or vim.fs.joinpath(vim.env.HOME or "", ".claude")
  return vim.fs.joinpath(root, "projects", (cwd:gsub("[^%w]", "-")))
end

-- "2026-11-04T19:36:08.595Z" -> seconds; UTC read as local on both sides, so differences are right
local function epoch(ts)
  local y, mo, d, h, mi, s = (ts or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  return y and os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s }) or 0
end

local function ago(secs)
  for _, u in ipairs({ { 86400, "d" }, { 3600, "h" }, { 60, "m" } }) do
    if secs >= u[1] then return math.floor(secs / u[1]) .. u[2] end
  end
  return "now"
end

-- injected context, not something you typed
local NOT_TYPED = { "^<system%-reminder>", "^<command%-", "^<local%-command", "^Caveat:" }

-- one row per message you typed, newest first: { id = session id, time, text = "2h  title │ message" }
function M.items(cwd)
  local rows, now = {}, os.time(os.date("!*t"))
  for name, kind in vim.fs.dir(dir(cwd)) do
    local id = kind == "file" and name:match("^(.+)%.jsonl$")
    local f = id and io.open(vim.fs.joinpath(dir(cwd), name))
    if f then
      local data = f:read("a")
      f:close()
      local title, msgs, printed = nil, {}, false
      for line in data:gmatch("[^\n]+") do
        -- decode only the few records we need: a session file is mostly tool output
        if line:find('"aiTitle"', 1, true) or line:find('"customTitle"', 1, true) then
          local ok, r = pcall(vim.json.decode, line)
          if ok then title = r.customTitle or r.aiTitle or title end
        elseif line:find('"role":"user"', 1, true) then
          local ok, r = pcall(vim.json.decode, line)
          if ok and r.type == "user" and not r.isMeta and type(r.message.content) == "string" then
            printed = printed or r.entrypoint == "sdk-cli" -- claude -p: a one-off run, not a chat
            local text = vim.trim((r.message.content:gsub("</?pasted_content[^>]*>", ""))) -- a paste's wrapper
            local typed = text ~= ""
            for _, p in ipairs(NOT_TYPED) do typed = typed and not text:match(p) end
            if typed then msgs[#msgs + 1] = { text = text, time = epoch(r.timestamp) } end
          end
        end
      end
      if not printed then
        title = title or (msgs[1] and msgs[1].text:match("[^\n]*") or id)
        for _, m in ipairs(msgs) do
          local text = m.text:gsub("%s+", " ")
          if #text > 300 then text = text:sub(1, 300) end
          rows[#rows + 1] = { id = id, time = m.time, text = ago(now - m.time) .. "  " .. title .. " │ " .. text }
        end
      end
    end
  end
  table.sort(rows, function(a, b) return a.time > b.time end)
  return rows
end

vim.api.nvim_set_hl(0, "SepalPickMatch", { link = "Special", default = true })
vim.api.nvim_set_hl(0, "SepalPickSelected", { link = "PmenuSel", default = true })
local NS = vim.api.nvim_create_namespace("sepal.pick")

-- fuzzy picker in a float: you type on the first line, rows below narrow with matchfuzzypos().
-- <CR> picks, <C-n>/<C-p> (<Down>/<Up>) move, <Esc>/<C-c> closes. on_choice(row) only when one is picked.
-- ponytail: shows the best `height` rows, no scrolling past them; type more to narrow instead
function M.pick(rows, prompt, on_choice)
  local width = math.min(vim.o.columns - 4, 120)
  local height = math.max(1, math.min(#rows, math.floor(vim.o.lines * 0.5)))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.b[buf].completion = false -- blink.cmp/nvim-cmp: no popup over the query
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = math.floor((vim.o.lines - height - 3) / 2), col = math.floor((vim.o.columns - width) / 2),
    width = width, height = height + 1, border = "rounded", title = " " .. prompt .. " ", style = "minimal",
  })
  local shown, sel = rows, 1
  local function render()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local query = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
    local pos = {}
    if query == "" then shown = rows else
      local m = vim.fn.matchfuzzypos(rows, query, { key = "text" })
      shown, pos = m[1], m[2]
    end
    sel = math.max(1, math.min(sel, math.min(#shown, height)))
    local lines = {}
    for i = 1, math.min(#shown, height) do lines[i] = shown[i].text end
    vim.api.nvim_buf_set_lines(buf, 1, -1, false, #lines > 0 and lines or { "  no match" })
    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    for i = 1, #lines do
      for _, c in ipairs(pos[i] or {}) do -- character index -> byte column
        local col = vim.str_byteindex(lines[i], "utf-32", c)
        vim.api.nvim_buf_set_extmark(buf, NS, i, col, { end_col = vim.str_byteindex(lines[i], "utf-32", c + 1), hl_group = "SepalPickMatch" })
      end
    end
    if #lines > 0 then vim.api.nvim_buf_set_extmark(buf, NS, sel, 0, { line_hl_group = "SepalPickSelected" }) end
  end
  local function close()
    vim.cmd.stopinsert()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  local function move(d) return function() sel = sel + d; render() end end
  local o = { buffer = buf }
  for _, k in ipairs({ "<C-n>", "<Down>" }) do vim.keymap.set("i", k, move(1), o) end
  for _, k in ipairs({ "<C-p>", "<Up>" }) do vim.keymap.set("i", k, move(-1), o) end
  vim.keymap.set("i", "<CR>", function()
    local row = shown[sel]
    close()
    if row then vim.schedule(function() on_choice(row) end) end
  end, o)
  for _, k in ipairs({ "<Esc>", "<C-c>" }) do vim.keymap.set("i", k, close, o) end
  local last = ""
  -- redrawing the rows changes the buffer too: only a new query starts over at the first row
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, { buffer = buf, callback = function()
    local q = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
    if q ~= last then last, sel = q, 1; render() end
  end })
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close })
  render()
  vim.cmd.startinsert()
end

return M
