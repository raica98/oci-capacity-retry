#!/usr/bin/env bash
# Keeps trying to launch a brand-new PumpBot executor VM (Always Free Arm, Ubuntu 24.04)
# with the runner installed by cloud-init on first boot. Tries 2 OCPU / 12 GB first,
# then 1 OCPU / 6 GB, in every availability domain, every ~20 seconds, for up to
# RUN_MINUTES. Writes success.txt when created, already.txt if one already exists.
set -uo pipefail

T="${OCI_TENANCY:?OCI_TENANCY missing}"      # root compartment == tenancy OCID
NAME="pumpbot-executor"
SUBNET_NAME="subnet-20260820-2040"
SHAPE="VM.Standard.A1.Flex"
SIZES=("2 12" "1 6")                          # "<ocpus> <memGB>", biggest first
RUN_MINUTES="${RUN_MINUTES:-50}"
PAUSE_SECONDS="${PAUSE_SECONDS:-20}"

o() { oci --no-retry "$@"; }                  # one quick try per call

# 1) Done already?
existing=$(o compute instance list --compartment-id "$T" --display-name "$NAME" --all 2>/dev/null \
  | jq -r '[.data[]? | select(."lifecycle-state" != "TERMINATED" and ."lifecycle-state" != "TERMINATING")] | .[0].id // empty')
if [ -n "$existing" ]; then
  echo "Instance '$NAME' already exists ($existing). Nothing to do."
  echo "exists" > already.txt
  exit 0
fi

# 2) Subnet (regional) by name, else first subnet in the tenancy.
SUBNET_ID=$(o network subnet list --compartment-id "$T" --display-name "$SUBNET_NAME" --all 2>/dev/null | jq -r '.data[0].id // empty')
[ -z "$SUBNET_ID" ] && SUBNET_ID=$(o network subnet list --compartment-id "$T" --all 2>/dev/null | jq -r '.data[0].id // empty')
if [ -z "$SUBNET_ID" ]; then echo "No subnet found"; exit 0; fi

# 3) Newest Ubuntu 24.04 image that works with the Arm shape.
IMAGE_ID=$(o compute image list --compartment-id "$T" --operating-system "Canonical Ubuntu" \
  --operating-system-version "24.04" --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC --limit 5 2>/dev/null \
  | jq -r '[.data[]? | select(."display-name" | test("aarch64"))] | .[0].id // empty')
if [ -z "$IMAGE_ID" ]; then echo "No Ubuntu 24.04 aarch64 image found"; exit 0; fi
echo "image ...${IMAGE_ID: -10}"

# 4) Cloud-init (gzip keeps it under Oracle's 32 KB limit).
R64=$(base64 -w0 runner/runner.js); A64=$(base64 -w0 runner/alpacaFeed.js)
sed -e "s|@@RUNNER@@|$R64|" -e "s|@@ALPACA@@|$A64|" cloud-init.tmpl > /tmp/cloud-init.yaml
gzip -9 -c /tmp/cloud-init.yaml > /tmp/userdata.gz
echo "user-data $(stat -c %s /tmp/userdata.gz) bytes"

ADS=$(o iam availability-domain list --compartment-id "$T" 2>/dev/null | jq -r '.data[].name')

# 5) Retry loop.
deadline=$(( $(date +%s) + RUN_MINUTES * 60 ))
round=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  round=$((round+1)); line="round $round:"
  for AD in $ADS; do
    for size in "${SIZES[@]}"; do
      set -- $size; ocpus=$1; mem=$2
      out=$(o compute instance launch \
        --availability-domain "$AD" \
        --compartment-id "$T" \
        --shape "$SHAPE" \
        --shape-config "{\"ocpus\":$ocpus,\"memoryInGBs\":$mem}" \
        --subnet-id "$SUBNET_ID" \
        --image-id "$IMAGE_ID" \
        --display-name "$NAME" \
        --assign-public-ip true \
        --user-data-file /tmp/userdata.gz \
        --metadata "{\"ssh_authorized_keys\":\"${SSH_PUBLIC_KEY:-}\"}" 2>&1)
      if [ $? -eq 0 ]; then
        id=$(echo "$out" | jq -r '.data.id // empty')
        echo "CREATED in $AD (${ocpus} OCPU / ${mem} GB): $id"
        echo "AD=$AD SIZE=${ocpus}/${mem} ID=$id" > success.txt
        exit 0
      fi
      if echo "$out" | grep -qi "out of host capacity\|out of capacity"; then
        line="$line ${AD##*-}:${ocpus}/${mem}=cap"
      else
        line="$line ${AD##*-}:${ocpus}/${mem}=ERR[$(echo "$out" | grep -Eo '"(code|message)": *"[^"]*"' | head -2 | tr '\n' ' ' | cut -c1-160)]"
      fi
    done
  done
  echo "$line"
  sleep "$PAUSE_SECONDS"
done
echo "Run window over ($RUN_MINUTES min, $round rounds), no capacity."
exit 0
