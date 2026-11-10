-- sepal.review — what a spec run changed, reviewed in the buffers themselves
-- Before a run the work tree is saved as a git tree (untracked files too, your index untouched);
-- after it, every file that differs (and that you didn't save yourself meanwhile) keeps its
-- before-text as a "base". The difference between base and the buffer is shown as hunks: changed
-- lines highlighted, removed lines as virtual lines. Accepting a hunk moves it into the base,
-- rejecting it puts the base text back in the buffer. A file is done when buffer == base.
-- ponytail: bases live in memory, a restarted nvim has nothing to review; your own edits to a
-- file under review (unsaved, or saved before the run) show up as hunks too

local M = {}

local NS = vim.api.nvim_create_namespace("sepal.review")
for k, v in pairs({ SepalAdd = "DiffAdd", SepalChange = "DiffChange", SepalDelete = "DiffDelete",
  SepalAddSign = "Added", SepalChangeSign = "Changed", SepalDeleteSign = "Removed" }) do
  vim.api.nvim_set_hl(0, k, { link = v, default = true })
end

-- files[abs path] = { base = lines before the agent, new = the agent created it }
local R = { files = {} }
local diff = (vim.text and vim.text.diff) or vim.diff

local function git(root, args, env)
  local ok, r = pcall(function() return vim.system(vim.list_extend({ "git", "-C", root }, args), { text = true, env = env }):wait() end)
  return ok and r or { code = -1, stdout = "", stderr = tostring(r) }
end

-- "a\nb\n" -> { "a", "b" }; an empty file and a file that is one empty line are both {}
local function lines_of(text)
  local l = vim.split(text, "\n", { plain = true })
  if l[#l] == "" then l[#l] = nil end
  if #l == 1 and l[1] == "" then l = {} end
  return l
end
local function text_of(l) return #l > 0 and table.concat(l, "\n") .. "\n" or "" end

-- the work tree as a git tree object, through a copy of the index so yours stays as it is
local function snapshot(root)
  local idx = vim.fn.tempname()
  local real = vim.trim(git(root, { "rev-parse", "--git-path", "index" }).stdout)
  if real ~= "" then
    if not real:match("^/") then real = vim.fs.joinpath(root, real) end
    vim.uv.fs_copyfile(real, idx) -- no index yet (fresh repo): start empty
  end
  local env = { GIT_INDEX_FILE = idx }
  local tree = git(root, { "add", "-A" }, env).code == 0 and vim.trim(git(root, { "write-tree" }, env).stdout) or ""
  os.remove(idx)
  return tree ~= "" and tree or nil
end

local function bufof(path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == path then return b end
  end
end

-- what the file holds now: its buffer if loaded, else the disk ({} if it's gone)
local function current(path)
  local b = bufof(path)
  if b then return lines_of(table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")), b end
  local f = io.open(path)
  if not f then return {} end
  local t = f:read("a")
  f:close()
  return lines_of(t)
end

-- { start_base, count_base, start_now, count_now } per hunk (a count of 0: after that line)
local function hunks(path, now)
  local f = R.files[path]
  if not f then return {} end
  return diff(text_of(f.base), text_of(now or current(path)), { result_type = "indices" })
end

local function slice(l, from, n) return vim.list_slice(l, from, from + n - 1) end

-- the first line a hunk covers in the buffer (1-based), where the cursor lands on it
local function top(h) return math.max(h[3], 1) end

local keymaps -- set below, once M.keys is known

local function forget(path)
  R.files[path] = nil
  local b = bufof(path)
  if not b then return end
  vim.api.nvim_buf_clear_namespace(b, NS, 0, -1)
  if vim.b[b].sepal_review then
    vim.b[b].sepal_review = nil
    for _, lhs in pairs(M.keys) do pcall(vim.keymap.del, "n", lhs, { buffer = b }) end
  end
end

local function render(b)
  if not vim.api.nvim_buf_is_valid(b) then return end
  local path = vim.api.nvim_buf_get_name(b)
  local f = R.files[path]
  vim.api.nvim_buf_clear_namespace(b, NS, 0, -1)
  if not f then return end
  local now = current(path)
  local hs = hunks(path, now)
  if #hs == 0 then return forget(path) end
  if not vim.b[b].sepal_review then vim.b[b].sepal_review = true; keymaps(b) end
  local width, ts = vim.o.columns, string.rep(" ", vim.bo[b].tabstop)
  for _, h in ipairs(hs) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    for l = sb, sb + cb - 1 do
      vim.api.nvim_buf_set_extmark(b, NS, l - 1, 0, { line_hl_group = ca == 0 and "SepalAdd" or "SepalChange",
        sign_text = "▎", sign_hl_group = ca == 0 and "SepalAddSign" or "SepalChangeSign" })
    end
    if ca > 0 then
      local vl = {}
      for _, line in ipairs(slice(f.base, sa, ca)) do
        line = line:gsub("\t", ts)
        vl[#vl + 1] = { { line .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(line))), "SepalDelete" } }
      end
      local above = cb > 0 or sb == 0 or #now == 0
      local row = math.min(math.max(sb - 1, 0), vim.api.nvim_buf_line_count(b) - 1) -- above its first line, or below the line it follows
      vim.api.nvim_buf_set_extmark(b, NS, row, 0, { virt_lines = vl, virt_lines_above = above,
        sign_text = cb == 0 and "▁" or nil, sign_hl_group = cb == 0 and "SepalDeleteSign" or nil })
    end
  end
end

-- re-render everything under review that is loaded
local function render_all()
  for path in pairs(R.files) do
    local b = bufof(path)
    if b then render(b) else if #hunks(path) == 0 then forget(path) end end
  end
end

local function hunk_at(b)
  local path, l = vim.api.nvim_buf_get_name(b), vim.api.nvim_win_get_cursor(0)[1]
  for _, h in ipairs(hunks(path)) do
    local s = top(h)
    if l >= s and l <= math.max(s, h[3] + h[4] - 1) then return h, path end
  end
end

local function save(b)
  if vim.bo[b].modified then vim.api.nvim_buf_call(b, function() vim.cmd("silent write ++p") end) end
end

-- give a file its base back: the buffer if loaded (and written), else the disk; a file the agent
-- created is deleted
local function restore(path)
  local f, b = R.files[path], bufof(path)
  if f.new then
    os.remove(path)
    if b then vim.api.nvim_buf_set_lines(b, 0, -1, false, {}); vim.bo[b].modified = false end
  elseif b then
    vim.api.nvim_buf_set_lines(b, 0, -1, false, f.base)
    save(b)
  else
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(f.base, path)
  end
  forget(path)
end

local function all_paths()
  local p = vim.tbl_keys(R.files)
  table.sort(p)
  return p
end

-- the hunk under the cursor: into the base (accept) or replaced by it (reject)
function M.accept()
  local b = vim.api.nvim_get_current_buf()
  local h, path = hunk_at(b)
  if not h then return require("sepal").notify("no change under the cursor") end
  local f, now = R.files[path], current(path)
  local pre = h[2] == 0 and h[1] or h[1] - 1
  local base = vim.list_slice(f.base, 1, pre)
  vim.list_extend(base, slice(now, h[3], h[4]))
  f.base = vim.list_extend(base, vim.list_slice(f.base, pre + h[2] + 1))
  render(b)
end

function M.reject()
  local b = vim.api.nvim_get_current_buf()
  local h, path = hunk_at(b)
  if not h then return require("sepal").notify("no change under the cursor") end
  local f = R.files[path]
  local old = slice(f.base, h[1], h[2])
  if #current(path) == 0 then
    vim.api.nvim_buf_set_lines(b, 0, -1, false, old) -- an empty buffer is one "" line: replace it
  else
    local s = h[4] == 0 and h[3] or h[3] - 1
    vim.api.nvim_buf_set_lines(b, s, s + h[4], false, old)
  end
  if f.new and #current(path) == 0 then return restore(path) end
  save(b)
  render(b)
end

function M.accept_all()
  for _, p in ipairs(all_paths()) do forget(p) end
  require("sepal").notify("accepted everything")
end

function M.reject_all()
  local n = #all_paths()
  for _, p in ipairs(all_paths()) do restore(p) end
  require("sepal").notify(("put %d file%s back as before"):format(n, n == 1 and "" or "s"))
end

-- the next (d = 1) or previous (-1) hunk; past the last one of this file, the next file's first
function M.jump(d)
  require("sepal").seen()
  local paths = all_paths()
  if #paths == 0 then return require("sepal").notify("nothing to review") end
  local path, l = vim.api.nvim_buf_get_name(0), vim.api.nvim_win_get_cursor(0)[1]
  local tops = vim.tbl_map(top, hunks(path))
  for i = d > 0 and 1 or #tops, d > 0 and #tops or 1, d do
    if (d > 0 and tops[i] > l) or (d < 0 and tops[i] < l) then return vim.api.nvim_win_set_cursor(0, { tops[i], 0 }) end
  end
  local at = 0
  for i, p in ipairs(paths) do if p == path then at = i end end
  if at == 0 and d < 0 then at = 1 end
  local nxt = paths[(at - 1 + d) % #paths + 1]
  if nxt == path and #tops > 0 then return require("sepal").notify(d > 0 and "last change" or "first change") end
  vim.cmd.edit(vim.fn.fnameescape(vim.fn.fnamemodify(nxt, ":.")))
  local hs = hunks(nxt)
  if #hs > 0 then vim.api.nvim_win_set_cursor(0, { math.min(top(d > 0 and hs[1] or hs[#hs]), vim.api.nvim_buf_line_count(0)), 0 }) end
end

-- every hunk in the quickfix list, and the cursor on the first
function M.open()
  require("sepal").seen()
  local items = {}
  for _, p in ipairs(all_paths()) do
    local now = current(p)
    for _, h in ipairs(hunks(p, now)) do
      local first = now[h[3]] or R.files[p].base[h[1]] or ""
      items[#items + 1] = { filename = vim.fn.fnamemodify(p, ":."), lnum = top(h), text = ("+%d -%d  %s"):format(h[4], h[2], vim.trim(first)) }
    end
  end
  if #items == 0 then return require("sepal").notify("nothing to review") end
  vim.fn.setqflist({}, " ", { title = "sepal review", items = items })
  vim.cmd("silent cfirst")
end

-- { hunks, files } still to review
function M.count()
  local n, f = 0, 0
  for _, p in ipairs(all_paths()) do
    local k = #hunks(p)
    if k > 0 then n, f = n + k, f + 1 end
  end
  return n, f
end

-- before a run: the snapshot to compare with afterwards, or nil outside a git repo
function M.begin(cwd)
  local root = vim.trim(git(cwd, { "rev-parse", "--show-toplevel" }).stdout)
  if root == "" then return nil end
  local h = { root = root, tree = snapshot(root), saved = {}, view = root }
  if not h.tree then return nil end
  -- the root as buffer names spell it: git resolves symlinks, a cwd reached through one doesn't
  local real = vim.uv.fs_realpath(cwd)
  if real and vim.startswith(real, root) and vim.endswith(cwd, real:sub(#root + 1)) then h.view = cwd:sub(1, #cwd - (#real - #root)) end
  -- files you write during the run are yours, not the agent's
  h.au = vim.api.nvim_create_autocmd("BufWritePost", { callback = function(a) h.saved[vim.api.nvim_buf_get_name(a.buf)] = true end })
  return h
end

-- after a run: reload what the agent changed and add its files to the review
function M.finish(h)
  pcall(vim.cmd, "silent! checktime")
  if not h then return end
  pcall(vim.api.nvim_del_autocmd, h.au)
  local after = snapshot(h.root)
  if not after then return end
  local out = git(h.root, { "diff-tree", "-r", "--no-renames", "-z", "--name-status", h.tree, after }).stdout
  local parts = vim.split(out, "\0", { plain = true })
  for i = 1, #parts - 1, 2 do
    local status, rel = parts[i], parts[i + 1]
    local path = vim.fs.joinpath(h.view, rel)
    local b = bufof(path) -- :checktime alone leaves hidden buffers as they were
    if b then vim.api.nvim_buf_call(b, function() pcall(vim.cmd, "silent! checktime") end) end
    if not h.saved[path] and not R.files[path] then -- already under review: keep the older base
      local blob = status ~= "A" and git(h.root, { "cat-file", "-p", h.tree .. ":" .. rel }).stdout or ""
      if not blob:find("\0", 1, true) then R.files[path] = { base = lines_of(blob), new = status == "A" } end -- binary: skipped
    end
  end
  render_all()
end

M.keys = { next = "]r", prev = "[r", accept = "<c-c><c-y>", reject = "<c-c><c-n>" }
keymaps = function(b)
  local o = function(desc) return { buffer = b, desc = desc } end
  local k = M.keys
  if k.next then vim.keymap.set("n", k.next, function() M.jump(1) end, o("Next change of the agent")) end
  if k.prev then vim.keymap.set("n", k.prev, function() M.jump(-1) end, o("Previous change of the agent")) end
  if k.accept then vim.keymap.set("n", k.accept, M.accept, o("Accept this change of the agent")) end
  if k.reject then vim.keymap.set("n", k.reject, M.reject, o("Reject this change of the agent")) end
end

vim.api.nvim_create_autocmd({ "BufWinEnter", "BufReadPost", "TextChanged", "InsertLeave", "BufWritePost" }, {
  group = vim.api.nvim_create_augroup("sepal.review", {}),
  callback = function(a) if R.files[vim.api.nvim_buf_get_name(a.buf)] then render(a.buf) end end,
})

M._t = { files = function() return R.files end, hunks = hunks, NS = NS }

return M
