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

-- git in dir off the main loop: on_done(r) runs on it
local function bg(dir, args, o, on_done)
  local ok, err = pcall(vim.system, vim.list_extend({ "git", "-C", dir }, args), { text = not (o and o.binary), env = o and o.env, stdin = o and o.stdin }, vim.schedule_wrap(on_done))
  if not ok then vim.schedule(function() on_done({ code = -1, stdout = "", stderr = tostring(err) }) end) end
end

-- each of refs pointing at commit, in one git process off the main loop, to cb(ok)
function M.update_refs_bg(root, refs, commit, cb)
  if #refs == 0 then return vim.schedule(function() cb(true) end) end
  local stdin = table.concat(vim.tbl_map(function(r) return ("update %s %s\n"):format(r, commit) end, refs))
  bg(root, { "update-ref", "--stdin" }, { stdin = stdin }, function(r) cb(r.code == 0) end)
end

-- a commit of tree (with parent, if any) kept at ref, to cb(commit or nil): git runs off the
-- main loop — a finishing agent doesn't freeze the editor
function M.commit_bg(root, tree, parent, ref, cb)
  local args = { "commit-tree", tree, "-m", "sepal" }
  if parent and parent ~= "" then vim.list_extend(args, { "-p", parent }) end
  bg(root, args, { env = ENV }, function(r)
    local c = r.code == 0 and vim.trim(r.stdout) or nil
    if not c then return cb(nil) end
    bg(root, { "update-ref", ref, c }, nil, function() cb(c) end)
  end)
end

-- the work tree (untracked files too, ignored ones not) as a commit on top of HEAD, through a copy of
-- the index, to on_done (nil if git failed); ref: where to keep it. add -A reads the whole work tree,
-- so it and write-tree run in the background: sending a task answers at once
function M.snapshot(root, ref, on_done)
  local idx = vim.fn.tempname()
  local env = vim.tbl_extend("force", ENV, { GIT_INDEX_FILE = idx })
  local function fail() os.remove(idx); on_done(nil) end
  local function step(args, cb)
    if not pcall(vim.system, vim.list_extend({ "git", "-C", root }, args), { text = true, env = env }, vim.schedule_wrap(cb)) then
      vim.schedule(fail)
    end
  end
  -- the index's path and HEAD in one call (no GIT_INDEX_FILE: it must name yours); a fresh repo
  -- has no HEAD (git fails, but prints the path first)
  bg(root, { "rev-parse", "--git-path", "index", "--verify", "-q", "HEAD" }, nil, function(rp)
    local lines = vim.split(vim.trim(rp.stdout or ""), "\n")
    local real, head = lines[1], rp.code == 0 and lines[2] or nil
    if real and real ~= "" then
      if not real:match("^/") then real = vim.fs.joinpath(root, real) end
      vim.uv.fs_copyfile(real, idx) -- no index yet (fresh repo): start empty
    end
    step({ "add", "-A" }, function(r)
      if r.code ~= 0 then return fail() end
      step({ "write-tree" }, function(w)
        os.remove(idx)
        if w.code ~= 0 then return on_done(nil) end
        M.commit_bg(root, vim.trim(w.stdout), head, ref, on_done)
      end)
    end)
  end)
end

-- a worktree of commit at dir, made in the background (checking out a big repo takes a while):
-- on_done(ok, err) runs on the main loop. Returns the git process, to stop it
function M.add_worktree(root, dir, commit, on_done)
  vim.fn.mkdir(vim.fs.dirname(dir), "p")
  return vim.system({ "git", "-C", root, "worktree", "add", "--detach", "-f", dir, commit }, { text = true },
    vim.schedule_wrap(function(r) on_done(r.code == 0, vim.trim(r.stderr or "")) end))
end

-- the path is free at once (renamed aside: a retry or reply reuses it) and git's record of it goes;
-- deleting the checkout, slow in a big repo, happens in the background. Not `git worktree prune`:
-- it would delete the record of a worktree another `worktree add` is making right then
function M.remove_worktree(root, dir)
  local trash = ("%s.old-%d"):format(dir, vim.uv.hrtime())
  if vim.uv.fs_rename(dir, trash) then
    local f = io.open(trash .. "/.git")
    local admin = f and f:read("*l"):match("^gitdir: (.+)$")
    if f then f:close() end
    if admin then vim.fn.delete(admin, "rf") end
    local ok = pcall(vim.system, { "rm", "-rf", trash })
    if ok then return end
    dir = trash
  end
  if M.run(root, { "worktree", "remove", "--force", dir }).code == 0 then return end
  -- git couldn't (a half-made or already deleted worktree): delete it by hand, then drop git's record of it
  if vim.uv.fs_stat(dir) then vim.fn.delete(dir, "rf") end
  M.run(root, { "worktree", "prune" })
end

-- what the agent left in its worktree, as a commit on top of base (nil if git failed), to on_done;
-- exclude: paths that aren't its work (what prepare made). In the background: add -A and the first
-- write-tree of a big checkout take a while
function M.result(root, wt, base, ref, exclude, on_done)
  bg(wt, { "add", "-A" }, { env = ENV }, function(r)
    if r.code ~= 0 then return on_done(nil) end
    local function tree()
      bg(wt, { "write-tree" }, nil, function(w)
        if w.code ~= 0 then return on_done(nil) end
        M.commit_bg(root, vim.trim(w.stdout), base, ref, on_done)
      end)
    end
    if exclude and #exclude > 0 then bg(wt, vim.list_extend({ "reset", "-q", "--" }, exclude), nil, tree)
    else tree() end
  end)
end

-- the numstat of a -> b parsed: { files, add, del, list = { "path +1 −3", ... }, paths = { "path", ... } }
local ESC = { ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function esc(c) return ESC[c] or ("\\%03o"):format(c:byte()) end
local function stat_of(s)
  local st = { files = 0, add = 0, del = 0, list = {}, paths = {} }
  for line in s:gmatch("[^%z]+") do
    local add, del, path = line:match("^(%S+)\t(%S+)\t(.*)$")
    local display = path:find("%c") and (path:gsub("%c", esc)) or path
    st.list[#st.list + 1] = display .. (tonumber(add) and (" +%s −%s"):format(add, del) or " binary")
    st.paths[#st.paths + 1] = path
    st.files, st.add, st.del = st.files + 1, st.add + (tonumber(add) or 0), st.del + (tonumber(del) or 0)
  end
  return st
end

local function unquote(path)
  if path:sub(1, 1) ~= '"' then return path end
  local out, i = {}, 2
  local escapes = { a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v" }
  while i < #path do
    local c = path:sub(i, i)
    if c == "\\" then
      local oct = path:sub(i + 1):match("^([0-7][0-7][0-7])")
      if oct then c, i = string.char(tonumber(oct, 8)), i + 4
      else c, i = escapes[path:sub(i + 1, i + 1)] or path:sub(i + 1, i + 1), i + 2 end
    else i = i + 1 end
    out[#out + 1] = c
  end
  return table.concat(out)
end

-- the -U0 diff of a -> b parsed: { [path] = line of its first change }
local function firsts_of(s)
  local t, path = {}, nil
  for l in s:gmatch("[^\n]+") do
    local b = l:byte(1)
    if b == 43 then
      local header = l:match("^%+%+%+ (.*)$")
      if header then path = unquote((header:gsub("\t$", ""))):match("^b/(.*)$") end
    elseif b == 64 then
      local n = l:match("^@@ %-%S+ %+(%d+)")
      if n and path and not t[path] then t[path] = math.max(1, tonumber(n)) end
    end
  end
  return t
end

local NUMSTAT = function(a, b) return { "diff", "--numstat", "-z", "--no-renames", a, b } end
local FIRSTS = function(a, b) return { "diff", "-U0", "--no-renames", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/", a, b } end

-- files and lines changed from a to b, to cb(st): the diff runs off the main loop
function M.stat_bg(root, a, b, cb)
  bg(root, NUMSTAT(a, b), nil, function(r) cb(stat_of(r.code == 0 and r.stdout or "")) end)
end

-- a git process started, not waited: { p } or nil when it couldn't start
local function start(root, args, o)
  local ok, p = pcall(vim.system, vim.list_extend({ "git", "-C", root }, args), o or { text = true })
  return ok and p or nil
end
local function text(p)
  local r = p and p:wait() or { code = -1, stdout = "" }
  return r.code == 0 and r.stdout or ""
end

-- stat and firsts of a -> b at once: the two diffs run concurrently. on_stat(st) runs
-- once the numstat is in, while the -U0 diff may still run — for work that only needs the paths;
-- its return value is this call's third
function M.review(root, a, b, on_stat)
  local num, uni = start(root, NUMSTAT(a, b)), start(root, FIRSTS(a, b))
  local st = stat_of(text(num))
  local extra = on_stat(st)
  return st, firsts_of(text(uni)), extra
end

-- delete every ref under a list of prefixes, then cb() (at once when there is nothing): one
-- for-each-ref + one update-ref, off the main loop
function M.delete_refs_bg(root, prefixes, cb)
  cb = cb or function() end
  bg(root, vim.list_extend({ "for-each-ref", "--format=delete %(refname)" }, prefixes), nil, function(r)
    local refs = vim.trim(r.code == 0 and r.stdout or "")
    if refs == "" then return cb() end
    bg(root, { "update-ref", "--stdin" }, { stdin = refs .. "\n" }, function() cb() end) -- all of them in one go
  end)
end

-- dir's porcelain status ("" on failure) to cb, off the main loop
function M.status_bg(dir, cb)
  bg(dir, { "status", "--porcelain=v1", "-z", "--untracked-files=normal" }, { binary = true }, function(r)
    cb(r.code == 0 and r.stdout or "")
  end)
end

local function readb(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end
local function writeb(path, s)
  local f = assert(io.open(path, "wb"))
  f:write(s)
  f:close()
end
-- cat-file --batch -Z's stdout parsed as a list in the specs' order: content, or nil where the
-- record's header was "<name> missing"/"<name> ambiguous" or the object isn't a blob
local function batch_of(s, n)
  local got, pos = {}, 1
  for i = 1, n do
    local eol = s:find("\0", pos, true)
    if not eol then break end
    local kind, size = s:sub(pos, eol - 1):match("^%x+ (%S+) (%d+)$")
    if not kind then pos = eol + 1 -- "<name> missing" / "<name> ambiguous"
    else
      size = tonumber(size)
      if kind == "blob" then got[i] = s:sub(eol + 1, eol + size) end
      pos = eol + size + 2 -- the content, then its NUL
    end
  end
  return got
end

-- cat-file --batch for specs, started not waited; files_wait's handle
function M.files_start(root, specs)
  if #specs == 0 then return nil end
  local p = start(root, { "cat-file", "--batch", "-Z" }, { stdin = table.concat(specs, "\0") .. "\0" })
  return p and { p = p, n = #specs } or nil
end

-- what files_start's process read: the parsed list (see batch_of)
function M.files_wait(h)
  local r = h and h.p:wait() or { code = -1, stdout = "" }
  return batch_of(h and r.code == 0 and r.stdout or "", h and h.n or 0)
end

-- the contents of many objects with one git process, in specs' order (specs: oids or names like
-- rev:path); nil where an object is missing or not a blob (a submodule's commit)
function M.files(root, specs)
  return M.files_wait(M.files_start(root, specs))
end

-- what a file is right now, as plan and its freshness check see it: a git-ish mode
-- ("000000"/"120000"/"100755"/"100644"/"other") and its content (readlink or readb)
local function observe(path)
  local st = vim.uv.fs_lstat(path)
  local mode = not st and "000000" or st.type == "link" and "120000"
    or st.type == "file" and (bit.band(st.mode, 64) ~= 0 and "100755" or "100644") or "other"
  local cur = st and (st.type == "link" and vim.uv.fs_readlink(path) or st.type == "file" and readb(path)) or nil
  return mode, cur
end

-- ":<mode> <mode> <old oid> <new oid> <status>\0<path>\0" per file -> the files, and the oids to read
local function parse_diff(s)
  local files, oids = {}, {}
  local raw = vim.split(s, "\0", { plain = true })
  for i = 1, #raw - 1, 2 do
    local oldmode, newmode, old, new, status = raw[i]:match("^:(%d+) (%d+) (%x+) (%x+) (%a)")
    if old then
      files[#files + 1] = { status = status, rel = raw[i + 1], old = old, new = new, oldmode = oldmode, newmode = newmode }
      if status ~= "A" then oids[#oids + 1] = old end
      if status ~= "D" then oids[#oids + 1] = new end
    end
  end
  return files, oids
end

local function merge3(root, c, cur, base, theirs, done)
  local base_ = vim.fn.tempname()
  local t = { base_ .. ".1", base_ .. ".2", base_ .. ".3" }
  writeb(t[1], cur); writeb(t[2], base); writeb(t[3], theirs)
  local function finish(r)
    for _, p in ipairs(t) do os.remove(p) end
    local merged = r.code >= 0 and r.code < 128 and r.stdout or nil
    c.content, c.conflict = merged or cur, r.code ~= 0 or not merged
    done()
  end
  -- no wait: every file's merge runs at once (see decide); its temp files go when it exits
  if not pcall(vim.system, vim.list_extend({ "git", "-C", root },
    { "merge-file", "-p", "-L", "yours", "-L", "base", "-L", "sepal", t[1], t[2], t[3] }), { text = false }, vim.schedule_wrap(finish)) then
    vim.schedule(function() finish({ code = -1, stdout = "" }) end)
  end
end

-- the change each file of files needs to apply a -> b, against blob (oid -> content); skipped ones
-- are left out, every kept one gets .seen (what it observed, for plan_bg's freshness check). The
-- merges run off the main loop: on_done(changes) when the last exits (at once when there are none)
local function decide(root, files, blob, on_done)
  local changes, pending = {}, 0
  local linked = {}
  local function linked_above(path)
    local dir, seen, res = vim.fs.dirname(path), {}, nil
    while dir ~= root and dir ~= vim.fs.dirname(dir) do
      if linked[dir] ~= nil then res = linked[dir]; break end
      seen[#seen + 1] = dir
      local p = vim.uv.fs_lstat(dir)
      if p and p.type == "link" then res = true; break end
      dir = vim.fs.dirname(dir)
    end
    for _, d in ipairs(seen) do linked[d] = res or false end
    return res == true
  end
  for _, f in ipairs(files) do
    local status, rel = f.status, f.rel
    local path = vim.fs.joinpath(root, rel)
    local mode, cur = observe(path)
    local old, new = status ~= "A" and blob[f.old] or nil, status ~= "D" and blob[f.new] or nil
    local c = { rel = rel, path = path, seen = { mode = mode, cur = cur } }
    c.mode = mode == f.oldmode and f.newmode or mode
    if linked_above(path) or mode == "other" or f.oldmode == "160000" or f.newmode == "160000" then
      c.conflict, c.preserve = true, true
    elseif mode == "120000" or f.oldmode == "120000" or f.newmode == "120000" then
      if cur == new and mode == f.newmode then c.skip = true
      elseif cur == old and mode == f.oldmode then c.content, c.mode = new, f.newmode
      else c.conflict, c.preserve = true, true end
    elseif cur == new then c.skip, c.content = mode == c.mode, cur -- content already like that; the mode may differ
    elseif cur == old then c.content = new -- you didn't touch it: take theirs (or delete)
    elseif new == nil or cur == nil then c.conflict, c.content = true, cur -- deleted on one side, changed on the other
    elseif (old or ""):find("\0", 1, true) or new:find("\0", 1, true) or cur:find("\0", 1, true) then c.conflict, c.content = true, cur -- binary
    else
      pending = pending + 1
      merge3(root, c, cur, old or "", new, function()
        pending = pending - 1
        if pending == 0 then on_done(changes) end
      end)
    end
    if not c.skip then changes[#changes + 1] = c end
  end
  if pending == 0 then on_done(changes) end
end

-- what applying a -> b to the work tree would do, to cb({ { rel, path, content (nil: delete),
-- conflict } } — nil when a file kept changing under it after 3 tries). The diff, the objects and
-- every merge run off the main loop; before cb each file is observed once more and cb runs in that
-- same tick, so what it checked and what the caller applies can't drift apart
function M.plan_bg(root, a, b, cb, tries)
  tries = tries or 0
  bg(root, { "diff", "--raw", "-z", "--no-renames", "--no-abbrev", a, b }, { binary = true }, function(r)
    local files, oids = parse_diff(r.code == 0 and r.stdout or "")
    local function check(changes)
      for _, c in ipairs(changes) do
        local mode, cur = observe(c.path)
        if mode ~= c.seen.mode or cur ~= c.seen.cur then
          if tries >= 2 then return cb(nil) end
          return M.plan_bg(root, a, b, cb, tries + 1)
        end
      end
      for _, c in ipairs(changes) do c.seen = nil end
      cb(changes)
    end
    local function with_blobs(blob) decide(root, files, blob, check) end
    if #oids == 0 then return with_blobs({}) end
    bg(root, { "cat-file", "--batch", "-Z" }, { stdin = table.concat(oids, "\0") .. "\0", binary = true }, function(r)
      local list, blob = batch_of(r.code == 0 and r.stdout or "", #oids), {}
      for i, oid in ipairs(oids) do if list[i] then blob[oid] = list[i] end end
      with_blobs(blob)
    end)
  end)
end

-- carry out a plan: write (or delete) each file
function M.apply(changes)
  local made = {}
  local function mkdirp(dir)
    if not made[dir] then made[dir] = true; vim.fn.mkdir(dir, "p") end
  end
  for _, c in ipairs(changes) do
    if not c.preserve then
      if c.content == nil then os.remove(c.path)
      else
        local st = vim.uv.fs_lstat(c.path)
        if st and st.type == "link" then assert(vim.uv.fs_unlink(c.path)) end
        if c.mode == "120000" then
          if st and st.type ~= "link" then assert(vim.uv.fs_unlink(c.path)) end
          mkdirp(vim.fs.dirname(c.path))
          assert(vim.uv.fs_symlink(c.content, c.path))
        else
          mkdirp(vim.fs.dirname(c.path))
          writeb(c.path, c.content)
          if c.mode and (not st or st.type ~= "file" or (bit.band(st.mode, 64) ~= 0) ~= (c.mode == "100755")) then
            local permissions = st and st.type == "file" and bit.band(st.mode, 511) or 420
            permissions = bit.band(permissions, bit.bnot(73)) + (c.mode == "100755" and 73 or 0)
            assert(vim.uv.fs_chmod(c.path, permissions))
          end
        end
      end
    end
  end
end

return M
