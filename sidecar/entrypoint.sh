#!/bin/sh
set -eu

log() { echo "[aws-spiffe-helper] $*"; }

SPIFFE_SOCKET=/var/run/secrets/spiffe.io/api.sock
SVID_DIR=/tmp/svid
SVID_CERT=${SVID_DIR}/svid.0.pem
SVID_KEY=${SVID_DIR}/svid.0.key.pem

# AWS_BINDINGS is a comma-separated list of "mountPath:profile" pairs injected by the XApi composition.
# Example: "/bindings/object-storage:object-storage,/bindings/nosql:nosql"
# CREDS_FILE is the output path for the AWS credentials file.

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

  # Write atomically to a temp file then rename — app containers never read a partial file.
  TEMP_FILE="${CREDS_FILE}.tmp"
  > "${TEMP_FILE}"

  # Loop over each binding and append a profile section to the credentials file.
  echo "${AWS_BINDINGS}" | tr ',' '\n' | while IFS=: read -r BINDING_DIR PROFILE_NAME; do
    ROLE_ARN=$(cat "${BINDING_DIR}/role-arn")
    PROFILE_ARN=$(cat "${BINDING_DIR}/profile-arn")
    # TRUST_ANCHOR_ARN is a platform-level value injected as an env var by the XApi composition.
    # It is not stored in the binding Secret to avoid exposing the AWS account ID to app tenants.

    log "exchanging SVID for STS credentials (profile: ${PROFILE_NAME}, role: ${ROLE_ARN})"

    CREDS_JSON=$(aws_signing_helper credential-process \
      --certificate "${SVID_CERT}" \
      --private-key "${SVID_KEY}" \
      --role-arn "${ROLE_ARN}" \
      --profile-arn "${PROFILE_ARN}" \
      --trust-anchor-arn "${TRUST_ANCHOR_ARN}")

    printf '[%s]\naws_access_key_id = %s\naws_secret_access_key = %s\naws_session_token = %s\n\n' \
      "${PROFILE_NAME}" \
      "$(echo "${CREDS_JSON}" | jq -r '.AccessKeyId')" \
      "$(echo "${CREDS_JSON}" | jq -r '.SecretAccessKey')" \
      "$(echo "${CREDS_JSON}" | jq -r '.SessionToken')" \
      >> "${TEMP_FILE}"

    log "wrote profile [${PROFILE_NAME}] to ${TEMP_FILE}"
  done

  mv "${TEMP_FILE}" "${CREDS_FILE}"
  log "credentials file updated at ${CREDS_FILE}"

  # IAM Roles Anywhere sessions last 1 hour. Refresh at 50 minutes.
  sleep 3000
done
