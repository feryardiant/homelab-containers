# AGENTS.md

Homelab Docker Compose monorepo: a container-manager suite and deployable stacks, all plain Docker Compose YAML. No code, no tests, no CI.

## Layout

- `managers/` — container-manager suite. Each manager (`arcane/`, `dockhand/`, `dbx/`) is a Compose **fragment**; only `managers/compose.yaml` (anchors + `extends:` + shared `manager-db` Postgres) is ever run. Manager deployment specifics: `managers/README.md`.
- `stacks/` — deployable stacks, one directory per stack. Specifics for a stack live in that stack's own `README.md`.

## Deployment reality

- On the deploy host(s) (see *Deployment targets* below) the clone is **symlinked** to `/opt/managers` and `/opt/stacks`; READMEs and compose defaults assume those paths.
- All services join an **external** user-defined bridge network named `shared` (create once: `docker network create -d bridge --attachable shared`).
- Runtime state (`*/data/`, `*/config/`, `*/logs/`, etc.) and `.env` files are gitignored. Keep empty placeholder dirs with a `.gitignore` containing `*` and `!.gitignore`.

### Deployment targets — `.agents/deployments.jsonc`

All runtime work happens on a deploy host, never on this machine.

- The file is gitignored, machine-local, and **required**. Entries look like `{ "host", "proto", "deploy": "rsync"|"clone", "maps": { "<local rel>": "<remote abs>" } }`. If it does not exist, stop and ask the human to create one before proceeding — never assume a target and never skip the check.
- **This clone is edit-only.** The only permitted local Docker command is `docker compose config`. No `docker run`, no `docker compose up/down/stop/restart/logs/ps`, no local inspection — not even a quick test. (Having `/opt/...` on this device grants nothing; go over ssh.)
- **Resolve the target before acting** — find the host(s) whose `maps` contains the path you're changing:
  - one match, or the human named a host → use it;
  - several matches and the human named hosts → do each mapped host in turn;
  - several matches, no host named → ask;
  - no match → touch no host: edit, `docker compose config`, then finish with a handoff to the human — *"Here's what you need to deploy and verify once the path is added to `.agents/deployments.jsonc`"* — a checklist of the exact rsync/ssh commands, logs, and URLs.
- **Deploy** only the mapped dir, e.g. `rsync -a --exclude .env --exclude data/ --exclude logs/ <local>/ <host>:<remote>/`. Never `--delete`, never push `.env` or runtime state — mapped dirs share a schema, not secrets or per-host config. Follow the entry's `deploy` method; if it isn't a method you know, ask.
- **Keep a mapped pair in shape** — rule of thumb for `deploy: "rsync"` entries:
  - Prefer the stack's excludes file: `rsync -a --exclude-from=.agents/<name>-deploy-excludes.txt …`. Besides `.env`/runtime state it lists files that exist **only locally** (helper scripts never meant to run on the host).
  - Deletions never propagate (no `--delete`): remove a stale remote file by hand over ssh and say so in the handoff.
  - Verify with checksums, not size+mtime: `rsync -a -c --dry-run --itemize-changes --exclude-from=… <local>/ <host>:<remote>/` must print nothing (or only mtime-only `.d..t....` lines); run it reversed to list remote-only files — expected leftovers are backups and runtime state, anything else is drift. For hard proof, md5 both sides of each changed file.
  - Check `git status` before removing anything from a mapped dir — parts of the tree are untracked or gitignored, so deletions cannot be recovered.
- **Run and verify over ssh:** `ssh <host> 'cd <remote> && docker compose up -d'`, same shape for `logs`, `ps`, and any stack scripts (`scripts/check.sh`).

## Compose conventions (apply to everything you add)

- Compose fragments (per-manager `compose.yaml`) are never run standalone; always run from `managers/` or `stacks/<name>/`.
- Stacks are exactly one level deep: only `stacks/<stack-name>/compose.yaml` is ever run. Every compose file is named `compose.yaml` (no `compose.yml`).
- In every `compose.yaml`:
  - Default network is `shared`, declared `external: true`.
  - Routing is discovered from **docker labels** — `traefik.enable: true`, `traefik.http.routers.<app>.*` with `entrypoints: https`. TLS (`certresolver: letsencrypt`) and default middlewares (`default-allowlist` + `default-headers`) are applied at the `https` entrypoint, so router labels don't need `tls`/`middlewares`. Traefik runs `exposedByDefault: false`, so a missing label = no route.
  - Keep `arcane.icon: <slug>` labels; the Arcane UI sources icons from `https://selfh.st/icons/`.
  - Images carry an explicit registry prefix (`docker.io/...`, `ghcr.io/...`); prefer `major.minor` tags over `latest` when upstream publishes them.
  - All state lives in bind-mounted dirs inside the stack dir — no named volumes.
- Every component ships `.env.example` (the `.env` variable names with empty values) and a `README.md`; `.env` is created by copying `.env.example`.
- Most variables fall back via `${VAR:-default}`; an un-defaulted variable is required by design.

## Workflow

- Validate with `docker compose config -f <file>`. Runtime inspection (`docker compose logs -f`) runs over ssh on the mapped host per *Deployment targets* above — never locally.
- Adding a stack = new `stacks/<name>/` dir with `compose.yaml`, `.env.example`, `README.md` per the conventions above.

## Style

- 2-space indent, LF (`.editorconfig`); markdown: no final newline, no trailing-whitespace trimming.

## AI artifacts

- Store AI-generated artifacts in `.agents/`. **Metadata docs** (plans, specs, ledgers, logs, handoffs) live in `.agents/logs/`; scripts and machine-local config (`.sh`, `grafana-deploy-excludes.txt`, `deployments.jsonc`) stay directly in `.agents/`.