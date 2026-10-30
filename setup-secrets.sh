#!/usr/bin/env bash
# Run this yourself, once, after saving your Oracle API key.
# It copies your Oracle API settings into this repo's GitHub Actions secrets.
#
# Expects:
#   ~/.oci/config           the "Configuration file preview" text from the Oracle console
#   ~/.oci/oci_api_key.pem  the private key you downloaded when adding the API key
#   ~/.ssh/pumpbot_vm_2026-10.pub  (already created)
set -euo pipefail

REPO="${1:-raica98/oci-capacity-retry}"
CFG="${OCI_CONFIG:-$HOME/.oci/config}"
KEY="${OCI_KEY_FILE:-$HOME/.oci/oci_api_key.pem}"
PUB="${SSH_PUB_FILE:-$HOME/.ssh/pumpbot_vm_2026-10.pub}"

for f in "$CFG" "$KEY" "$PUB"; do
  [ -f "$f" ] || { echo "Missing file: $f"; exit 1; }
done

get() { grep -E "^[[:space:]]*$1[[:space:]]*=" "$CFG" | head -1 | cut -d= -f2- | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

for k in user fingerprint tenancy region; do
  [ -n "$(get $k)" ] || { echo "Could not find '$k' in $CFG"; exit 1; }
done

gh secret set OCI_USER        --repo "$REPO" --body "$(get user)"
gh secret set OCI_FINGERPRINT --repo "$REPO" --body "$(get fingerprint)"
gh secret set OCI_TENANCY     --repo "$REPO" --body "$(get tenancy)"
gh secret set OCI_REGION      --repo "$REPO" --body "$(get region)"
gh secret set OCI_KEY         --repo "$REPO" < "$KEY"
gh secret set SSH_PUBLIC_KEY  --repo "$REPO" < "$PUB"

echo "Secrets saved. Starting the first run..."
gh workflow run retry-oci-vm --repo "$REPO" || true
echo "Done. Watch it at: https://github.com/$REPO/actions"
