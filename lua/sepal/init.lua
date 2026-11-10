-- sepal — write a spec in Neovim, the agent works on it in the background, you review what it
-- changed in your buffers. There is no terminal: each spec is a `claude -p` run that continues one
-- chat (at first this directory's last one), so `claude -c` or :Sepal open shows what happened.
-- Specs sent while one runs wait in a queue and run one after another, in the same chat.

local M = {}

local KEYS = { next = "]r", prev = "[r", accept = "<c-c><c-y>", reject = "<c-c><c-n>" }
local C = {
  cmd = { "claude" },  -- the agent. A spec runs: cmd -p --output-format stream-json --verbose <args> [--resume <chat>]
  args = { "--permission-mode", "acceptEdits" }, -- added to each spec run: --model, --allowedTools…
  continue = true,     -- the first spec continues this directory's last chat; false: starts a new one
  spec_suggest = nil,  -- argv: rough spec on stdin -> finished spec on stdout; <c-c><c-s> in a spec runs it
  open = nil,          -- function(argv, cwd) for :Sepal open; default: a new tmux window, outside tmux the command is copied
  keys = KEYS,         -- in buffers with changes to review; a key set to false is not mapped, keys = false maps none
}
function M.setup(opts)
  opts = opts or {}
  local keys = opts.keys
  C = vim.tbl_extend("force", C, opts)
  if type(keys) == "table" then C.keys = vim.tbl_extend("force", KEYS, keys) elseif keys == false then C.keys = {} end
  require("sepal.review").keys = C.keys
end
function M.config() return C end

-- session: nil = not chosen yet (continue: this directory's last chat), false = the next spec starts a
-- new chat, else the chat's id. run: the spec running now ({ job, stopped… }); queue: specs waiting
local S = { session = nil, run = nil, queue = {} }

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

-- the "done" notification can go: you're looking at what the agent did
function M.seen()
  local ok, fidget = pcall(require, "fidget")
  if ok then pcall(fidget.notification.remove, "default", "sepal-done") end
end

-- the first non-empty line of s, cut to n characters
local function first(s, n)
  local l = type(s) == "string" and vim.iter(vim.split(s, "\n")):map(vim.trim):find(function(x) return x ~= "" end) or nil
  if l and vim.fn.strchars(l) > n then l = vim.fn.strcharpart(l, 0, n - 1) .. "…" end
  return l
end

local function plural(n, word) return ("%d %s%s"):format(n, word, n == 1 and "" or "s") end

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

local EDITS = { Edit = true, MultiEdit = true, Write = true, NotebookEdit = true }

-- what a tool call is about, for the spinner: "Edit src/pool.cpp", "Bash make test"
local function about(tool)
  local i = type(tool.input) == "table" and tool.input or {}
  local arg = (type(i.file_path) == "string" and vim.fn.fnamemodify(i.file_path, ":."))
    or (type(i.path) == "string" and vim.fn.fnamemodify(i.path, ":."))
    or vim.iter({ i.command, i.pattern, i.url, i.description }):find(function(v) return type(v) == "string" end)
  return tostring(tool.name) .. (arg and " " .. first(arg, 50) or "")
end

-- "Bash(make test)" for each tool call the agent was not allowed to make
local function denied(res)
  local names, seen = {}, {}
  for _, d in ipairs(type(res) == "table" and type(res.permission_denials) == "table" and res.permission_denials or {}) do
    local i = type(d.tool_input) == "table" and d.tool_input or {}
    local arg = i.command or i.file_path or i.url
    local name = tostring(d.tool_name) .. (type(arg) == "string" and "(" .. first(arg, 40) .. ")" or "")
    if not seen[name] then seen[name] = true; names[#names + 1] = name end
  end
  return names
end

-- run a spec: the agent gets it on stdin, in this directory's chat; queued if one is running
local function run(text)
  if S.run then
    S.queue[#S.queue + 1] = text
    return M.notify(("queued after the running spec (%d waiting)"):format(#S.queue))
  end
  local cwd, review = vim.fn.getcwd(), require("sepal.review")
  if S.session == nil then S.session = C.continue and require("sepal.resume").latest(cwd) or false end
  local argv = vim.list_extend(vim.list_extend({}, C.cmd), { "-p", "--output-format", "stream-json", "--verbose" })
  vim.list_extend(argv, C.args or {})
  if S.session then vim.list_extend(argv, { "--resume", S.session }) end

  local snap = review.begin(cwd) -- before the agent touches anything
  local done, update = progress("working: " .. (first(text, 60) or "the spec"))
  local r = { started = false, edited = {} }
  S.run = r
  local partial = ""
  local function event(line)
    local ok, ev = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if not ok or type(ev) ~= "table" then return end
    if type(ev.session_id) == "string" and (S.run == r or S.run == nil) then S.session = ev.session_id end
    if ev.type == "system" and ev.subtype == "init" then r.started = true end
    if ev.type == "result" then r.started, r.result = true, ev end
    if ev.type == "assistant" and type(ev.message) == "table" and type(ev.message.content) == "table" then
      for _, c in ipairs(ev.message.content) do
        if type(c) == "table" and c.type == "tool_use" then
          update(about(c))
          if EDITS[c.name] and type(c.input) == "table" and type(c.input.file_path) == "string" then r.edited[c.input.file_path] = true end
        end
      end
    end
  end

  local function exited(out)
    if partial ~= "" then event(partial); partial = "" end
    S.run = nil
    review.finish(snap)
    local n, files = review.count()
    local res = r.result
    local tail = n > 0 and " · " .. plural(n, "change") .. " in " .. plural(files, "file") .. " to review" or ""
    if r.stopped then
      done(true)
      M.notify("stopped" .. tail)
    elseif not r.started then
      done()
      local err = first(out.stderr, 200) or ("exit " .. tostring(out.code))
      M.notify("the agent didn't start: " .. err .. "\nthe spec is back in its buffer", vim.log.levels.ERROR)
      giveback(text)
    elseif not res or res.is_error then
      done()
      M.notify("the spec failed: " .. (first(res and res.result, 200) or first(out.stderr, 200) or ("exit " .. tostring(out.code))) .. tail,
        vim.log.levels.ERROR)
    else
      done(true)
      if not snap and next(r.edited) then tail = " · edited " .. plural(vim.tbl_count(r.edited), "file") .. " (not a git repo: no review)" end
      local reply = first(res.result, 80)
      M.notify("done" .. tail .. (reply and ": " .. reply or ""), vim.log.levels.INFO,
        { icon = { "✓", "DiagnosticOk" }, key = "sepal-done", ttl = math.huge })
    end
    local no = denied(res)
    if #no > 0 then
      M.notify("the agent was not allowed: " .. table.concat(no, ", ") .. "\nallow tools with --allowedTools in args, see :h sepal-args",
        vim.log.levels.WARN)
    end
    if #S.queue > 0 then run(table.remove(S.queue, 1)) end
  end

  local ok, job = pcall(vim.system, argv, { cwd = cwd, stdin = text, text = true, stdout = function(_, data)
    if not data then return end
    partial = partial .. data
    local lines = {}
    for l in partial:gmatch("([^\n]*)\n") do lines[#lines + 1] = l end
    partial = partial:match("[^\n]*$")
    if #lines > 0 then vim.schedule(function() for _, l in ipairs(lines) do event(l) end end) end
  end }, vim.schedule_wrap(exited))
  if not ok then
    S.run = nil
    review.finish(snap)
    done()
    M.notify("could not run " .. tostring(argv[1]) .. "\n" .. tostring(job):match("[^\n]*") .. "\nthe spec is back in its buffer", vim.log.levels.ERROR)
    return giveback(text)
  end
  r.job = job
end

-- :Sepal stop: stop the running spec; the queued ones come back to the spec buffer
function M.stop()
  if not S.run then return M.notify("no spec is running") end
  S.run.stopped = true
  pcall(S.run.job.kill, S.run.job, 15)
  if #S.queue > 0 then
    local q = S.queue
    S.queue = {}
    giveback(table.concat(q, "\n\n"))
    M.notify(plural(#q, "queued spec") .. " back in the spec buffer")
  end
end

vim.api.nvim_create_autocmd("VimLeavePre", { group = vim.api.nvim_create_augroup("sepal", {}), callback = function()
  if S.run and S.run.job then pcall(S.run.job.kill, S.run.job, 15) end -- don't leave it editing after you quit
end })

-- :Sepal new: the next spec starts a new chat
function M.new()
  S.session = false
  M.notify("the next spec starts a new chat")
end

-- :Sepal resume: pick the chat the next specs continue, by what you wrote in it
function M.resume()
  local r = require("sepal.resume")
  local rows = r.items(vim.fn.getcwd())
  if #rows == 0 then return M.notify("no conversations in this directory yet") end
  r.choose(rows, "continue with", function(row)
    S.session = row.id
    M.notify("the next spec continues " .. row.title)
  end)
end

-- :Sepal open: the chat the specs went to, in Claude Code itself (a new tmux window by default),
-- to read what the agent did and why, or to keep talking to it
function M.open()
  local cwd = vim.fn.getcwd()
  local id = S.session
  if id == nil then id = require("sepal.resume").latest(cwd) end
  if not id then return M.notify("no chat yet: send a spec first") end
  if S.run then return M.notify("a spec is running; open the chat once it's done, or :Sepal stop", vim.log.levels.WARN) end
  local argv = vim.list_extend(vim.list_extend({}, C.cmd), { "--resume", id })
  if C.open then return C.open(argv, cwd) end
  local line = table.concat(vim.tbl_map(vim.fn.shellescape, argv), " ")
  if vim.env.TMUX then
    local r = vim.system({ "tmux", "new-window", "-c", cwd, "-n", "sepal", line }):wait()
    if r.code ~= 0 then M.notify("tmux new-window failed: " .. (first(r.stderr, 200) or r.code), vim.log.levels.ERROR) end
    return
  end
  pcall(vim.fn.setreg, "+", line)
  M.notify("run this in a terminal (copied): " .. line)
end

-- :Sepal review: every change to review in the quickfix list, the cursor on the first.
-- :Sepal accept / reject: the change under the cursor; with "all": every change in every file
function M.review() require("sepal.review").open() end
function M.accept(all) local r = require("sepal.review"); if all then r.accept_all() else r.accept() end end
function M.reject(all) local r = require("sepal.review"); if all then r.reject_all() else r.reject() end end

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
      return vim.api.nvim_set_current_win(w)
    end
  end
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
    run(table.concat(lines, "\n"))
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

M._t = { state = function() return S end }

return M
