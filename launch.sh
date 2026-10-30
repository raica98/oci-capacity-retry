#!/usr/bin/env bash
# Keeps trying to launch the PumpBot executor VM (Always Free Arm, 2 OCPU / 12 GB)
# from the saved boot volumes, one attempt per availability domain per run.
# Exits 0 either way; writes success.txt only when an instance was created.
set -uo pipefail

T="${OCI_TENANCY:?OCI_TENANCY missing}"      # root compartment == tenancy OCID
NAME="pumpbot-executor"
SUBNET_NAME="subnet-20260820-2040"
SHAPE="VM.Standard.A1.Flex"
OCPUS=2
MEM_GB=12

# 1) Done already? Any instance with our name that is not terminated.
existing=$(oci compute instance list --compartment-id "$T" --display-name "$NAME" --all 2>/dev/null \
  | jq -r '[.data[]? | select(."lifecycle-state" != "TERMINATED" and ."lifecycle-state" != "TERMINATING")] | .[0].id // empty')
if [ -n "$existing" ]; then
  echo "Instance '$NAME' already exists ($existing). Nothing to do."
  echo "exists" > already.txt
  exit 0
fi

# 2) Subnet (regional) by name, else first subnet in the tenancy.
SUBNET_ID=$(oci network subnet list --compartment-id "$T" --display-name "$SUBNET_NAME" --all 2>/dev/null | jq -r '.data[0].id // empty')
[ -z "$SUBNET_ID" ] && SUBNET_ID=$(oci network subnet list --compartment-id "$T" --all 2>/dev/null | jq -r '.data[0].id // empty')
if [ -z "$SUBNET_ID" ]; then echo "No subnet found"; exit 0; fi

# 3) Try every availability domain that holds one of our saved boot volumes.
ads=$(oci iam availability-domain list --compartment-id "$T" 2>/dev/null | jq -r '.data[].name')
for AD in $ads; do
  bvjson=$(oci bv boot-volume list --compartment-id "$T" --availability-domain "$AD" --all 2>&1)
  if ! echo "$bvjson" | jq -e . >/dev/null 2>&1; then
    echo "[$AD] boot volume list failed: $(echo "$bvjson" | tr '\n' ' ' | cut -c1-300)"; continue
  fi
  echo "[$AD] boot volumes seen: $(echo "$bvjson" | jq -r '[.data[]? | ."display-name" + " (" + ."lifecycle-state" + ")"] | join(", ")')"
  BV=$(echo "$bvjson" | jq -r '[.data[]? | select(."lifecycle-state" == "AVAILABLE") | select(."display-name" | test("pumpbot-executor-disk|instance-20260820-2037"))] | .[0].id // empty')
  if [ -z "$BV" ]; then echo "[$AD] no saved boot volume here, skipping"; continue; fi

  echo "[$AD] launching $SHAPE ${OCPUS}/${MEM_GB}GB from boot volume ${BV: -12}"
  out=$(oci compute instance launch \
    --availability-domain "$AD" \
    --compartment-id "$T" \
    --shape "$SHAPE" \
    --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEM_GB}" \
    --subnet-id "$SUBNET_ID" \
    --source-boot-volume-id "$BV" \
    --display-name "$NAME" \
    --assign-public-ip true \
    --metadata "{\"ssh_authorized_keys\":\"${SSH_PUBLIC_KEY:-}\"}" 2>&1)
  rc=$?
  if [ $rc -eq 0 ]; then
    id=$(echo "$out" | jq -r '.data.id // empty')
    echo "CREATED in $AD: $id"
    echo "AD=$AD ID=$id" > success.txt
    exit 0
  fi
  echo "[$AD] failed: $(echo "$out" | grep -Eio 'out of (host )?capacity[^"]*|LimitExceeded[^"]*|"message": *"[^"]*' | head -1)"
done
echo "No capacity this round."
exit 0
