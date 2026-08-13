#!/bin/sh
set -eu

log() { echo "[aws-spiffe-helper] $*"; }

SPIFFE_SOCKET=/var/run/secrets/spiffe.io/api.sock
SVID_DIR=/tmp/svid
SVID_CERT=${SVID_DIR}/svid.0.pem
SVID_KEY=${SVID_DIR}/svid.0.key
JWT_FILE=${SVID_DIR}/jwt

# AWS_BINDINGS is a comma-separated list of "mountPath:profile" pairs injected by the XApi composition.
# Example: "/bindings/object-storage:object-storage,/bindings/nosql:nosql"
# CREDS_FILE is the output path for the AWS credentials file.
# TRUST_ANCHOR_ARN is only read on the Roles Anywhere path and goes away once every
# binding has migrated. It is injected as an env var rather than stored in the binding
# Secret so the AWS account id is never exposed to app tenants.

# Must match a client id registered on the AWS OIDC identity provider, or STS rejects the token.
STS_AUDIENCE=${STS_AUDIENCE:-sts.amazonaws.com}
# Regional, not the global endpoint — the mesh egress allowlist only permits this host.
STS_ENDPOINT=${STS_ENDPOINT:-https://sts.us-east-1.amazonaws.com}

# Defaulted so a migrated pod, where the composition no longer injects it, does not die
# on set -u before reaching the branch that never uses it.
TRUST_ANCHOR_ARN=${TRUST_ANCHOR_ARN:-}

mkdir -p "${SVID_DIR}"

# Pull one field out of an STS XML response. Newlines are stripped first so a single
# regex works regardless of how the response happens to be wrapped.
xml_field() {
  printf '%s' "$1" | tr -d '\n\r' | sed -n "s|.*<$2>\(.*\)</$2>.*|\1|p"
}

# Wait for the SPIFFE Workload API socket before the first exchange.
until [ -S "${SPIFFE_SOCKET}" ]; do
  log "waiting for SPIFFE socket at ${SPIFFE_SOCKET}"
  sleep 2
done

while true; do
  # Fetch both identity documents. A binding uses the JWT unless it still carries a
  # profile-arn, so during the migration a single pod can need either or both.
  X509_OK=0
  if spire-agent api fetch x509 \
      -socketPath "${SPIFFE_SOCKET}" \
      -write "${SVID_DIR}" > /dev/null 2>&1; then
    X509_OK=1
  fi

  # The JWT is the second line of the command's output, indented under a token(...) header.
  JWT_OK=0
  if spire-agent api fetch jwt \
      -audience "${STS_AUDIENCE}" \
      -socketPath "${SPIFFE_SOCKET}" 2>/dev/null \
      | sed -n '2p' | tr -d '\t ' > "${JWT_FILE}" && [ -s "${JWT_FILE}" ]; then
    JWT_OK=1
  fi

  if [ "${X509_OK}" -eq 0 ] && [ "${JWT_OK}" -eq 0 ]; then
    log "failed to fetch any SVID from SPIFFE socket, retrying in 10s"
    sleep 10
    continue
  fi

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
    if ! ROLE_ARN=$(cat "${BINDING_DIR}/role-arn" 2>/dev/null); then
      log "binding files missing in ${BINDING_DIR}, keeping previous credentials"
      EXCHANGE_FAILED=1
      break
    fi

    # Role name only — the full ARN embeds the AWS account id, and these logs ship
    # to a log aggregator. The name is the part that identifies which binding failed.
    log "exchanging SVID for STS credentials (profile: ${PROFILE_NAME}, role: ${ROLE_ARN##*/})"

    # A profile-arn means this binding has not migrated yet and still trusts the SPIRE CA
    # registered in AWS as a Roles Anywhere trust anchor. Without one, AWS verifies the
    # JWT against the keys published at the OIDC issuer instead.
    if PROFILE_ARN=$(cat "${BINDING_DIR}/profile-arn" 2>/dev/null); then
      if [ "${X509_OK}" -eq 0 ]; then
        log "no X.509 SVID available for Roles Anywhere binding ${PROFILE_NAME}"
        EXCHANGE_FAILED=1
        break
      fi

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
    else
      if [ "${JWT_OK}" -eq 0 ]; then
        log "no JWT-SVID available for binding ${PROFILE_NAME}"
        EXCHANGE_FAILED=1
        break
      fi

      # AssumeRoleWithWebIdentity is unsigned — the token is the credential, so there is
      # nothing to sign with and no SDK needed.
      if ! RESPONSE=$(curl -sS -X POST "${STS_ENDPOINT}/" \
        -d "Action=AssumeRoleWithWebIdentity" \
        -d "Version=2011-06-15" \
        -d "DurationSeconds=3600" \
        --data-urlencode "RoleSessionName=${PROFILE_NAME}" \
        --data-urlencode "RoleArn=${ROLE_ARN}" \
        --data-urlencode "WebIdentityToken@${JWT_FILE}" 2>&1); then
        log "STS request failed for profile ${PROFILE_NAME}, keeping previous credentials"
        EXCHANGE_FAILED=1
        break
      fi

      ACCESS_KEY=$(xml_field "${RESPONSE}" AccessKeyId)
      SECRET_KEY=$(xml_field "${RESPONSE}" SecretAccessKey)
      SESSION_TOKEN=$(xml_field "${RESPONSE}" SessionToken)

      if [ -z "${ACCESS_KEY}" ] || [ -z "${SECRET_KEY}" ] || [ -z "${SESSION_TOKEN}" ]; then
        # Only the error code is logged. The body can echo the token back.
        log "STS refused profile ${PROFILE_NAME}: $(xml_field "${RESPONSE}" Code)"
        EXCHANGE_FAILED=1
        break
      fi

      cat >> "${TEMP_FILE}" <<PROFILE
[${PROFILE_NAME}]
aws_access_key_id = ${ACCESS_KEY}
aws_secret_access_key = ${SECRET_KEY}
aws_session_token = ${SESSION_TOKEN}

PROFILE
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

  # Both paths issue 1 hour sessions. Refresh at 50 minutes.
  sleep 3000
done
