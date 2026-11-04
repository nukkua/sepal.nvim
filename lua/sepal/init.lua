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

M._t = { state = function() return S end }

return M
