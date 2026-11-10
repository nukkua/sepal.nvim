-- sepal.git — the git side of a spec: its starting point, its worktree, its result, and landing it.
-- A spec starts from what you see: your work tree, uncommitted and untracked files included, saved
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
function M.root(cwd)
  local root = out(cwd, { "rev-parse", "--show-toplevel" })
  if not root or root == "" then return nil end
  local real = vim.uv.fs_realpath(cwd)
  if real and vim.startswith(real, root) and vim.endswith(cwd, real:sub(#root + 1)) then return cwd:sub(1, #cwd - (#real - #root)) end
  return root
end

-- the work tree (untracked files too, ignored ones not) as a commit on top of HEAD, through a copy of
-- the index; ref: where to keep it
function M.snapshot(root, ref)
  local idx = vim.fn.tempname()
  local real = out(root, { "rev-parse", "--git-path", "index" })
  if real and real ~= "" then
    if not real:match("^/") then real = vim.fs.joinpath(root, real) end
    vim.uv.fs_copyfile(real, idx) -- no index yet (fresh repo): start empty
  end
  local env = vim.tbl_extend("force", ENV, { GIT_INDEX_FILE = idx })
  local tree = M.run(root, { "add", "-A" }, { env = env }).code == 0 and out(root, { "write-tree" }, { env = env })
  os.remove(idx)
  if not tree then return nil end
  return M.commit(root, tree, out(root, { "rev-parse", "--verify", "-q", "HEAD" }), ref)
end

-- a commit of tree (with parent, if any) kept at ref
function M.commit(root, tree, parent, ref)
  local args = { "commit-tree", tree, "-m", "sepal" }
  if parent and parent ~= "" then vim.list_extend(args, { "-p", parent }) end
  local c = out(root, args, { env = ENV })
  if c and ref then M.run(root, { "update-ref", ref, c }) end
  return c
end

-- a worktree of commit at dir; nil, err when it can't be made
function M.add_worktree(root, dir, commit)
  vim.fn.mkdir(vim.fs.dirname(dir), "p")
  local r = M.run(root, { "worktree", "add", "--detach", "-f", dir, commit })
  if r.code ~= 0 then return nil, vim.trim(r.stderr) end
  return dir
end

function M.remove_worktree(root, dir)
  M.run(root, { "worktree", "remove", "--force", dir })
  if vim.uv.fs_stat(dir) then vim.fn.delete(dir, "rf") end
  M.run(root, { "worktree", "prune" })
end

-- what the agent left in its worktree, as a commit on top of base; exclude: paths that aren't its
-- work (what prepare made)
function M.result(root, wt, base, ref, exclude)
  if M.run(wt, { "add", "-A" }, { env = ENV }).code ~= 0 then return nil end
  if exclude and #exclude > 0 then M.run(wt, vim.list_extend({ "reset", "-q", "--" }, exclude)) end
  local tree = out(wt, { "write-tree" })
  return tree and M.commit(root, tree, base, ref)
end

-- files and lines changed from a to b: { files, add, del }
function M.stat(root, a, b)
  local s = { files = 0, add = 0, del = 0 }
  for line in (out(root, { "diff", "--numstat", "--no-renames", a, b }) or ""):gmatch("[^\n]+") do
    local add, del = line:match("^(%S+)%s+(%S+)")
    s.files, s.add, s.del = s.files + 1, s.add + (tonumber(add) or 0), s.del + (tonumber(del) or 0)
  end
  return s
end

function M.diff(root, a, b) return out(root, { "diff", "--no-renames", a, b }) or "" end

function M.delete_refs(root, prefix)
  for ref in (out(root, { "for-each-ref", "--format=%(refname)", prefix }) or ""):gmatch("[^\n]+") do
    M.run(root, { "update-ref", "-d", ref })
  end
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
local function blob(root, commit, rel)
  local r = M.run(root, { "cat-file", "-p", commit .. ":" .. rel }, { binary = true })
  return r.code == 0 and r.stdout or nil
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
  local changes = {}
  local names = vim.split(out(root, { "diff", "--name-status", "--no-renames", "-z", a, b }) or "", "\0", { plain = true })
  for i = 1, #names - 1, 2 do
    local status, rel = names[i], names[i + 1]
    local path = vim.fs.joinpath(root, rel)
    local cur, old, new = readb(path), status ~= "A" and blob(root, a, rel) or nil, status ~= "D" and blob(root, b, rel) or nil
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
