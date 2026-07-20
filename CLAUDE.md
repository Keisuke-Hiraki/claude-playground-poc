# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A PoC for a shared "playground" where workshop participants log in via a browser and get a per-user
container running Claude Code (on Amazon Bedrock) with a web terminal (ttyd). Build/teardown
instructions live in [README.md](./README.md); the design rationale (why ALB-auth + a single gateway
instead of per-user target groups, threat model, cost estimate) is written up in a blog post rather
than kept in this repo — read this file for the parts that matter when editing code, below.

There are no automated tests in this repo. Verification is manual (see "Common commands" below);
when in doubt about test coverage, ask the user rather than assuming.

This repo is published as open source. `terraform/terraform.tfvars.example` and `.env.example` must
only ever contain placeholder values (`example.com`, `vpc-xxxxxxxxxxxxxxxxx`, etc.) — never a real
account ID, domain, or email allowlist. The actual `terraform.tfvars`/`.env` files are gitignored.

## Repository layout

```
docker/    Per-user container image: ttyd + Claude Code, built from docker/Dockerfile
gateway/   Session gateway (Node.js): WebSocket proxy from user -> their container
lambda/pre-signup/  Cognito Pre-SignUp trigger (email-domain allowlist for self-registration)
terraform/ AWS production-equivalent infra: Cognito, ALB, ECS Fargate, NAT Gateway, IAM
scripts/   One-off ops scripts (Bedrock Marketplace agreement, image build & push)
docker-compose.yml  Local-only mock of the whole stack (2 static users, no Cognito/ALB)
```

The codebase has **two parallel operating modes**, both implemented in the same `gateway/server.js`:

- **Local (docker-compose) mode**: no `ECS_CLUSTER` env var set → `DYNAMIC_MODE` is `false`. Users
  are a static `gateway/users.json` map; `/login?user=<name>` sets a plaintext cookie. No real auth.
- **AWS (Terraform) mode**: `ECS_CLUSTER` set → `DYNAMIC_MODE` is `true`. Identity comes from the
  ALB's signed `x-amzn-oidc-data` JWT (verified in-process against ALB's public key, never trusted
  unverified); the gateway dynamically `RunTask`s a per-user Fargate task and proxies to its private IP.

When editing `gateway/server.js`, preserve this fork — both modes must keep working from the one file.

## Common commands

### Local (docker-compose) loop
```bash
cp .env.example .env        # fill in AWS creds if you want real Bedrock responses
docker compose up --build   # builds docker/ and gateway/ images, starts alice+bob+gateway
docker compose down
```
Verify by visiting `http://localhost:8080/login?user=alice` and `?user=bob` (separate browser/incognito
sessions) and running `claude --version` / `claude` inside each terminal.

### AWS (Terraform) deploy loop
```bash
# one-time per account/region, before first real Bedrock call:
AWS_PROFILE=your-profile AWS_REGION=ap-northeast-1 ./scripts/accept_bedrock_agreements.sh

cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in vpc_id, domain_name, route53_zone_id, etc.
terraform init
terraform apply

cd ..
AWS_PROFILE=your-profile AWS_REGION=ap-northeast-1 ./scripts/build_and_push.sh
aws ecs update-service --profile your-profile --region ap-northeast-1 \
  --cluster claude-playground-poc --service gateway --force-new-deployment

# teardown:
cd terraform && terraform destroy   # if this fails, empty the ECR repos first
```

### Gateway-only local run (no Docker)
```bash
cd gateway && npm install && npm start   # DYNAMIC_MODE off unless ECS_CLUSTER is set
```

There is no lint/build/test script defined anywhere in this repo (`gateway/package.json` only has
`start`). Don't invent one — verify changes by running the relevant mode above.

## Architecture notes worth knowing before editing

- **`gateway/server.js` is the whole gateway** (~340 lines, single file, no framework). Key sections:
  ALB JWT verification (`verifyOidcJwt`), dynamic task lifecycle (`launchSession`/`getOrCreateSession`/
  `stopSession`), and the static local-mode fallback (`loadStaticUsers`). Session state (`sessions` Map)
  is in-memory only — a gateway restart drops all live sessions.
- **The IAM task role for per-user containers (`terraform/iam.tf` `user_task`) is the single most
  important security boundary in this design.** Every workshop participant has a shell in that
  container, so that role's permissions *are* the participant's effective permissions. It must only
  ever grant `bedrock:InvokeModel*` on the specific approved model ARNs — never broaden it casually.
  A `ssmmessages:*` debug policy had been manually attached to this role in the account outside of
  Terraform (for `ecs execute-command` debugging) and was removed — `enableExecuteCommand` was
  already `false` on the service/tasks, so nothing used it. Don't re-add ECS Exec access here without
  reconsidering this boundary.
- **Access windows and session TTLs are enforced in the gateway, not in AWS**, via JST-aware time math
  (`isWithinLaunchWindow`, `sessionExpiryUtcMs`) and `setTimeout`. Its precision under concurrent load
  (many simultaneous logins/expirations) has not been verified at scale — don't assume it's exact.
- **Claude Code needs general internet egress even when `CLAUDE_CODE_USE_BEDROCK=1`** — it still
  reaches `api.anthropic.com` and similar auxiliary endpoints. This is why `terraform/network.tf` gives
  the private subnet a NAT Gateway rather than trying to route purely through VPC endpoints.
  `DISABLE_AUTOUPDATER=1`/`DISABLE_TELEMETRY=1`/`DISABLE_ERROR_REPORTING=1` (set in `ecs.tf`) reduce but
  don't eliminate this traffic.
- **Bedrock model access requires an AWS Marketplace agreement per model, per account/region**,
  separate from IAM permissions and not created by Terraform. Missing it produces a slow retry loop
  in Claude Code before a 403 surfaces, not an immediate error — `scripts/accept_bedrock_agreements.sh`
  handles it. Any new model added to `variables.tf`'s `bedrock_model_ids` needs this script re-run.
- **`docker/init-firewall.sh`'s egress allowlist is IP-based and resolved once at container start**;
  it has a known DNS-tunneling gap (upstream `anthropics/claude-code` issues #36907, #35197) and is
  disabled by default (`ENABLE_FIREWALL=false`). It's defense-in-depth on top of the security-group/NAT
  boundary in `terraform/network.tf`, not a substitute for it.
- **The ALB-auth + WebSocket combination is verified working** (confirmed end-to-end: Cognito login →
  ALB-signed ID token verification → dynamic task launch → WebSocket proxy), but AWS doesn't document
  this combination explicitly — if this behavior seems to regress, that's a real risk area, not a
  likely misconfiguration on our side.
- **Resource naming in `terraform/` uses three separate prefix variables, not one.** The deployed
  account already had resources under inconsistent names before this repo standardized on Terraform,
  so the code matches that instead of using `project_name` everywhere:
  - `var.project_name` (`claude-playground-poc`): ECS cluster, IAM roles, Cognito user pool, the
    Pre-SignUp Lambda.
  - `var.image_name_prefix` (`claude-playground`): ECR repositories, ECS task definition families.
  - `var.network_resource_prefix` (`playground`): ALB, target group, security groups.
  - The ECS task execution role (`${project_name}-task-execution-role`) is created as a `resource` in
    `iam.tf`, so `terraform apply` works on a fresh account with no manual pre-provisioning. The
    project prefix keeps it from colliding with a standard account-wide `ecsTaskExecutionRole` if one
    already exists. (Earlier revisions referenced a pre-existing role via `data "aws_iam_role"`, which
    forced manual role creation on any account that lacked it — that's why it's a `resource` now.)
  Don't consolidate these into one prefix without confirming the account's actual resource names —
  see the sibling `iam.tf`/`ecs.tf`/`network.tf`/`alb.tf` comments for what maps to what.
- **Tearing down `terraform destroy` can fail on `aws_subnet.private`/security groups if a GuardDuty
  Runtime Monitoring VPC endpoint (`com.amazonaws.<region>.guardduty-data`) has attached an ENI to
  that subnet.** GuardDuty auto-creates this per-VPC when it detects ECS Fargate tasks could run
  there; it's not a Terraform-managed resource and can't be deleted by removing anything in this
  repo's state. If destroy hangs on `DependencyViolation` for the subnet, check
  `aws ec2 describe-network-interfaces --filters Name=subnet-id,Values=<subnet-id>` — if the ENI
  belongs to a `guardduty-data` endpoint, either wait for GuardDuty to release it or
  `aws ec2 modify-vpc-endpoint --remove-subnet-ids <subnet-id>` on that endpoint (confirm with the
  account owner first if the same endpoint also serves other subnets/workloads in the VPC — deleting
  it outright can stop Fargate runtime monitoring account/VPC-wide, not just for this project).
- **The per-user task definition doesn't set an `ephemeral_storage` override** — it runs at Fargate's
  default (20GiB) regardless of `var.storage_limit_gib`, which only feeds the in-container banner text.
