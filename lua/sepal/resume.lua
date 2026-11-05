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
-- (<system-reminder>, <task-notification>, <command-name>…: any message that opens with a tag; a paste's
-- <pasted_content> wrapper is stripped before this)
local NOT_TYPED = { "^<[%w_-]+[ >]", "^Caveat:" }

-- one row per message you typed, newest first: { id = session id, time, age = "2h", title, msg,
-- text = "title │ message" (what a search matches) }
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
          rows[#rows + 1] = { id = id, time = m.time, age = ago(now - m.time), title = title, msg = text, text = title .. " │ " .. text }
        end
      end
    end
  end
  table.sort(rows, function(a, b) return a.time > b.time end)
  return rows
end

for k, v in pairs({ SepalPickMatch = "Special", SepalPickSelected = "PmenuSel", SepalPickDim = "Comment", SepalPickPrompt = "Question" }) do
  vim.api.nvim_set_hl(0, k, { link = v, default = true })
end
local NS = vim.api.nvim_create_namespace("sepal.pick")
local AGE_W, TITLE_W = 4, 26 -- columns: "▸ " age  title  message

-- s cut to w cells (… when cut) and padded to w
local function fit(s, w)
  if vim.fn.strdisplaywidth(s) > w then s = vim.fn.strcharpart(s, 0, w - 1) .. "…" end
  return s .. string.rep(" ", w - vim.fn.strdisplaywidth(s))
end

-- sepal's fuzzy picker in a float: you type after › on the first line, rows below narrow with
-- matchfuzzypos() on "title │ message". <CR> picks, <C-n>/<C-p> (<Down>/<Up>) move and scroll,
-- <Esc>/<C-c> closes. on_choice(row) only when one is picked.
function M.pick(rows, prompt, on_choice)
  local width = math.min(vim.o.columns - 4, 140)
  local height = math.max(1, math.min(#rows, math.floor(vim.o.lines * 0.6)))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.b[buf].completion = false -- blink.cmp/nvim-cmp: no popup over the query
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = math.floor((vim.o.lines - height - 4) / 2), col = math.floor((vim.o.columns - width) / 2),
    width = width, height = height + 2, border = "rounded", title = " " .. prompt .. " ", style = "minimal",
  })
  vim.wo[win].wrap = false
  local shown, pos, sel, top = rows, {}, 1, 1
  local function render()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    sel = math.max(1, math.min(sel, #shown))
    if sel < top then top = sel elseif sel >= top + height then top = sel - height + 1 end
    local lines, marks = {}, {}
    for i = top, math.min(#shown, top + height - 1) do
      local row = shown[i]
      local age, title = fit(row.age, AGE_W), fit(row.title, TITLE_W)
      lines[#lines + 1] = "  " .. age .. "  " .. title .. "  " .. row.msg
      marks[#lines] = { i, #age, #title }
    end
    vim.api.nvim_buf_set_lines(buf, 1, -1, false, #lines > 0 and lines or { "  no match" })
    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    vim.api.nvim_buf_set_extmark(buf, NS, 0, 0, { virt_text = { { "› ", "SepalPickPrompt" } }, virt_text_pos = "inline", right_gravity = false,
      virt_lines = { { { string.rep("─", width), "FloatBorder" } } } })
    for l, m in ipairs(marks) do
      local line, i, agelen, titlelen = lines[l], m[1], m[2], m[3]
      vim.api.nvim_buf_set_extmark(buf, NS, l, 2, { end_col = 2 + agelen + 2 + titlelen, hl_group = "SepalPickDim" })
      -- a match in "title │ message" (character positions) -> the title or message column on screen
      local tlen = vim.fn.strchars(shown[i].title)
      for _, p in ipairs(pos[i] or {}) do
        local c = p < tlen and (p < TITLE_W - 1 and 2 + AGE_W + 2 + p) or p >= tlen + 3 and 2 + AGE_W + 2 + TITLE_W + 2 + (p - tlen - 3)
        local ok, s0 = pcall(vim.str_byteindex, line, "utf-32", c or -1)
        local ok2, s1 = pcall(vim.str_byteindex, line, "utf-32", (c or -1) + 1)
        if c and ok and ok2 then vim.api.nvim_buf_set_extmark(buf, NS, l, s0, { end_col = s1, hl_group = "SepalPickMatch" }) end
      end
      if i == sel then
        vim.api.nvim_buf_set_extmark(buf, NS, l, 0, { line_hl_group = "SepalPickSelected", virt_text = { { "▸", "SepalPickPrompt" } }, virt_text_pos = "overlay" })
      end
    end
    vim.api.nvim_win_set_config(win, { footer = (" %d/%d "):format(#shown, #rows), footer_pos = "right" })
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
    if q == last then return end
    last, sel, top = q, 1, 1
    if q == "" then shown, pos = rows, {} else
      local m = vim.fn.matchfuzzypos(rows, q, { key = "text" })
      shown, pos = m[1], m[2]
    end
    render()
  end })
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close })
  render()
  -- after keys already typed: a mapping like `cnoremap <CR> <CR>zz` would type its zz into the query
  vim.schedule(function() if vim.api.nvim_get_current_win() == win then vim.cmd.startinsert() end end)
end

-- a picker plugin's vim.ui.select (snacks, fzf-lua, telescope…) when there is one, else sepal's
function M.choose(rows, prompt, on_choice)
  local src = debug.getinfo(vim.ui.select, "S").source or "" -- the builtin is runtime/lua/vim/ui.lua
  if src:match("^@?vim/") or src:match("/lua/vim/ui%.lua$") then return M.pick(rows, prompt, on_choice) end
  vim.ui.select(rows, { prompt = prompt, format_item = function(r) return r.age .. "  " .. r.title .. " │ " .. r.msg end },
    function(r) if r then on_choice(r) end end)
end

return M
