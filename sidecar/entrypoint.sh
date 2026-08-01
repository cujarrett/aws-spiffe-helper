#!/bin/sh
set -eu

log() { echo "[aws-spiffe-helper] $*"; }

SPIFFE_SOCKET=/var/run/secrets/spiffe.io/api.sock
SVID_DIR=/tmp/svid
SVID_CERT=${SVID_DIR}/svid.0.pem
SVID_KEY=${SVID_DIR}/svid.0.key

# AWS_BINDINGS is a comma-separated list of "mountPath:profile" pairs injected by the XApi composition.
# Example: "/bindings/object-storage:object-storage,/bindings/nosql:nosql"
# CREDS_FILE is the output path for the AWS credentials file.
# TRUST_ANCHOR_ARN is a platform-level value injected as an env var by the XApi composition.
# It is not stored in the binding Secret to avoid exposing the AWS account ID to app tenants.

mkdir -p "${SVID_DIR}"

# Wait for the SPIFFE Workload API socket before the first exchange.
until [ -S "${SPIFFE_SOCKET}" ]; do
  log "waiting for SPIFFE socket at ${SPIFFE_SOCKET}"
  sleep 2
done

while true; do
  # Fetch the X.509 SVID from the SPIRE agent via the Workload API socket.
  spire-agent api fetch x509 \
    -socketPath "${SPIFFE_SOCKET}" \
    -write "${SVID_DIR}" > /dev/null 2>&1 || {
    log "failed to fetch SVID from SPIFFE socket, retrying in 10s"
    sleep 10
    continue
  }

  # Log what was written for debugging.
  log "SVID files: $(ls ${SVID_DIR} 2>/dev/null | tr '\n' ' ')"

  # Write atomically to a temp file then rename — app containers never read a partial file.
  TEMP_FILE="${CREDS_FILE}.tmp"
  : > "${TEMP_FILE}"

  # Loop over each binding and write a named profile section to the credentials file.
  # A failed exchange must not kill the container: the previous credentials file is
  # still valid for up to an hour, so keep it and retry the whole cycle in 30s.
  EXCHANGE_FAILED=0
  for PAIR in $(echo "${AWS_BINDINGS}" | tr ',' ' '); do
    BINDING_DIR=${PAIR%%:*}
    PROFILE_NAME=${PAIR#*:}
    if ! ROLE_ARN=$(cat "${BINDING_DIR}/role-arn" 2>/dev/null) ||
       ! PROFILE_ARN=$(cat "${BINDING_DIR}/profile-arn" 2>/dev/null); then
      log "binding files missing in ${BINDING_DIR}, keeping previous credentials"
      EXCHANGE_FAILED=1
      break
    fi

    # Role name only — the full ARN embeds the AWS account id, and these logs ship
    # to a log aggregator. The name is the part that identifies which binding failed.
    log "exchanging SVID for STS credentials (profile: ${PROFILE_NAME}, role: ${ROLE_ARN##*/})"

    if ! AWS_SHARED_CREDENTIALS_FILE="${TEMP_FILE}" aws_signing_helper update \
      --once \
      --certificate "${SVID_CERT}" \
      --private-key "${SVID_KEY}" \
      --role-arn "${ROLE_ARN}" \
      --profile-arn "${PROFILE_ARN}" \
      --trust-anchor-arn "${TRUST_ANCHOR_ARN}" \
      --profile "${PROFILE_NAME}"; then
      log "exchange failed for profile ${PROFILE_NAME}, keeping previous credentials"
      EXCHANGE_FAILED=1
      break
    fi

    log "wrote profile [${PROFILE_NAME}] to ${TEMP_FILE}"
  done

  if [ "${EXCHANGE_FAILED}" -eq 1 ]; then
    rm -f "${TEMP_FILE}"
    sleep 30
    continue
  fi

  mv "${TEMP_FILE}" "${CREDS_FILE}"
  log "credentials file updated at ${CREDS_FILE}"

  # IAM Roles Anywhere sessions last 1 hour. Refresh at 50 minutes.
  sleep 3000
done
