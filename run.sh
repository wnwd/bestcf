#!/usr/bin/env bash
# bestcf — run XIU2 CloudflareSpeedTest, distribute the best IPs across
# per-domain records (each in its own zone), grouped + sticky:
#   * targets.conf lists records as: <fqdn> <zone name> <group>
#   * records in one group always share a single IP
#   * a group keeps its current IP while it stays in the qualified pool;
#     only a group whose IP dropped out gets the best free pool IP
#   * if the qualified pool runs dry, nobody's records are touched
#
# Required env: CF_API_TOKEN. See .env.example / README.md for the rest.
set -u

API_BASE="https://api.cloudflare.com/client/v4"
CF_API_TOKEN="${CF_API_TOKEN:-}"
TARGETS_FILE="${TARGETS_FILE:-/app/targets.conf}"
CF_TTL="${CF_TTL:-120}"
CF_PROXIED="${CF_PROXIED:-false}"      # records must stay grey-cloud
RUN_INTERVAL="${RUN_INTERVAL:-3600}"   # seconds; 0 = one-shot
CFST_ARGS="${CFST_ARGS:--dn 10}"       # need a deep enough pool to share out
MAX_LATENCY_MS="${MAX_LATENCY_MS:-300}" # hard cap for a qualified IP
LATENCY_FACTOR="${LATENCY_FACTOR:-2}"   # ...and at most this x the best latency

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

api() { # method path [json-data]
  local method="$1" path="$2" data="${3:-}"
  if [ -n "$data" ]; then
    curl -fsS -X "$method" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H 'Content-Type: application/json' \
      --data "$data" "${API_BASE}${path}"
  else
    curl -fsS -X "$method" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H 'Content-Type: application/json' \
      "${API_BASE}${path}"
  fi
}

declare -A ZONE_IDS=()
ZID=""
zone_id() { # zone name -> sets ZID (cached). No stdout: callers must not use
            # $(...) here, a subshell would throw the cache away.
  local name="$1"
  if [ -z "${ZONE_IDS[$name]:-}" ]; then
    local resp id
    resp="$(api GET "/zones?name=${name}")" || die "zone lookup failed: ${name}"
    id="$(printf '%s' "$resp" | jq -r '.result[0].id // empty')"
    [ -n "$id" ] || die "zone not found (or token cannot see it): ${name}"
    ZONE_IDS[$name]="$id"
    log "zone ${name} -> ${id}"
  fi
  ZID="${ZONE_IDS[$name]}"
}

# ---- targets -------------------------------------------------------------
REC_NAME=(); REC_ZONE=(); REC_GROUP=(); T_GROUPS=()
load_targets() {
  [ -f "$TARGETS_FILE" ] || die "targets file not found: ${TARGETS_FILE} — mount your real targets.conf (see targets.conf.example); it is not baked into the image"
  local name zone group g seen
  while read -r name zone group; do
    case "$name" in ''|'#'*) continue ;; esac
    [ -n "${zone:-}" ] && [ -n "${group:-}" ] || die "bad targets line: $name $zone $group"
    REC_NAME+=("$name"); REC_ZONE+=("$zone"); REC_GROUP+=("$group")
    seen=0
    for g in "${T_GROUPS[@]:-}"; do [ "$g" = "$group" ] && seen=1; done
    [ "$seen" = "1" ] || T_GROUPS+=("$group")
  done < "$TARGETS_FILE"
  [ "${#REC_NAME[@]}" -gt 0 ] || die "no targets in ${TARGETS_FILE}"
}

# ---- Cloudflare record read/write ---------------------------------------
record_current() { # zone-id fqdn -> sets CUR_ID / CUR_IP
  local zid="$1" name="$2" resp
  resp="$(api GET "/zones/${zid}/dns_records?type=A&name=${name}")" || return 1
  CUR_ID="$(printf '%s' "$resp" | jq -r '.result[0].id // empty')"
  CUR_IP="$(printf '%s' "$resp" | jq -r '.result[0].content // empty')"
}

sync_record() { # zone-id fqdn ip current-id current-ip
  local zid="$1" name="$2" ip="$3" rid="$4" cur="$5" payload
  payload="$(jq -cn --arg name "$name" --arg content "$ip" \
    --argjson ttl "$CF_TTL" --argjson proxied "$CF_PROXIED" \
    '{type:"A", name:$name, content:$content, ttl:$ttl, proxied:$proxied}')"
  if [ -z "$rid" ]; then
    api POST "/zones/${zid}/dns_records" "$payload" >/dev/null \
      || { log "ERROR: create failed for ${name}"; return 1; }
    log "created  ${name} -> ${ip}"
  elif [ "$cur" = "$ip" ]; then
    log "unchanged ${name} = ${ip}"
  else
    api PUT "/zones/${zid}/dns_records/${rid}" "$payload" >/dev/null \
      || { log "ERROR: update failed for ${name}"; return 1; }
    log "updated  ${name}: ${cur} -> ${ip}"
  fi
}

# ---- qualification pool ---------------------------------------------------
qualified_pool() { # result.csv -> one qualified IP per line, best first
  awk -F',' -v maxms="$MAX_LATENCY_MS" -v factor="$LATENCY_FACTOR" '
    NR>1 {
      gsub(/\r/, "", $0)
      if ($1 == "") next
      n++; ip[n]=$1; loss[n]=$4; lat[n]=$5
      if (min == "" || $5 < min) min = $5
    }
    END {
      cap = min * factor; if (cap > maxms) cap = maxms
      for (i = 1; i <= n; i++)
        if (loss[i] == 0 && lat[i] <= cap) print ip[i]
    }' result.csv 2>/dev/null
}

in_list() { local needle="$1"; shift; local x; for x in "$@"; do [ "$x" = "$needle" ] && return 0; done; return 1; }

run_once() {
  log "running: cfst ${CFST_ARGS}"
  ./cfst $CFST_ARGS -o result.csv </dev/null \
    || { log "ERROR: cfst exited non-zero"; return 1; }

  local -a POOL=()
  mapfile -t POOL < <(qualified_pool)
  if [ "${#POOL[@]}" -eq 0 ]; then
    log "ERROR: no qualified IPs this round; all records left untouched"
    return 1
  fi
  log "qualified pool (${#POOL[@]}): ${POOL[*]}"

  # read current state
  local -a CURID=() CURIP=()
  local i zid
  for i in "${!REC_NAME[@]}"; do
    zone_id "${REC_ZONE[$i]}"; zid="$ZID"
    CUR_ID=""; CUR_IP=""
    record_current "$zid" "${REC_NAME[$i]}" \
      || { log "ERROR: query failed for ${REC_NAME[$i]}"; return 1; }
    CURID[$i]="$CUR_ID"; CURIP[$i]="$CUR_IP"
  done

  # sticky assignment per group
  local -A GROUP_IP=() GROUP_CUR=() USED=()
  local g first ip pick
  for g in "${T_GROUPS[@]}"; do
    first=""
    for i in "${!REC_NAME[@]}"; do
      if [ "${REC_GROUP[$i]}" = "$g" ]; then first="$i"; break; fi
    done
    GROUP_CUR[$g]="${CURIP[$first]}"
  done
  for g in "${T_GROUPS[@]}"; do
    if in_list "${GROUP_CUR[$g]}" "${POOL[@]}"; then
      GROUP_IP[$g]="${GROUP_CUR[$g]}"; USED["${GROUP_CUR[$g]}"]=1
      log "group ${g}: sticky keep ${GROUP_CUR[$g]}"
    fi
  done
  for g in "${T_GROUPS[@]}"; do
    [ -n "${GROUP_IP[$g]:-}" ] && continue
    pick=""
    for ip in "${POOL[@]}"; do
      if [ -z "${USED[$ip]:-}" ]; then pick="$ip"; break; fi
    done
    if [ -z "$pick" ]; then
      pick="${POOL[0]}"
      log "group ${g}: pool exhausted, sharing best IP ${pick}"
    else
      log "group ${g}: reassign ${GROUP_CUR[$g]:-none} -> ${pick}"
    fi
    GROUP_IP[$g]="$pick"; USED["$pick"]=1
  done

  # write out
  local rc=0
  for i in "${!REC_NAME[@]}"; do
    zone_id "${REC_ZONE[$i]}"; zid="$ZID"
    sync_record "$zid" "${REC_NAME[$i]}" "${GROUP_IP[${REC_GROUP[$i]}]}" \
      "${CURID[$i]}" "${CURIP[$i]}" || rc=1
  done
  return $rc
}

main() {
  [ -n "$CF_API_TOKEN" ] || die "CF_API_TOKEN is required"
  case "$CF_PROXIED" in true|false) ;; *) die "CF_PROXIED must be true or false" ;; esac
  printf '%s' "$CF_TTL" | grep -Eq '^[0-9]+$' || die "CF_TTL must be a number"
  load_targets
  log "targets: ${#REC_NAME[@]} records in ${#T_GROUPS[@]} groups"
  while true; do
    run_once
    local rc=$?
    if [ "$RUN_INTERVAL" = "0" ]; then
      log "one-shot mode, exit ${rc}"
      exit "$rc"
    fi
    [ "$rc" = "0" ] || log "cycle failed; will retry next round"
    log "sleeping ${RUN_INTERVAL}s"
    sleep "$RUN_INTERVAL" &
    wait $!
  done
}

main "$@"
