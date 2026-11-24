-- nvim -u tests/demo.lua  (from the repo root): orchestrate in a throwaway repo against a fake
-- agent. SEPAL_DEMO_REAL=1 uses the real claude instead; SEPAL_DEMO_CHECK=1 (headless) runs one
-- orchestrate from draft to two landed tasks, then quits (0 ok, 1 failed).
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.cmd.runtime("plugin/sepal.lua")

local sepal = require("sepal")
local agent = require("sepal.agent")
local inbox = require("sepal.inbox")
local git = require("sepal.git")

-- a scratch git repo: a small committed greet.txt, its sepal state in .sepal/ (gitignored, so a
-- task's snapshot of your work tree never picks it up)
local T = vim.fn.tempname()
vim.fn.mkdir(T, "p")
vim.fn.chdir(T)
vim.system({ "sh", "-c", [[git init -q && printf '.sepal/\n' > .gitignore && printf 'hello\n' > greet.txt
  && git add .gitignore greet.txt && git -c user.name=demo -c user.email=demo@demo commit -qm init]] },
  { cwd = T, text = true }):wait()
vim.env.CLAUDE_CONFIG_DIR = vim.fs.joinpath(T, ".sepal", "claude") -- a real claude's chats stay in the sandbox
vim.cmd.edit("greet.txt")

-- a fake agent, like tests/run.lua's: it reports through the hooks ($SEPAL_EVENTS), ends its turn
-- writing its reply as the transcript's last assistant line, and stays open like claude. What it
-- does reads the prompt (its last argument): "How to plan this" -> the plan below, "task N of" ->
-- that item's edit, "How to answer this" -> a plain answer, else the Goal is appended to greet.txt.
local fake = [[
n=$#; i=0; resumed=
for a; do
  i=$((i+1))
  if [ $i -eq $n ]; then prompt=$a; fi
  if [ "$a" = --resume ]; then resumed=1; fi
done
if [ -n "$resumed" ]; then printf 'the chat so far\n'; while :; do sleep 1; done; fi
sid="demo$$"
ev() { printf '%s\n' "$1" >> "$SEPAL_EVENTS"; }
t="$SEPAL_EVENTS.jsonl"
: > "$t"
ev "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$sid\",\"transcript_path\":\"$t\"}"
case "$prompt" in
  *"How to plan this"*)
    reply='Two tasks, one file each.\n\nPlan:\n1. [opus] Shout greet.txt\n   Goal: upper case greet.txt\n   Done when: grep -q HELLO greet.txt\n   Files:\n   - @greet.txt\n2. [haiku] Add NOTES.md\n   Goal: add NOTES.md\n   Done when: test -f NOTES.md\n   Files:\n   - @NOTES.md\n\nAssumptions:\n- the two halves are independent';;
  *"task 1 of"*)
    ev "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"$sid\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$PWD/greet.txt\"}}"
    tr '[:lower:]' '[:upper:]' < greet.txt > greet.txt.new && mv greet.txt.new greet.txt
    reply='Shouted greet.txt.\n\nAssumptions:\n- none';;
  *"task 2 of"*)
    ev "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"$sid\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PWD/NOTES.md\"}}"
    printf 'demo notes\n' > NOTES.md
    reply='Added NOTES.md.\n\nAssumptions:\n- none';;
  *"How to answer this"*)
    reply='sepal hands each task to an agent working alone in a git worktree, then lands the result.\n\nAssumptions:\n- none';;
  *)
    printf '%s\n' "$prompt" | sed -n 's/^Goal: //p' | head -n 1 >> greet.txt
    reply='Appended the goal to greet.txt.\n\nAssumptions:\n- none';;
esac
printf '%s\n' '{"type":"user","message":{"content":"go"}}' \
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"$reply\"}]}}" > "$t"
ev "{\"hook_event_name\":\"Stop\",\"session_id\":\"$sid\",\"transcript_path\":\"$t\"}"
while :; do sleep 1; done]]

local cmd = { "sh", "-c", fake, "sh" }
local real = vim.env.SEPAL_DEMO_REAL == "1"
sepal.setup({
  cmd = real and { "claude" } or cmd,
  worktrees = vim.fs.joinpath(T, ".sepal"),
  agents = real and nil or {
    { cmd = cmd, name = "fake" },
    { cmd = cmd, model = "opus" },
    { cmd = cmd, model = "sonnet" },
    { cmd = cmd, model = "haiku" },
  },
})

vim.schedule(function()
  vim.api.nvim_echo({
    { "sepal demo", "SepalTitle" }, { " — a throwaway repo at " .. T },
    { "\n:Sepal task", "SepalAccent" }, { "  then o, write a Goal, <c-c><c-c> sends it" },
    { "\n:Sepal inbox", "SepalAccent" }, { "  m picks a plan task's model, s swarms it into tasks" },
    { "\n:Sepal panel", "SepalAccent" }, { "  the tasks and their agents at the right" },
  }, true, {})
end)

if vim.env.SEPAL_DEMO_CHECK ~= "1" then return end

-- headless: one orchestrate start to finish
vim.schedule(function()
  local ok, err = pcall(function()
    local root = assert(git.root(T), "no git repo at " .. T)
    local function newest() return inbox.list(root)[1] end
    -- an orchestrate draft, filled and sent with <c-c><c-c> (as tests/run.lua's send does)
    sepal.task(nil, nil, "orchestrate")
    local buf
    for _, b in ipairs(vim.api.nvim_list_bufs()) do if vim.b[b].sepal_task then buf = b end end
    assert(buf, "the task draft never opened")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false,
      { "Goal: shout the greeting and leave notes", "", "Files:", "- @greet.txt" })
    vim.api.nvim_feedkeys(vim.keycode("<c-c><c-c>"), "tx", false)
    assert(vim.wait(30000, function()
      local e = newest()
      return e and e.status ~= "running" and e.status ~= "queued"
    end, 50), "the plan never came")
    local e = newest()
    assert(e.status == "planned" and #(e.plan or {}) == 2,
      ("expected a 2-task plan, got %s%s"):format(tostring(e and e.status), e and e.error and ": " .. e.error or ""))
    agent.swarm(e)
    local function done(x) return not vim.tbl_contains({ "running", "queued", "checking" }, x.status) end
    assert(vim.wait(60000, function()
      local l = inbox.list(root)
      return l[1] and l[2] and done(l[1]) and done(l[2])
    end, 50), "the plan's tasks never finished")
    local l = inbox.list(root)
    assert(l[1].status == "landed" and l[2].status == "landed",
      ("expected both landed, got %s, %s"):format(l[1] and l[1].status, l[2] and l[2].status))
    local f = assert(io.open(vim.fs.joinpath(root, "greet.txt")))
    local s = f:read("a"); f:close()
    assert(s:find("HELLO", 1, true), "greet.txt wasn't shouted: " .. s)
    assert(vim.uv.fs_stat(vim.fs.joinpath(root, "NOTES.md")), "NOTES.md wasn't added")
  end)
  if not ok then
    print("sepal demo check failed: " .. tostring(err))
    vim.fn.delete(T, "rf")
    return vim.cmd("cquit 1")
  end
  print("sepal demo: planned 2 tasks, both landed")
  vim.fn.delete(T, "rf")
  vim.cmd("qa!")
end)
