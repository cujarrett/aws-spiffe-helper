# aws-spiffe-helper

Sidecar container that exchanges a [SPIFFE](https://spiffe.io/) X.509 SVID for AWS STS credentials using [IAM Roles Anywhere](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/introduction.html). The [XApi](https://github.com/cujarrett/homelab/tree/main/platform/api) Crossplane composition injects this sidecar into pods that declare AWS resource bindings.

## How it works

Every pod running on this cluster gets a short-lived [SPIFFE SVID](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/#svid) from the SPIRE agent. Think of it as a cryptographic identity badge for the pod — it proves *which workload* is running without any passwords or API keys.

When an app needs AWS credentials (e.g. to talk to S3 or DynamoDB), the XApi Crossplane composition adds this sidecar to the pod alongside the app. The sidecar:

1. Waits for the SPIFFE Workload API socket to be available at startup
2. Calls the SPIRE agent via the socket to fetch a JWT-SVID and an X.509 SVID
3. Presents that identity to AWS STS, once per binding
4. Receives short-lived STS credentials (access key + secret + session token) in return
5. Writes those credentials into a shared file as named profiles — one per AWS binding
6. Sleeps 50 minutes, then repeats (credentials expire after 1 hour)

Step 3 has two forms, chosen per binding by whether the binding directory contains a `profile-arn`:

| Binding has | Identity presented | How AWS verifies it |
|---|---|---|
| No `profile-arn` | JWT-SVID, via `sts:AssumeRoleWithWebIdentity` | Fetches the signing keys from the OIDC issuer published by the cluster and checks the signature, the `sub` claim and the `aud` claim |
| A `profile-arn` | X.509 SVID, via [AWS IAM Roles Anywhere](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/introduction.html) | Validates the certificate chain against the SPIRE trust anchor registered in AWS and reads the SPIFFE ID from the URI SAN |

The second form exists so bindings can migrate one at a time rather than all at once. It goes away, along with the `aws_signing_helper` binary in the image, once none remain.

`sts:AssumeRoleWithWebIdentity` needs no request signing, because the token is itself the credential. That is why the JWT path is a plain HTTPS POST and needs no AWS SDK or CLI in the image.

The app container reads credentials from that shared file. It never handles certificates, calls AWS directly for credentials, or stores any long-lived secrets.

If a binding's files aren't readable yet or an exchange fails (AWS throttle, transient network blip), the sidecar keeps the previous credentials file untouched — it's still valid for up to an hour — and retries the whole cycle in 30 seconds instead of crashing.

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
| `TRUST_ANCHOR_ARN` | ARN of the IAM Roles Anywhere trust anchor. Only read for bindings that still carry a `profile-arn`, and unnecessary once every binding has migrated. Injected as a platform-level value by the XApi composition, never stored in a binding Secret, since it embeds the AWS account ID. |

## Volumes expected

| Mount | Contents |
|---|---|
| `/var/run/secrets/spiffe.io/` | SPIFFE Workload API socket (`api.sock`), provided by the SPIFFE CSI driver. The sidecar fetches both a JWT-SVID and an X.509 SVID from it each cycle. |
| Each binding `mountPath` | `role-arn` from the Crossplane binding Secret, plus `profile-arn` on bindings that have not migrated |
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

## Updating binaries

To update `aws_signing_helper`: bump `HELPER_VERSION` in `sidecar/Dockerfile`, push to `main`, and roll affected pods.

To update `spire-agent`: bump `SPIRE_VERSION` in `sidecar/Dockerfile`, push to `main`, and roll affected pods. Match the version running in the cluster (`kubectl exec -n spire-server spire-server-0 -- /opt/spire/bin/spire-server --version`).
