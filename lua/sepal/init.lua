-- sepal — delegate, verify, land. You write a task next to your code; the agent works on it alone
-- in a git worktree (so your files never change under you), sepal runs the task's check itself
-- (`Done when:`), and the result lands in your work tree as unstaged changes, reviewed with the git
-- tools you already use. You hear about it when it's landed or when something needs you;
-- :Sepal inbox lists every task. See sepal.agent for a task's life, sepal.git for the git side.

local M = {}

local C = {
  cmd = { "claude" },  -- the agent (claude or devin). A task runs it in a hidden terminal in its worktree
  args = { "--permission-mode", "acceptEdits" }, -- added to each Claude Code run: --model, --allowedTools…
  auto_mode = false,   -- true: every run and chat in Claude Code's auto mode (--permission-mode auto, instead of args')
  check = nil,         -- the check for tasks without a `Done when:` line, e.g. "make test"; nil: no check
  retries = 1,         -- when the check fails, the agent gets its output and this many more tries
  land = "auto",       -- "auto": a task that passes lands by itself; "manual": it waits in the inbox for L
  prepare = nil,       -- shell command run in each new worktree before the agent, $SEPAL_ROOT is your repo
  worktrees = vim.fs.joinpath(vim.fn.stdpath("state"), "sepal"), -- where worktrees and the inbox live
  task_sharpen = nil,  -- argv: rough task on stdin -> finished task on stdout; <c-c><c-s> in a task runs it
  max_running = 3,     -- tasks running at once, the rest wait in a queue; nil: no limit
  models = {},         -- task kind -> its --model: implement (nil: the agent's default, or args'), btw, orchestrate (the planner)
  agents = nil,        -- the agents :Sepal task asks you to pick from, { cmd = "devin", model = "fusion-…", args = {…}, name = "devin", key = "d" }; nil: cmd
  panel_width = 46,    -- :Sepal panel's width: columns (46), a share of the editor's ("30%" or 0.3)
  sakura = true,       -- blossom pinks for sepal's accents; false: only your colorscheme's colors
  highlights = {},     -- Sepal* group -> nvim_set_hl spec, over everything else: { SepalOk = { fg = "#a3be8c" } }
  icons = {},          -- inbox status -> icon: { landed = "✔", running = "~" }
  skills = {},         -- name -> a SKILL.md path or its text, over ~/.claude/skills and ~/.config/devin/skills; /name in a task sends the skill along: { how = "~/.claude/skills/how/SKILL.md" }
}
local MODELS = { btw = "sonnet" } -- a question needs no top-tier model
C.models = vim.tbl_extend("force", {}, MODELS)
local highlight -- below
-- the supported agent kind of a command's executable basename, without loading sepal.agent
local function cmd_kind(c)
  local c1 = type(c) == "string" and c or type(c) == "table" and c[1] or ""
  local b = vim.fs.basename(c1)
  return b:match("^claude") and "claude" or b:match("^devin") and "devin" or nil
end
M._cmd_kind = cmd_kind
function M.setup(opts)
  C = vim.tbl_extend("force", C, opts or {})
  C.models = vim.tbl_extend("force", MODELS, (opts or {}).models or {}) -- models = { implement = "opus" } keeps btw's
  local function check(c, where) -- anything else can't run: sepal knows both agents' hooks
    if c and not cmd_kind(c) then
      M.notify(("%s %s isn't a supported agent: sepal runs claude or devin")
        :format(where, vim.inspect(c)), vim.log.levels.ERROR)
    end
  end
  check(C.cmd, "cmd")
  for _, a in ipairs(type(C.agents) == "table" and C.agents or {}) do check(a.cmd, "agents: cmd") end
  highlight()
end
function M.config() return C end

-- the models a plan's tasks are picked from (m in the inbox too): your agents' (agents option), in order
function M.plan_models()
  local out = {}
  for _, a in ipairs(type(C.agents) == "table" and C.agents or {}) do
    if type(a.model) == "string" and a.model ~= "" and not vim.tbl_contains(out, a.model) then out[#out + 1] = a.model end
  end
  return out
end

-- sepal's colors are its own groups, linked to your colorscheme's by default: a colorscheme (or
-- :hi) that sets a Sepal* group wins over the links and over sakura; the highlights option wins over all
local LINKS = { SepalTitle = "Title", SepalAccent = "Special", SepalInfo = "DiagnosticInfo", SepalOk = false,
  SepalWarn = false, SepalError = false, SepalDim = "Comment", SepalAdded = "Added",
  SepalRemoved = "Removed", SepalInboxFolded = false, SepalPanelTitle = "@markup.strong",
  SepalClaude = false, SepalAgent = "SepalClaude", SepalShimmer = "SepalPanelTitle" }
-- groups with a color of their own instead of a link, whatever the theme or sakura: { on dark, on light }.
-- The states (✔ landed, ✘ failed, ▲ needs you) must read as green, red and amber everywhere
local FG = { SepalClaude = { "#d97757", "#d97757" }, SepalOk = { "#7ed491", "#1e8e3e" },
  SepalError = { "#f2777a", "#d32f2f" }, SepalWarn = { "#f0c674", "#b26a00" } }
-- sakura: { on a dark background, on a light one }
local SAKURA = { SepalTitle = { "#ffb6c1", "#c2185b", bold = true }, SepalAccent = { "#ffb6c1", "#d81b60" },
  SepalInfo = { "#c49aa6", "#ad1457" }, SepalShimmer = { "#fff0f5", "#880e4f", bold = true } }
-- what sepal set each group to: a group that's empty or still sepal's is redefined, one your
-- colorscheme (or :hi) set is left alone, so setup() after :colorscheme doesn't undo it
local mine = {}
highlight = function()
  for name, link in pairs(LINKS) do
    local cur = vim.api.nvim_get_hl(0, { name = name })
    if vim.tbl_isempty(cur) or vim.deep_equal(cur, mine[name]) then
      local s = C.sakura and SAKURA[name] or FG[name]
      vim.api.nvim_set_hl(0, name, s and { fg = s[vim.o.background == "light" and 2 or 1], bold = s.bold } or { link = link or nil })
      mine[name] = vim.api.nvim_get_hl(0, { name = name })
    end
  end
  for name, spec in pairs(C.highlights or {}) do vim.api.nvim_set_hl(0, name, spec) end
end
highlight()
-- :colorscheme clears every group; a new background wants sakura's pinks for it
vim.api.nvim_create_autocmd("ColorScheme", { group = vim.api.nvim_create_augroup("sepal.hl", {}), callback = function() highlight() end })
vim.api.nvim_create_autocmd("OptionSet", { group = "sepal.hl", pattern = "background", callback = function() highlight() end })

-- a status's icon in the inbox: the icons option, else def
function M.icon(status, def) return (C.icons or {})[status] or def end

-- for your statusline: "~2 ●1 ▲1" (running, ready to land, needs you) for the repo you're in, "" when
-- none. Cheap, it reads what's loaded; User SepalChanged fires (and the statusline redraws) when it moves
local loading = {} -- cwd -> true: its inbox is being loaded, once
local status_cwd, status_ver = {}, nil
local STATUS_PARTS = { { "running", "~" }, { "ready", "●" }, { "needs", "▲" } }
function M.status()
  local cwd, inbox = vim.fn.getcwd(), require("sepal.inbox")
  local ver = inbox.roots_ver()
  if status_ver ~= ver then status_cwd, status_ver = {}, ver end
  local root = status_cwd[cwd]
  if root == nil then
    for r in pairs(inbox.cache) do
      if (cwd == r or vim.startswith(cwd, r .. "/")) and (not root or #r > #root) then root = r end
    end
    status_cwd[cwd] = root or false
  elseif root == false then root = nil end
  if not root then
    -- not loaded yet (a restart): find it outside the statusline, which can't run git
    if not loading[cwd] then
      loading[cwd] = true
      require("sepal.git").root_bg(cwd, function(r)
        if r then inbox.list(r); inbox.render() end
      end)
    end
    return ""
  end
  local n1, n2, n3 = inbox.counts_raw(root)
  if n1 == 0 and n2 == 0 and n3 == 0 then return "" end
  local out = {}
  for i, s in ipairs(STATUS_PARTS) do
    local n = i == 1 and n1 or i == 2 and n2 or n3
    if n > 0 then out[#out + 1] = M.icon(s[1], s[2]) .. n end
  end
  return table.concat(out, " ")
end

-- every message is "what happened", shown under "sepal".
-- info goes to fidget if installed (corner, fades out); warnings/errors stay in vim.notify so they're not missed.
-- with the builtin vim.notify they're echoed with a colored icon; a notifier plugin gets plain text
-- o.icon: { text, hl } instead of the level's; o.key, o.ttl: fidget's (same key replaces, ttl in seconds)
local ICON = { [vim.log.levels.ERROR] = { "✘", "SepalError" }, [vim.log.levels.WARN] = { "▲", "SepalWarn" } }
local missing = {} -- module -> true when require failed; a changed runtimepath tries it again
local function optional(name)
  local m = package.loaded[name]
  if m ~= nil then return m end
  if missing[name] then return nil end
  local ok, mod = pcall(require, name)
  if ok then missing[name] = nil; return mod end
  missing[name] = true
end
vim.api.nvim_create_autocmd("OptionSet", { group = "sepal.hl", pattern = "runtimepath", callback = function() missing = {} end })
-- while you're in the agent (or a chat) they wait, shown once you leave it
local held = {}
function M.notify(msg, lvl, o)
  if vim.b.sepal_agent then
    held[#held + 1] = { msg, lvl, o }
    if #held == 1 then
      vim.api.nvim_create_autocmd("BufEnter", { callback = function()
        if vim.b.sepal_agent then return end
        local h = held
        held = {}
        for _, n in ipairs(h) do M.notify(n[1], n[2], n[3]) end
        return true
      end })
    end
    return
  end
  lvl, o = lvl or vim.log.levels.INFO, o or {}
  local fidget = optional("fidget")
  if fidget and lvl <= vim.log.levels.INFO then
    return fidget.notify((o.icon and o.icon[1] .. " " or "") .. msg, lvl, { annote = "sepal", key = o.key, ttl = o.ttl })
  end
  if not (debug.getinfo(vim.notify, "S").source or ""):match("^@?vim/") then return vim.notify(msg, lvl, { title = "sepal" }) end
  local icon = o.icon or ICON[lvl] or { "●", "SepalInfo" }
  vim.api.nvim_echo({ { icon[1] .. " ", icon[2] }, { "sepal ", "SepalTitle" }, { msg } }, true, { err = lvl >= vim.log.levels.ERROR })
end

-- fidget spinner while waiting; returns done(msg), update(msg). done(msg) ends it showing msg,
-- done(true) ends it quietly (another notification follows), done() cancels it (a failure, which
-- gets its own warning). Without fidget: no spinner, done(msg) is a plain notification
local function progress(msg)
  local fp = optional("fidget.progress")
  if not fp then return function(final) if type(final) == "string" then M.notify(final) end end, function() end end
  local h = fp.handle.create({ title = "sepal", message = msg, lsp_client = { name = "sepal" } })
  return function(final)
    if not final then return h:cancel() end
    if type(final) == "string" then h.message = final end
    h:finish()
  end, function(m) h:report({ message = m }) end
end

M.progress = progress

-- in the agent (or a chat), the inbox, or with the panel open, fidget's window is noise: the panel already shows it.
-- It shows again (with what's current) once you leave
local hid_fidget = false
function M.fidget()
  local panel = package.loaded["sepal.panel"]
  local hide = vim.b.sepal_agent == true or vim.bo.filetype == "sepal-inbox" or (panel ~= nil and panel.shown())
  if hide == hid_fidget then return end -- only flip on a change, so your own suppress() isn't undone
  local n = optional("fidget.notification")
  if n then n.suppress(hide); hid_fidget = hide end
end
local fidget_pending = false
vim.api.nvim_create_autocmd({ "BufEnter", "WinClosed" }, { group = vim.api.nvim_create_augroup("sepal.fidget", {}),
  callback = function() -- scheduled: on WinClosed the window is still there
    if fidget_pending then return end
    fidget_pending = true
    vim.schedule(function() fidget_pending = false; M.fidget() end)
  end })

-- q in sepal's buffers: close the window; in the last one (E444: can't close it) show another buffer there
function M.close()
  local cur = vim.api.nvim_get_current_buf()
  local wins = vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative == "" end, vim.api.nvim_tabpage_list_wins(0))
  if vim.api.nvim_win_get_config(0).relative ~= "" or #wins > 1 or vim.fn.tabpagenr("$") > 1 then -- a float (the agent) always closes
    vim.cmd.close()
  else -- back to the buffer before, unless that's another agent or chat: :Sepal open would bounce between them
    local alt = vim.fn.bufnr("#")
    local back = alt > 0 and alt ~= cur and vim.bo[alt].buflisted and not vim.b[alt].sepal_agent
    if not (back and pcall(vim.cmd.buffer, alt)) then vim.cmd.enew() end
  end
end

local draft_buf
function M.draft() return draft_buf and vim.api.nvim_buf_is_valid(draft_buf) and vim.b[draft_buf].sepal_task and draft_buf or nil end

-- a task that didn't run goes back to the task buffer (below the open draft, if there is one)
local function giveback(text, kind, agent)
  local lines = vim.split(text, "\n")
  local b = M.draft()
  if b then
    vim.api.nvim_buf_set_lines(b, -1, -1, false, vim.list_extend({ "" }, lines))
    return M.task()
  end
  M.task(nil, lines, kind, agent)
end


-- the tasks of this directory's repo, newest first; nil outside a repo
local function entries()
  local root = require("sepal.git").root(vim.fn.getcwd())
  if not root then M.notify("not in a git repository", vim.log.levels.WARN) end
  return root and require("sepal.inbox").list(root), root
end
-- the newest task whose status is one of `statuses`
local function newest(statuses, what)
  local list = entries()
  if not list then return end
  for _, e in ipairs(list) do if vim.tbl_contains(statuses, e.status) then return e end end
  M.notify("no task " .. what)
end

-- :Sepal inbox: every task of this repo and where it stands
function M.inbox()
  local _, root = entries()
  if root then require("sepal.inbox").open(root) end
end
-- :Sepal qf: the quickfix list as a planned large feat, one task per file, then the inbox
function M.qf()
  local e, why = require("sepal.agent").plan_from_qf(vim.fn.getcwd())
  if not e then return M.notify(why, vim.log.levels.WARN) end
  require("sepal.inbox").open(e.root)
end
-- :Sepal panel: a board at the right that shows each task and what its agent is doing (a toggle)
function M.panel()
  local _, root = entries()
  if root then require("sepal.panel").toggle(root) end
end
-- :Sepal land / undo / open / stop: the newest task it applies to (the inbox acts on any)
function M.land()
  local e = newest({ "ready", "needs", "undone", "failed", "error", "interrupted", "stopped" }, "to land")
  if e then require("sepal.agent").land(e) end
end
function M.undo()
  local e = newest({ "landed" }, "landed")
  if e then require("sepal.agent").undo(e) end
end
function M.open()
  if vim.b.sepal_agent then return M.close() end -- a toggle: from the agent (or a chat) it leaves, like q
  local agent, list = require("sepal.agent"), entries()
  for _, e in ipairs(list or {}) do if agent.running(e) or e.session then return agent.open(e) end end
  if list then M.notify("no task has a chat yet") end
end
function M.stop()
  local agent, n = require("sepal.agent"), 0
  for _, e in ipairs(entries() or {}) do if agent.running(e) or agent.chatting(e) then agent.stop(e); n = n + 1 end end
  if n == 0 then M.notify("no task is running") end
end
-- :Sepal clean: drop the tasks that are over (landed, no changes, undone, stopped, interrupted, answered, swarmed)
function M.clean()
  local agent, list = require("sepal.agent"), {}
  for _, e in ipairs(vim.list_slice(entries() or {}, 1)) do
    if vim.tbl_contains({ "landed", "nochange", "undone", "stopped", "interrupted", "answered", "swarmed" }, e.status) then list[#list + 1] = e end
  end
  agent.drop_many(list)
  M.notify("dropped " .. #list .. " task" .. (#list == 1 and "" or "s"))
end

-- the task as it's sent: no empty bullets, no field without text (Goal:, Constraints:, Files:…), no
-- doubled blank lines; code in a ``` block is sent as it is. nil and why when there's nothing to send
function M.tidy(buf)
  local kept, fenced = {}, false
  for _, l in ipairs(buf) do
    if l:match("^%s*```") then fenced = not fenced end
    if fenced or not l:match("^%s*%-%s*$") then kept[#kept + 1] = { l, fenced } end
  end
  local function field(l) return l and not l[2] and l[1]:match("^%s*%u[%w ]*:") end
  local lines, goal = {}, false
  for i, l in ipairs(kept) do
    local empty = not l[2] and l[1]:match("^%s*%u[%w ]*:%s*$")
    local blank = vim.trim(l[1]) == "" and not l[2]
    local nxt = kept[i + 1]
    -- an empty field is dropped when nothing is under it (the end, a blank line or the next field)
    local drop = empty and (not nxt or (vim.trim(nxt[1]) == "" and not nxt[2]) or field(nxt))
    if drop and l[1]:match("^%s*Goal:") then goal = true end
    if not drop and not (blank and (#lines == 0 or vim.trim(lines[#lines]) == "")) then lines[#lines + 1] = l[1] end
  end
  while #lines > 0 and vim.trim(lines[#lines]) == "" do lines[#lines] = nil end
  if #lines == 0 then return nil, "the task is empty, nothing sent" end
  if goal then return nil, "the goal is empty, nothing sent" end
  return lines
end

-- the project's test command for a new task's Done when:, and where it was found; nil when there's none
local function readf(p) local f = io.open(p); if not f then return nil end local s = f:read("a"); f:close(); return s end
function M.find_check(cwd)
  local root = vim.fs.root(cwd, ".git")
  if not root then return nil end
  local function at(name) return readf(vim.fs.joinpath(root, name)) end
  for _, name in ipairs({ "AGENTS.md", "CLAUDE.md" }) do -- "- Tests: `nvim -l tests/run.lua`"
    local c = ("\n" .. (at(name) or "")):match("\n[ \t%-%*]*Tests?:[^\n`]*`([^`\n]+)`")
    if c then return c, name end
  end
  local mk = at("Makefile")
  if mk and (mk:match("^test:") or mk:match("\ntest:")) then return "make test", "Makefile" end
  local ok, pkg = pcall(vim.json.decode, at("package.json") or "")
  local t = ok and type(pkg) == "table" and type(pkg.scripts) == "table" and pkg.scripts.test
  if type(t) == "string" and not t:match("no test specified") then return "npm test", "package.json" end
  if vim.uv.fs_stat(vim.fs.joinpath(root, "Cargo.toml")) then return "cargo test", "Cargo.toml" end
  if vim.uv.fs_stat(vim.fs.joinpath(root, "go.mod")) then return "go test ./...", "go.mod" end
  if vim.uv.fs_stat(vim.fs.joinpath(root, "pytest.ini")) then return "pytest", "pytest.ini" end
  local s = at("pyproject.toml")
  if s and s:match("%[tool%.pytest") then return "pytest", "pyproject.toml" end
end

-- name -> SKILL.md path or text: Claude Code's and Devin's user skills, then the skills option over them
local function all_skills()
  local out = {}
  local claude = vim.env.CLAUDE_CONFIG_DIR or vim.fn.expand("~/.claude")
  local devin = vim.fs.joinpath(vim.env.XDG_CONFIG_HOME or vim.fn.expand("~/.config"), "devin")
  for _, dir in ipairs({ devin, claude }) do
    for _, p in ipairs(vim.fn.glob(vim.fs.joinpath(dir, "skills", "*", "SKILL.md"), true, true)) do
      out[vim.fs.basename(vim.fs.dirname(p))] = p
    end
  end
  return vim.tbl_extend("force", out, C.skills or {})
end

-- the task with each skill it names as /name (the skills option) appended, frontmatter dropped, once each
function M.skills(text)
  local out, seen, all = text, {}, all_skills()
  for name in (" " .. text):gmatch("%s/([%w_%-]+)") do
    local s = all[name]
    if type(s) == "string" and not seen[name] then
      seen[name] = true
      s = readf(vim.fn.expand(s)) or s
      out = out .. "\n\nSkill /" .. name .. ":\n" .. vim.trim((s:gsub("^%-%-%-\n.-\n%-%-%-\n", "")))
    end
  end
  return out
end

-- 'omnifunc' of the task draft: /name completes the skills option's names (the blink source is sepal.blink)
function M.complete_skills(findstart, base)
  if findstart == 1 then
    local before = vim.api.nvim_get_current_line():sub(1, vim.fn.col(".") - 1)
    local s = (" " .. before):match("%s()/[%w_%-]*$")
    return s and s - 2 or -3
  end
  local out = {}
  for name, s in pairs(all_skills()) do
    if ("/" .. name):find(base, 1, true) == 1 then
      local info = type(s) == "string" and s:match("^[^\n]*") or nil
      out[#out + 1] = { word = "/" .. name, menu = "skill", info = info }
    end
  end
  table.sort(out, function(a, b) return a.word < b.word end)
  return out
end

local function template(check)
  return { "Goal: ", "", "Done when: " .. (check or ""), "", "Files:" }
end
local IDEA = { "", "", "Files:" } -- a large feat with task_sharpen (or a btw): the idea goes on top, <c-c><c-s> writes the task
local HINT = { btw = "ask anything about the project; it answers, nothing changes",
  orchestrate = "the whole job; it's planned as tasks, each with its model; <c-c><c-s> writes it" }
local HINT_NS = vim.api.nvim_create_namespace("sepal.hint")
-- <c-c><c-s> on a short feat: this goes to task_sharpen above the task's filled-in fields (M.tidy's)
local SHARPEN = [[Make this task deeper, not bigger. First work out:
1. What a top professional in this field would do here that I'm not asking for.
2. The rawest material they'd start from, instead of what's been digested for me.
3. The specific methods and tools they'd use.
4. What, other than you or me, would show the result is right.

Then rewrite my task to ask for exactly that. Have it ask the agent to prototype any choice an
experiment can settle and recommend an option from what it observed; leave product or preference
choices no experiment can settle to me.

Output only the rewritten task in its fields (Goal:, Done when:, Files: as @path),
keeping Done when: and Files: unless wrong; no code fences, no filler. The task:
]]

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

-- who a task of kind would run with (as sepal.agent picks it): its provider's logo and hl, and its
-- model's short name (nil: the agent's own default) and the agent's name (its command's)
local function who(kind, agent)
  local panel = require("sepal.panel")
  agent = agent or (C.agents or {})[1]
  local m = agent and agent.model or (C.models or {})[kind or "implement"]
  local c = agent and agent.cmd or C.cmd
  c = vim.fs.basename(tostring(type(c) == "table" and c[1] or type(c) == "string" and c:match("^%S+") or ""))
  local l, hl = panel.logo(m or c)
  return { l, hl }, m and panel.model(m), agent and agent.name or c
end

-- at the end of the Done when: line, what it does: green lands, red goes back to the agent; and
-- where sepal found it, while it's still that. A virtual text, so never sent
local CHECK_NS = vim.api.nvim_create_namespace("sepal.check")
local CHECK_STATE = {}
local function check_hint(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local row, val
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:find("Done when:", 1, true) then
      local v = l:match("^%s*Done when:%s*(.-)%s*$")
      if v then row, val = i, v break end
    end
  end
  local found = vim.b[buf].sepal_found
  local prev = CHECK_STATE[buf]
  if prev and prev.row == row and prev.val == val and prev.found == found then
    if not row then return end
    local m = vim.api.nvim_buf_get_extmarks(buf, CHECK_NS, { row - 1, 0 }, { row, 0 }, {})
    for _, x in ipairs(m) do
      if x[2] == row - 1 then return end
    end
  end
  CHECK_STATE[buf] = { row = row, val = val, found = found }
  vim.api.nvim_buf_clear_namespace(buf, CHECK_NS, 0, -1)
  if row then
    local v = val
    local chunks = v == "" and { { "  a command that proves it's done; empty: not checked", "SepalDim" } }
      or { { "  " }, { "✔ green", "SepalOk" }, { " lands  ", "SepalDim" }, { "✘ red", "SepalError" },
        { " goes back to the agent" .. (found and v == found[1] and "  · found in " .. found[2] .. ", dd: no check" or ""), "SepalDim" } }
    vim.api.nvim_buf_set_extmark(buf, CHECK_NS, row - 1, 0, { virt_text = chunks, virt_text_pos = "eol" })
  end
end

-- the task's keys, a dim line and a blank on top of it like the inbox's: virtual lines, so never sent;
-- the provider's logo and model first, so you see who'll work on it
local KEYS_NS = vim.api.nvim_create_namespace("sepal.keys")
local KEYS_SIG = {}
local SPIN = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local BUSY = {} -- buf -> { label, frame }: task_sharpen is at work on it, a spinner after who works on it
local function keys(buf, text_only)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  if text_only and KEYS_SIG[buf] then
    local m = vim.api.nvim_buf_get_extmarks(buf, KEYS_NS, 0, -1, {})
    if #m == 1 and m[1][2] == 0 and m[1][3] == 0 then return end
  end
  local kind = vim.b[buf].sepal_kind
  local help = kind == "btw" and { "btw", "<c-c><c-c> ask" }
    or kind == "orchestrate" and { "large feat", "<c-c><c-c> plan", "<c-c><c-w> plan, its tasks wait", C.task_sharpen and "<c-c><c-s> write" or nil }
    or { "<c-c><c-c> send", "<c-c><c-w> wait", C.task_sharpen and "<c-c><c-s> sharpen" or nil }
  vim.list_extend(help, { "<c-c><c-o> model", "<c-c><c-f> file", "<c-c><c-p> image", "<c-c><c-k> discard" })
  local items = vim.tbl_map(function(s) return { { s, "SepalDim" } } end, help)
  local w = vim.b[buf].sepal_who
  local b = BUSY[buf]
  if b then table.insert(items, 1, { { SPIN[b[2]] .. " ", "SepalAccent" }, { b[1], "SepalTitle" } }) end
  if w then table.insert(items, 1, { { w[1], w[2] }, { " " .. w[3], "SepalDim" } }) end
  -- virt_lines don't wrap: the items go on as many lines as the narrowest window needs
  local width = math.huge
  local wins = vim.fn.win_findbuf(buf)
  for _, win in ipairs(wins) do
    width = math.min(width, vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff)
  end
  local sig = { width }
  for _, item in ipairs(items) do
    for _, c in ipairs(item) do sig[#sig + 1] = c[1]; sig[#sig + 1] = c[2] or "" end
  end
  sig = table.concat(sig, "\0")
  if sig == KEYS_SIG[buf] then
    local m = vim.api.nvim_buf_get_extmarks(buf, KEYS_NS, 0, -1, {})
    if #m == 1 and m[1][2] == 0 and m[1][3] == 0 then return end
  end
  local lines, used = { {} }, 0
  for _, item in ipairs(items) do
    local iw = 0
    for _, c in ipairs(item) do iw = iw + vim.api.nvim_strwidth(c[1]) end
    local line = lines[#lines]
    if #line > 0 and used + 2 + iw > width then line, used = {}, 0; lines[#lines + 1] = line end
    if #line > 0 then line[#line + 1], used = { "  ", "SepalDim" }, used + 2 end
    vim.list_extend(line, item)
    used = used + iw
  end
  lines[#lines + 1] = { { "" } }
  vim.api.nvim_buf_clear_namespace(buf, KEYS_NS, 0, -1) -- all of it: replacing line 1 pushes the mark down
  vim.api.nvim_buf_set_extmark(buf, KEYS_NS, 0, 0, { virt_lines = lines, virt_lines_above = true })
  for _, win in ipairs(wins) do
    -- lines above line 1 only show with topfill
    vim.api.nvim_win_call(win, function() if vim.fn.line("w0") == 1 then vim.fn.winrestview({ topfill = #lines }) end end)
  end
  KEYS_SIG[buf] = sig
end

-- a spinner and label in buf's keys until the returned stop() (or buf is gone)
local function busy(buf, label)
  local b, timer = { label, 1 }, vim.uv.new_timer()
  BUSY[buf] = b
  keys(buf)
  local function stop()
    if BUSY[buf] == b then BUSY[buf] = nil; keys(buf) end
    if not timer:is_closing() then timer:stop(); timer:close() end
  end
  timer:start(100, 100, vim.schedule_wrap(function()
    if BUSY[buf] ~= b or not vim.api.nvim_buf_is_valid(buf) then return stop() end
    b[2] = b[2] % #SPIN + 1
    keys(buf)
  end))
  return stop
end

-- the kinds :Sepal task picks from; the shown names (the kinds stay: saved inboxes, models keys)
local KINDS = { s = "implement", b = "btw", l = "orchestrate" }
local LABEL = { implement = "short feat", btw = "btw", orchestrate = "large feat" }

-- :Sepal task: write a task in a buffer above the code, then run it in the background.
-- <c-c><c-c> runs it and lands it by itself, <c-c><c-w> runs it and has it wait for L,
-- <c-c><c-k> discards, <c-c><c-f> adds a file (fff.nvim if installed), <c-c><c-p> pastes an image,
-- <c-c><c-s> has task_sharpen turn what's there (an idea + files) into the task; on a short feat
-- (implement) it sharpens it: its filled-in fields go with the SHARPEN prompt.
-- range: { first, last } lines of the current buffer to put in the task (:'<,'>Sepal task)
-- lines: the text to start from (a task that could not be sent comes back with it)
-- kind: "implement" (nil) changes the code; "btw" asks about the project: it answers, nothing lands;
-- "orchestrate" plans the job as tasks, each with its model, that s in the inbox starts (<c-c><c-c>:
-- they land by themselves, <c-c><c-w>: they wait for L)
-- ponytail: a range is whole lines; a charwise selection brings its full lines
-- agent: one of the agents option's (nil: its first)
function M.task(range, lines, kind, agent)
  kind = kind or "implement"
  if agent then -- a stored agent: back to its agents-option entry when that's still it (its name shows)
    for _, x in ipairs(C.agents or {}) do
      if vim.deep_equal(x.cmd, agent.cmd) and x.model == agent.model then agent = vim.deepcopy(x) break end
    end
  end
  local btw = kind == "btw"
  local block, path
  if range then block, path = selection(range[1], range[2]) end
  local b = M.draft()
  if b then
    local w = vim.fn.win_findbuf(b)[1] -- only a draft in a window exists (bufhidden=wipe)
    if block then add_selection(b, block, path) end -- a draft is open: the selection joins it
    keys(b)
    return vim.api.nvim_set_current_win(w)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  draft_buf = buf
  vim.b[buf].sepal_task, vim.b[buf].sepal_kind = true, kind
  local l, m, name = who(kind, agent)
  vim.b[buf].sepal_who = { l[1], l[2], m or name }
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].omnifunc = "v:lua.require'sepal'.complete_skills"
  if not package.loaded["blink.cmp"] then -- blink shows sepal.blink's items itself
    vim.api.nvim_create_autocmd("InsertCharPre", { buffer = buf, callback = function()
      local before = vim.api.nvim_get_current_line():sub(1, vim.fn.col(".") - 1)
      if vim.v.char == "/" and next(all_skills()) and vim.fn.pumvisible() == 0 and (before == "" or before:match("%s$")) then
        vim.schedule(function() vim.api.nvim_feedkeys(vim.keycode("<c-x><c-o>"), "n", false) end)
      end
    end })
  end
  vim.bo[buf].bufhidden = "wipe" -- closing the window drops the draft: :Sepal task always starts a new one
  -- the check option is used anyway when the line is gone, so only a found one says "dd: no check"
  local check = C.check
  if not check and not btw and not lines then
    local c, from = M.find_check(vim.fn.getcwd())
    if c then check, vim.b[buf].sepal_found = c, { c, from } end
  end
  local idea = btw or (kind == "orchestrate" and C.task_sharpen) -- a short feat keeps its fields: <c-c><c-s> sharpens them
  local template = idea and IDEA or template(check)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or template)
  if block then add_selection(buf, block, path) end
  local from = vim.api.nvim_get_current_win()
  local w = vim.api.nvim_open_win(buf, true, { split = "above", win = 0, height = 12 })
  -- a split copies its window's options: from the inbox, nowrap scrolls a long line sideways as you type
  vim.wo[w].wrap, vim.wo[w].cursorline = true, false
  -- back to where the draft came from (the inbox for yyp): with splitbelow, closing it would focus the window above
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = function()
    KEYS_SIG[buf], CHECK_STATE[buf] = nil, nil
    -- not when a new draft opened meanwhile: it keeps the focus
    vim.schedule(function() if vim.api.nvim_win_is_valid(from) and not vim.b.sepal_task then vim.api.nvim_set_current_win(from) end end)
  end })
  keys(buf)
  check_hint(buf)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = buf, callback = function() keys(buf, true); check_hint(buf) end })
  vim.api.nvim_create_autocmd("WinResized", { callback = function()
    if not vim.api.nvim_buf_is_valid(buf) then return true end
    keys(buf)
  end })
  if not lines then
    vim.api.nvim_win_set_cursor(0, { 1, #template[1] })
    vim.schedule(function() vim.cmd.startinsert({ bang = true }) end) -- after keys already typed (see sepal.resume)
  end
  if idea then
    -- placeholder on an empty idea line: an extmark, so it's never sent or piped (and changedtick stays)
    local function hint()
      if not vim.api.nvim_buf_is_valid(buf) then return end
      vim.api.nvim_buf_clear_namespace(buf, HINT_NS, 0, -1) -- all of it: replacing line 1 pushes the mark down
      if (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "") ~= "" then return end
      vim.api.nvim_buf_set_extmark(buf, HINT_NS, 0, 0, { virt_text = { { HINT[kind], "SepalDim" } }, virt_text_pos = "overlay" })
    end
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = buf, callback = hint })
    hint()
  end

  local o = { buffer = buf }
  -- land: "auto" lands it by itself once it passes, "manual" has it wait in the inbox for L
  local function send(land)
    local lines, err = M.tidy(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    if not lines then return M.notify(err, vim.log.levels.WARN) end
    vim.cmd.stopinsert()
    vim.api.nvim_buf_delete(buf, { force = true })
    local text = table.concat(lines, "\n")
    local function back(why)
      M.notify(why .. "\nthe task is back in its buffer", vim.log.levels.ERROR)
      giveback(text, kind, agent)
    end
    local e, why = require("sepal.agent").start(M.skills(text), vim.fn.getcwd(), land, back, kind, agent)
    if not e then return back(why) end
    if e.status == "queued" then return M.notify("queued: " .. e.title .. " · it starts when a running task is done") end
    if btw then return M.notify("asking: " .. e.title .. " · :Sepal open watches") end
    if kind == "orchestrate" then return M.notify("planning: " .. e.title .. " · its tasks wait in :Sepal inbox, s starts them") end
    M.notify("working on it: " .. e.title .. (e.check and " · done when `" .. e.check .. "` passes" or "") .. " · :Sepal open watches")
  end
  vim.keymap.set({ "n", "i" }, "<c-c><c-o>", function()
    local insert = vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
    local pos = vim.api.nvim_win_get_cursor(0)
    vim.cmd.stopinsert()
    local cur = agent or (C.agents or {})[1]
    M.pick_model(LABEL[kind] .. " model", cur and cur.model, function(m)
      local picked
      if m then
        for _, x in ipairs(C.agents or {}) do
          if x.model == m then picked = vim.deepcopy(x) break end
        end
      end
      if picked then
        agent = picked
      else
        agent = vim.deepcopy(agent or (C.agents or {})[1] or {})
        agent.model = m
      end
      if vim.api.nvim_buf_is_valid(buf) then
        local l, shown, name = who(kind, agent)
        vim.b[buf].sepal_who = { l[1], l[2], shown or name }
        keys(buf)
      end
    end)
    if insert and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_win_set_cursor, 0, pos)
      vim.cmd.startinsert()
    end
  end, vim.tbl_extend("force", o, { desc = "Pick the task's model" }))
  vim.keymap.set({ "n", "i" }, "<c-c><c-c>", function() send("auto") end,
    vim.tbl_extend("force", o, { desc = "Run the task, it lands by itself" }))
  if not btw then -- a question doesn't land, nor is it a task to write
    vim.keymap.set({ "n", "i" }, "<c-c><c-w>", function() send("manual") end,
      vim.tbl_extend("force", o, { desc = "Run the task, it waits in the inbox" }))
  end
  vim.keymap.set({ "n", "i" }, "<c-c><c-k>", function()
    vim.cmd.stopinsert()
    vim.api.nvim_buf_delete(buf, { force = true })
  end, vim.tbl_extend("force", o, { desc = "Discard the task" }))
  local job -- the running task_sharpen
  vim.api.nvim_create_autocmd("BufUnload", { buffer = buf, once = true, callback = function()
    if job then pcall(job.kill, job, 15) end -- sent or discarded before it answered: don't leave it running
  end })
  vim.keymap.set({ "n", "i" }, "<c-c><c-s>", function()
    if btw then return M.notify("a btw is sent as you wrote it: <c-c><c-c> asks") end
    if not C.task_sharpen then return M.notify("set task_sharpen to have <c-c><c-s> write the task, see :h sepal-task_sharpen", vim.log.levels.WARN) end
    if job then return M.notify("still writing the task") end
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    if vim.trim((text:gsub("Files:", ""))) == "" then return M.notify("write the idea first", vim.log.levels.WARN) end
    if kind == "implement" then
      local filled, err = M.tidy(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      if not filled then return M.notify(err:gsub(", nothing sent", ", nothing to sharpen"), vim.log.levels.WARN) end
      text = SHARPEN .. table.concat(filled, "\n")
    end
    vim.cmd.stopinsert()
    local label = kind == "implement" and "sharpening the task" or "writing the task"
    local tick, finish, stop = vim.b[buf].changedtick, progress(label), busy(buf, label .. "…")
    local function done(final) stop(); finish(final) end
    local ok, j = pcall(vim.system, C.task_sharpen, { stdin = text, text = true }, vim.schedule_wrap(function(r)
      job = nil
      if not vim.api.nvim_buf_is_valid(buf) then return done() end
      local out = vim.trim(((r.stdout or ""):gsub("^%s*```%w*\n", "")):gsub("\n?```%s*$", ""))
      if r.code ~= 0 or out == "" then
        done()
        return M.notify("task_sharpen failed" .. (r.code ~= 0 and " (exit " .. r.code .. ")" or ": empty answer")
          .. ((r.stderr or "") ~= "" and "\n" .. vim.trim(r.stderr):match("[^\n]*") or ""), vim.log.levels.ERROR)
      end
      if vim.b[buf].changedtick ~= tick then -- never overwrite what you typed meanwhile
        done()
        return M.notify("the task changed while it was being written, <c-c><c-s> again", vim.log.levels.WARN)
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(out, "\n"))
      done("task ready: <c-c><c-c> runs it, u undoes")
    end))
    if not ok then
      done()
      return M.notify("could not run " .. tostring(C.task_sharpen[1]) .. "\n" .. tostring(j):match("[^\n]*"), vim.log.levels.ERROR)
    end
    job = j
  end, vim.tbl_extend("force", o, { desc = kind == "implement" and "Sharpen the task with task_sharpen" or "Write the task with task_sharpen" }))
  vim.keymap.set({ "n", "i" }, "<c-c><c-f>", function()
    vim.cmd.stopinsert()
    local fff = optional("fff")
    if fff then return fff.find_files({ on_submit = function(_, ctx) add_file(buf, ctx.relative_path) end }) end
    vim.ui.input({ prompt = "File: ", completion = "file" }, function(p) add_file(buf, p) end)
  end, vim.tbl_extend("force", o, { desc = "Add a file to the task" }))
  -- the clipboard's image (a screenshot, a mockup), saved under the cache so it outlives Neovim for r
  -- (dropping the task deletes it); listed by its absolute path, which the agent may read (see sepal.agent)
  vim.keymap.set({ "n", "i" }, "<c-c><c-p>", function()
    local cmd = vim.env.WAYLAND_DISPLAY and { "wl-paste", "--type", "image/png" }
      or vim.fn.has("mac") == 1 and { "pngpaste", "-" }
      or { "xclip", "-selection", "clipboard", "-t", "image/png", "-o" }
    local ok, r = pcall(function() return vim.system(cmd):wait(3000) end)
    if not ok then return M.notify("could not run " .. cmd[1], vim.log.levels.ERROR) end
    if r.code ~= 0 or (r.stdout or "") == "" then return M.notify("no image in the clipboard", vim.log.levels.WARN) end
    local agent = require("sepal.agent")
    vim.fn.mkdir(agent.PASTES, "p")
    agent.sweep_pastes()
    local p = vim.fs.joinpath(agent.PASTES, ("paste-%d.png"):format(vim.uv.hrtime()))
    local f = assert(io.open(p, "wb"))
    f:write(r.stdout)
    f:close()
    add_file(buf, p)
  end, vim.tbl_extend("force", o, { desc = "Paste the clipboard's image into the task" }))
end

-- yyp + :w in the inbox on an answered btw: an implement draft with the question and its answer as
-- context (the question's files listed again), the check found as for a new task; you write the Goal
function M.implement(e)
  if e.kind ~= "btw" or not e.answer then return M.notify("only an answered btw turns into a task") end
  local q, files = {}, nil
  for _, l in ipairs(vim.split(e.task, "\n")) do
    if l:match("^Files:") then files = {} end
    table.insert(files or q, l)
  end
  local lines = template(C.check or M.find_check(vim.fn.getcwd()))
  table.remove(lines) -- its Files:, the question's come last
  vim.list_extend(lines, { "Asked:", vim.trim(table.concat(q, "\n")), "", "Answer:", e.answer, "" })
  vim.list_extend(lines, files or { "Files:" })
  M.task(nil, vim.split(table.concat(lines, "\n"), "\n"), nil, e.agent)
  if vim.b.sepal_task then vim.api.nvim_win_set_cursor(0, { 1, #"Goal: " }) end
end

-- :Sepal task: pick its kind first, l large feat (an orchestrate), s short feat (an implement) or b btw
-- (any other key cancels); an open draft just gets the focus (and the range), whatever its kind
-- a pick in a bottom split like the inbox (here and the inbox's m): one item a row, the key you press (nil: <Esc>, <c-c>)
local CHOOSE_NS = vim.api.nvim_create_namespace("sepal.choose")
local function pad(s, w) return s .. (" "):rep(math.max(0, w - vim.api.nvim_strwidth(s))) end
function M.choose(items, opts)
  local kw, iw, lw, diw, has_detail = 0, 0, 0, 0, false
  for _, item in ipairs(items) do
    if not item.sep then
      kw = math.max(kw, vim.api.nvim_strwidth(item.key))
      if item.icon then iw = math.max(iw, vim.api.nvim_strwidth(item.icon[1])) end
      lw = math.max(lw, vim.api.nvim_strwidth(item.label))
      if item.detail_icon then diw = math.max(diw, vim.api.nvim_strwidth(item.detail_icon[1])) end
      has_detail = has_detail or (item.detail ~= nil and item.detail ~= "")
    end
  end
  local lines, marks = {}, {}
  for row, item in ipairs(items) do
    local chunks = {}
    local function add(text, hl) chunks[#chunks + 1] = { text, hl } end
    if not item.sep then
      add("  ")
      add(pad(item.key, kw), "SepalAccent")
      add("  ")
      if iw > 0 then
        if item.icon then
          add(pad(item.icon[1], iw), item.icon[2])
          add(" ")
        else
          add((" "):rep(iw + 1))
        end
      end
      if has_detail and item.detail and item.detail ~= "" then
        add(pad(item.label, lw), item.label_hl)
        add("  ")
        if diw > 0 then
          if item.detail_icon then
            add(pad(item.detail_icon[1], diw), item.detail_icon[2])
            add(" ")
          else
            add((" "):rep(diw + 1))
          end
        end
        add(item.detail, item.detail_hl or "SepalDim")
      else
        add(item.label, item.label_hl)
      end
      if item.current then
        add("  ")
        add("●", "SepalAccent")
      end
    end
    local parts, col = {}, 0
    for _, c in ipairs(chunks) do
      parts[#parts + 1] = c[1]
      if c[2] and c[1] ~= "" then marks[#marks + 1] = { row - 1, col, col + #c[1], c[2] } end
      col = col + #c[1]
    end
    lines[row] = table.concat(parts)
  end
  -- like the inbox: a full-width split at the bottom, its header line first
  local title = "sepal" .. (opts and opts.title and " · " .. opts.title or "")
  table.insert(lines, 1, "")
  table.insert(lines, 1, title)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.b[buf].sepal_choose = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_extmark(buf, CHOOSE_NS, 0, 0, { end_col = 5, hl_group = "SepalTitle" })
  if #title > 5 then vim.api.nvim_buf_set_extmark(buf, CHOOSE_NS, 0, 5, { end_col = #title, hl_group = "SepalDim" }) end
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, CHOOSE_NS, m[1] + 2, m[2], { end_col = m[3], hl_group = m[4] })
  end
  local win = vim.api.nvim_open_win(buf, false, { split = "below", win = -1, noautocmd = true,
    height = math.max(1, math.min(#lines, vim.o.lines - 4)) })
  vim.wo[win].wrap, vim.wo[win].cursorline = false, false
  vim.wo[win].number, vim.wo[win].relativenumber, vim.wo[win].signcolumn, vim.wo[win].foldcolumn = false, false, "no", "0"
  vim.wo[win].fillchars = "eob: "
  vim.cmd.redraw()
  local ok, c = pcall(vim.fn.getcharstr)
  if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  vim.cmd.redraw()
  return ok and c or nil
end

-- a model picker, in the inbox and in a task draft: your agents' models, the models option's, the
-- current one if it's another, then d default and o one you type. cur == false: no current (several)
function M.pick_model(title, cur, set)
  local choices = {}
  local function add(m)
    if type(m) == "string" and m ~= "" and m ~= "default" and m ~= "other…" and not vim.tbl_contains(choices, m) then
      choices[#choices + 1] = m
    end
  end
  for _, m in ipairs(M.plan_models()) do add(m) end
  add(C.models.implement)
  add(C.models.btw)
  add(C.models.orchestrate)
  add(cur)
  local panel, by, items = require("sepal.panel"), {}, {}
  local agents, used, n = C.agents or {}, {}, #(C.agents or {})
  for i, a in ipairs(agents) do used[a.key or tostring(i)] = true end
  for _, m in ipairs(choices) do
    local k, ai
    for i, a in ipairs(agents) do
      if a.model == m then k, ai = a.key or tostring(i), a break end
    end
    local item = { current = m == cur }
    if ai then
      local l, short, name = who(nil, ai)
      item.icon, item.label, item.detail = l, name, short ~= name and short or nil
    else
      repeat n = n + 1 until not used[tostring(n)]
      k = tostring(n)
      local l, hl = panel.logo(m)
      item.icon, item.label = { l, hl }, panel.model(m)
    end
    item.key = k
    by[k] = by[k] or m
    items[#items + 1] = item
  end
  if #items > 0 then items[#items + 1] = { sep = true } end
  local dk, ok = used.d and "-" or "d", used.o and "/" or "o"
  items[#items + 1] = { key = dk, label = "default", label_hl = "SepalDim", current = cur == nil }
  items[#items + 1] = { key = ok, label = "other…", label_hl = "SepalDim" }
  local c = M.choose(items, { title = title })
  if by[c] then return set(by[c]) end
  if c == dk then return set(nil) end
  if c == ok then
    return vim.ui.input({ prompt = "model: " }, function(s)
      if s then set(require("sepal.agent").model_of(s)) end
    end)
  end
end
function M.pick(range)
  if M.draft() then return M.task(range) end
  -- each kind with its provider's logo and model, unless the agent is picked next
  local agents = C.agents or {}
  local items = {}
  for _, k in ipairs({ "l", "s", "b" }) do
    local item = { key = k, label = LABEL[KINDS[k]] }
    if #agents < 2 then
      local l, m, name = who(KINDS[k])
      item.detail_icon, item.detail = l, m or name
    end
    items[#items + 1] = item
  end
  local c = M.choose(items)
  if not KINDS[c] then return end
  if #agents < 2 then return M.task(range, nil, KINDS[c]) end
  -- then which agent: its key, else 1, 2… as listed in the agents option (any other key cancels)
  items = {}
  local by = {}
  for i, a in ipairs(agents) do
    local k = a.key or tostring(i)
    by[k] = by[k] or a
    local l, m, name = who(KINDS[c], a)
    items[#items + 1] = { key = k, icon = l, label = name, detail = m ~= name and m or nil }
  end
  local a = by[M.choose(items, { title = LABEL[KINDS[c]] })]
  if a then M.task(range, nil, KINDS[c], a) end
end

return M
