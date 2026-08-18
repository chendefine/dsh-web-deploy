#!/bin/sh
# Discover dsh runtime services and apply the selected HTTP entry override.
# POSIX sh port of the former compose_mode.py; subcommands, output, exit codes,
# and semantics are unchanged.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd) || exit 2
COMPOSE_FILE="$ROOT/compose.yaml"
HTTP_ALIAS=dsh-http-entry
ALL_PROFILES="--profile dsh --profile auth --profile tls --profile build"
LEGACY_CONTAINERS="dsh-deploy-single dsh-deploy-dsh-http dsh-deploy-auth-http"

# Temporary override/model files are removed on exit (and on INT/TERM, which
# re-raise after cleanup so exit codes stay 130/143 like the Python original).
TMP_FILES=
on_exit() {
  for f in $TMP_FILES; do rm -f "$f"; done
}
register_tmp() {
  TMP_FILES="$TMP_FILES $1"
}
trap on_exit EXIT
trap 'on_exit; trap - INT; kill -INT $$' INT
trap 'on_exit; trap - TERM; kill -TERM $$' TERM

die() {
  echo "error: $*" >&2
  exit 2
}

usage() {
  name=${0##*/}
  echo "usage: $name services|primary|data-dirs|validate|entry-clean|legacy-clean|tls-refresh [container]" >&2
  echo "       $name run COMPOSE_ARGS..." >&2
  echo "       $name target-service 'CLI_ARGS'" >&2
  echo "       $name target-args 'CLI_ARGS'" >&2
}

# ---------------------------------------------------------------------------
# compose.yaml model discovery (declaration order of real *dsh-runtime services
# is contractual: the first one is the no-auth instance).
# ---------------------------------------------------------------------------
services() {
  awk '
    $0 == "services:" { in_services = 1; cur = ""; next }
    in_services && $0 != "" && $0 !~ /^ / && $0 !~ /^#/ { exit }
    in_services && /^  [A-Za-z0-9][A-Za-z0-9_.-]*:([[:space:]]*#.*)?$/ {
      cur = $0
      sub(/^  /, "", cur)
      sub(/:.*/, "", cur)
      next
    }
    in_services && cur != "" && cur != "dsh-runtime" \
      && /^    <<:[[:space:]]*\*dsh-runtime([[:space:]]*#.*)?$/ {
      if (!(cur in seen)) { seen[cur] = 1; print cur }
    }
  ' "$COMPOSE_FILE"
}

primary() {
  first=$(services | sed -n '1p')
  if [ -z "$first" ]; then
    echo "error: compose.yaml must declare at least one real service using" \
      "'<<: *dsh-runtime'" >&2
    return 2
  fi
  printf '%s\n' "$first"
}

# Host-side bind sources of the per-user data mounts (/data/dsh-home and
# /data/workspace) of every real *dsh-runtime service, one absolute path per
# line; relative sources resolve against ROOT, duplicates collapse. The
# user_admin.sh generator emits ./dsh-home/<name> and ./workspace/<name>, but
# instances can be renamed or their mounts hand-re-pointed, so callers
# (Taskfile dirs:base) must take the paths from the compose model instead of
# assuming a fixed user name. Sources using variable or ~ expansion cannot be
# resolved statically and are skipped with a warning.
data_dirs() {
  awk -v root="$ROOT" '
    function emit(src) {
      if (src ~ /^\.\//) src = substr(src, 3)
      if (src ~ /^[$~]/ || src ~ /\$/) {
        printf "warning: skipping data dir with non-static source: %s\n", src | "cat 1>&2"
        return
      }
      if (src !~ /^\//) src = root "/" src
      if (!(src in seen)) { seen[src] = 1; print src }
    }
    $0 == "services:" { in_services = 1; cur = ""; runtime = 0; next }
    in_services && $0 != "" && $0 !~ /^ / && $0 !~ /^#/ { exit }
    in_services && /^  [A-Za-z0-9][A-Za-z0-9_.-]*:([[:space:]]*#.*)?$/ {
      cur = $0
      sub(/^  /, "", cur)
      sub(/:.*/, "", cur)
      runtime = 0
      next
    }
    in_services && cur != "" && cur != "dsh-runtime" \
      && /^    <<:[[:space:]]*\*dsh-runtime([[:space:]]*#.*)?$/ {
      runtime = 1
      next
    }
    in_services && runtime && /^      - / {
      vol = $0
      sub(/^      - /, "", vol)
      sub(/[[:space:]]*#.*$/, "", vol)
      sub(/:(ro|rw)$/, "", vol)
      if (vol ~ /:\/data\/dsh-home$/) { sub(/:\/data\/dsh-home$/, "", vol); emit(vol) }
      else if (vol ~ /:\/data\/workspace$/) { sub(/:\/data\/workspace$/, "", vol); emit(vol) }
    }
  ' "$COMPOSE_FILE"
}

project_name() {
  name=$(sed -n 's/^name:[[:space:]]*\([A-Za-z0-9][A-Za-z0-9_.-]*\)[[:space:]]*$/\1/p' \
    "$COMPOSE_FILE" | sed -n '1p')
  if [ -z "$name" ]; then
    echo "error: compose.yaml must declare a top-level project name" >&2
    return 2
  fi
  printf '%s\n' "$name"
}

# ---------------------------------------------------------------------------
# Per-instance targeting: "task dsh:up/down/restart -- <name> [flags]".
# The raw CLI args split into an optional leading instance name plus the
# remaining Compose flags; the name resolves against the declared services.
# ---------------------------------------------------------------------------
# Splits one raw CLI-args string (unquoted expansion is intentional) into
# TP_NAME (first word unless it starts with '-') and TP_ARGS (the rest).
parse_target() {
  TP_NAME=
  TP_ARGS=
  set -f
  set -- ${1-}
  set +f
  if [ $# -gt 0 ]; then
    case $1 in
      -*) ;;
      *) TP_NAME=$1; shift ;;
    esac
  fi
  TP_ARGS=$*
}

# Maps an instance name (user or dsh-user) to its service name, mirroring the
# resolution rules of the Taskfile `shell` task; unknown names fail with the
# list of available instances.
resolve_service() {
  requested=${1:-}
  instance=${requested#dsh-}
  match=$(services | grep -Fx -m1 "$instance" || true)
  [ -n "$match" ] || match=$(services | grep -Fx -m1 "dsh-$instance" || true)
  if [ -z "$match" ]; then
    echo "error: unknown dsh instance '$requested'; available instances:" >&2
    services >&2
    return 2
  fi
  printf '%s\n' "$match"
}

# Prints the resolved target service name, or nothing when no target is given.
target_service() {
  parse_target "$1" || return 2
  [ -n "$TP_NAME" ] || return 0
  resolve_service "$TP_NAME"
}

# Prints the Compose flags that follow the target name (empty when none).
target_args() {
  parse_target "$1" || return 2
  [ -n "$TP_ARGS" ] && printf '%s\n' "$TP_ARGS"
  return 0
}

# Sets MODE_AUTH / MODE_PORT / MODE_ENTRY from the environment (the Taskfile
# always supplies an explicit prefix; defaults match the Python original).
normalized_mode() {
  auth_value=$(printf '%s' "${AUTH_GATEWAY-false}" \
    | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  case "$auth_value" in
    true|false) ;;
    *)
      echo "error: AUTH_GATEWAY must be true or false (got '$auth_value')" >&2
      return 2
      ;;
  esac

  port_value=$(printf '%s' "${HTTP_PORT-3080}" \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  case "$port_value" in
    ''|*[!0-9]*)
      echo "error: HTTP_PORT must be between 1 and 65535 (got '$port_value')" >&2
      return 2
      ;;
  esac
  if [ "$port_value" -lt 1 ] || [ "$port_value" -gt 65535 ]; then
    echo "error: HTTP_PORT must be between 1 and 65535 (got '$port_value')" >&2
    return 2
  fi

  if [ "$auth_value" = true ]; then
    entry=gateway
  else
    entry=$(primary) || return 2
  fi
  case "$entry" in
    ''|*[!A-Za-z0-9_.-]*|[.-]*)
      echo "error: unsafe HTTP entry service name: '$entry'" >&2
      return 2
      ;;
  esac

  MODE_AUTH=$auth_value
  MODE_PORT=$port_value
  MODE_ENTRY=$entry
}

# ---------------------------------------------------------------------------
# Docker housekeeping
# ---------------------------------------------------------------------------
container_service_label() {
  docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' \
    "$1" 2>/dev/null
}

entry_clean() {
  normalized_mode || return 2
  project=$(project_name) || return 2
  cids=$(docker ps -q --filter "label=com.docker.compose.project=$project" 2>/dev/null) \
    || die "docker ps failed"
  for cid in $cids; do
    docker port "$cid" 2>/dev/null \
      | grep -qE "^[0-9]+/tcp -> .*:${MODE_PORT}\$" || continue
    svc=$(container_service_label "$cid")
    [ "$svc" = "$MODE_ENTRY" ] && continue
    echo "removing $svc container $(printf '%.12s' "$cid") that still holds HTTP_PORT ${MODE_PORT}"
    docker rm -f "$cid" >/dev/null 2>&1
  done
  return 0
}

legacy_clean() {
  project=$(project_name) || return 2
  for name in $LEGACY_CONTAINERS; do
    lbl=$(docker inspect -f \
      '{{ index .Config.Labels "com.docker.compose.project" }}' "$name" 2>/dev/null) \
      || continue
    [ "$lbl" = "$project" ] || continue
    echo "removing legacy container $name (service ${name#dsh-deploy-})"
    docker rm -f "$name" >/dev/null 2>&1
  done
  return 0
}

tls_refresh() {
  container=${1:-dsh-base-tls}
  running=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null) || return 0
  [ "$running" = true ] || return 0
  docker exec "$container" nginx -s reload >/dev/null 2>&1
  return 0
}

# ---------------------------------------------------------------------------
# Mode-aware Compose invocation
# ---------------------------------------------------------------------------
write_override() {
  _entry=$1
  _port=$2
  _out=$3
  {
    printf 'services:\n'
    printf '  %s:\n' "$_entry"
    printf '    ports:\n'
    printf '      - target: 80\n'
    printf '        published: "%s"\n' "$_port"
    printf '        protocol: tcp\n'
    printf '    networks:\n'
    printf '      runtime:\n'
    printf '        aliases:\n'
    printf '          - %s\n' "$HTTP_ALIAS"
  } > "$_out"
}

run_compose() {
  normalized_mode || return 2
  override=$(mktemp "${TMPDIR:-/tmp}/dsh-compose-mode-XXXXXX.yaml") \
    || die "mktemp failed"
  register_tmp "$override"
  write_override "$MODE_ENTRY" "$MODE_PORT" "$override"
  cd "$ROOT" || return 2
  COMPOSE_PROFILES= docker compose -f "$COMPOSE_FILE" -f "$override" "$@"
}

# ---------------------------------------------------------------------------
# Model validation
# ---------------------------------------------------------------------------
render_model() {
  _out=$1
  shift
  if ! COMPOSE_PROFILES= docker compose -f "$COMPOSE_FILE" $ALL_PROFILES \
      config --format json > "$_out" 2> "$_out.err"; then
    cat "$_out.err" >&2
    rm -f "$_out.err"
    die "docker compose config failed"
  fi
  rm -f "$_out.err"
}

validate_model() {
  command -v jq >/dev/null 2>&1 || die "validate requires jq"
  normalized_mode || return 2

  runtimes_list=$(services)
  [ -n "$runtimes_list" ] \
    || die "compose.yaml must declare at least one real service using '<<: *dsh-runtime'"
  primary_svc=$(printf '%s\n' "$runtimes_list" | sed -n '1p')

  base_json=$(mktemp "${TMPDIR:-/tmp}/dsh-validate-base-XXXXXX.json") || die "mktemp failed"
  eff_json=$(mktemp "${TMPDIR:-/tmp}/dsh-validate-eff-XXXXXX.json") || die "mktemp failed"
  register_tmp "$base_json"
  register_tmp "$eff_json"

  render_model "$base_json"

  override=$(mktemp "${TMPDIR:-/tmp}/dsh-compose-mode-XXXXXX.yaml") || die "mktemp failed"
  register_tmp "$override"
  write_override "$MODE_ENTRY" "$MODE_PORT" "$override"
  # render_model with the override appended
  if ! COMPOSE_PROFILES= docker compose -f "$COMPOSE_FILE" -f "$override" \
      $ALL_PROFILES config --format json > "$eff_json" 2> "$eff_json.err"; then
    cat "$eff_json.err" >&2
    rm -f "$eff_json.err"
    die "docker compose config failed"
  fi
  rm -f "$eff_json.err"

  cd "$ROOT" || return 2

  runtimes_json=$(printf '%s\n' "$runtimes_list" | jq -Rn '[inputs]')
  if [ "$MODE_AUTH" = true ]; then
    expected_ports='[]'
  else
    expected_ports=$(printf '[%s]' "\"$primary_svc\"")
  fi

  jq_prog=$(cat <<'JQ'
. as $eff | $base[0] as $base |
[
  (if (($base.services? // null) | type) != "object" or (($eff.services? // null) | type) != "object"
   then "rendered Compose model has no services map"
   else empty end),

  ([($eff.services // {}) | keys[]
    | select(. == "dsh-single" or . == "dsh-http" or . == "auth-http")]
   | if length > 0 then "removed services are still present: " + join(", ") else empty end),

  ([$runtimes[] | . as $r | select((($eff.services // {}) | has($r)) | not)]
   | if length > 0 then "runtime service '\(.[0])' is missing from the rendered model" else empty end),

  (if (($eff.services // {}) | has($entry)) | not
   then "selected HTTP entry service '\($entry)' is missing"
   else empty end),

  ([($base.services // {}) | to_entries[]
     | select(((.value.ports // []) | map(.target | tostring) | index("80")) != null)
     | .key]
   | if length > 0 then "base compose.yaml must not publish HTTP ports: " + join(", ") else empty end),

  ([($eff.services // {}) | to_entries[]
     | select(((.value.ports // []) | map(.target | tostring) | index("80")) != null)
     | {owner: .key,
        published: ([.value.ports[] | select((.target | tostring) == "80")
                     | (.published | tostring)] | join(","))}]
   | if length != 1
     then "expected exactly one HTTP publisher, found: "
          + (if length == 0 then "none" else (map(.owner) | join(", ")) end)
     elif (.[0].owner != $entry or .[0].published != $port)
     then "HTTP publisher must be \($entry):\($port)->80, got \(.[0].owner):\(.[0].published)->80"
     else empty end),

  ([($eff.services // {}) | to_entries[]
     | select(((.value.networks.runtime.aliases? // []) | index($alias)) != null)
     | .key]
   | if length != 1 or .[0] != $entry
     then "\($alias) must belong only to \($entry); found: "
          + (if length == 0 then "none" else join(", ") end)
     else empty end),

  ([$runtimes[] | . as $r
     | select(((($eff.services // {})[$r].ports // []) | length) > 0) | $r]
   | if . != $expected_ports
     then "runtime host-port owners do not match the selected mode: expected \($expected_ports), got \(.)"
     else empty end),

  (if (($eff.services // {})["dsh-runtime"].profiles? // []) != ["build"]
   then "build-only dsh-runtime service must have only the build profile"
   else empty end)
]
| .[]
JQ
)

  errs=$(jq -r --arg entry "$MODE_ENTRY" --arg port "$MODE_PORT" \
    --arg alias "$HTTP_ALIAS" --argjson runtimes "$runtimes_json" \
    --argjson expected_ports "$expected_ports" --slurpfile base "$base_json" \
    "$jq_prog" "$eff_json")
  if [ -n "$errs" ]; then
    printf '%s\n' "$errs" | sed 's/^/error: /' >&2
    return 2
  fi

  printf 'primary=%s http_service=%s dsh_services=%s http_port=%s\n' \
    "$primary_svc" "$MODE_ENTRY" \
    "$(printf '%s\n' "$runtimes_list" | paste -sd, -)" "$MODE_PORT"
}

# ---------------------------------------------------------------------------
main() {
  if [ $# -lt 1 ]; then
    usage
    exit 2
  fi
  command=$1
  case "$command" in
    services) services ;;
    primary) primary ;;
    data-dirs) data_dirs ;;
    validate) validate_model ;;
    entry-clean) entry_clean ;;
    legacy-clean) legacy_clean ;;
    tls-refresh) tls_refresh "${2:-dsh-base-tls}" ;;
    target-service)
      [ $# -ge 2 ] || die "target-service requires the raw CLI args"
      target_service "$2"
      ;;
    target-args)
      [ $# -ge 2 ] || die "target-args requires the raw CLI args"
      target_args "$2"
      ;;
    run)
      shift
      run_compose "$@"
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
