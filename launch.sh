#!/usr/bin/env bash
# Keeps trying to launch the PumpBot executor VM (Always Free Arm) from the saved
# boot volumes. Tries 2 OCPU / 12 GB first, then 1 OCPU / 6 GB, in every availability
# domain that holds a saved disk, every ~20 seconds, for up to RUN_MINUTES.
# Writes success.txt when an instance is created, already.txt if one already exists.
set -uo pipefail

T="${OCI_TENANCY:?OCI_TENANCY missing}"      # root compartment == tenancy OCID
NAME="pumpbot-executor"
SUBNET_NAME="subnet-20260820-2040"
SHAPE="VM.Standard.A1.Flex"
SIZES=("2 12" "1 6")                          # "<ocpus> <memGB>", biggest first
RUN_MINUTES="${RUN_MINUTES:-50}"
PAUSE_SECONDS="${PAUSE_SECONDS:-20}"

o() { oci --no-retry "$@"; }                  # no internal retries: one quick try per call

# 1) Done already? Any instance with our name that is not terminated.
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

# 3) Find the saved boot volume in each availability domain (once per run).
declare -A BVS
for AD in $(o iam availability-domain list --compartment-id "$T" 2>/dev/null | jq -r '.data[].name'); do
  bvjson=$(o bv boot-volume list --compartment-id "$T" --availability-domain "$AD" --all 2>&1)
  if ! echo "$bvjson" | jq -e . >/dev/null 2>&1; then
    echo "[$AD] boot volume list failed: $(echo "$bvjson" | tr '\n' ' ' | cut -c1-300)"; continue
  fi
  BV=$(echo "$bvjson" | jq -r '[.data[]? | select(."lifecycle-state" == "AVAILABLE") | select(."display-name" | test("pumpbot-executor-disk|instance-20260820-2037"))] | .[0].id // empty')
  if [ -n "$BV" ]; then BVS["$AD"]="$BV"; echo "[$AD] saved boot volume ...${BV: -10}"; else echo "[$AD] no saved boot volume"; fi
done
if [ ${#BVS[@]} -eq 0 ]; then echo "No saved boot volumes found - nothing to launch from."; exit 0; fi

# 4) Retry loop.
deadline=$(( $(date +%s) + RUN_MINUTES * 60 ))
round=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  round=$((round+1)); line="round $round:"
  for AD in "${!BVS[@]}"; do
    for size in "${SIZES[@]}"; do
      set -- $size; ocpus=$1; mem=$2
      out=$(o compute instance launch \
        --availability-domain "$AD" \
        --compartment-id "$T" \
        --shape "$SHAPE" \
        --shape-config "{\"ocpus\":$ocpus,\"memoryInGBs\":$mem}" \
        --subnet-id "$SUBNET_ID" \
        --source-boot-volume-id "${BVS[$AD]}" \
        --display-name "$NAME" \
        --assign-public-ip true \
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
