# aws-spiffe-helper

Sidecar container that exchanges a SPIFFE X.509 SVID for AWS STS credentials using IAM Roles Anywhere. The `ghcr.io/cujarrett/aws-spiffe-helper` image is built by CI in this repo and injected into [XApi](https://github.com/cujarrett/homelab/tree/main/platform/api) pods by the XApi Crossplane composition when the pod declares AWS resource bindings.

## Sidecar

`sidecar/Dockerfile` builds `ghcr.io/cujarrett/aws-spiffe-helper`. It installs `aws_signing_helper` and `spire-agent` (ARM64 binaries) and runs `sidecar/entrypoint.sh`.

The sidecar waits for the SPIFFE Workload API socket at `/var/run/secrets/spiffe.io/api.sock` (provided by the SPIFFE CSI driver), calls `spire-agent api fetch x509` to obtain the SVID cert and key, then calls `aws_signing_helper credential-process` once per binding and writes named profile sections directly to `CREDS_FILE`. Refreshes every 50 minutes.

To update `aws_signing_helper`: bump `HELPER_VERSION` in `sidecar/Dockerfile` and push to main. To update `spire-agent`: bump `SPIRE_VERSION` in `sidecar/Dockerfile` and push to main. Match the cluster's SPIRE version.

## Rules

- Never run `git commit`, `git push`, or any git command that writes to or modifies repository history or remotes.

### Pre-commit safety check

Before telling the user to commit, always run `/pre-commit-review`. It checks for secrets, sensitive identifiers, PII, credential templates, and cluster safety, and returns explicit verdicts on whether the changes are safe for a public repo.

## Philosophy: Grug-Brained Development

> "Complexity very, very bad." — [grugbrain.dev](https://grugbrain.dev/)

- **Say no.** The best weapon against complexity is the word "no". No new feature, no new abstraction, until it earns its place.
- **No abstraction until a pattern repeats three times.** Let cut points emerge naturally from the code; don't invent them up front.
- **80/20 solutions.** Ship 80% of the value with 20% of the code. Ugly but working beats elegant but over-engineered.
- **Chesterton's Fence.** Understand why code exists before removing it. If you don't see the use, go away and think.
- **Boring, obvious code wins.** Intermediate variables with good names beat clever one-liners. Easier to debug.
- **DRY is not a law.** A little copy-paste beats a complex abstraction built for two cases.
- **No FOLD** (Fear Of Looking Dumb). If something is too complex, say so. That's a signal to simplify, not a personal failing.
