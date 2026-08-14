#!/bin/sh
set -eu

# What this does: SPIRE, already running in this cluster, hands this pod a signed
# token proving which pod it is — a JWT-SVID. AWS trusts SPIRE's signature because
# the cluster's public signing keys are registered with AWS ahead of time (OIDC
# federation). Presenting that token to AWS STS trades it for real, short-lived
# AWS credentials. No password and no long-lived key are ever involved.

log() { echo "[workload-identity-sidecar] $*"; }

SPIFFE_SOCKET=/var/run/secrets/spiffe.io/api.sock
SVID_DIR=/tmp/svid
JWT_FILE=${SVID_DIR}/jwt

# AWS_BINDINGS is a comma-separated list of "mountPath:profile" pairs injected by the XApi composition.
# Example: "/bindings/object-storage:object-storage,/bindings/nosql:nosql"
# CREDS_FILE is the output path for the AWS credentials file.

# Must match a client id registered on the AWS OIDC identity provider, or STS rejects the token.
STS_AUDIENCE=${STS_AUDIENCE:-sts.amazonaws.com}
# Regional, not the global endpoint — the mesh egress allowlist only permits this host.
STS_ENDPOINT=${STS_ENDPOINT:-https://sts.us-east-1.amazonaws.com}

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
  # Ask the SPIRE agent already running on this node for a signed token proving
  # "this is that exact pod". -audience scopes it: STS will only accept a token
  # minted for sts.amazonaws.com, so a token meant for one purpose cannot be
  # replayed against another. The JWT itself is the second line of the command's
  # output, indented under a token(...) header.
  if ! spire-agent api fetch jwt \
      -audience "${STS_AUDIENCE}" \
      -socketPath "${SPIFFE_SOCKET}" 2>/dev/null \
      | sed -n '2p' | tr -d '\t ' > "${JWT_FILE}" || [ ! -s "${JWT_FILE}" ]; then
    log "failed to fetch JWT-SVID from SPIFFE socket, retrying in 10s"
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

    # Hand the JWT to AWS STS. AWS fetched SPIRE's public signing keys from the
    # cluster's OIDC endpoint ahead of time, so it can verify the signature itself
    # — then it checks the token's subject and audience against this role's trust
    # policy. A match returns real, temporary credentials for that role.
    # AssumeRoleWithWebIdentity needs no request signing, because the token itself
    # is the proof: there is nothing else to sign, and no AWS SDK is needed.
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

    log "wrote profile [${PROFILE_NAME}] to ${TEMP_FILE}"
  done

  if [ "${EXCHANGE_FAILED}" -eq 1 ]; then
    rm -f "${TEMP_FILE}"
    sleep 30
    continue
  fi

  mv "${TEMP_FILE}" "${CREDS_FILE}"
  log "credentials file updated at ${CREDS_FILE}"

  # STS sessions last 1 hour. Refresh at 50 minutes.
  sleep 3000
done
