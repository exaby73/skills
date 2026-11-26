# The Machine

Every delegate shares one machine with the owner. Paste the rules a delegate needs into its brief.

## Memory and Test Workers

- Before tests run, check that at least 4 GB is free: the "available" column of `free -m` on Linux, or `memory_pressure` on macOS. With less, wait, or stop a delegate.
- Run tests with at most 2 workers, through the runner's own flag (`--maxWorkers=2`, `-p 2`, `--workers=2`).
- One browser per agent: reuse your own, and close it when you're done.

## Containers

- Each agent runs its own containers, named for its worktree, such as `<project>-<worktree>-postgres`, on free ports. Leave port 5432 to the owner's database: pick another, and check it's free with `lsof -iTCP:<port> -sTCP:LISTEN`.
- Set a guard in each worktree, such as `POSTGRES_CONTAINER=<name>` in its local environment file, so its scripts and tests touch only its own container.
- Remove your containers by name when done, with their volumes: `docker rm -f -v <name>`.
- Leave every other container and volume alone. Never run `docker system prune`, `docker volume prune`, or another prune: they remove other agents' and the owner's data.
