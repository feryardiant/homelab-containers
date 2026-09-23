# Container Managers

Arcane, Dockhand, and DBX share a `manager-db` (Postgres 17) instance.

## Run

```sh
cp .env.example .env
docker compose up -d
```

- Arcane uses its default credential; you'll be asked to create a new password on first login.
- Dockhand disables authentication by default.
- DBX asks for the access password on first visit.

## Layout

- Fragments: `arcane/compose.yaml`, `dockhand/compose.yaml`, `dbx/compose.yaml`
- Entrypoint: `compose.yaml` (YAML anchors + `extends:` per fragment + `manager-db`)
- DB bootstrap: `shared/init-db.sh` (mounted as a Postgres init script)

## Gotchas

- `manager-db` runs `shared/init-db.sh` on **first init only** (creates the `arcane` and `dockhand` databases). Changing `DB_PASS` after first boot won't reprovision — wipe `shared/db/` instead.
- `ARCANE_ENCRYPTION_KEY`, `DOCKHAND_ENCRYPTION_KEY` have **no defaults** and are required: generate via `openssl rand -hex 32` (arcane) and `openssl rand -base64 32` (dockhand). Other vars fall back via `${VAR:-default}` (e.g. `ROOT_DOMAIN:-homelab.lan`, `DB_PASS:-secret`).
- Arcane and Dockhand use `group_add: ${GID}` — must be the host's docker group GID (`getent group docker | cut -d: -f3`); `PUID`/`PGID` from `id -u`/`id -g`.
- Managers mount `/opt/managers` + `/opt/stacks` + `/var/run/docker.sock` (they deploy stacks through the Docker socket).