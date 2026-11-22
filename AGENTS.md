# sepal.nvim

- Tests: `nvim -l tests/run.lua` from the repo root (uses a fake agent, no Claude Code needed).
- Keep git work off the main loop where callers allow it (local `bg`, exported `commit_bg`, `stat_bg`, `update_refs_bg` in lua/sepal/git.lua); batch git processes (`files`, `delete_refs` with a list) instead of one per file/task.
- Inbox saves/renders inside `inbox.batch(fn)` are deferred until the outermost batch ends (one save per affected repo, one render, also on error); use it for bulk changes.
