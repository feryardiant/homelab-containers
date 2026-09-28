#!/usr/bin/env bash
# validate.sh — project-wide convention checks for stacks/<name>/compose.yaml.
#
# Usage:  scripts/validate.sh [stack-name] [--help]
#
#   stack-name   validate only stacks/<stack-name>/
#   (no arg)     validate every stack under stacks/
#
# Runs LOCALLY in this clone (needs only `docker compose config` + jq);
# scripts under stacks/<name>/scripts/ run on the deploy host instead.
#
# Exit codes: 0 = no FAIL findings (warnings allowed), 1 = at least one FAIL,
#             2 = usage/setup error.

set -u

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STACKS_DIR="$ROOT/stacks"

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

# ------------------------------------------------------------------ arguments
TARGET=""
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
    *)
      if [ -n "$TARGET" ]; then echo "only one stack-name may be given" >&2; exit 2; fi
      TARGET="$arg" ;;
  esac
done

# --------------------------------------------------------------------- setup
command -v docker >/dev/null || { echo "docker not found" >&2; exit 2; }
docker compose version >/dev/null 2>&1 || { echo "docker compose (v2+) not available" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 2; }
test -d "$STACKS_DIR" || { echo "no stacks/ directory at $STACKS_DIR" >&2; exit 2; }

STACKS=()
if [ -n "$TARGET" ]; then
  if [ ! -d "$STACKS_DIR/$TARGET" ]; then
    {
      echo "unknown stack: $TARGET"
      echo -n "available:"
      for d in "$STACKS_DIR"/*/; do echo -n " $(basename "$d")"; done
      echo
    } >&2
    exit 2
  fi
  STACKS=("$TARGET")
else
  for d in "$STACKS_DIR"/*/; do [ -d "$d" ] && STACKS+=("$(basename "$d")"); done
  [ "${#STACKS[@]}" -gt 0 ] || { echo "no stacks found under $STACKS_DIR" >&2; exit 2; }
fi

# ------------------------------------------------------------------- counters
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

section() { printf '\n%s== %s ==%s\n' "$C_SECTION" "$*" "$C_RESET"; }
ok()   { printf '  [%sPASS%s] %s\n' "$C_PASS" "$C_RESET" "$*"; PASS=$((PASS+1)); }
wn()   { printf '  [%sWARN%s] %s\n' "$C_WARN" "$C_RESET" "$*"; WARN=$((WARN+1)); }
bad()  { printf '  [%sFAIL%s] %s\n' "$C_FAIL" "$C_RESET" "$*"; FAIL=$((FAIL+1)); }
info() { printf '         %s\n' "$*"; }

# --------------------------------------------------------------- one stack
validate_stack() {
  local name="$1" dir="$STACKS_DIR/$1"
  local json="" out rc f missing s seg ref tag

  section "$name"

  # 1 — compose config parses
  out="$(cd "$dir" && docker compose config --format json 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    ok "docker compose config parses"
    json="$out"
  else
    bad "docker compose config failed: $(printf '%s' "$out" | head -1)"
    info "config-derived checks below are skipped"
  fi

  # 2 — default network declared; a network named 'shared' must be external
  if [ -n "$json" ]; then
    # Note: compose config always materializes an implicit default network,
    # so "declared" must be checked against the source YAML, not the JSON.
    if awk '/^networks:/{n=1;next} n&&/^[^# ]/{n=0} n&&/^  default:/{f=1} END{exit !f}' \
         "$dir/compose.yaml" 2>/dev/null; then
      ok "default network declared under networks:"
    else
      bad "no ${C_SECTION}networks.default${C_RESET} declared (implicit project default hides intent)"
    fi
    local shared_bad
    shared_bad="$(printf '%s' "$json" | jq -r '.networks // {}
      | to_entries[] | select((.value.name // .key) == "shared") | select(.value.external != true) | .key')"
    if [ -z "$shared_bad" ]; then
      ok "every network named '${C_SECTION}shared${C_RESET}' is external: true"
    else
      for s in $shared_bad; do bad "network '$s' resolves to name 'shared' but is not external: true"; done
    fi
  fi

  # 3 — required files
  missing=""
  for f in compose.yaml README.md .env.example; do
    [ -e "$dir/$f" ] || missing="$missing $f"
  done
  if [ -z "$missing" ]; then ok "required files present (${C_SECTION}.yaml${C_RESET}, ${C_SECTION}README.md${C_RESET}, ${C_SECTION}.env.example${C_RESET})"
  else bad "missing:$missing"; fi

  # 4 — no named volumes; state lives in bind mounts
  if [ -n "$json" ]; then
    local vols
    vols="$(printf '%s' "$json" | jq -r '.services | to_entries[] | .key as $s
      | (.value.volumes // [])[] | select(.type == "volume") | "\($s) \(.target)"')"
    if [ -z "$vols" ]; then
      ok "no named volumes — state lives in bind mounts"
    else
      while IFS= read -r line; do
        [ -n "$line" ] && bad "named volume on $line — state must be a bind mount inside the stack dir"
      done <<< "$vols"
    fi
  fi

  # 5 — traefik.enable implies router rule + entrypoints https
  if [ -n "$json" ]; then
    local on rules eps n=0
    on="$(printf '%s' "$json" | jq -r '.services | to_entries[]
      | select((.value.labels // {})["traefik.enable"] != null)
      | select(((.value.labels // {})["traefik.enable"] | tostring) == "true") | .key')"
    for s in $on; do
      n=$((n+1))
      rules="$(printf '%s' "$json" | jq -r --arg s "$s" '[.services[$s].labels
        | keys[] | select(test("^traefik\\.http\\.routers\\..*\\.rule$"))] | length')"
      eps="$(printf '%s' "$json" | jq -r --arg s "$s" '[.services[$s].labels
        | to_entries[] | select(.key | test("^traefik\\.http\\.routers\\..*\\.entrypoints$"))
        | .value] | unique | join(",")')"
      if [ "${rules:-0}" -eq 0 ]; then
        bad "${C_SECTION}traefik.enable=true${C_RESET} but no router rule label: ${C_SECTION}$s${C_RESET}"
      elif [ -z "$eps" ]; then
        bad "${C_SECTION}traefik.enable=true${C_RESET} but no router entrypoints label: ${C_SECTION}$s${C_RESET}"
      elif [ "$eps" != "https" ]; then
        bad "router entrypoints must be https for ${C_SECTION}$s${C_RESET} (got: ${C_SECTION}$eps${C_RESET})"
      else
        ok "traefik labels complete: ${C_SECTION}$s${C_RESET}"
      fi
    done
    [ "$n" -eq 0 ] && info "no service enables traefik routing"
  fi

  # 6 — .env.example declares every live ${VAR}; .env parity when present
  if [ -f "$dir/.env.example" ]; then
    local live envx gap envk gap2
    live="$(grep -E '^[^#]*\$\{' "$dir/compose.yaml" 2>/dev/null \
            | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*' | sed 's/${//' | sort -u)"
    envx="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*' "$dir/.env.example" | sort -u)"
    gap=""
    if [ -n "$live" ]; then
      gap="$(comm -23 <(printf '%s\n' "$live") <(printf '%s\n' "$envx") | tr '\n' ' ')"
    fi
    if [ -z "$gap" ]; then ok "${C_SECTION}.env.example${C_RESET} declares every ${C_SECTION}\${VAR}${C_RESET} used by ${C_SECTION}compose.yaml${C_RESET}"
    else bad "${C_SECTION}.env.example${C_RESET} lacks compose variables: ${C_SECTION}$gap${C_RESET}"; fi

    if [ -f "$dir/.env" ]; then
      envk="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*' "$dir/.env" | sort -u)"
      if [ -z "$envk" ]; then
        info "local ${C_SECTION}.env${C_RESET} has no keys — parity check skipped"
      else
        gap2="$(comm -23 <(printf '%s\n' "$envk") <(printf '%s\n' "$envx") | tr '\n' ' ')"
        if [ -z "$gap2" ]; then ok ".env and .env.example declare the same keys"
        else wn "${C_SECTION}.env${C_RESET} has keys missing from .env.example: $gap2"; fi
      fi
    else
      info "no local ${C_SECTION}.env${C_RESET} — parity check skipped"
    fi
  else
    info "no ${C_SECTION}.env.example${C_RESET} — variable coverage check skipped"
  fi

  if [ -z "$json" ]; then return; fi

  # 7 — a service with no traefik.* labels needs ports or a dockhand.url label
  local noroute
  noroute="$(printf '%s' "$json" | jq -r '.services | to_entries[] | .key as $k
    | select((.value.labels // {}) | keys | any(startswith("traefik.")) | not) | $k')"
  for s in $noroute; do
    local ports du
    ports="$(printf '%s' "$json" | jq -r --arg s "$s" '(.services[$s].ports // []) | length')"
    du="$(printf '%s' "$json" | jq -r --arg s "$s" '((.services[$s].labels // {})["dockhand.url"]) // ""')"
    if [ "${ports:-0}" -gt 0 ]; then
      ok "${C_SECTION}$s${C_RESET} reachable via published ports (${C_SECTION}$ports${C_RESET})"
    elif [ -n "$du" ]; then
      ok "${C_SECTION}$s${C_RESET} reachable via ${C_SECTION}dockhand.url${C_RESET} ($du)"
    else
      wn "${C_WARN_B}$s${C_RESET} has no ${C_SECTION}traefik.*${C_RESET} labels, no published ${C_SECTION}ports${C_RESET} and no ${C_SECTION}dockhand.url${C_RESET} label"
    fi
  done

  # 8 — router labels without traefik.enable: true (route stays dead)
  local orph
  orph="$(printf '%s' "$json" | jq -r '.services | to_entries[]
    | select(((.value.labels // {}) | keys | map(select(test("^traefik\\.http\\."))) | length) > 0)
    | select(((.value.labels // {})["traefik.enable"] // "" | tostring) != "true") | .key')"
  if [ -z "$orph" ]; then
    ok "no orphan ${C_SECTION}traefik.*${C_RESET} router labels"
  else
    for s in $orph; do wn "$s has ${C_SECTION}traefik.*${C_RESET} router labels but ${C_SECTION}traefik.enable${C_RESET} is not ${C_SECTION}true${C_RESET}"; done
  fi

  # 9 — explicit registry prefix on every image
  local badimg=""
  while IFS=$'\t' read -r s seg; do
    if [ "$seg" = "${seg%%/*}" ]; then
      badimg="$badimg $s($seg)"
    else
      case "${seg%%/*}" in
        *.*|*:*|localhost) ;;
        *) badimg="$badimg $s($seg)" ;;
      esac
    fi
  done < <(printf '%s' "$json" | jq -r '.services | to_entries[] | "\(.key)\t\(.value.image // "")"')
  if [ -z "$badimg" ]; then ok "every image carries an explicit registry prefix"
  else wn "images without registry ${C_SECTION}prefix:$badimg${C_RESET}"; fi

  # 10 — no :latest (explicit or implicit) tags
  local badtag=""
  while IFS=$'\t' read -r s ref; do
    tag=""
    case "$ref" in *:*) tag="${ref##*:}" ;; esac
    if [ -z "$tag" ] || [ "$tag" = "latest" ]; then
      badtag="$badtag $s($ref)"
    fi
  done < <(printf '%s' "$json" | jq -r '.services | to_entries[] | "\(.key)\t\(.value.image // "")"')
  if [ -z "$badtag" ]; then ok "every image pins an explicit tag (no ${C_SECTION}:latest${C_RESET})"
  else wn "images with ${C_SECTION}:latest${C_RESET} or no ${C_SECTION}tag:$badtag${C_RESET}"; fi

  # 11 — deploy.resources.limits
  local nolim
  nolim="$(printf '%s' "$json" | jq -r '.services | to_entries[]
    | select(.value.deploy.resources.limits == null) | .key')"
  if [ -z "$nolim" ]; then ok "all services declare ${C_SECTION}deploy.resources.limits${C_RESET}"
  else
    local list=""
    for s in $nolim; do list="$list $s"; done
    wn "no ${C_SECTION}deploy.resources.limits${C_RESET}:$list"
  fi

  # 12 — arcane.icon label on every service
  local noicon
  noicon="$(printf '%s' "$json" | jq -r '.services | to_entries[]
    | select(((.value.labels // {})["arcane.icon"] // "") == "") | .key')"
  if [ -z "$noicon" ]; then ok "all services carry an ${C_SECTION}arcane.icon${C_RESET} label"
  else
    local list2=""
    for s in $noicon; do list2="$list2 $s"; done
    wn "no ${C_SECTION}arcane.icon${C_RESET} label:$list2"
  fi
}

# --------------------------------------------------------------------- drive
printf 'validate.sh — stack convention checks — %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
printf 'repo: %s\n' "$ROOT"

checked=0
for name in "${STACKS[@]}"; do
  validate_stack "$name"
  checked=$((checked+1))
done

section "summary"
printf '  stacks checked: %s%d%s\n' "$C_SECTION" "$checked" "$C_RESET"
printf '  %sPASS=%d%s  %sWARN=%d%s  %sFAIL=%d%s\n' \
  "$C_PASS_B" "$PASS" "$C_RESET" "$C_WARN_B" "$WARN" "$C_RESET" "$C_FAIL_B" "$FAIL" "$C_RESET"
if [ "$FAIL" -gt 0 ]; then
  printf '  result: %sFAIL%s — exit 1 (see [FAIL] items above)\n' "$C_FAIL_B" "$C_RESET"
  exit 1
fi
if [ "$WARN" -gt 0 ]; then
  printf '  result: %sWARN%s — exit 0 (review warnings)\n' "$C_WARN_B" "$C_RESET"
  exit 0
fi
printf '  result: %sOK%s\n' "$C_PASS_B" "$C_RESET"
exit 0
