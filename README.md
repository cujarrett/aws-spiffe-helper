# workload-identity-sidecar

Sidecar container that exchanges a [SPIFFE](https://spiffe.io/) SVID for short-lived cloud credentials via OIDC federation. The [XApi](https://github.com/cujarrett/homelab/tree/main/platform/api) Crossplane composition injects this sidecar into pods that declare cloud resource bindings.

**Not yet implemented: Entra.** The name is deliberately not AWS-specific so a second cloud can land here rather than in a second sidecar - but everything below (`STS_AUDIENCE`, the credential exchange, the profile format) is AWS-shaped today. There is no Entra code path yet.

## How it works

Every pod running on this cluster gets a short-lived [SPIFFE JWT-SVID](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/#svid) from the SPIRE agent. Think of it as a cryptographic identity badge for the pod - it proves *which workload* is running without any passwords or API keys.

When an app needs AWS credentials (e.g. to talk to S3 or DynamoDB), the XApi Crossplane composition adds this sidecar to the pod alongside the app. The sidecar:

1. Waits for the SPIFFE Workload API socket to be available at startup
2. Calls the SPIRE agent via the socket to fetch a JWT-SVID
3. Presents that token to AWS STS via `sts:AssumeRoleWithWebIdentity`, once per binding
4. Receives short-lived STS credentials (access key + secret + session token) in return
5. Writes those credentials into a shared file as named profiles - one per AWS binding
6. Sleeps 50 minutes, then repeats (credentials expire after 1 hour)

`sts:AssumeRoleWithWebIdentity` needs no request signing, because the token is itself the credential. AWS verifies it by fetching the signing keys from the OIDC issuer published by the cluster and checking the signature, the `sub` claim and the `aud` claim. That is why the exchange is a plain HTTPS POST and needs no AWS SDK or CLI in the image.

The app container reads credentials from that shared file. It never handles the token, calls AWS directly for credentials, or stores any long-lived secrets.

If a binding's files aren't readable yet or an exchange fails (AWS throttle, transient network blip), the sidecar keeps the previous credentials file untouched - it's still valid for up to an hour - and retries the whole cycle in 30 seconds instead of crashing.

## Platform context

This helper is the runtime component that connects the pieces of my [platform](https://github.com/cujarrett/homelab/tree/main/platform) together:

- **Crossplane** provisions AWS resources and IAM roles.
- **SPIRE** proves the workload's identity with a SPIFFE SVID.
- **This helper** exchanges that identity for temporary AWS credentials.
- **The AWS SDK** consumes those credentials transparently.

That separation is what makes the developer experience clean: developers declare that they need an AWS capability, while the platform handles identity, authorization, credential acquisition, and rotation behind the scenes.

## Environment variables

| Variable | Description |
|---|---|
| `AWS_BINDINGS` | Comma-separated `mountPath:profile` pairs (e.g. `/bindings/object-storage:object-storage,/bindings/nosql:nosql`) |
| `CREDS_FILE` | Output path for the AWS credentials file (e.g. `/aws-credentials/credentials`) |
| `STS_AUDIENCE` | Audience requested for the JWT-SVID, default `sts.amazonaws.com`. Must match a client id registered on the AWS OIDC identity provider, or STS rejects the token. |
| `STS_ENDPOINT` | STS endpoint, default `https://sts.us-east-1.amazonaws.com`. Regional because the mesh egress allowlist permits only that host. |

## Volumes expected

| Mount | Contents |
|---|---|
| `/var/run/secrets/spiffe.io/` | SPIFFE Workload API socket (`api.sock`), provided by the SPIFFE CSI driver. The sidecar fetches a JWT-SVID from it each cycle. |
| Each binding `mountPath` | `role-arn` from the Crossplane binding Secret |
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

App containers point `AWS_SHARED_CREDENTIALS_FILE` at this file and select a profile via `AWS_PROFILE_<BINDING>` env vars - both injected by the XApi composition.

## Image

```
ghcr.io/cujarrett/workload-identity-sidecar:main
```

Built by CI on every push to `main`. ARM64 only (Raspberry Pi 5 nodes).

## Updating binaries

Renovate opens a PR when SPIRE cuts a release, tracking `SPIRE_VERSION` in `sidecar/Dockerfile`. The PR carries a reminder to check it against the cluster's running version before merging.
