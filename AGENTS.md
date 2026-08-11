# Coda development instructions

## Git workflow

- Work on the current branch. Do not create or switch branches unless the user explicitly asks.
- After completing and verifying a normal requested code change, create a commit unless the user explicitly says not to commit it.
- When the user explicitly creates or requests a prototype or experimental branch, commit each stable, working iteration as a checkpoint so experiments are easy to compare and revert.
- Leave an iteration uncommitted when the user explicitly calls it an experiment or prototype and asks not to commit it.
- Do not commit broken, incomplete, or unverified states merely to create a checkpoint.
- Preserve unrelated user changes and never include them in a commit without explicit permission.
- Do not merge, push, publish, tag, release, rewrite history, or delete a branch unless the user explicitly asks.
