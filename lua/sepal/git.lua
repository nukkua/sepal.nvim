-- sepal.git — the git side of a task: its starting point, its worktree, its result, and landing it.
-- A task starts from what you see: your work tree, uncommitted and untracked files included, saved
-- as a commit through a temporary index (yours stays as it is). The agent works in a worktree of
-- that commit; its result is a commit too. Landing applies base -> result to your work tree as
-- unstaged changes, a three-way merge per file (git merge-file), so your edits meanwhile are kept.
-- Commits are kept alive by refs/sepal/<id>/*.

local M = {}

local ENV = { GIT_AUTHOR_NAME = "sepal", GIT_AUTHOR_EMAIL = "sepal@localhost",
  GIT_COMMITTER_NAME = "sepal", GIT_COMMITTER_EMAIL = "sepal@localhost" }

-- run git in dir: { code, stdout, stderr }
function M.run(dir, args, o)
  o = o or {}
  local ok, r = pcall(function()
    return vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = not o.binary, env = o.env, stdin = o.stdin }):wait()
  end)
  return ok and r or { code = -1, stdout = "", stderr = tostring(r) }
end
local function out(dir, args, o)
  local r = M.run(dir, args, o)
  if r.code ~= 0 then return nil, vim.trim(r.stderr or "") end
  return vim.trim(r.stdout)
end

-- the repo's top directory, as buffer names spell it (git resolves symlinks, a cwd reached
-- through one doesn't), or nil outside a repo
local roots = {} -- cwd -> its root: every :Sepal command asks; only found ones are kept (a `git init` later counts)
function M.root(cwd)
  local known = roots[cwd]
  if known and vim.uv.fs_stat(vim.fs.joinpath(known, ".git")) then return known end
  local root = out(cwd, { "rev-parse", "--show-toplevel" })
  if not root or root == "" then roots[cwd] = nil; return nil end
  local real = vim.uv.fs_realpath(cwd)
  if real and vim.startswith(real, root) and vim.endswith(cwd, real:sub(#root + 1)) then root = cwd:sub(1, #cwd - (#real - #root)) end
  roots[cwd] = root
  return root
end

-- the work tree (untracked files too, ignored ones not) as a commit on top of HEAD, through a copy of
-- the index, to on_done (nil if git failed); ref: where to keep it. add -A reads the whole work tree,
-- so it and write-tree run in the background: sending a task answers at once
function M.snapshot(root, ref, on_done)
  local idx = vim.fn.tempname()
  -- the index's path and HEAD in one call; a fresh repo has no HEAD (git fails, but prints the path first)
  local rp = M.run(root, { "rev-parse", "--git-path", "index", "--verify", "-q", "HEAD" })
  local lines = vim.split(vim.trim(rp.stdout or ""), "\n")
  local real, head = lines[1], rp.code == 0 and lines[2] or nil
  if real and real ~= "" then
    if not real:match("^/") then real = vim.fs.joinpath(root, real) end
    vim.uv.fs_copyfile(real, idx) -- no index yet (fresh repo): start empty
  end
  local env = vim.tbl_extend("force", ENV, { GIT_INDEX_FILE = idx })
  local function fail() os.remove(idx); on_done(nil) end
  local function step(args, cb)
    if not pcall(vim.system, vim.list_extend({ "git", "-C", root }, args), { text = true, env = env }, vim.schedule_wrap(cb)) then
      vim.schedule(fail)
    end
  end
  step({ "add", "-A" }, function(r)
    if r.code ~= 0 then return fail() end
    step({ "write-tree" }, function(w)
      os.remove(idx)
      on_done(w.code == 0 and M.commit(root, vim.trim(w.stdout), head, ref) or nil)
    end)
  end)
end

-- a commit of tree (with parent, if any) kept at ref
function M.commit(root, tree, parent, ref)
  local args = { "commit-tree", tree, "-m", "sepal" }
  if parent and parent ~= "" then vim.list_extend(args, { "-p", parent }) end
  local c = out(root, args, { env = ENV })
  if c and ref then M.run(root, { "update-ref", ref, c }) end
  return c
end

-- a worktree of commit at dir, made in the background (checking out a big repo takes a while):
-- on_done(ok, err) runs on the main loop. Returns the git process, to stop it
function M.add_worktree(root, dir, commit, on_done)
  vim.fn.mkdir(vim.fs.dirname(dir), "p")
  return vim.system({ "git", "-C", root, "worktree", "add", "--detach", "-f", dir, commit }, { text = true },
    vim.schedule_wrap(function(r) on_done(r.code == 0, vim.trim(r.stderr or "")) end))
end

-- the path is free at once (renamed aside: a retry or reply reuses it); deleting the checkout, slow
-- in a big repo, happens in the background, then git drops its record of it
function M.remove_worktree(root, dir)
  local trash = ("%s.old-%d"):format(dir, vim.uv.hrtime())
  if vim.uv.fs_rename(dir, trash) then
    local ok = pcall(vim.system, { "rm", "-rf", trash }, {}, vim.schedule_wrap(function()
      pcall(vim.system, { "git", "-C", root, "worktree", "prune" })
    end))
    if ok then return end
    dir = trash
  end
  if M.run(root, { "worktree", "remove", "--force", dir }).code == 0 then return end
  -- git couldn't (a half-made or already deleted worktree): delete it by hand, then drop git's record of it
  if vim.uv.fs_stat(dir) then vim.fn.delete(dir, "rf") end
  M.run(root, { "worktree", "prune" })
end

-- git in dir off the main loop: on_done(r) runs on it
local function bg(dir, args, o, on_done)
  local ok, err = pcall(vim.system, vim.list_extend({ "git", "-C", dir }, args), { text = true, env = o and o.env }, vim.schedule_wrap(on_done))
  if not ok then vim.schedule(function() on_done({ code = -1, stdout = "", stderr = tostring(err) }) end) end
end

-- what the agent left in its worktree, as a commit on top of base (nil if git failed), to on_done;
-- exclude: paths that aren't its work (what prepare made). In the background: add -A and the first
-- write-tree of a big checkout take a while
function M.result(root, wt, base, ref, exclude, on_done)
  bg(wt, { "add", "-A" }, { env = ENV }, function(r)
    if r.code ~= 0 then return on_done(nil) end
    if exclude and #exclude > 0 then M.run(wt, vim.list_extend({ "reset", "-q", "--" }, exclude)) end
    bg(wt, { "write-tree" }, nil, function(w)
      on_done(w.code == 0 and M.commit(root, vim.trim(w.stdout), base, ref) or nil)
    end)
  end)
end

-- files and lines changed from a to b: { files, add, del, list = { "path +1 −3", ... }, paths = { "path", ... } }
function M.stat(root, a, b)
  local s = { files = 0, add = 0, del = 0, list = {}, paths = {} }
  for line in (out(root, { "diff", "--numstat", "--no-renames", a, b }) or ""):gmatch("[^\n]+") do
    local add, del, path = line:match("^(%S+)%s+(%S+)%s+(.*)$")
    s.list[#s.list + 1] = path .. (tonumber(add) and (" +%s −%s"):format(add, del) or " binary")
    s.paths[#s.paths + 1] = path
    s.files, s.add, s.del = s.files + 1, s.add + (tonumber(add) or 0), s.del + (tonumber(del) or 0)
  end
  return s
end

-- path's content at rev, "" if it isn't there (added or deleted)
function M.file(root, rev, path)
  local r = M.run(root, { "show", rev .. ":" .. path })
  return r.code == 0 and r.stdout or ""
end

function M.delete_refs(root, prefix)
  local refs = out(root, { "for-each-ref", "--format=delete %(refname)", prefix }) or ""
  if refs ~= "" then M.run(root, { "update-ref", "--stdin" }, { stdin = refs .. "\n" }) end -- all of them in one go
end

local function readb(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end
local function writeb(path, s)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(s)
  f:close()
end
-- the contents of many blobs with one git process: { [oid] = content }; an object that isn't a blob
-- (a submodule's commit) or isn't there is left out
local function blobs(root, oids)
  if #oids == 0 then return {} end
  local r = M.run(root, { "cat-file", "--batch" }, { binary = true, stdin = table.concat(oids, "\n") .. "\n" })
  local got, s, pos = {}, r.code == 0 and r.stdout or "", 1
  while pos <= #s do
    local eol = s:find("\n", pos, true)
    if not eol then break end
    local oid, kind, size = s:sub(pos, eol - 1):match("^(%x+) (%S+) (%d+)$")
    if not oid then pos = eol + 1 -- "<oid> missing"
    else
      size = tonumber(size)
      if kind == "blob" then got[oid] = s:sub(eol + 1, eol + size) end
      pos = eol + size + 2 -- the content, then its "\n"
    end
  end
  return got
end
local function merge3(root, cur, base, theirs)
  local t = { vim.fn.tempname(), vim.fn.tempname(), vim.fn.tempname() }
  writeb(t[1], cur); writeb(t[2], base); writeb(t[3], theirs)
  local r = M.run(root, { "merge-file", "-p", "-L", "yours", "-L", "base", "-L", "sepal", t[1], t[2], t[3] }, { binary = true })
  for _, p in ipairs(t) do os.remove(p) end
  return r.code >= 0 and r.code < 128 and r.stdout or nil, r.code ~= 0
end

-- what applying a -> b to the work tree would do: { { rel, path, content (nil: delete), conflict } }
function M.plan(root, a, b)
  local changes, files, oids = {}, {}, {}
  -- ":<mode> <mode> <old oid> <new oid> <status>\0<path>\0" per file; the blobs come in one batch below
  local r = M.run(root, { "diff", "--raw", "-z", "--no-renames", "--no-abbrev", a, b })
  local raw = vim.split(r.code == 0 and r.stdout or "", "\0", { plain = true })
  for i = 1, #raw - 1, 2 do
    local old, new, status = raw[i]:match("^:%d+ %d+ (%x+) (%x+) (%a)")
    if old then
      files[#files + 1] = { status = status, rel = raw[i + 1], old = old, new = new }
      if status ~= "A" then oids[#oids + 1] = old end
      if status ~= "D" then oids[#oids + 1] = new end
    end
  end
  local blob = blobs(root, oids)
  for _, f in ipairs(files) do
    local status, rel = f.status, f.rel
    local path = vim.fs.joinpath(root, rel)
    local cur, old, new = readb(path), status ~= "A" and blob[f.old] or nil, status ~= "D" and blob[f.new] or nil
    local c = { rel = rel, path = path }
    if cur == new then c.skip = true -- already like that
    elseif cur == old then c.content = new -- you didn't touch it: take theirs (or delete)
    elseif new == nil or cur == nil then c.conflict, c.content = true, cur -- deleted on one side, changed on the other
    elseif (old or ""):find("\0", 1, true) or new:find("\0", 1, true) or cur:find("\0", 1, true) then c.conflict, c.content = true, cur -- binary
    else
      local merged, conflict = merge3(root, cur, old or "", new)
      c.content, c.conflict = merged or cur, conflict or not merged
    end
    if not c.skip then changes[#changes + 1] = c end
  end
  return changes
end

-- carry out a plan: write (or delete) each file
function M.apply(changes)
  for _, c in ipairs(changes) do
    if c.content == nil then os.remove(c.path) else writeb(c.path, c.content) end
  end
end

return M
