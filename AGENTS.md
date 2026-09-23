# AGENTS.md

Homelab Docker Compose monorepo: a container-manager suite and deployable stacks, all plain Docker Compose YAML. No code, no tests, no CI.

## Layout

- `managers/` — container-manager suite. Each manager (`arcane/`, `dockhand/`, `dbx/`) is a Compose **fragment**; only `managers/compose.yaml` (anchors + `extends:` + shared `manager-db` Postgres) is ever run. Manager deployment specifics: `managers/README.md`.
- `stacks/` — deployable stacks, one directory per stack. Specifics for a stack live in that stack's own `README.md`.

## Deployment reality

- The clone is **symlinked** to `/opt/managers` and `/opt/stacks`; READMEs and compose defaults assume those paths.
- All services join an **external** user-defined bridge network named `shared` (create once: `docker network create -d bridge --attachable shared`).
- Runtime state (`*/data/`, `*/config/`, `*/logs/`, etc.) and `.env` files are gitignored. Keep empty placeholder dirs with a `.gitignore` containing `*` and `!.gitignore`.

### Docker command gate

Before running any Docker command other than `docker compose config`, check whether this clone is deployed on this device:

```sh
test -e /opt/managers && test -e /opt/stacks
```

Either form counts — real directories or symlinks both pass.

- **Both exist** — full Docker access is allowed: `docker run`, `docker compose up/down/logs`, etc. Use it to test, check, and verify that changes to any stack actually work (bring it up, inspect logs, confirm behavior).
- **Either missing** (e.g. a dev laptop) — `docker compose config` is the **only** permitted Docker command. No `docker run`, no `docker compose up/down/stop/restart`, no read-only inspection. Instead, finish your task with a handoff to the human: *"Here's what you need to verify once you've deployed the changes"* — a checklist of the exact commands/logs/URLs to check after deploying on the real device.

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

- Validate with `docker compose config -f <file>`. Runtime inspection (`docker compose logs -f`) only on a device that passes the Docker command gate above.
- Adding a stack = new `stacks/<name>/` dir with `compose.yaml`, `.env.example`, `README.md` per the conventions above.

## Style

- 2-space indent, LF (`.editorconfig`); markdown: no final newline, no trailing-whitespace trimming.

## AI artifacts

- Store AI-generated plans/specs/scripts in `.agents/`.