# Traefik

Reverse proxy for all stacks. Publishes wildcard Let's Encrypt certificates via Cloudflare DNS challenge and discovers routes from docker labels.

## Setup

1. `cp .env.example .env`, set `ACME_EMAIL` and `CF_DNS_API_TOKEN`
2. `docker compose up -d`
3. First issuance takes a minute — `docker compose logs -f` until you see `Validations succeeded; requesting certificates.` then `Server responded with a certificate.`

## Env vars

- `TZ`, `ROOT_DOMAIN` (apex domain, default `homelab.lan`), `TRAEFIK_DOMAIN`
- `ALLOWED_IP_RANGES` — Comma-separated list of allowed IP ranges in CIDR notation (default: `10.10.0.0/24`)
- `ACME_EMAIL` — Let's Encrypt registration (no default, required)
- `CF_DNS_API_TOKEN` — Cloudflare API token for the DNS challenge (no default, required)

## Config

- Static config: `config/traefik/traefik.yaml` — pinned to `traefik:3.7` and uses v3 directives (e.g. `aliasHeadersStrategy: delete` for v3.7.12+). `exposedByDefault: false`; dashboard, ping, JSON logs; access log filters drop `200` (only `400-404`/`500-503` logged). The `https` entrypoint applies defaults to every router: `default-allowlist@file` + `default-headers@file` middlewares and `tls.certResolver: letsencrypt`, which is why router labels below omit `tls` and `middlewares`.
- File provider: `config/traefik/providers/` 
  - `default-middlewares.yaml`: defines the `default-allowlist` and `default-headers` middleware used by default for every `https` entrypoint app
  - Static host routing should be defined in `host-routes.yaml` (gitignored) that contains `http.routers` and `http.services`, create new one if none exists. Let say you need to route `cockpit` service from the host then add the following to your `host-routes.yaml`.

  ```yaml
  # yaml-language-server: $schema=https://www.schemastore.org/traefik-v3-file-provider.json
  
  http:
    routers:
      cockpit:
        entryPoints:
          - https
          rule: Host(`cockpit.{{ env "ROOT_DOMAIN" }}`)
          service: cockpit
          tls: {}
      # other routers...
          
    services:
      cockpit:
        loadBalancer:
          passHostHeader: true
          servers:
            - url: https://host.docker.internal:9090
      # other services...
  ```

  For more info consult the [Traefik file provider doc](https://doc.traefik.io/traefik/reference/routing-configuration/other-providers/file).

## Routing labels (what app stacks must add)

```yaml
traefik.enable: true
traefik.http.routers.<app>.entrypoints: https
traefik.http.routers.<app>.observability.accessLogs: false
traefik.http.routers.<app>.rule: Host(`<app>.${ROOT_DOMAIN}`)
traefik.http.services.<app>.loadbalancer.server.port: <port>
```

## State (gitignored)

- `config/letsencrypt/` — ACME account + wildcard certificates
- `config/traefik/providers/host-routes.yaml` — Static host routing
- `logs/` — JSON access logs (`access.log`)