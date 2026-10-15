# Cost Estimate — Valhuntir on AWS

**Approximate** monthly costs, **us-east-1, on-demand pricing, mid-2026**. Real
figures vary by region, usage, and pricing changes — validate with the
[AWS Pricing Calculator](https://calculator.aws) before committing. All prices
USD. A month is treated as 730 hours.

This estimate is for the **full topology** (SIFT + OpenSearch + Windows + REMnux
+ bastion). Turn off `enable_*` workers you don't need to cut cost proportionally.

---

## 1. Compute (instances running 24/7)

| Host | Instance | vCPU / RAM | $/hr | $/mo (730h) |
|------|----------|-----------|------|-------------|
| Bastion | t3.small | 2 / 2 | 0.021 | 15 |
| SIFT | m6i.2xlarge | 8 / 32 | 0.384 | 280 |
| OpenSearch | r6i.large | 2 / 16 | 0.151 | 110 |
| Windows | m6i.xlarge *(Windows)* | 4 / 16 | 0.378 | 276 |
| REMnux | m6i.large | 2 / 8 | 0.096 | 70 |
| **Compute subtotal (24/7)** | | | | **~$751** |

Windows carries an OS license premium (~$0.18/hr here) on top of the Linux rate.
SIFT + Windows alone are ~$556/mo — they dominate the bill.

## 2. Storage & fixed infrastructure (billed even when instances are *stopped*)

| Item | Basis | $/mo |
|------|-------|------|
| EBS gp3 — SIFT (100 root + 500 /cases) | 600 GB × $0.08 | 48 |
| EBS gp3 — OpenSearch (40 + 200) | 240 GB × $0.08 | 19 |
| EBS gp3 — Windows (100) | 100 GB × $0.08 | 8 |
| EBS gp3 — REMnux (120) | 120 GB × $0.08 | 10 |
| EBS gp3 — Bastion (20) | 20 GB × $0.08 | 2 |
| NAT Gateway | $0.045/hr + $0.045/GB | ~33 + data |
| SSM interface endpoints ×3 | $0.01/hr each | 22 |
| Public IPv4 ×2 (bastion + NAT EIP) | $0.005/hr each | 7 |
| Secrets Manager | 1 secret | 0.40 |
| KMS | 1 key | 1 |
| Golden AMIs (Packer snapshots) | ~220 GB × $0.05 | ~11 |
| Terraform **state** bucket | one tiny JSON | ~0 |
| **Fixed subtotal (excl. evidence)** | | **~$161** |

## 3. Evidence storage (S3, scales with case data)

| Volume | S3 Standard @ $0.023/GB | 
|--------|--------------------------|
| 1 TB | ~$23/mo |
| 5 TB | ~$115/mo |
| 20 TB | ~$460/mo |

Evidence **ingress is free**; SIFT pulling it over the S3 gateway endpoint (same
region) is **free**. Object Lock/versioning keeps *all* versions — deletes don't
free space until retention expires, so budget for retained volume. Consider a
lifecycle rule to S3 Glacier for closed cases (~$0.004/GB, ~6× cheaper).

---

## Scenarios

| Scenario | What's running | ~$/mo (excl. evidence) |
|----------|----------------|------------------------|
| **All-on 24/7** | every instance + all infra | **~$912** |
| **Idle between engagements** | instances **stopped**, NAT + endpoints up | **~$184** |
| **Parked / torn down** | only S3 (state + evidence) + AMIs | **~$34** |

Add evidence storage (§3) to each. Example: all-on with 1 TB evidence ≈ **$935/mo**.

"Idle" still pays for EBS volumes ($87), the NAT gateway ($33), SSM endpoints
($22), and idle EIPs ($7) — stopping instances zeroes *compute* but not storage
or networking.

---

## Cost levers (biggest first)

1. **Stop instances between engagements.** Compute is ~$751 of the ~$912; stopping
   idle workers is the single largest saving. `aws ec2 stop-instances` — EBS
   persists, so `/cases` and installs survive.
2. **Deploy only what you need.** `enable_windows=false` saves ~$276+$8, 
   `enable_remnux=false` ~$70+$10, `enable_opensearch=false` ~$110+$19.
3. **Tear down NAT + endpoints when parked.** ~$55/mo. They re-create fast on the
   next `apply`. (Or drop the SSM endpoints permanently and rely on the bastion +
   SSM-over-NAT if you don't need fully-private SSM.)
4. **Reserved Instances / Compute Savings Plans** — ~30–40% off compute if the
   platform runs steadily. Not worth it for occasional-use IR.
5. **Right-size SIFT.** m6i.2xlarge (32 GB) is sized for Volatility 3 memory
   analysis; drop to m6i.xlarge (16 GB) if you don't run large memory forensics
   (~$140/mo saved). Do **not** undersize below 16 GB.
6. **Glacier lifecycle for closed-case evidence** (§3).
7. **Spot is NOT appropriate** for these stateful, long-lived forensic hosts.

## What is *not* metered here

- LLM/API costs (Anthropic etc.) — separate from AWS, driven by analysis volume.
- Cross-region or internet **egress** of results/reports (first 100 GB/mo free,
  then ~$0.09/GB). Interactive RDP over the tunnel is modest.
- One-time NAT data-processing during provisioning (cast/salt pulls hundreds of
  MB–GBs per build; negligible steady-state).
