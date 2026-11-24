# sepal.nvim

- Tests: `nvim -l tests/run.lua` from the repo root (uses a fake agent, no Claude Code needed). `SEPAL_TEST=<part of a test name> nvim -l tests/run.lua` runs just those while iterating.
- Keep git work off the main loop where callers allow it (local `bg`, exported `commit_bg`, `stat_bg`, `update_refs_bg`, `plan_bg`, `delete_refs_bg`, `status_bg` in lua/sepal/git.lua); batch git processes (`files`, `delete_refs_bg` with a list) instead of one per file/task.
- Landing/undo plan via `git.plan_bg`, which rechecks each file before applying; `agent._t.landing` lists the in-flight ones and tests wait on it (`settled()`/`idle()`).
- Optional plugins (fidget, fff) go through `optional(name)` in lua/sepal/init.lua (a missing module isn't searched for again until 'runtimepath' changes); the open task draft is `require("sepal").draft()`, don't scan buffers for `vim.b.sepal_task`.
- Inbox saves/renders inside `inbox.batch(fn)` are deferred until the outermost batch ends (one save per affected repo, one render, also on error); use it for bulk changes.
