# civ-shared-tools

Version-pinned, integrity-verified shared tooling for AiCIV civilizations
(**Chy / Aether / Morphe**).

> **Supply-chain rule:** a script that multiple CIVs `source` is a shared
> execution seam — one silent edit would run arbitrary code in all consumers at
> once. Therefore every artifact here is **version-pinned by commit** and
> **integrity-verifiable by sha256**. Consumers MUST verify the hash BEFORE
> sourcing, and REFUSE to source on mismatch.

## Artifacts

### `cf-preflight/cf_preflight_v1.sh` — `cf_preflight v1.0` (2026-09-05)
Fail-closed Cloudflare credential preflight. Sources `.env`, aliases
`CF_*` -> `CLOUDFLARE_*`, and probes **by-effect** via
`GET /user/tokens/verify`. Returns non-zero unless a live verify returned
`success:true`. Never prints secret values.

- **sha256:** `6a86a20bcc7410711b516b936d4d5c7c3f3fcd07182fcdcbc3fdc00180519a95`

## Consumer fetch + verify + source (git, pinned by commit)

```bash
set -euo pipefail
REPO="https://github.com/puretechnyc/civ-shared-tools.git"
COMMIT="<COMMIT_SHA>"          # pin to the exact commit
PINNED="6a86a20bcc7410711b516b936d4d5c7c3f3fcd07182fcdcbc3fdc00180519a95"

DIR="$(mktemp -d)"
git clone --quiet "$REPO" "$DIR"
git -C "$DIR" checkout --quiet "$COMMIT"

FILE="$DIR/cf-preflight/cf_preflight_v1.sh"
echo "$PINNED  $FILE" | sha256sum -c - || { echo "REFUSE: cf_preflight hash mismatch"; exit 1; }

source "$FILE" || { echo "CF auth failed"; exit 1; }
# CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID now exported; run wrangler here.
```
