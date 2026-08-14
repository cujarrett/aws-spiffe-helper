# workload-identity-sidecar

Sidecar container that exchanges a SPIFFE SVID for short-lived cloud credentials. The `ghcr.io/cujarrett/workload-identity-sidecar` image is built by CI in this repo and injected into [XApi](https://github.com/cujarrett/homelab/tree/main/platform/api) pods by the XApi Crossplane composition when the pod declares cloud resource bindings.

## Sidecar

`sidecar/Dockerfile` builds `ghcr.io/cujarrett/workload-identity-sidecar`. It installs `spire-agent` (ARM64 binary) and runs `sidecar/entrypoint.sh`.

The sidecar waits for the SPIFFE Workload API socket at `/var/run/secrets/spiffe.io/api.sock` (provided by the SPIFFE CSI driver), then fetches a JWT-SVID from the SPIRE agent each cycle. Per binding it presents that token to AWS STS via `AssumeRoleWithWebIdentity` (a plain unsigned HTTPS POST) and writes a named profile section to a temp file that is atomically renamed to `CREDS_FILE`. Refreshes every 50 minutes; on a failed exchange it keeps the previous credentials file and retries in 30 seconds.

Renovate opens a PR automatically when SPIRE cuts a release, tracking `SPIRE_VERSION` in `sidecar/Dockerfile`. The PR carries a reminder to check it against the cluster's running version before merging.

## Rules

- Never run `git commit`, `git push`, or any git command that writes to or modifies repository history or remotes.

### Pre-commit safety check

Before telling the user to commit, always run `/security-review`. It reviews the pending changes on the current branch for security issues. Once it confirms the changes are safe, offer the user a suggested commit message — do not run `git commit` yourself.

## Philosophy: Grug-Brained Development

> "Complexity very, very bad." — [grugbrain.dev](https://grugbrain.dev/)

- **Say no.** The best weapon against complexity is the word "no". No new feature, no new abstraction, until it earns its place.
- **No abstraction until a pattern repeats three times.** Let cut points emerge naturally from the code; don't invent them up front.
- **80/20 solutions.** Ship 80% of the value with 20% of the code. Ugly but working beats elegant but over-engineered.
- **Chesterton's Fence.** Understand why code exists before removing it. If you don't see the use, go away and think.
- **Boring, obvious code wins.** Intermediate variables with good names beat clever one-liners. Easier to debug.
- **DRY is not a law.** A little copy-paste beats a complex abstraction built for two cases.
- **No FOLD** (Fear Of Looking Dumb). If something is too complex, say so. That's a signal to simplify, not a personal failing.
