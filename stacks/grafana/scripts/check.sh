#!/bin/bash
# check.sh - Verify dashboard provisioning and probe every panel query.
#
# Exit codes (same convention as the sibling scripts/audit.sh):
#   0 = no FAIL findings (WARN allowed), 1 = at least one FAIL, 2 = setup error.
#
# Fixes over the previous version:
#   - Loki probes use query_range: log queries are invalid as instant queries,
#     which made every plain log panel report a false failure.
#   - Tempo probes pick /api/search vs /api/metrics/query by query shape
#     (search queries only compile on /api/search).
#   - all expansions quoted; jq fed via printf '%s' (unquoted echo let the
#     shell glob-expand `.*` inside queries); query shown via printf (echo -e
#     mangled backslashes in displayed queries).
#   - JSON error responses are FAIL (they used to print green "error").
#   - WARN when a successful Loki result contains __error__ parse failures.
#   - Valid JSON that isn't a response we can score (e.g. a bare array) is
#     FAIL, not a silent PASS (empty jq extractions used to fall through).
#   - An empty remote checksum never matches ("Deployed" used to print when
#     the API returned no sourceChecksum).
#   - Loki responses over Loki's 4MB gRPC cap score WARN, not FAIL (working
#     query, pathological 100KB+ log lines), and LOKI_LIMIT bounds bytes.
#   - PASS/WARN/FAIL summary and a meaningful exit code.
#   - Empty and whitespace-only bodies print the explicit (empty response…)
#     text; whitespace alone used to be rendered as invisible failure text.
#   - Empty results say so — "success (empty: …)" — instead of a bare success.
#   - "sampled to first N log lines" only appears on stream results; metric
#     results carry no lines to sample.
#   - -h/--help prints usage; an unexpected argument exits 2.
#   - probe/file subcommands (folded in from the retired probe-query.sh):
#     raw single-query dumps and whole-file pre-deploy validation, with the
#     backend request built by the same q_* helpers the suite uses.

set -u

# Colors only on a TTY with NO_COLOR unset, so pipes/logs stay plain.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_MENTION=$'\033[34m'    # blue
    C_SECTION=$'\033[1;34m'  # bold blue
    C_PASS_B=$'\033[1;32m'   # bold green (summary counts / result)
    C_WARN_B=$'\033[1;33m'   # bold yellow
    C_FAIL_B=$'\033[1;31m'   # bold red
    C_RESET=$'\033[0m'
else
    C_MENTION=""; C_SECTION=""
    C_PASS_B=""; C_WARN_B=""; C_FAIL_B=""; C_RESET=""
fi

usage() {
    printf '%s\n' \
'check.sh - verify dashboard provisioning and probe every panel query.

Usage:
    check.sh                            full suite: provisioning status + every panel expr
    check.sh probe <mode> <expr>        dump the raw backend response for one query (no verdict)
    check.sh file <dashboard.json>      probe every target expr in a dashboard file (pre-deploy)
    check.sh -h | --help                this text

probe modes: loki | prom | tempo | tempo-search | tempo-metrics
    (tempo picks the endpoint by query shape; the tempo-* modes force one)

Runs on the deploy host: probes go over the docker network to grafana/loki/
prometheus/tempo, and the local dashboard files are read from
/opt/stacks/grafana/config/grafana. Companion: sibling scripts/audit.sh
audits the stack configuration itself. The probe/file subcommands were
folded in from the retired probe-query.sh.

Environment:
    GRAFANA_USER / GRAFANA_PASS   Grafana API basic auth (default admin/admin)

Exit codes: 0 = no FAIL findings (WARN allowed), 1 = at least one FAIL,
            2 = setup error or bad usage.'
}

probe_usage() {
    printf '%s\n' 'Usage: check.sh probe <loki|prom|tempo|tempo-search|tempo-metrics> <expr>'
}

file_usage() {
    printf '%s\n' 'Usage: check.sh file <dashboard.json>'
}

MODE=${1:-}

case "$MODE" in
    -h|--help) usage; exit 0 ;;
    "") ;;
    probe|file) ;; # argument validation below, deliberately BEFORE the env guards
    *) printf 'unknown argument: %s\n\n' "$MODE" >&2; usage >&2; exit 2 ;;
esac

# Subcommand args are validated before the docker/jq/config guards so a usage
# error is reported even on a machine that cannot probe (and never probes by
# accident: bad input exits here, before anything is executed).
if [ "$MODE" = "probe" ]; then
    if [ "$#" -ne 3 ]; then
        printf 'probe needs a mode and an expression\n\n' >&2
        probe_usage >&2
        exit 2
    fi
    PROBE_MODE=$2
    PROBE_EXPR=$3
    case "$PROBE_MODE" in
        loki|prom|tempo|tempo-search|tempo-metrics) ;;
        *) printf 'unknown mode: %s\n\n' "$PROBE_MODE" >&2; probe_usage >&2; exit 2 ;;
    esac
elif [ "$MODE" = "file" ]; then
    if [ "$#" -ne 2 ]; then
        printf 'file needs a dashboard path\n\n' >&2
        file_usage >&2
        exit 2
    fi
    DASH_FILE=$2
    if [ ! -f "$DASH_FILE" ]; then
        printf 'file not found: %s\n' "$DASH_FILE" >&2
        exit 2
    fi
fi

GRAFANA_STACK_DIR=/opt/stacks/grafana
GRAFANA_CONFIG_DIR="$GRAFANA_STACK_DIR/config/grafana"

GRAFANA_URL="http://grafana:3000/apis/dashboard.grafana.app/v1/namespaces/default"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASS="${GRAFANA_PASS:-admin}"

LOCAL_DASHBOARDS_DIR="provisioning/dashboards"
CURL_IMAGE=curlimages/curl:8.7.1
LOKI_WINDOW_S=300   # query_range window for Loki probes
LOKI_LIMIT=10       # max returned lines (response-size guard: pathological
                    # lines reach 160KB+, so 100 lines could exceed Loki's
                    # 4MB gRPC cap and fail an otherwise-valid query)

PASS=0
WARN=0
FAIL=0

command -v docker >/dev/null 2>&1 || { echo "docker not found" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 2; }
test -d "$GRAFANA_CONFIG_DIR" || { echo "not the deploy host ($GRAFANA_CONFIG_DIR missing)" >&2; exit 2; }

# HTTP body via the curl container (optionally with basic auth / method).
fetch() { # fetch <url> [extra curl args...]
    local url="$1"; shift
    docker run --rm --network shared "$CURL_IMAGE" -s -m 20 "$@" "$url" 2>/dev/null </dev/null
}

paint() { # paint <pass|warn|fail|none> <text>
    case $1 in
        pass) printf '%s%s%s' "$C_PASS_B" "$2" "$C_RESET" ;;
        warn) printf '%s%s%s' "$C_WARN_B" "$2" "$C_RESET" ;;
        fail) printf '%s%s%s' "$C_FAIL_B" "$2" "$C_RESET" ;;
        *)    printf '%s' "$2" ;;
    esac
}

count() { # count <pass|warn|fail|none>
    case $1 in
        pass) PASS=$((PASS + 1)) ;;
        warn) WARN=$((WARN + 1)) ;;
        fail) FAIL=$((FAIL + 1)) ;;
    esac
}

# probe_* set _verdict (pass|warn|fail) and _result (plain text, printed raw).
_verdict=none
_result=none

# One request builder per backend: the suite scores the body via _interpret,
# the probe/file subcommands print it raw (both folded in from probe-query.sh).
q_prom() { # q_prom <query> -> raw response body
    fetch "http://prometheus:9090/api/v1/query" --data-urlencode "query=$1"
}

q_loki() { # q_loki <query> -> raw response body
    local now start
    now=$(( $(date +%s) * 1000000000 ))
    start=$(( now - LOKI_WINDOW_S * 1000000000 ))
    # Explicit step: with a 300s range and no step, Loki uses ~1s-granularity
    # steps, re-evaluating big [6h] windows dozens of times (probe timed out).
    fetch "http://loki:3100/loki/api/v1/query_range" -G \
        --data-urlencode "query=$1" \
        --data-urlencode "start=$start" \
        --data-urlencode "end=$now" \
        --data-urlencode "step=$LOKI_WINDOW_S" \
        --data-urlencode "limit=$LOKI_LIMIT"
}

# metrics-generation queries (| rate(), | count_over_time(), | avg(), | by (...)
# only compile on /api/metrics/query; trace searches only on /api/search.
tempo_endpoint() { # tempo_endpoint <query> -> api/metrics/query | api/search
    if [[ "$1" =~ \|\ *(rate|count_over_time|avg|sum|min|max|p[0-9]+|histogram|by\ ) ]]; then
        printf 'api/metrics/query'
    else
        printf 'api/search'
    fi
}

q_tempo() { # q_tempo <endpoint> <query> -> raw response body
    fetch "http://grafana-tempo:3200/$1" -G --data-urlencode "q=$2"
}

probe_prometheus() { _interpret "$(q_prom "$1")" prometheus; }
probe_loki() { _interpret "$(q_loki "$1")" loki; }
probe_tempo() { _interpret "$(q_tempo "$(tempo_endpoint "$1")" "$1")" tempo; }

# --- probe/file subcommands: raw mode, no verdict, no counting ---------------
raw() { # raw <body> — never print an invisible (whitespace-only) response
    if [ -z "${1//[[:space:]]}" ]; then
        printf '%s\n' "(empty response: probe timed out or failed before returning a body)"
    else
        printf '%s\n' "$1"
    fi
}

cmd_probe() { # cmd_probe <mode> <expr>
    case $1 in
        loki)          raw "$(q_loki "$2")" ;;
        prom)          raw "$(q_prom "$2")" ;;
        tempo-search)  raw "$(q_tempo "api/search" "$2")" ;;
        tempo-metrics) raw "$(q_tempo "api/metrics/query" "$2")" ;;
        tempo)         raw "$(q_tempo "$(tempo_endpoint "$2")" "$2")" ;;
    esac
}

cmd_file() { # cmd_file <dashboard.json> — probe every target expr, by datasource
    jq -r 'def ds_type:
            (if (.datasource | type) == "object" then (.datasource.type // "?")
            else (.datasource // "?") end);
        .. | objects | select(has("targets"))
        | ds_type as $ds | .title as $t
        | .targets[] | select(has("expr") and (.expr | type) == "string")
        | [$ds, $t, (.expr | @base64)] | @tsv' "$1" \
    | while IFS=$'\t' read -r ds title b64; do
        ds=${ds,,}
        expr=$(printf '%s' "$b64" | base64 -d)
        printf '== %s%s%s: [%s%s%s]\n   query: %s%s%s\n' "$C_SECTION" "$ds" "$C_RESET" "$C_MENTION" "$title" "$C_RESET" "$C_MENTION" "$expr" "$C_RESET"
        case $ds in
            loki)         cmd_probe loki "$expr" ;;
            prometheus)   cmd_probe prom "$expr" ;;
            tempo)        cmd_probe tempo "$expr" ;;
            *)            printf '   (skipped: datasource %s%s%s)\n\n' "$C_SECTION" "$ds" "$C_RESET" ;;
        esac
    done
}

_interpret() { # _interpret <raw-response> <prometheus|loki|tempo>
    local result=$1 kind=$2 status err err_entries err_reasons
    _verdict=fail
    _result=$result

    # Whitespace-only bodies (proxy keep-alive, truncated read) are as
    # unscorable as empty ones: without the strip test they fell through to the
    # non-JSON branch below and printed raw whitespace as the failure text.
    if [[ -z "${result//[[:space:]]}" ]]; then
        _result="(empty response: probe timed out or failed before returning a body)"
        return
    fi

    # Non-JSON (HTTP error text, timeouts) stays raw: print exactly what came back.
    # Exception: Loki's 4MB gRPC cap surfaces as plain `rpc error: …
    # ResourceExhausted` text when a window contains pathological (100KB+) log
    # lines. The query executed fine — that's a sampling limit, not a broken
    # expr, so score it WARN instead of FAIL. Matched only on the NON-JSON path
    # (and on the extracted JSON .error below) so a successful response whose
    # log data merely contains the phrase can never false-positive this gate.
    if ! jq -e . >/dev/null 2>&1 <<<"$result"; then
        if grep -qE 'ResourceExhausted|message larger than max' <<<"$result"; then
            _verdict=warn
            _result="response too large to sample (pathological log lines; query itself executes)"
        fi
        return
    fi

    status=$(jq -r '.status // empty' <<<"$result" 2>/dev/null)
    err=$(jq -r '.error // .message // empty' <<<"$result" 2>/dev/null)
    if [ -n "$err" ] || { [ -n "$status" ] && [ "$status" != "success" ]; }; then
        _result=${err:-$status}
        [ -n "$_result" ] || _result=$result
        # Same cap exception on a JSON error body (message/extracted text only).
        if grep -qE 'ResourceExhausted|message larger than max' <<<"$_result"; then
            _verdict=warn
            _result="response too large to sample (pathological log lines; query itself executes)"
        fi
        return
    fi

    # Valid JSON but not a response we can score (e.g. a bare array from a
    # proxy): without this gate the empty extractions below fall through to
    # a false PASS. loki/prometheus must carry .data.result as an array —
    # `{"data":{}}`/`{"data":null}` would otherwise score a silent PASS too.
    if ! jq -e --arg kind "$kind" '
        type == "object" and (
            ($kind != "tempo" and ((.data.result? | type) == "array"))
            or ($kind == "tempo" and (has("traces") or has("status")))
        )' >/dev/null 2>&1 <<<"$result"; then
        _result="unrecognized response shape: $(printf '%s' "$result" | head -c 400)"
        return
    fi

    case $kind in
        loki)
            err_entries=$(jq -r '[.data.result[] | select((.stream.__error__ // .metric.__error__) != null) | (.values | length)] | add // 0' <<<"$result" 2>/dev/null)
            err_reasons=$(jq -r '[.data.result[] | .stream.__error__ // .metric.__error__ | select(. != null)] | unique | join(",")' <<<"$result" 2>/dev/null)
            if [ "${err_entries:-0}" -gt 0 ]; then
                _verdict=warn
                # Only stream results hold log lines to sample; a metric result
                # (rate/count_over_time) has no lines, so it must not claim one.
                if jq -e '.data.result[0]? | has("stream")' >/dev/null 2>&1 <<<"$result"; then
                    _result="success, but $err_entries entries failed parsing ($err_reasons; sampled to first $LOKI_LIMIT log lines)"
                else
                    _result="success, but $err_entries entries failed parsing ($err_reasons)"
                fi
            elif jq -e '.data.result? | type == "array" and length == 0' >/dev/null 2>&1 <<<"$result"; then
                _verdict=pass
                _result="success (empty: no matching lines/series in window)"
            else
                _verdict=pass
                _result="success"
            fi
            ;;
        tempo)
            _verdict=pass
            if jq -e '.traces' >/dev/null 2>&1 <<<"$result"; then
                _result="success ($(jq -r '.traces | length' <<<"$result" 2>/dev/null) traces)"
            elif jq -e '.data.result? | type == "array" and length == 0' >/dev/null 2>&1 <<<"$result"; then
                _result="success (empty: 0 series)"
            else
                _result=${status:-success}
            fi
            ;;
        *)
            _verdict=pass
            if jq -e '.data.result? | type == "array" and length == 0' >/dev/null 2>&1 <<<"$result"; then
                _result="success (empty: 0 series)"
            else
                _result=${status:-success}
            fi
            ;;
    esac
}

# Subcommand dispatch: raw probe/file output instead of the suite.
case "$MODE" in
    probe) cmd_probe "$PROBE_MODE" "$PROBE_EXPR"; exit 0 ;;
    file)  cmd_file "$DASH_FILE"; exit 0 ;;
esac

printf '%s=== Dashboard Provisioning Status ===%s\n' "$C_SECTION" "$C_RESET"
echo ""

declare -A local_jsons

while IFS= read -r _local_json; do
    _local_path=$(realpath -s --relative-to="$GRAFANA_CONFIG_DIR" "$_local_json")
    _local_sum=$(md5sum "$_local_json" | awk '{print $1}')
    local_jsons["$_local_path"]="$_local_sum"
    unset _local_path _local_sum
done < <(find "$GRAFANA_CONFIG_DIR/$LOCAL_DASHBOARDS_DIR" -type f -name '*.json')

# Get all dashboards
DASHBOARDS=$(fetch "$GRAFANA_URL/dashboards" -u "$GRAFANA_USER:$GRAFANA_PASS")
if ! printf '%s' "$DASHBOARDS" | jq -e '.items' >/dev/null 2>&1; then
    echo "cannot fetch dashboards from the Grafana API:" >&2
    printf '%s\n' "$DASHBOARDS" | head -c 400 >&2
    echo >&2
    exit 2
fi

printf 'Total: %s\n' "$(printf '%s' "$DASHBOARDS" | jq -r '.items | length')"

while IFS= read -r spec; do
    _src_path=$(printf '%s' "$spec" | jq -r '.annotations."grafana.app/sourcePath" // empty')
    _deploy_sum=$(printf '%s' "$spec" | jq -r '.annotations."grafana.app/sourceChecksum" // empty')

    if [ -z "$_src_path" ]; then
        echo " - (unmanaged dashboard: no sourcePath annotation)"
        count warn
        continue
    fi

    _deploy_path=$(realpath -s --relative-to=/etc/grafana "$_src_path")

    if [ -n "$_deploy_sum" ] && [ "${local_jsons[$_deploy_path]:-}" = "$_deploy_sum" ]; then
        _dep_verdict=pass
        _dep_text="Deployed"
    else
        _dep_verdict=fail
        _dep_text="Not deployed"
    fi
    count "$_dep_verdict"

    printf ' - %s%s%s %s ' "$C_MENTION" "$_deploy_sum" "$C_RESET" "$_deploy_path"
    paint "$_dep_verdict" "$_dep_text"
    printf '.\n'

    while IFS= read -r panel; do
        _panel_title=$(printf '%s' "$panel" | jq -r '.title // "-"')
        _panel_source=$(printf '%s' "$panel" | jq -r 'if (.datasource | type) == "object" then (.datasource.type // "?") else (.datasource // "?") end')
        _panel_type=$(printf '%s' "$panel" | jq -r '.type // "-"')

        printf '   - source: %s%s%s, type: %s%s%s, title: %s%s%s\n' \
            "$C_SECTION" "$_panel_source" "$C_RESET" "$C_MENTION" "$_panel_type" "$C_RESET" "$C_MENTION" "$_panel_title" "$C_RESET"

        while IFS= read -r target; do
            _target_expr=$(printf '%s' "$target" | jq -r '.expr // empty')
            _target_legend=$(printf '%s' "$target" | jq -r '.legendFormat // "-"')

            if [ -z "$_target_expr" ]; then
                printf '     - legend: %s%s%s, result: (no expr)\n' "$C_MENTION" "$_target_legend" "$C_RESET"
                continue
            fi

            _verdict=none
            _result=none
            case ${_panel_source,,} in
                loki)       probe_loki "$_target_expr" ;;
                prometheus) probe_prometheus "$_target_expr" ;;
                tempo)      probe_tempo "$_target_expr" ;;
                *)
                    _verdict=warn
                    _result="unchecked datasource: $_panel_source"
                    ;;
            esac
            count "$_verdict"

            printf '     - legend: %s%s%s, result: ' "$C_MENTION" "$_target_legend" "$C_RESET"
            paint "$_verdict" "$_result"
            printf '\n'
            printf '       query: %s%s%s\n' "$C_MENTION" "$_target_expr" "$C_RESET"
        done < <(printf '%s' "$panel" | jq -rc '.targets // [] | .[]')
    done < <(printf '%s' "$spec" | jq -rc '.panels // [] | .[]')
done < <(printf '%s' "$DASHBOARDS" | jq -rc '.items[] | {annotations: (.metadata.annotations // {}), panels: (.spec.panels // [])}')

echo ""
printf '%s== summary ==%s\n' "$C_SECTION" "$C_RESET"
printf '  PASS=%s%d%s WARN=%s%d%s FAIL=%s%d%s\n' "$C_PASS_B" "$PASS" "$C_RESET" "$C_WARN_B" "$WARN" "$C_RESET" "$C_FAIL_B" "$FAIL" "$C_RESET"
if [ "$FAIL" -gt 0 ]; then
    printf '  result: %s%d FAIL%s\n' "$C_FAIL_B" "$FAIL" "$C_RESET"
    exit 1
fi
printf '  result: %sno failures%s\n' "$C_PASS_B" "$C_RESET"
exit 0
