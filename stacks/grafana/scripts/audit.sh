#!/usr/bin/env bash
# audit.sh — read-only health & consistency audit for the grafana (LGTM) stack.
#
# Usage:  scripts/audit.sh [--push] [--quick] [--help]
#
#   --push   also run write probes: Loki sample-age probes (writes a tiny
#            amount of harmless test data).
#   --quick  skip log-tail analysis, Grafana API checks and dashboard scans.
#
# Exit codes: 0 = no FAIL findings, 1 = at least one FAIL, 2 = usage/setup error.
#
# Safe to re-run at any time; every check is read-only unless --push is given.

set -u

STACK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$STACK_DIR" || exit 2

PUSH=0; QUICK=0
for arg in "$@"; do
  case "$arg" in
    --push) PUSH=1 ;;
    --quick) QUICK=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

command -v docker >/dev/null || { echo "docker not found" >&2; exit 2; }
command -v jq     >/dev/null || { echo "jq not found" >&2;     exit 2; }
test -e /opt/stacks || { echo "not the deploy host (/opt/stacks missing); aborting." >&2; exit 2; }

CURL_IMAGE=curlimages/curl:8.7.1
PASS=0; WARN=0; FAIL=0

# Colors only on a TTY with NO_COLOR unset, so pipes/logs stay plain.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_SECTION=$'\033[1;34m'  # bold blue
  C_PASS=$'\033[32m'       # green
  C_WARN=$'\033[33m'       # yellow
  C_FAIL=$'\033[31m'       # red
  C_PASS_B=$'\033[1;32m'   # bold green (summary counts / result)
  C_WARN_B=$'\033[1;33m'   # bold yellow
  C_FAIL_B=$'\033[1;31m'   # bold red
  C_RESET=$'\033[0m'
else
  C_SECTION=""; C_PASS=""; C_WARN=""; C_FAIL=""
  C_PASS_B=""; C_WARN_B=""; C_FAIL_B=""; C_RESET=""
fi

ok()   { printf '  %s[PASS]%s %s\n' "$C_PASS" "$C_RESET" "$*"; PASS=$((PASS+1)); }
wn()   { printf '  %s[WARN]%s %s\n' "$C_WARN" "$C_RESET" "$*"; WARN=$((WARN+1)); }
bad()  { printf '  %s[FAIL]%s %s\n' "$C_FAIL" "$C_RESET" "$*"; FAIL=$((FAIL+1)); }
info() { printf '         %s\n' "$*"; }
section() { printf '\n%s== %s ==%s\n' "$C_SECTION" "$*" "$C_RESET"; }

# curl against a container on the shared network. Prints "<code> <curl-exit>".
# code is 000 when the connection failed before an HTTP response.
# stdin is always /dev/null so docker can never steal input from callers' loops.
probe() { # probe <url> [extra curl args...]
  local url="$1"; shift
  local out rc
  out=$(docker run --rm --network shared "$CURL_IMAGE" -s -m 5 \
        -o /dev/null -w '%{http_code}' "$@" "$url" 2>/dev/null </dev/null); rc=$?
  echo "${out:-000} $rc"
}

# HTTP body via the curl container (optionally with basic auth / method).
fetch() { # fetch <url> [extra curl args...]
  local url="$1"; shift
  docker run --rm --network shared "$CURL_IMAGE" -s -m 10 "$@" "$url" 2>/dev/null </dev/null
}

# POST a body via the curl container; prints the http status code.
post() { # post <url> <content-type> <body>
  docker run --rm --network shared "$CURL_IMAGE" -s -m 10 -X POST \
    -H "Content-Type: $2" --data-binary "$3" -o /dev/null -w '%{http_code}' \
    "$1" 2>/dev/null </dev/null
}

# Count log lines matching an extended regex in the last <since>.
log_count() { # log_count <container> <since> <grep-ere>
  docker logs "$1" --since "$2" 2>&1 | grep -cE "$3" || true
}

printf 'grafana stack audit — %s\n' "$(date -Is)"
printf 'stack dir: %s\n' "$STACK_DIR"

# ---------------------------------------------------------------- compose.json
section "Compose & static files"
CMPSVC_JSON=$(docker compose config --format json 2>/dev/null)
# Generic convention checks (config validity, network, tags, limits, .env
# coverage) live in scripts/validate.sh — run it locally before deploying.

missing=""
for f in compose.yaml .env .env.example config/grafana/grafana.ini \
         config/prometheus config/loki config/tempo config/alloy \
         config/grafana/provisioning; do
  [ -e "$f" ] || missing="$missing $f"
done
if [ -z "$missing" ]; then ok "required files & config dirs present"
else bad "missing:$missing"; fi
for f in README.md scripts/check.sh; do
  [ -e "$f" ] || wn "optional file missing: $f"
done

# Published host ports: Web UIs stay Traefik-only; data intake ports are required.
PORTS=$(echo "$CMPSVC_JSON" | jq -r '.services|to_entries[]|"\(.key): "+((.value.ports//[])|.[]|"\(.protocol) \(.published) -> \(.target)")')
if [ -z "$PORTS" ]; then
  bad "no host ports published — OTLP (4317/4318) and syslog (514/udp) intake unreachable"
else
  while IFS= read -r line; do info "host port published — $line"; done <<< "$PORTS"
  echo "$PORTS" | grep -q '12345' && wn "alloy UI (12345) is published on 0.0.0.0 — bypasses the Traefik IP allowlist (F13)"
  for p in 4317 4318; do
    if echo "$PORTS" | grep -qE "tcp [0-9]+ -> $p\$"; then
      ok "OTLP port $p published on host (tempo direct intake, env-configurable)"
    else
      bad "OTLP port $p not published — LAN apps cannot export traces (F1)"
    fi
  done
  if echo "$PORTS" | grep -qE 'udp [0-9]+ -> 514'; then
    ok "syslog intake published (udp -> 514, env-configurable)"
  else
    wn "syslog intake (udp -> 514) not published — OpenWrt logs cannot arrive"
  fi
fi

# Traefik routing labels.
for s in grafana prometheus grafana-tempo grafana-alloy; do
  LB=$(docker inspect "$s" --format '{{json .Config.Labels}}' 2>/dev/null || echo '{}')
  EN=$(echo "$LB" | jq -r '."traefik.enable" // empty')
  RL=$(echo "$LB" | jq -r 'to_entries[]|select(.key|test("routers\\..*\\.rule$"))|.value' | head -1)
  EP=$(echo "$LB" | jq -r 'to_entries[]|select(.key|test("routers\\..*\\.entrypoints$"))|.value' | head -1)
  if [ "$EN" = "true" ] && [ -n "$RL" ] && [ "$EP" = "https" ]; then
    ok "traefik labels for $s: $RL"
  else
    bad "traefik labels incomplete for $s (enable=$EN entrypoints=${EP:-?})"
  fi
done

# Dead variables must stay gone (F12).
if grep -E '^[^#]*\$\{PUID' compose.yaml >/dev/null 2>&1; then
  wn "PUID/PGID are passed to services that do not implement them (no effect)"
fi
if grep -q 'HOST_HOSTNAME' compose.yaml 2>/dev/null; then
  wn "HOST_HOSTNAME is set by compose but never read by config.alloy (F12)"
fi
if grep -q 'ALLOY_PORT' .env 2>/dev/null || grep -q 'ALLOY_PORT' .env.example 2>/dev/null; then
  info "ALLOY_PORT declared but unused by compose (Alloy UI port is not published, F12)"
fi

# ---------------------------------------------------------------- containers
section "Containers"
RUNNING=$(docker compose ps --status running --format '{{.Service}}' 2>/dev/null)
for s in $(echo "$CMPSVC_JSON" | jq -r '.services|keys[]'); do
  if echo "$RUNNING" | grep -qx "$s"; then
    H=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$s" 2>/dev/null)
    RC=$(docker inspect -f '{{.RestartCount}}' "$s" 2>/dev/null || echo 0)
    case "$H" in
      healthy) ok "$s running (healthy)" ;;
      unhealthy) bad "$s running but UNHEALTHY" ;;
      starting) wn "$s running (healthcheck still starting)" ;;
      *) ok "$s running (no healthcheck)" ;;
    esac
    [ "${RC:-0}" -gt 0 ] && wn "$s has restarted ${RC}x"
    CFG_IMG=$(echo "$CMPSVC_JSON" | jq -r --arg s "$s" '.services[$s].image')
    RUN_IMG=$(docker inspect -f '{{.Config.Image}}' "$s" 2>/dev/null)
    [ "$CFG_IMG" = "$RUN_IMG" ] || bad "$s image drift: running=$RUN_IMG config=$CFG_IMG"
  else
    bad "$s is not running"
  fi
done

# ---------------------------------------------------------------- endpoints
section "Service endpoints"
h=$(probe "http://grafana:3000/api/health"); [ "${h%% *}" = "200" ] && ok "grafana /api/health" || bad "grafana /api/health -> $h"
DBOK=$(fetch "http://grafana:3000/api/health" | jq -r '.database // empty' 2>/dev/null)
[ "$DBOK" = "ok" ] && ok "grafana database: ok" || bad "grafana database status: ${DBOK:-?}"
VER=$(fetch "http://grafana:3000/api/health" | jq -r '.version // empty' 2>/dev/null)
[ -n "$VER" ] && info "grafana version: $VER"

h=$(probe "http://prometheus:9090/-/healthy"); [ "${h%% *}" = "200" ] && ok "prometheus /-/healthy" || bad "prometheus /-/healthy -> $h"
h=$(probe "http://loki:3100/ready");            [ "${h%% *}" = "200" ] && ok "loki /ready"           || bad "loki /ready -> $h"
h=$(probe "http://grafana-tempo:3200/ready");   [ "${h%% *}" = "200" ] && ok "tempo /ready"          || bad "tempo /ready -> $h"
h=$(probe "http://grafana-alloy:12345/-/ready");[ "${h%% *}" = "200" ] && ok "alloy /-/ready"        || bad "alloy /-/ready -> $h"

# OTLP receivers: tempo 4317/4318 must listen for traces to flow (F1).
h=$(probe "telnet://grafana-tempo:4317"); RC="${h##* }"
if [ "$RC" = "0" ] || [ "$RC" = "28" ]; then ok "tempo OTLP gRPC :4317 listening"
else bad "tempo OTLP gRPC :4317 NOT listening (rc=$RC) — check the distributor/otlp receivers in config/tempo/config.yaml"; fi
h=$(probe "http://grafana-tempo:4318/v1/traces" -X POST -H 'Content-Type: application/json' -d '{}'); RC="${h##* }"
if [ "$RC" = "7" ]; then bad "tempo OTLP HTTP :4318 NOT listening — traces cannot be exported"
else ok "tempo OTLP HTTP :4318 listening (http=${h%% *})"; fi

# OTLP intake is direct-to-tempo; Alloy's former pass-through must stay removed.
h=$(probe "http://grafana-alloy:4318/v1/traces" -X POST -H 'Content-Type: application/json' -d '{}'); RC="${h##* }"
if [ "$RC" = "7" ]; then ok "alloy has no OTLP pass-through (LAN pushes go direct to tempo)"
else wn "alloy OTLP listener present (http=${h%% *}) — pass-through reintroduced; design is direct-to-tempo"; fi

# ---------------------------------------------------------------- prometheus
section "Prometheus"
TGT=$(fetch "http://prometheus:9090/api/v1/targets?state=active")
if [ -n "$TGT" ] && echo "$TGT" | jq -e '.data.activeTargets' >/dev/null 2>&1; then
  TOT=$(echo "$TGT" | jq '.data.activeTargets|length')
  UP=$(echo "$TGT"  | jq '[.data.activeTargets[]|select(.health=="up")]|length')
  JOBS=$(echo "$TGT" | jq -r '[.data.activeTargets[].labels.job]|unique|join(", ")')
  info "active jobs: $JOBS"
  if [ "$UP" = "$TOT" ]; then ok "all $TOT active targets up"
  else
    wn "$UP/$TOT active targets up"
    echo "$TGT" | jq -r '.data.activeTargets[]|select(.health!="up")|"[\(.labels.job)] \(.labels.instance) :: \(.lastError // "no error")"' | while IFS= read -r l; do info "down: $l"; done
  fi
  # docker_sd gate (F3): discovery must yield every path+port-labeled container.
  # Note: the `job` label is relabeled to the compose project, so discovery is
  # asserted on scrapePool (always `docker-stacks`), not on labels.job.
  if echo "$TGT" | jq -e '.data.activeTargets[]|select(.scrapePool=="docker-stacks")' >/dev/null 2>&1; then
    DS_N=$(echo "$TGT" | jq '[.data.activeTargets[]|select(.scrapePool=="docker-stacks")]|length')
    ok "label-gated docker_sd discovery: $DS_N targets"
  else
    wn "scrape pool docker-stacks has zero discovered targets (docker.sock permissions? F3)"
  fi
  POOLS=$(echo "$TGT" | jq -r '[.data.activeTargets[].scrapePool]|unique|join(", ")')
  if [ "$POOLS" = "docker-stacks" ]; then
    ok "single scrape pool (docker-stacks) owns all targets"
  else
    wn "unexpected scrape pools active: $POOLS (design: docker-stacks only)"
  fi
  # Baseline 6 = grafana stack ×5 (grafana, loki, tempo, alloy, prometheus) + traefik.
  if [ "$TOT" -ge 6 ]; then ok "$TOT active targets (baseline 6 = grafana stack ×5 + traefik)"
  else wn "$TOT active targets — baseline is 6 (grafana ×5 + traefik); a labeled container is missing"; fi
  # Jobs that must stay gone: no phantom collectors (F6), no manager-suite (F5).
  if echo "$JOBS" | grep -qE '(^|, )(node-exporter|cadvisor)(, |$)'; then
    wn "node-exporter/cadvisor jobs active but no such containers ship with this stack (F6)"
  fi
  # `job` is the compose *project*, so the manager suite would surface as
  # project "managers" (service names can never appear as jobs anymore).
  if echo "$JOBS" | grep -qE '(^|, )managers(, |$)'; then
    wn "manager-suite project scraped although arcane/dockhand/dbx serve no metrics (F5)"
  fi
else
  bad "cannot query prometheus targets API"
fi

if [ "$QUICK" = "0" ]; then
  PD=$(log_count prometheus 24h 'permission denied')
  if [ "$PD" -gt 0 ]; then
    bad "docker_sd discovery failing: docker.sock 'permission denied' x$PD (24h) — prometheus runs as nobody (F3)"
  else
    ok "no docker.sock permission errors in prometheus logs (24h)"
  fi
fi

RET=$(grep -E 'retention' config/prometheus/prometheus.yaml | head -1 | tr -d ' ')
if [ -n "$RET" ]; then info "retention config: $RET"
else info "retention not set in config (Prometheus default 15d)"; fi

# TSDB persistence: data must live in the bind mount, not an anonymous volume (F2).
PROM_MOUNT=$(docker inspect prometheus --format '{{range .Mounts}}{{.Destination}} {{.Source}}{{"\n"}}{{end}}' | awk '$1=="/prometheus/data"{print $2}')
PROM_DATA=$(docker exec prometheus sh -c 'ls /prometheus/data 2>/dev/null | head -1' 2>/dev/null)
if [ -n "$PROM_DATA" ]; then
  if [ -z "$PROM_MOUNT" ] || echo "$PROM_MOUNT" | grep -q '/var/lib/docker/volumes/'; then
    bad "TSDB not on the bind mount (mount: ${PROM_MOUNT:-none}) — anonymous volume regression (F2)"
    info "fix: mount ./data/prometheus:/prometheus/data (keeps TSDB visible on the host)"
  elif [ ! -d data/prometheus ] || [ -z "$(ls -A data/prometheus 2>/dev/null)" ]; then
    bad "TSDB active under $PROM_MOUNT but data/prometheus is empty"
  else
    ok "TSDB persisted on the bind mount ($PROM_MOUNT)"
  fi
else
  wn "could not confirm prometheus TSDB location"
fi

# ---------------------------------------------------------------- loki
section "Loki"
CFG=$(fetch "http://loki:3100/config")
if [ -n "$CFG" ]; then
  RJ=$(echo "$CFG" | grep -oE 'reject_old_samples_max_age: *[^ ,]+' | head -1 | awk '{print $2}')
  MQ=$(echo "$CFG" | grep -oE 'max_query_series: *[0-9]+' | head -1 | awk '{print $2}')
  if echo "$CFG" | grep -q 'reject_old_samples: true'; then
    ok "old-sample rejection active (window ${RJ:-?}, max_query_series ${MQ:-?})"
  else
    bad "reject_old_samples is not enabled"
  fi
else
  wn "could not read loki /config"
fi
RET=$(grep -E 'retention_period:' config/loki/config.yaml | head -1 | tr -d ' ')
info "retention config: ${RET:-<default>}"

if [ "$QUICK" = "0" ]; then
  TFB=$(log_count loki 1h 'too far behind')
  if [ "$TFB" -eq 0 ]; then ok "no 'too far behind' rejections in the last hour"
  elif [ "$PUSH" = "1" ]; then info "$TFB 'too far behind' rejections in the last hour (may include this run's/earlier audit probes)"
  else wn "$TFB rejected log entries in the last hour (entries >~1h behind an existing stream are dropped by design, F7)"; fi
fi

if [ "$PUSH" = "1" ]; then
  # 50h-old entry into a fresh stream must be accepted (168h window).
  B=$(python3 -c "import json,time;print(json.dumps({'streams':[{'stream':{'job':'audit-probe-a'},'values':[[str(int((time.time()-180000)*1e9)),'audit probe']]}]}))")
  c=$(post "http://loki:3100/loki/api/v1/push" "application/json" "$B"); [ "$c" = "204" ] \
    && ok "push of 50h-old sample accepted (window >= 50h)" || bad "50h-old sample rejected (http=$c) — 168h window no longer effective"
  # 200h-old entry must be rejected (>168h).
  B=$(python3 -c "import json,time;print(json.dumps({'streams':[{'stream':{'job':'audit-probe-b'},'values':[[str(int((time.time()-720000)*1e9)),'audit probe']]}]}))")
  c=$(post "http://loki:3100/loki/api/v1/push" "application/json" "$B"); [ "$c" = "400" ] \
    && ok "push of 200h-old sample rejected as expected (window = 168h)" || wn "200h-old sample response: http=$c (expected 400)"
  # 2h-old entry into an EXISTING live stream must be rejected (~1h stream window).
  LB=$(fetch "http://loki:3100/loki/api/v1/series?start=$(( ($(date +%s) - 3600) * 1000000000 ))&match=%7Bjob%3D%22openwrt%22%7D" | jq -c '.data[0] // empty' 2>/dev/null)
  if [ -n "$LB" ] && [ "$LB" != "null" ]; then
    B=$(python3 -c "
import json,time,sys
print(json.dumps({'streams':[{'stream':json.loads(sys.argv[1]),'values':[[str(int((time.time()-7200)*1e9)),'audit probe']]}]}))" "$LB")
    c=$(post "http://loki:3100/loki/api/v1/push" "application/json" "$B")
    if [ "$c" = "400" ]; then ok "2h-old sample into live stream rejected (~1h stream-behind window, as documented)"
    else wn "2h-old sample into live stream accepted (http=$c) — stream-behind window changed"; fi
  else
    info "no live openwrt series found — skipped stream-behind probe"
  fi
fi

# ---------------------------------------------------------------- alloy
section "Alloy"
if [ "$QUICK" = "0" ]; then
  EF=$(log_count grafana-alloy 10m 'Exporting failed|connection refused')
  if [ "$EF" -eq 0 ]; then ok "no remote-write/export failures in the last 10m"
  else bad "$EF export errors in the last 10m (loki/prometheus unreachable, or tempo receiver — config/tempo/config.yaml)"; fi
fi

# Alloy must stay logs-only (F4): prometheus's label-gated docker_sd is the
# single metrics path — no prometheus.scrape / remote_write anywhere in alloy.
if grep -qE 'discovery\.docker "prometheus"|prometheus\.relabel "docker_containers"|prometheus\.(scrape|remote_write)' config/alloy/config.alloy; then
  wn "alloy carries metrics scrape/remote-write code — prometheus owns metrics, alloy is logs-only (F4)"
else
  ok "alloy is logs-only: no prometheus scrape/remote-write components (F4)"
fi

# Manager-suite must not satisfy the metrics gate (F5): arcane/dockhand/dbx
# serve no /metrics, so they must carry no prometheus.path/port labels
# (either spelling — dotted and underscored sanitize to the same gate).
for c in arcane dockhand dbx; do
  LBL=$(docker inspect "$c" 2>/dev/null | jq -r '.[0].Config.Labels // {} | [to_entries[] | select(.key=="prometheus.path" or .key=="prometheus_path" or .key=="prometheus.port" or .key=="prometheus_port") | "\(.key)=\(.value)"] | join(", ")' 2>/dev/null)
  if [ -n "$LBL" ]; then
    wn "$c carries metrics-gate labels ($LBL) but serves no /metrics (F5) — recreate from /opt/managers"
  else
    ok "$c not labeled for scraping (no /metrics endpoint)"
  fi
done
if grep -qE '"__address__" = "(arcane|dockhand|dbx):' config/alloy/config.alloy; then
  wn "alloy static scrape still targets manager-suite containers (F5)"
else
  ok "alloy static scrape has no manager-suite targets (F5)"
fi

# ---------------------------------------------------------------- grafana api
if [ "$QUICK" = "0" ]; then
  section "Grafana API (provisioned content)"
  AUTH=(-u admin:admin)
  h=$(probe "http://grafana:3000/api/org" "${AUTH[@]}")
  if [ "${h%% *}" = "200" ]; then
    wn "default credentials admin/admin still active"
  elif [ "${h%% *}" = "401" ] || [ "${h%% *}" = "403" ]; then
    ok "default credentials admin/admin no longer accepted"
  else
    info "could not verify grafana credentials (http=${h%% *})"
  fi

  DS=$(fetch "http://grafana:3000/api/datasources" "${AUTH[@]}")
  NDS=$(echo "$DS" | jq 'length' 2>/dev/null || echo 0)
  if [ "$NDS" = "0" ]; then
    bad "no datasources readable via API"
  else
    ok "$NDS provisioned datasources"
    while IFS= read -r uid; do
      [ -n "$uid" ] || continue
      name=$(echo "$DS" | jq -r --arg u "$uid" '.[]|select(.uid==$u)|.name')
      s=$(fetch "http://grafana:3000/api/datasources/uid/$uid/health" "${AUTH[@]}" | jq -r '.status // "?"' 2>/dev/null)
      if [ "$s" = "OK" ]; then ok "datasource health OK: $name"
      else bad "datasource health ${s:-?}: $name"; fi
    done < <(echo "$DS" | jq -r '.[].uid' 2>/dev/null)
  fi

  API_DB=$(fetch "http://grafana:3000/api/search?type=dash-db" "${AUTH[@]}" | jq 'length' 2>/dev/null || echo 0)
  FILE_DB=$(find config/grafana/provisioning/dashboards -name '*.json' | wc -l | tr -d ' ')
  if [ "$API_DB" = "$FILE_DB" ]; then ok "$API_DB dashboards provisioned (= $FILE_DB JSON files)"
  else bad "dashboards mismatch: API=$API_DB files=$FILE_DB"; fi

  # Collector-dependent jobs/queries must stay gone (F6): no node-exporter/cadvisor
  # jobs in prometheus.yaml and no node_*/container_* queries in dashboards.
  HAS_NODE=$(grep -cE "job_name: '(node-exporter|cadvisor)'" config/prometheus/prometheus.yaml || true)
  # container_name (log/target label) is legitimate — strip it before matching
  # against collector metrics (container_memory_*, container_cpu_*, ...).
  BROKEN=""
  for f in config/grafana/provisioning/dashboards/*/*.json; do
    [ -e "$f" ] || continue
    if sed 's/container_name//g' "$f" | grep -qE '"expr": *"[^"]*(node_|container_)'; then
      BROKEN="$BROKEN $(basename "$f")"
    fi
  done
  BROKEN="${BROKEN# }"
  F6_OK=1
  if [ "$HAS_NODE" -gt 0 ]; then
    wn "node-exporter/cadvisor jobs reintroduced but no collectors ship with this stack (F6)"; F6_OK=0
  fi
  if [ -n "$BROKEN" ]; then
    wn "dashboards querying node_*/container_* with no collector: $BROKEN (F6)"; F6_OK=0
  fi
  [ "$F6_OK" = "1" ] && ok "no collector-dependent jobs or dashboard queries (F6)"
fi

# ---------------------------------------------------------------- traefik/host
section "Traefik & host"
if docker ps --format '{{.Names}}' | grep -qx traefik; then
  ok "traefik container running"
  ACME=""
  while IFS= read -r src; do
    if [ -f "$src" ] && [ "${src##*/}" = "acme.json" ]; then ACME=$src; break; fi
    if [ -d "$src" ]; then
      f=$(find "$src" -maxdepth 3 -name acme.json 2>/dev/null | head -1)
      [ -n "$f" ] && { ACME=$f; break; }
    fi
  done < <(docker inspect traefik --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' 2>/dev/null)
  if [ -n "$ACME" ]; then
    MODE=$(stat -c '%a' "$ACME" 2>/dev/null)
    if [ "$MODE" = "600" ]; then ok "acme.json present (mode 600): $ACME"
    else wn "acme.json mode is $MODE (should be 600): $ACME"; fi
  else
    wn "acme.json not found under traefik's mounts"
  fi
else
  wn "traefik container not found (routing checks limited to labels)"
fi

for p in 9090 3000; do
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$p\$"; then
    info "host port $p is already in use by another process — publishing this stack on it would conflict"
  fi
done
if [ -f /opt/stacks/traefik/.env ]; then
  ALW=$(grep -E '^ALLOWED_IP_RANGES=' /opt/stacks/traefik/.env | head -1)
  info "traefik allowlist setting: ${ALW:-ALLOWED_IP_RANGES unset (defaults to 10.10.0.0/24)}"
fi

# ---------------------------------------------------------------- summary
section "summary"
printf '  %sPASS=%d%s  %sWARN=%d%s  %sFAIL=%d%s\n' \
  "$C_PASS_B" "$PASS" "$C_RESET" "$C_WARN_B" "$WARN" "$C_RESET" "$C_FAIL_B" "$FAIL" "$C_RESET"
if [ "$FAIL" -gt 0 ]; then
  printf '  result: %sFAIL%s — see [FAIL] items above (details in README.md)\n' "$C_FAIL_B" "$C_RESET"
  exit 1
fi
if [ "$WARN" -gt 0 ]; then
  printf '  result: %sWARN%s — core function OK, review warnings\n' "$C_WARN_B" "$C_RESET"
  exit 0
fi
printf '  result: %sOK%s\n' "$C_PASS_B" "$C_RESET"
exit 0
