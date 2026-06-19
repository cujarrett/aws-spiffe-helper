# aws-spiffe-helper

Sidecar container that exchanges a [SPIFFE](https://spiffe.io/) X.509 SVID for AWS STS credentials using [IAM Roles Anywhere](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/introduction.html). The [XApi](https://github.com/cujarrett/homelab/tree/main/platform/api) Crossplane composition injects this sidecar into pods that declare AWS resource bindings.

## How it works

Every pod running on this cluster gets a short-lived X.509 certificate called a [SPIFFE SVID](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/#svid) from the SPIRE agent. Think of it as a cryptographic identity badge for the pod — it proves *which workload* is running without any passwords or API keys.

When an app needs AWS credentials (e.g. to talk to S3 or DynamoDB), the XApi Crossplane composition adds this sidecar to the pod alongside the app. The sidecar:

1. Waits for the SVID certificate to be mounted at startup
2. Presents the certificate to [AWS IAM Roles Anywhere](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/introduction.html), which validates it against the SPIRE trust anchor registered in AWS
3. Receives short-lived STS credentials (access key + secret + session token) in return
4. Writes those credentials into a shared file as named profiles — one per AWS binding
5. Sleeps 50 minutes, then repeats (credentials expire after 1 hour)

The app container reads credentials from that shared file. It never handles certificates, calls AWS directly for credentials, or stores any long-lived secrets.

## Environment variables

| Variable | Description |
|---|---|
| `AWS_BINDINGS` | Comma-separated `mountPath:profile` pairs (e.g. `/bindings/object-storage:object-storage,/bindings/nosql:nosql`) |
| `CREDS_FILE` | Output path for the AWS credentials file (e.g. `/aws-credentials/credentials`) |

## Volumes expected

| Mount | Contents |
|---|---|
| `/var/run/secrets/spiffe.io/` | SVID cert (`tls.crt`) and key (`tls.key`) — provided by the SPIFFE CSI driver |
| Each binding `mountPath` | `role-arn`, `profile-arn`, `trust-anchor-arn` files from the Crossplane binding Secret |
| `dirname($CREDS_FILE)` | Writable emptyDir shared with app containers |

## Credentials file format

```ini
[object-storage]
aws_access_key_id = REDACTED
aws_secret_access_key = REDACTED
aws_session_token = REDACTED

[nosql]
aws_access_key_id = REDACTED
aws_secret_access_key = REDACTED
aws_session_token = REDACTED
```

App containers point `AWS_SHARED_CREDENTIALS_FILE` at this file and select a profile via `AWS_PROFILE_<BINDING>` env vars — both injected by the XApi composition.

## Image

```
ghcr.io/cujarrett/aws-spiffe-helper:main
```

Built by CI on every push to `main`. ARM64 only (Raspberry Pi 5 nodes).

## Updating `aws_signing_helper`

Bump the version in `sidecar/Dockerfile`, push to `main`, and roll the affected pods. No composition changes needed.
