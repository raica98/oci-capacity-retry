# oci-capacity-retry

Retries launching an Oracle Cloud Always Free Arm VM (`VM.Standard.A1.Flex`, 2 OCPU / 12 GB)
every 5 minutes from a saved boot volume until Oracle has capacity, then opens an issue and
stops retrying.

All credentials live in GitHub Actions secrets (`OCI_USER`, `OCI_FINGERPRINT`, `OCI_TENANCY`,
`OCI_REGION`, `OCI_KEY`, `SSH_PUBLIC_KEY`). Nothing sensitive is stored in this repo.
