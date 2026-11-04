-- sepal — a CLI agent in a terminal split next to your code
-- :Sepal toggles it, :Sepal new starts a fresh chat. The first toggle continues the last chat in
-- this directory (cmd + resume, e.g. `claude -c`); the agent keeps its chat on disk, so it comes
-- back after nvim or tmux goes away. Hiding the split keeps the agent running.
-- ponytail: "nothing to continue" is detected as a resume that fails within 3s; an agent that
-- shows an error and waits instead stays on screen, use :Sepal new there

local M = {}

local C = {
  -- agent argv; tui=default keeps Claude Code off the alt screen, so its output stays in the buffer's scrollback
  cmd = { "claude", "--settings", '{"tui":"default"}' },
  resume = { "-c" },  -- appended to cmd to continue this directory's last chat; {} to always start fresh
  side = "right",     -- "right" | "left"
  width = 40,         -- split width, percent of the editor (1-99)
  focus = true,       -- move to the agent when it opens
}
function M.setup(opts) C = vim.tbl_extend("force", C, opts or {}) end
function M.config() return C end

local S = { buf = nil } -- the agent's terminal buffer

local function alive() return S.buf ~= nil and vim.api.nvim_buf_is_valid(S.buf) end

local function enter(win)
  if C.focus then vim.api.nvim_set_current_win(win); vim.cmd.startinsert() end
end

local function split(buf)
  return vim.api.nvim_open_win(buf, false, { split = C.side, win = -1, width = math.floor(vim.o.columns * C.width / 100) })
end

-- start the agent in a new terminal buffer, in place of the old one (which is killed)
local function start(resume)
  local old, buf = S.buf, vim.api.nvim_create_buf(false, true)
  S.buf = buf
  local win = old and vim.api.nvim_buf_is_valid(old) and vim.fn.bufwinid(old) or -1
  if win ~= -1 then vim.api.nvim_win_set_buf(win, buf) else win = split(buf) end
  if old and vim.api.nvim_buf_is_valid(old) then vim.api.nvim_buf_delete(old, { force = true }) end

  local argv = vim.list_extend(vim.list_extend({}, C.cmd), resume and C.resume or {})
  local t = vim.uv.now()
  local ok, job = pcall(vim.api.nvim_win_call, win, function()
    return vim.fn.jobstart(argv, { term = true, on_exit = vim.schedule_wrap(function(_, code)
      if S.buf ~= buf then return end -- replaced by :Sepal new
      -- nothing to continue in this directory: start a fresh chat instead
      if resume and #C.resume > 0 and code ~= 0 and vim.uv.now() - t < 3000 then return start(false) end
      S.buf = nil
      if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    end) })
  end)
  if not ok or job <= 0 then
    S.buf = nil
    vim.api.nvim_buf_delete(buf, { force = true })
    return vim.notify("sepal: could not start " .. argv[1] .. (ok and "" or "\n" .. tostring(job)), vim.log.levels.ERROR)
  end
  enter(win)
end

function M.toggle()
  local win = alive() and vim.fn.bufwinid(S.buf) or -1
  if win ~= -1 then
    -- floats don't count: hiding the last normal window fails with E444 even if a float is open
    local normal = vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative == "" end, vim.api.nvim_tabpage_list_wins(0))
    if #normal == 1 then return vim.notify("sepal: the agent is the only window", vim.log.levels.WARN) end
    return vim.api.nvim_win_hide(win)
  end
  if alive() then return enter(split(S.buf)) end
  start(true)
end

function M.new() start(false) end

-- paste text into the agent and press Enter, starting it first if it isn't running
local function send(text)
  local function go()
    local ch = vim.bo[S.buf].channel
    vim.fn.chansend(ch, "\27[200~" .. text .. "\27[201~") -- bracketed paste: newlines stay in the prompt
    vim.defer_fn(function() pcall(vim.fn.chansend, ch, "\r") end, 100) -- Enter in the same write lands inside the paste; pcall: the agent may have exited
    if vim.fn.bufwinid(S.buf) == -1 then enter(split(S.buf)) end
  end
  if alive() then return go() end
  start(true)
  -- ponytail: a fresh agent is "ready" once its buffer has stayed the same for 3s (past the resume
  -- fallback) and shows output; an agent that boots slower than 15s gets the text before its prompt
  local buf, since, tries = S.buf, vim.uv.now(), 0
  local function poll()
    if not alive() then return vim.notify("sepal: the agent exited, the spec was not sent", vim.log.levels.WARN) end
    if S.buf ~= buf then buf, since = S.buf, vim.uv.now() end
    tries = tries + 1
    local shown = vim.iter(vim.api.nvim_buf_get_lines(buf, 0, -1, false)):any(function(l) return l ~= "" end)
    if (vim.uv.now() - since >= 3000 and shown) or tries >= 75 then return go() end
    vim.defer_fn(poll, 200)
  end
  vim.defer_fn(poll, 200)
end

local TEMPLATE = { "Scope: ", "Goal: ", "", "Constraints:", "- ", "", "Files:" }

-- add "- @path" at the end of the Files: list
local function add_file(buf, path)
  if not path or path == "" or not vim.api.nvim_buf_is_valid(buf) then return end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, l in ipairs(lines) do
    if l:match("^Files:") then
      while lines[i + 1] and lines[i + 1]:match("^%- ") do i = i + 1 end
      return vim.api.nvim_buf_set_lines(buf, i, i, false, { "- @" .. path })
    end
  end
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "Files:", "- @" .. path })
end

-- :Sepal spec: write a spec in a buffer above the code, then send it to the agent.
-- <c-c><c-c> sends, <c-c><c-k> discards, <c-c><c-f> adds a file (fff.nvim if installed)
function M.spec()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[b].sepal_spec then
      local w = vim.fn.bufwinid(b)
      if w == -1 then w = vim.api.nvim_open_win(b, true, { split = "above", win = 0, height = 12 }) end
      return vim.api.nvim_set_current_win(w)
    end
  end
  if alive() and vim.api.nvim_get_current_buf() == S.buf then vim.cmd.wincmd("p") end -- not over the agent
  local buf = vim.api.nvim_create_buf(false, true)
  vim.b[buf].sepal_spec = true
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "hide" -- closing the window keeps the draft; :Sepal spec brings it back
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, TEMPLATE)
  vim.api.nvim_open_win(buf, true, { split = "above", win = 0, height = 12 })
  vim.api.nvim_win_set_cursor(0, { 1, #TEMPLATE[1] })
  vim.cmd.startinsert({ bang = true })

  local o = { buffer = buf }
  vim.keymap.set({ "n", "i" }, "<c-c><c-c>", function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    while #lines > 0 and vim.trim(lines[#lines]) == "" do lines[#lines] = nil end
    if #lines == 0 then return vim.notify("sepal: the spec is empty", vim.log.levels.WARN) end
    vim.cmd.stopinsert()
    vim.api.nvim_buf_delete(buf, { force = true })
    send(table.concat(lines, "\n"))
  end, vim.tbl_extend("force", o, { desc = "Send the spec to the agent" }))
  vim.keymap.set({ "n", "i" }, "<c-c><c-k>", function()
    vim.cmd.stopinsert()
    vim.api.nvim_buf_delete(buf, { force = true })
  end, vim.tbl_extend("force", o, { desc = "Discard the spec" }))
  vim.keymap.set({ "n", "i" }, "<c-c><c-f>", function()
    vim.cmd.stopinsert()
    local ok, fff = pcall(require, "fff")
    if ok then return fff.find_files({ on_submit = function(_, ctx) add_file(buf, ctx.relative_path) end }) end
    vim.ui.input({ prompt = "File: ", completion = "file" }, function(p) add_file(buf, p) end)
  end, vim.tbl_extend("force", o, { desc = "Add a file to the spec" }))
end

M._t = { state = function() return S end }

return M
