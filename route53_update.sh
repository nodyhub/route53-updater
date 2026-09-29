#!/usr/bin/env bash
set -uo pipefail

# This script updates AWS Route 53 A/AAAA records with the current external
# IPv4/IPv6 address of this machine. It only manages the record type(s) that
# already exist for the hostname -- e.g. if only an AAAA record exists, only
# the AAAA record is kept in sync, and the same applies to A records. It
# checks whether the address has actually changed before updating, and can
# optionally run in a loop to periodically re-check.
#
## Source of the idea: https://unix.stackexchange.com/a/410518

# **Required environment variables:**
#   ROUTE53_HOSTED_ZONE_ID  Route 53 Hosted Zone ID (e.g. ZXC...AMPLE)
#   ROUTE53_HOSTNAME        The record/host name to update (e.g. rpi)
#   ROUTE53_DOMAIN          The domain the hostname lives under (e.g. example.com)
#                           Combined into the FQDN "$ROUTE53_HOSTNAME.$ROUTE53_DOMAIN"
#
# **Optional environment variables:**
#   UPDATE_INTERVAL   If set, the script runs in a loop, updating every this
#                      many seconds (e.g. 900 = 15 minutes). If unset, the
#                      script runs once and exits.
#   ROUTE53_TTL        TTL (in seconds) to set on updated records. Default: 600
#   RECORD_TYPES       Space separated list of record types (A and/or AAAA)
#                      to create when NEITHER an A nor an AAAA record exists
#                      yet for the hostname (first-time bootstrap). Ignored
#                      once a record already exists -- existing record types
#                      are always the ones kept in sync. Default: "A"
#
# Ensure the AWS CLI is installed and configured with credentials/permissions
# to read and write records in the target hosted zone (e.g. via
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_DEFAULT_REGION, or
# `aws configure`).

# Log function to prepend an ISO-8601 timestamp to every message.
log() {
  echo "$(date -Iseconds) $*"
}

# --- Configuration & validation --------------------------------------------

ROUTE53_TTL="${ROUTE53_TTL:-600}"
RECORD_TYPES="${RECORD_TYPES:-A}"

if [ -z "${ROUTE53_HOSTED_ZONE_ID:-}" ] || [ -z "${ROUTE53_HOSTNAME:-}" ] || [ -z "${ROUTE53_DOMAIN:-}" ]; then
  log "Error: ROUTE53_HOSTED_ZONE_ID, ROUTE53_HOSTNAME and ROUTE53_DOMAIN must all be set."
  log "  For example:"
  log "  export ROUTE53_HOSTED_ZONE_ID=ZXCVBNMEXAMPLE"
  log "  export ROUTE53_HOSTNAME=rpi"
  log "  export ROUTE53_DOMAIN=your-route53-domain.com"
  exit 1
fi

ROUTE53_DOMAIN_NAME="${ROUTE53_HOSTNAME}.${ROUTE53_DOMAIN}"

if [ -n "${UPDATE_INTERVAL:-}" ] && ! [[ "$UPDATE_INTERVAL" =~ ^[0-9]+$ ]]; then
  log "Error: UPDATE_INTERVAL must be a positive integer (number of seconds)."
  exit 1
fi

if ! [[ "$ROUTE53_TTL" =~ ^[0-9]+$ ]]; then
  log "Error: ROUTE53_TTL must be a positive integer (number of seconds)."
  exit 1
fi

for cmd in curl aws jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "Error: required command '$cmd' not found in PATH."
    exit 1
  fi
done

# Temp file used for the change-batch payload. Created fresh (via mktemp, to
# avoid predictable-filename/symlink races) for every update and always
# removed afterwards, even on failure.
CHANGE_BATCH_FILE=""
cleanup() {
  [ -n "$CHANGE_BATCH_FILE" ] && rm -f "$CHANGE_BATCH_FILE"
}
trap cleanup EXIT

# Allow the loop to be stopped gracefully (e.g. `docker stop`) instead of
# being killed mid-update.
STOP=0
request_stop() {
  log "Received termination signal, stopping after current cycle."
  STOP=1
}
trap request_stop TERM INT

# --- Helpers -----------------------------------------------------------------

# Fetch the external IPv4/IPv6 address. Prints an empty string (and returns
# non-zero, which is intentionally ignored by the caller) if that address
# family isn't reachable from this host.
fetch_external_ip() {
  local family_flag="$1" # -4 or -6
  curl -fsS --max-time 10 "$family_flag" https://ifconfig.co 2>/dev/null || true
}

# Look up the current value of a given record type for our hostname.
get_current_record_value() {
  local record_type="$1"
  aws route53 list-resource-record-sets \
    --hosted-zone-id "$ROUTE53_HOSTED_ZONE_ID" \
    --query "ResourceRecordSets[?Name == '${ROUTE53_DOMAIN_NAME}.' && Type == '${record_type}'].ResourceRecords[].Value" \
    --output text 2>/dev/null || true
}

# Check whether a record type currently exists at all for our hostname.
record_type_exists() {
  local record_type="$1"
  local value
  value="$(get_current_record_value "$record_type")"
  [ -n "$value" ] && [ "$value" != "None" ]
}

# Build the change-batch JSON with jq (safer than hand-rolled heredoc string
# interpolation) and submit the UPSERT to Route 53.
update_record() {
  local record_type="$1"
  local ip_value="$2"

  CHANGE_BATCH_FILE="$(mktemp /tmp/r53-update.XXXXXX.json)"

  jq -n \
    --arg name "$ROUTE53_DOMAIN_NAME" \
    --arg type "$record_type" \
    --arg value "$ip_value" \
    --argjson ttl "$ROUTE53_TTL" \
    '{
      Changes: [
        {
          Action: "UPSERT",
          ResourceRecordSet: {
            Name: $name,
            Type: $type,
            TTL: $ttl,
            ResourceRecords: [ { Value: $value } ]
          }
        }
      ]
    }' > "$CHANGE_BATCH_FILE"

  log "Submitting ${record_type} record update: ${ROUTE53_DOMAIN_NAME} -> ${ip_value}"

  if ! aws route53 change-resource-record-sets \
      --hosted-zone-id "$ROUTE53_HOSTED_ZONE_ID" \
      --change-batch "file://${CHANGE_BATCH_FILE}"; then
    log "Failed to update ${record_type} record."
    rm -f "$CHANGE_BATCH_FILE"
    CHANGE_BATCH_FILE=""
    return 1
  fi

  log "${record_type} record updated successfully."
  rm -f "$CHANGE_BATCH_FILE"
  CHANGE_BATCH_FILE=""
  return 0
}

# Sync a single record type (A/AAAA) against the matching external IP.
# Only touches the record type if it already exists in the hosted zone, or
# if bootstrap mode is active (neither A nor AAAA exist yet) and this type
# is listed in RECORD_TYPES.
sync_record_type() {
  local record_type="$1"
  local family_flag="$2"
  local bootstrap="$3" # "true" if neither A nor AAAA currently exist

  local exists=false
  record_type_exists "$record_type" && exists=true

  if [ "$exists" = false ]; then
    if [ "$bootstrap" != true ] || [[ " $RECORD_TYPES " != *" $record_type "* ]]; then
      log "No existing ${record_type} record; skipping (not requested via RECORD_TYPES for bootstrap, or another record type already exists)."
      return 0
    fi
    log "No existing A or AAAA record found; creating ${record_type} because RECORD_TYPES includes ${record_type}."
  fi

  local ext_ip
  ext_ip="$(fetch_external_ip "$family_flag")"
  if [ -z "$ext_ip" ]; then
    log "Could not determine external ${record_type} address (no ${record_type} connectivity?); skipping."
    return 0
  fi
  log "Current external ${record_type} address: ${ext_ip}"

  local current_value
  current_value="$(get_current_record_value "$record_type")"
  if [ "$ext_ip" = "$current_value" ]; then
    log "${record_type} record already up to date. No update needed."
    return 0
  fi

  update_record "$record_type" "$ext_ip"
}

# --- Main update routine ------------------------------------------------------

update_ip() {
  local status=0
  local bootstrap=false

  # Bootstrap mode only applies the very first time: when NEITHER an A nor
  # an AAAA record exists yet for the hostname. Once either type exists,
  # RECORD_TYPES is ignored and only the pre-existing type(s) are managed.
  if ! record_type_exists "A" && ! record_type_exists "AAAA"; then
    bootstrap=true
    log "Neither A nor AAAA record exists yet for ${ROUTE53_DOMAIN_NAME}; bootstrapping RECORD_TYPES=${RECORD_TYPES}."
  fi

  sync_record_type "A" "-4" "$bootstrap" || status=1
  sync_record_type "AAAA" "-6" "$bootstrap" || status=1
  return "$status"
}

# --- Entrypoint ----------------------------------------------------------------

if [ -n "${UPDATE_INTERVAL:-}" ]; then
  log "Running in a loop, updating every ${UPDATE_INTERVAL} seconds."
  while [ "$STOP" -eq 0 ]; do
    update_ip || true
    # Run sleep in the background and wait on it so pending traps (e.g. from
    # `docker stop`) interrupt the wait immediately instead of only being
    # handled once the full sleep duration elapses.
    sleep "$UPDATE_INTERVAL" &
    wait $! || true
  done
  log "Stopped."
else
  update_ip
fi

exit 0

