# Teardown & Cleanup

How to pause, partially remove, or fully destroy the deployment — and the
gotchas specific to this stack (WORM evidence bucket, protected state bucket,
Packer AMIs, delayed KMS/Secrets deletion).

> **Read §1 first.** Some resources hold data you may need (evidence, case
> files) or are intentionally hard to delete (Object Lock). `terraform destroy`
> is not fully self-service here.

---

## 1. Before you remove anything — preserve data

`terraform destroy` **permanently deletes the EBS volumes**, including SIFT's
`/cases` volume (evidence copies, extractions, findings, reports). Pull anything
you need off the instances first:

- **Case exports / reports** — from SIFT: `vhir case export …`, or copy
  `/cases/<case>/reports/` out. Push to the evidence bucket's `exports/` prefix
  (SIFT's role can write there) or `scp` via the bastion.
- **Findings / timeline** — included in case exports.
- **Original evidence** already lives in the **evidence bucket** and is retained
  independently of the instances (see §4).

Confirm what's on the volumes before destroying — the `/cases` volume is *not*
the evidence bucket; its contents are gone on destroy.

---

## 2. Option A — Pause (keep everything, cut most cost)

Cheapest way to stop paying for compute without losing data. See
[COST.md](COST.md) — this is the "idle" scenario (~$184/mo vs ~$912).

```bash
# Stop all instances (EBS volumes, installs, /cases all persist)
aws ec2 stop-instances --instance-ids $(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=valhuntir" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
```

Restart later with `start-instances`. To trim the idle bill further, you can also
`terraform destroy -target=aws_nat_gateway.main -target=aws_vpc_endpoint.ssm`
(they re-create on the next `apply`), but leave the instances/volumes alone.

Nothing to preserve — this is reversible.

---

## 3. Option B — Full teardown (main deployment)

Order matters: destroy the **main config** first, then the **state bucket**
(bootstrap) last, because the main config's state lives in that bucket.

```bash
cd terraform
terraform destroy      # add -backend-config=backend.hcl init first if using remote state
```

This removes instances, EBS volumes, EIPs, NAT, VPC + endpoints, security groups,
IAM roles/profiles, and schedules the KMS key and secret for deletion. **It will
fail on the evidence bucket if it still contains objects** — handle that first
(§4). KMS and Secrets Manager don't block destroy; they're covered in §5.

If `destroy` stalls on the evidence bucket with `BucketNotEmpty`, empty it per §4
and re-run `terraform destroy`.

---

## 4. The evidence bucket (WORM) — the hard part

The evidence bucket has **Object Lock + versioning** and **no `force_destroy`**,
by design (chain of custody). Consequences:

- **You usually want to keep it.** Consider *not* destroying it — let the main
  deployment go and leave the bucket (it's just S3 storage, ~$23/TB/mo). Remove
  it from Terraform's management with `terraform state rm aws_s3_bucket.evidence`
  (and its related `aws_s3_bucket_*` resources) so `destroy` leaves it alone.
- **Object Lock blocks deletion until retention expires** — even `force_destroy`
  cannot delete an object still under retention. Two cases:
  - **GOVERNANCE mode** (the default): a principal with
    `s3:BypassGovernanceRetention` can delete early by passing the bypass header.
  - **COMPLIANCE mode**: *nobody*, including root, can delete before the
    retention date. You must wait it out.

**To empty a GOVERNANCE-mode bucket** (deletes all versions + delete markers):

```bash
BUCKET=valhuntir-evidence-xxxx   # from: terraform output evidence_bucket

aws s3api list-object-versions --bucket "$BUCKET" --output json \
  --query '[Versions,DeleteMarkers][].{Key:Key,VersionId:VersionId}' \
| jq -c '.[]' | while read -r obj; do
    key=$(echo "$obj" | jq -r .Key)
    vid=$(echo "$obj" | jq -r .VersionId)
    aws s3api delete-object --bucket "$BUCKET" --key "$key" \
      --version-id "$vid" --bypass-governance-retention
  done
```

Then re-run `terraform destroy` (or `aws s3api delete-bucket --bucket "$BUCKET"`).
For COMPLIANCE mode, this fails until each object's retention date passes.

---

## 5. Delayed-deletion resources (KMS, Secrets Manager)

These don't block `destroy`; they enter a waiting period and keep existing
(minimal cost) until it elapses:

- **KMS key** — scheduled for deletion with a **14-day** window
  (`deletion_window_in_days`). It's disabled immediately but not billed-free
  until gone. To cancel during the window: `aws kms cancel-key-deletion`.
- **Secrets Manager secret** — default **30-day** recovery window. To purge
  immediately instead:
  ```bash
  aws secretsmanager delete-secret --secret-id valhuntir/harness \
    --force-delete-without-recovery
  ```

---

## 6. Checkpoint AMIs and the build network (not managed by the main config)

Each checkpoint's four AMIs ([checkpoints/](checkpoints/README.md)) are **not**
tracked by Terraform, so `destroy` leaves them — deliberately: they are what lets
you redeploy a known-good stack later. Their snapshots bill on used blocks
(roughly $5–10/month per checkpoint). To retire a checkpoint:

```bash
# list them (tagged Project=valhuntir, Checkpoint=<name>)
aws ec2 describe-images --owners self \
  --filters "Name=tag:Project,Values=valhuntir" \
  --query 'Images[].{Id:ImageId,Name:Name,Checkpoint:Tags[?Key==`Checkpoint`]|[0].Value}' --output table

# for each AMI: deregister, then delete its snapshot(s)
aws ec2 deregister-image --image-id ami-0abc...
aws ec2 delete-snapshot   --snapshot-id snap-0abc...   # from describe-images BlockDeviceMappings
```

Then set the checkpoint's `status` to `retired` (or delete its JSON) so nobody
tries to deploy it.

The Packer build network (`packer/build-vpc`: VPC, subnet, internet gateway) has
no hourly cost. Remove it with `cd packer/build-vpc && terraform destroy` if you
won't bake again.

---

## 7. The state bucket (bootstrap) — destroy last

The `bootstrap/` state bucket has `prevent_destroy = true` and versioning, so it
survives an ordinary `destroy` on purpose. Only remove it **after** the main
deployment is gone and you no longer need the state history.

```bash
cd bootstrap
# 1. remove the prevent_destroy guard: delete the lifecycle{} block in main.tf
# 2. empty the versioned bucket:
BUCKET=$(terraform output -raw state_bucket)
aws s3api list-object-versions --bucket "$BUCKET" --output json \
  --query '[Versions,DeleteMarkers][].{Key:Key,VersionId:VersionId}' \
| jq -c '.[]' | while read -r o; do
    aws s3api delete-object --bucket "$BUCKET" \
      --key "$(echo "$o" | jq -r .Key)" --version-id "$(echo "$o" | jq -r .VersionId)"
  done
# 3. destroy
terraform destroy
```

If you used remote state, back up `terraform/backend.hcl` before this — you'll
need it to re-init if you rebuild.

---

## 8. Final verification (avoid surprise charges)

After teardown, confirm nothing lingers (idle EIPs, unattached EBS, and orphaned
snapshots are the usual culprits):

```bash
REGION=us-east-1
aws ec2 describe-instances     --region $REGION --filters "Name=tag:Project,Values=valhuntir" --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output table
aws ec2 describe-volumes       --region $REGION --filters "Name=tag:Project,Values=valhuntir" --query 'Volumes[].[VolumeId,State]' --output table
aws ec2 describe-addresses     --region $REGION --query 'Addresses[].[PublicIp,AssociationId]' --output table
aws ec2 describe-nat-gateways  --region $REGION --filter "Name=tag:Project,Values=valhuntir" --query 'NatGateways[].[NatGatewayId,State]' --output table
aws ec2 describe-images        --region $REGION --owners self --filters "Name=tag:Project,Values=valhuntir" --query 'Images[].ImageId' --output table
aws ec2 describe-snapshots     --region $REGION --owner-ids self --filters "Name=tag:Project,Values=valhuntir" --query 'Snapshots[].SnapshotId' --output table
```

Anything still listed is still (or about to be) billable — release/delete it, or
confirm it's an intentional keep (evidence bucket, state bucket).

---

## Quick reference

| Goal | Action |
|------|--------|
| Stop paying for compute, keep data | Stop instances (§2) |
| Remove deployment, keep evidence | `state rm` the evidence bucket (§4), then `destroy` |
| Remove everything | §1 → §4 → §3 → §5 → §6 → §7 → §8 |
| Kill the state bucket | bootstrap, remove `prevent_destroy`, empty, destroy (§7) |
