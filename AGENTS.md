# sepal.nvim

- Tests: `nvim -l tests/run.lua` from the repo root (uses a fake agent, no Claude Code needed).
- Keep git work off the main loop where callers allow it (`bg`, `commit_bg`, `stat_bg` in lua/sepal/git.lua); batch git processes (`files`, `delete_refs` with a list) instead of one per file/task.
- Inbox saves/renders inside `inbox.batch(fn)` happen once at its end; use it for bulk changes.
