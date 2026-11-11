-- sepal — delegate, verify, land. You write a spec next to your code; the agent works on it alone
-- in a git worktree (so your files never change under you), sepal runs the spec's check itself
-- (`Done when:`), and the result lands in your work tree as unstaged changes, reviewed with the git
-- tools you already use. You hear about it when it's landed or when something needs you;
-- :Sepal inbox lists every spec. See sepal.agent for a spec's life, sepal.git for the git side.

local M = {}

local C = {
  cmd = { "claude" },  -- the agent. A spec runs Claude Code (cmd <args> <spec>) in a hidden terminal in its worktree
  args = { "--permission-mode", "acceptEdits" }, -- added to each run: --model, --allowedTools…
  check = nil,         -- the check for specs without a `Done when:` line, e.g. "make test"; nil: no check
  retries = 1,         -- when the check fails, the agent gets its output and this many more tries
  land = "auto",       -- "auto": a spec that passes lands by itself; "manual": it waits in the inbox for L
  prepare = nil,       -- shell command run in each new worktree before the agent, $SEPAL_ROOT is your repo
  worktrees = vim.fs.joinpath(vim.fn.stdpath("state"), "sepal"), -- where worktrees and the inbox live
  spec_suggest = nil,  -- argv: rough spec on stdin -> finished spec on stdout; <c-c><c-s> in a spec runs it
  max_running = 2,     -- specs running at once, the rest wait in a queue; nil: no limit
}
function M.setup(opts) C = vim.tbl_extend("force", C, opts or {}) end
function M.config() return C end

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

-- fidget spinner while waiting; returns done(msg), update(msg). done(msg) ends it showing msg,
-- done(true) ends it quietly (another notification follows), done() cancels it (a failure, which
-- gets its own warning). Without fidget: no spinner, done(msg) is a plain notification
local function progress(msg)
  local ok, fp = pcall(require, "fidget.progress")
  if not ok then return function(final) if type(final) == "string" then M.notify(final) end end, function() end end
  local h = fp.handle.create({ title = "sepal", message = msg, lsp_client = { name = "sepal" } })
  return function(final)
    if not final then return h:cancel() end
    if type(final) == "string" then h.message = final end
    h:finish()
  end, function(m) h:report({ message = m }) end
end

M.progress = progress

-- a spec that didn't run goes back to the spec buffer (below the open draft, if there is one)
local function giveback(text)
  local lines = vim.split(text, "\n")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[b].sepal_spec then
      vim.api.nvim_buf_set_lines(b, -1, -1, false, vim.list_extend({ "" }, lines))
      return M.spec()
    end
  end
  M.spec(nil, lines)
end


-- the specs of this directory's repo, newest first; nil outside a repo
local function entries()
  local root = require("sepal.git").root(vim.fn.getcwd())
  if not root then M.notify("not in a git repository", vim.log.levels.WARN) end
  return root and require("sepal.inbox").list(root), root
end
-- the newest spec whose status is one of `statuses`
local function newest(statuses, what)
  local list = entries()
  if not list then return end
  for _, e in ipairs(list) do if vim.tbl_contains(statuses, e.status) then return e end end
  M.notify("no spec " .. what)
end

-- :Sepal inbox: every spec of this repo and where it stands
function M.inbox()
  local _, root = entries()
  if root then require("sepal.inbox").open(root) end
end
-- :Sepal land / undo / open / stop: the newest spec it applies to (the inbox acts on any)
function M.land()
  local e = newest({ "ready", "needs", "undone", "failed", "error", "interrupted", "stopped" }, "to land")
  if e then require("sepal.agent").land(e) end
end
function M.undo()
  local e = newest({ "landed" }, "landed")
  if e then require("sepal.agent").undo(e) end
end
function M.open()
  local agent, list = require("sepal.agent"), entries()
  for _, e in ipairs(list or {}) do if agent.running(e) or e.session then return agent.open(e) end end
  if list then M.notify("no spec has a chat yet") end
end
function M.stop()
  local agent, n = require("sepal.agent"), 0
  for _, e in ipairs(entries() or {}) do if agent.running(e) then agent.stop(e); n = n + 1 end end
  if n == 0 then M.notify("no spec is running") end
end
-- :Sepal clean: drop the specs that are over (landed, no changes, undone, stopped, interrupted)
function M.clean()
  local agent, n = require("sepal.agent"), 0
  for _, e in ipairs(vim.list_slice(entries() or {}, 1)) do
    if vim.tbl_contains({ "landed", "nochange", "undone", "stopped", "interrupted" }, e.status) then agent.drop(e); n = n + 1 end
  end
  M.notify("dropped " .. n .. " spec" .. (n == 1 and "" or "s"))
end

local function template()
  return { "Scope: ", "Goal: ", "", "Constraints:", "- ", "", "Done when: " .. (C.check or ""), "", "Files:" }
end
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

-- the spec's keys, shown when it opens (like petal's commit buffer); one notification, replaced each time
local function keys()
  M.notify("spec: <c-c><c-c> sends it" .. (C.spec_suggest and ", <c-c><c-s> writes it for you" or "")
    .. ", <c-c><c-f> adds a file, <c-c><c-k> discards", vim.log.levels.INFO, { key = "sepal-spec-keys" })
end

-- :Sepal spec: write a spec in a buffer above the code, then run it in the background.
-- <c-c><c-c> runs it, <c-c><c-k> discards, <c-c><c-f> adds a file (fff.nvim if installed),
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
      keys()
      return vim.api.nvim_set_current_win(w)
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.b[buf].sepal_spec = true
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "hide" -- closing the window keeps the draft; :Sepal spec brings it back
  local template = C.spec_suggest and IDEA or template()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or template)
  if block then add_selection(buf, block, path) end
  vim.api.nvim_open_win(buf, true, { split = "above", win = 0, height = 12 })
  keys()
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
    local fenced = false -- no empty bullets (or empty Done when:), but code in a ``` block is sent as it is
    local lines = vim.tbl_filter(function(l)
      if l:match("^%s*```") then fenced = not fenced end
      return fenced or not (l:match("^%s*%-%s*$") or l:match("^%s*Done when:%s*$"))
    end, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    while #lines > 0 and vim.trim(lines[#lines]) == "" do lines[#lines] = nil end
    if #lines == 0 then return M.notify("the spec is empty", vim.log.levels.WARN) end
    vim.cmd.stopinsert()
    vim.api.nvim_buf_delete(buf, { force = true })
    local text = table.concat(lines, "\n")
    local e, why = require("sepal.agent").start(text, vim.fn.getcwd())
    if not e then
      M.notify(why .. "\nthe spec is back in its buffer", vim.log.levels.ERROR)
      return giveback(text)
    end
    if e.status == "queued" then return M.notify("queued: " .. e.title .. " · it starts when a running spec is done") end
    M.notify("working on it: " .. e.title .. (e.check and " · done when `" .. e.check .. "` passes" or "") .. " · :Sepal open watches")
  end, vim.tbl_extend("force", o, { desc = "Run the spec in the background" }))
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
      done("spec ready: <c-c><c-c> runs it, u undoes")
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


return M
