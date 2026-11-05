-- sepal — a CLI agent in a terminal split next to your code
-- :Sepal toggles it, :Sepal new starts a fresh chat. The first toggle continues the last chat in
-- this directory (cmd + resume, e.g. `claude -c`); the agent keeps its chat on disk, so it comes
-- back after nvim or tmux goes away. Hiding the split keeps the agent running.
-- ponytail: "nothing to continue" is detected as a resume that fails within 3s; an agent that
-- shows an error and waits instead stays on screen, use :Sepal new there

local M = {}

-- Claude Code runs this after every reply: it saves the hook's JSON (which has the reply) to a temp
-- file and calls back into this nvim with it ($NVIM, set for terminal jobs)
local STOP_HOOK = [[f=$(mktemp) && cat >"$f" && ]] .. vim.fn.shellescape(vim.v.progpath)
  .. [[ --server "$NVIM" --remote-expr "v:lua.require'sepal'.stopped('$f')" >/dev/null 2>&1]]

local C = {
  -- agent argv. tui=default keeps Claude Code off the alt screen, so its output stays in the buffer's
  -- scrollback; the Stop hook is what notifies "the agent is done"
  cmd = { "claude", "--settings", vim.json.encode({ tui = "default", hooks = { Stop = { { hooks = { { type = "command", command = STOP_HOOK } } } } } }) },
  resume = { "-c" },  -- appended to cmd to continue this directory's last chat; {} to always start fresh
  side = "right",     -- "right" | "left"
  width = 40,         -- split width, percent of the editor (1-99)
  focus = true,       -- move to the agent when it opens
  spec_suggest = nil, -- argv: rough spec on stdin -> finished spec on stdout; <c-c><c-s> in a spec runs it
  resume_pick = nil,  -- args for the agent's own conversation picker (codex: { "resume" }); :Sepal resume
                      -- uses them for agents other than Claude Code, whose conversations sepal searches itself
}
function M.setup(opts) C = vim.tbl_extend("force", C, opts or {}) end
function M.config() return C end

local S = { buf = nil } -- the agent's terminal buffer

-- every message is "what happened", shown under "sepal".
-- info goes to fidget if installed (corner, fades out); warnings/errors stay in vim.notify so they're not missed.
-- with the builtin vim.notify they're echoed with a colored icon; a notifier plugin gets plain text
-- o.icon: { text, hl } instead of the level's; o.key, o.ttl: fidget's (same key replaces, ttl in seconds)
local ICON = { [vim.log.levels.ERROR] = { "✗", "DiagnosticError" }, [vim.log.levels.WARN] = { "▲", "DiagnosticWarn" } }
function M.notify(msg, lvl, o)
  lvl, o = lvl or vim.log.levels.INFO, o or {}
  local ok, fidget = pcall(require, "fidget")
  if ok and lvl <= vim.log.levels.INFO then
    return fidget.notify((o.icon and o.icon[1] .. " " or "") .. msg, lvl, { annote = "sepal", key = o.key, ttl = o.ttl })
  end
  if not (debug.getinfo(vim.notify, "S").source or ""):match("^@?vim/") then return vim.notify(msg, lvl, { title = "sepal" }) end
  local icon = o.icon or ICON[lvl] or { "●", "DiagnosticInfo" }
  vim.api.nvim_echo({ { icon[1] .. " ", icon[2] }, { "sepal ", "Title" }, { msg } }, true, { err = lvl >= vim.log.levels.ERROR })
end

-- fidget spinner while waiting; returns done(msg), which ends it showing msg, or cancels it without
-- msg (a failure, which gets its own warning). Without fidget: no spinner, done(msg) is a plain notification
local function progress(msg)
  local ok, fp = pcall(require, "fidget.progress")
  if not ok then return function(final) if final then M.notify(final) end end end
  local h = fp.handle.create({ title = "sepal", message = msg, lsp_client = { name = "sepal" } })
  return function(final)
    if not final then return h:cancel() end
    h.message = final; h:finish()
  end
end

local function alive() return S.buf ~= nil and vim.api.nvim_buf_is_valid(S.buf) end

local function enter(win)
  if C.focus then vim.api.nvim_set_current_win(win); vim.cmd.startinsert() end
end

local function split(buf)
  return vim.api.nvim_open_win(buf, false, { split = C.side, win = -1, width = math.floor(vim.o.columns * C.width / 100) })
end

-- start the agent in a new terminal buffer, in place of the old one (which is killed).
-- hidden: start it in a split sized like the agent's and hide it, so the pty gets the right width.
-- args: appended to cmd instead of resume (e.g. { "-r", id })
local function start(resume, hidden, args)
  local old, buf = S.buf, vim.api.nvim_create_buf(false, true)
  S.buf = buf
  local win = old and vim.api.nvim_buf_is_valid(old) and vim.fn.bufwinid(old) or -1
  if win ~= -1 then vim.api.nvim_win_set_buf(win, buf) else win = split(buf) end
  if old and vim.api.nvim_buf_is_valid(old) then vim.api.nvim_buf_delete(old, { force = true }) end

  local argv = vim.list_extend(vim.list_extend({}, C.cmd), resume and C.resume or args or {})
  local t = vim.uv.now()
  local ok, job = pcall(vim.api.nvim_win_call, win, function()
    return vim.fn.jobstart(argv, { term = true, on_exit = vim.schedule_wrap(function(_, code)
      if S.buf ~= buf then return end -- replaced by :Sepal new
      -- nothing to continue in this directory: start a fresh chat instead
      if resume and #C.resume > 0 and code ~= 0 and vim.uv.now() - t < 3000 then
        return start(false, vim.fn.bufwinid(buf) == -1) -- stays hidden if it was
      end
      S.buf = nil
      if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    end) })
  end)
  if not ok or job <= 0 then
    S.buf = nil
    vim.api.nvim_buf_delete(buf, { force = true })
    return M.notify("could not start " .. argv[1] .. (ok and "" or "\n" .. (tostring(job):match("E%d+:[^\n]*") or tostring(job):match("[^\n]*"))), vim.log.levels.ERROR)
  end
  -- you've seen it: the "done" notification can go
  vim.api.nvim_create_autocmd("BufEnter", { buffer = buf, callback = function()
    local fok, fidget = pcall(require, "fidget")
    if fok then pcall(fidget.notification.remove, "default", "sepal-done") end
  end })
  if hidden then vim.api.nvim_win_hide(win) else enter(win) end
end

-- the agent finished a reply (Claude Code's Stop hook, path: its JSON); not shown while you're in the agent.
-- "✓ the agent is done: <first line of the reply>", kept in fidget until you enter the agent
function M.stopped(path)
  local reply
  if path and path ~= "" then
    local f = io.open(path)
    if f then
      local ok, hook = pcall(vim.json.decode, f:read("a"))
      f:close()
      reply = ok and type(hook) == "table" and hook.last_assistant_message or nil
    end
    os.remove(path)
  end
  vim.schedule(function()
    if alive() and vim.api.nvim_get_current_buf() == S.buf then return end
    local first = type(reply) == "string" and vim.iter(vim.split(reply, "\n")):map(vim.trim):find(function(l) return l ~= "" end)
    if first and vim.fn.strchars(first) > 80 then first = vim.fn.strcharpart(first, 0, 79) .. "…" end
    M.notify("the agent is done" .. (first and ": " .. first or ""), vim.log.levels.INFO,
      { icon = { "✓", "DiagnosticOk" }, key = "sepal-done", ttl = math.huge })
  end)
  return ""
end

function M.toggle()
  local win = alive() and vim.fn.bufwinid(S.buf) or -1
  if win ~= -1 then
    -- floats don't count: hiding the last normal window fails with E444 even if a float is open
    local normal = vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative == "" end, vim.api.nvim_tabpage_list_wins(0))
    if #normal == 1 then return M.notify("the agent is the only window", vim.log.levels.WARN) end
    return vim.api.nvim_win_hide(win)
  end
  if alive() then return enter(split(S.buf)) end
  start(true)
end

function M.new() start(false) end

-- :Sepal resume: pick a conversation of this directory by what you wrote in it and continue it.
-- Claude Code: sepal's fuzzy picker over its saved chats; other agents: their own picker (resume_pick)
function M.resume()
  if vim.fs.basename(C.cmd[1]) ~= "claude" then
    if not C.resume_pick then return M.notify("set resume_pick to the agent's resume arguments, e.g. { \"resume\" } for codex", vim.log.levels.WARN) end
    return start(false, false, C.resume_pick)
  end
  local r = require("sepal.resume")
  local rows = r.items(vim.fn.getcwd())
  if #rows == 0 then return M.notify("no conversations in this directory yet") end
  r.choose(rows, "resume a conversation", function(row) start(false, false, { "-r", row.id }) end)
end

-- paste text into the agent and press Enter, without opening its split; starts it (hidden) if it isn't running.
-- failed(): the text never reached the agent
local function send(text, failed)
  local function go()
    local ch = vim.bo[S.buf].channel
    vim.fn.chansend(ch, "\27[200~" .. text .. "\27[201~") -- bracketed paste: newlines stay in the prompt
    vim.defer_fn(function() pcall(vim.fn.chansend, ch, "\r") end, 100) -- Enter in the same write lands inside the paste; pcall: the agent may have exited
  end
  if alive() then go(); return M.notify("spec sent") end
  start(true, true)
  if not alive() then return failed() end -- start already said why
  local done = progress("starting the agent")
  -- ponytail: a fresh agent is "ready" once its buffer has stayed the same for 3s (past the resume
  -- fallback) and shows output; an agent that boots slower than 15s gets the text before its prompt
  local buf, since, tries = S.buf, vim.uv.now(), 0
  local function poll()
    if not alive() then done(); return failed() end
    if S.buf ~= buf then buf, since = S.buf, vim.uv.now() end
    tries = tries + 1
    local shown = vim.iter(vim.api.nvim_buf_get_lines(buf, 0, -1, false)):any(function(l) return l ~= "" end)
    if (vim.uv.now() - since >= 3000 and shown) or tries >= 75 then go(); return done("spec sent") end
    vim.defer_fn(poll, 200)
  end
  vim.defer_fn(poll, 200)
end

local TEMPLATE = { "Scope: ", "Goal: ", "", "Constraints:", "- ", "", "Files:" }
local IDEA = { "", "", "Files:" } -- with spec_suggest: the idea goes on top, <c-c><c-s> writes the spec
local HINT = "what to change, where and why; <c-c><c-s> writes the spec"
local HINT_NS = vim.api.nvim_create_namespace("sepal.hint")

-- add "- @path" at the end of the Files: list (once)
local function add_file(buf, path)
  if not path or path == "" or not vim.api.nvim_buf_is_valid(buf) then return end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if vim.tbl_contains(lines, "- @" .. path) then return end
  for i, l in ipairs(lines) do
    if l:match("^Files:") then
      while lines[i + 1] and lines[i + 1]:match("^%- ") do i = i + 1 end
      return vim.api.nvim_buf_set_lines(buf, i, i, false, { "- @" .. path })
    end
  end
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "Files:", "- @" .. path })
end

-- lines first..last of the current buffer as a "Selection:" block, and the file to list (nil if unnamed)
local function selection(first, last)
  local name = vim.api.nvim_buf_get_name(0)
  local path = name ~= "" and vim.fn.fnamemodify(name, ":.") or nil
  local block = { "Selection: " .. (path and path .. ":" or "lines ") .. first .. (last > first and "-" .. last or ""),
    "```" .. vim.bo.filetype }
  vim.list_extend(block, vim.api.nvim_buf_get_lines(0, first - 1, last, false))
  vim.list_extend(block, { "```", "" })
  return block, path
end

-- put a selection block above Files: (at the end if there's none) and list its file
local function add_selection(buf, block, path)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local at = #lines
  for i, l in ipairs(lines) do if l:match("^Files:") then at = i - 1 break end end
  vim.api.nvim_buf_set_lines(buf, at, at, false, block)
  add_file(buf, path)
end

-- :Sepal spec: write a spec in a buffer above the code, then send it to the agent.
-- <c-c><c-c> sends, <c-c><c-k> discards, <c-c><c-f> adds a file (fff.nvim if installed),
-- <c-c><c-s> has spec_suggest turn what's there (an idea + files) into the spec.
-- range: { first, last } lines of the current buffer to put in the spec (:'<,'>Sepal spec)
-- lines: the text to start from (a spec that could not be sent comes back with it)
-- ponytail: a range is whole lines; a charwise selection brings its full lines
function M.spec(range, lines)
  local block, path
  if range then block, path = selection(range[1], range[2]) end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[b].sepal_spec then
      local w = vim.fn.bufwinid(b)
      if w == -1 then w = vim.api.nvim_open_win(b, true, { split = "above", win = 0, height = 12 }) end
      if block then add_selection(b, block, path) end -- a draft is open: the selection joins it
      return vim.api.nvim_set_current_win(w)
    end
  end
  if alive() and vim.api.nvim_get_current_buf() == S.buf then vim.cmd.wincmd("p") end -- not over the agent
  local buf = vim.api.nvim_create_buf(false, true)
  vim.b[buf].sepal_spec = true
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "hide" -- closing the window keeps the draft; :Sepal spec brings it back
  local template = C.spec_suggest and IDEA or TEMPLATE
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or template)
  if block then add_selection(buf, block, path) end
  vim.api.nvim_open_win(buf, true, { split = "above", win = 0, height = 12 })
  if not lines then
    vim.api.nvim_win_set_cursor(0, { 1, #template[1] })
    vim.schedule(function() vim.cmd.startinsert({ bang = true }) end) -- after keys already typed (see sepal.resume)
  end
  if C.spec_suggest then
    -- placeholder on an empty idea line: an extmark, so it's never sent or piped (and changedtick stays)
    local function hint()
      if not vim.api.nvim_buf_is_valid(buf) then return end
      vim.api.nvim_buf_clear_namespace(buf, HINT_NS, 0, -1) -- all of it: replacing line 1 pushes the mark down
      if (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "") ~= "" then return end
      vim.api.nvim_buf_set_extmark(buf, HINT_NS, 0, 0, { virt_text = { { HINT, "Comment" } }, virt_text_pos = "overlay" })
    end
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = buf, callback = hint })
    hint()
  end

  local o = { buffer = buf }
  vim.keymap.set({ "n", "i" }, "<c-c><c-c>", function()
    local fenced = false -- no empty bullets, but code in a ``` block is sent as it is
    local lines = vim.tbl_filter(function(l)
      if l:match("^%s*```") then fenced = not fenced end
      return fenced or not l:match("^%s*%-%s*$")
    end, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    while #lines > 0 and vim.trim(lines[#lines]) == "" do lines[#lines] = nil end
    if #lines == 0 then return M.notify("the spec is empty", vim.log.levels.WARN) end
    vim.cmd.stopinsert()
    vim.api.nvim_buf_delete(buf, { force = true })
    send(table.concat(lines, "\n"), function()
      M.notify("the spec was not sent, it is back in its buffer", vim.log.levels.WARN)
      M.spec(nil, lines)
    end)
  end, vim.tbl_extend("force", o, { desc = "Send the spec to the agent" }))
  vim.keymap.set({ "n", "i" }, "<c-c><c-k>", function()
    vim.cmd.stopinsert()
    vim.api.nvim_buf_delete(buf, { force = true })
  end, vim.tbl_extend("force", o, { desc = "Discard the spec" }))
  local job -- the running spec_suggest
  vim.api.nvim_create_autocmd("BufUnload", { buffer = buf, once = true, callback = function()
    if job then pcall(job.kill, job, 15) end -- sent or discarded before it answered: don't leave it running
  end })
  vim.keymap.set({ "n", "i" }, "<c-c><c-s>", function()
    if not C.spec_suggest then return M.notify("set spec_suggest to have <c-c><c-s> write the spec, see :h sepal-spec_suggest", vim.log.levels.WARN) end
    if job then return M.notify("still writing the spec") end
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    if vim.trim((text:gsub("Files:", ""))) == "" then return M.notify("write the idea first", vim.log.levels.WARN) end
    vim.cmd.stopinsert()
    local tick, done = vim.b[buf].changedtick, progress("writing the spec")
    local ok, j = pcall(vim.system, C.spec_suggest, { stdin = text, text = true }, vim.schedule_wrap(function(r)
      job = nil
      if not vim.api.nvim_buf_is_valid(buf) then return done() end
      local out = vim.trim(((r.stdout or ""):gsub("^%s*```%w*\n", "")):gsub("\n?```%s*$", ""))
      if r.code ~= 0 or out == "" then
        done()
        return M.notify("spec_suggest failed" .. (r.code ~= 0 and " (exit " .. r.code .. ")" or ": empty answer")
          .. ((r.stderr or "") ~= "" and "\n" .. vim.trim(r.stderr):match("[^\n]*") or ""), vim.log.levels.ERROR)
      end
      if vim.b[buf].changedtick ~= tick then -- never overwrite what you typed meanwhile
        done()
        return M.notify("the spec changed while it was being written, <c-c><c-s> again", vim.log.levels.WARN)
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(out, "\n"))
      done("spec ready: <c-c><c-c> sends it, u undoes")
    end))
    if not ok then
      done()
      return M.notify("could not run " .. tostring(C.spec_suggest[1]) .. "\n" .. tostring(j):match("[^\n]*"), vim.log.levels.ERROR)
    end
    job = j
  end, vim.tbl_extend("force", o, { desc = "Write the spec with spec_suggest" }))
  vim.keymap.set({ "n", "i" }, "<c-c><c-f>", function()
    vim.cmd.stopinsert()
    local ok, fff = pcall(require, "fff")
    if ok then return fff.find_files({ on_submit = function(_, ctx) add_file(buf, ctx.relative_path) end }) end
    vim.ui.input({ prompt = "File: ", completion = "file" }, function(p) add_file(buf, p) end)
  end, vim.tbl_extend("force", o, { desc = "Add a file to the spec" }))
end

M._t = { state = function() return S end, start = function(...) start(...) end }

return M
