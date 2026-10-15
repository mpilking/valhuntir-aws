# Testing — dedicated IAM identity & permissions

Permissions for an identity that **deploys and tears down** the Valhuntir stack.
Pick one of two approaches. Both cover the same actions; they differ only in how
much of the "everything else" you grant.

> Whoever *creates* this user/role needs admin/IAM rights — do that step with your
> existing admin or SSO identity, then hand the test identity to Terraform.

## What the deployment touches

EC2/VPC (instances, EBS, EIP, NAT, endpoints, security groups), KMS (the project
key), S3 (evidence bucket, and state bucket if you use remote state), Secrets
Manager (generated credentials), IAM (per-host roles + instance profiles, and
**`iam:PassRole`** to EC2), SSM (Windows AMI lookup + Session Manager), STS.

The easy-to-miss one is **`iam:PassRole`** — `RunInstances` with an instance
profile requires the deployer to be allowed to pass that role to `ec2.amazonaws.com`.

## Option A — one least-privilege policy (tightest)

Attach [`iam-deploy-policy.json`](iam-deploy-policy.json). It scopes to
`valhuntir-*` resources where AWS allows it; EC2/VPC actions are `Resource:*`
because those creates can't be resource-scoped. Nothing broader than needed.

## Option B — PowerUserAccess + the IAM piece (simplest)

Attach the AWS-managed **`PowerUserAccess`** (full access to services *except*
IAM/Organizations) plus [`iam-passrole-policy.json`](iam-passrole-policy.json)
for the role/instance-profile/PassRole actions PowerUser omits. Quicker to reason
about; broader than Option A.

## Create the user (Option A shown)

```bash
AWS=~/.local/bin/aws
$AWS iam create-user --user-name valhuntir-deployer

# attach the least-privilege policy inline (or create-policy + attach-user-policy)
$AWS iam put-user-policy --user-name valhuntir-deployer \
  --policy-name valhuntir-deploy \
  --policy-document file://iam-deploy-policy.json

# access keys for Terraform
$AWS iam create-access-key --user-name valhuntir-deployer
# -> configure them:  aws configure --profile valhuntir-deployer
```

For **Option B**:

```bash
$AWS iam attach-user-policy --user-name valhuntir-deployer \
  --policy-arn arn:aws:iam::aws:policy/PowerUserAccess
$AWS iam put-user-policy --user-name valhuntir-deployer \
  --policy-name valhuntir-passrole --policy-document file://iam-passrole-policy.json
```

## Prefer a role over a user

A user means **long-lived access keys** — a standing credential to rotate and
delete. If your org uses SSO/Identity Center, an equivalent is to attach either
policy set to a **permission set / role** and `aws sso login` into it instead.
Same permissions, no static keys. If you do use a user, delete its access keys
when testing is done.

## Caveats

- **`name_prefix`.** The ARNs assume the default `name_prefix = "valhuntir"`.
  If you change it in `terraform.tfvars`, update the `valhuntir-*` ARNs in the
  policies (roles, instance profiles, S3 buckets, secret path).
- **Remote state (optional).** Using the S3 backend adds S3 access to the
  `valhuntir-tfstate*` bucket — already covered by the `valhuntir-*` S3 ARNs in
  both options. Creating that bucket via `bootstrap/` also uses only S3.
- **Packer (optional).** Baking AMIs additionally needs
  `ec2:CreateImage`, `ec2:RegisterImage`, `ec2:DeregisterImage`,
  `ec2:CreateSnapshot`, `ec2:DeleteSnapshot`, `ec2:CopyImage`, and
  `ec2:ModifyImageAttribute`. Not required for the plan → bastion → SIFT test.
- **Permissions boundaries.** In stricter orgs, `iam:CreateRole` may require a
  boundary; add `--permissions-boundary` and a matching policy condition.
- First real `apply` is the true test of these — if something's missing you'll
  get a clear `is not authorized to perform: <action>` error; add that action.
