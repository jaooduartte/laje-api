# LAJE AWS database infrastructure

This directory contains the Terraform baseline for the AWS database environments defined by LAJE-82. The provisioned state remains the LAJE-127 integration/staging environment; LAJE-88 adds the production configuration and cutover controls.

## Scope

The current Terraform creates:

- one dedicated VPC in `sa-east-1`;
- two public subnets reserved for the future Application Load Balancer;
- two private application subnets reserved for ECS/Fargate;
- two private database subnets for Amazon RDS;
- Security Groups implementing `ALB -> ECS -> RDS` least-privilege ingress;
- an RDS subnet group;
- a PostgreSQL 17 parameter group with `rds.force_ssl=1`;
- one private, Single-AZ RDS for PostgreSQL 17 per isolated Terraform state;
- encrypted gp3 storage and automated backups;
- PostgreSQL logs exported to CloudWatch Logs;
- the RDS master password generated and managed by AWS Secrets Manager.

The current Supabase production environment is not modified by this stack.

## Staging API runtime — LAJE-136

The module now contains the integration/staging runtime for `laje-api`:

- Amazon ECR with scan-on-push and retention of the three newest images;
- Amazon ECS/Fargate using one 0.25 vCPU / 512 MiB task while staging is active;
- internal Application Load Balancer in the application subnets;
- API Gateway HTTP API as the public HTTPS endpoint, connected through a VPC Link;
- CloudWatch Logs with short staging retention;
- RDS credentials injected from the RDS-managed Secrets Manager secret;
- browser CORS configured through Terraform variables.

To avoid a NAT Gateway, the staging Fargate task runs in the public subnets with a public IP **but does not accept Internet ingress**. Its Security Group permits application traffic only from the ALB. The ALB is internal and receives traffic only from API Gateway through a VPC Link. RDS remains private and accepts PostgreSQL only from the ECS Security Group.

The billable ALB, API Gateway VPC Link/runtime and ECS service are controlled by `staging_api_enabled`. Keep it `false` when staging is not being actively validated. ECR, the ECS cluster, task definition, execution role and short-retention log group may remain because they do not create continuous compute/load-balancer charges.

Still intentionally outside this module/task:

- SQS/EventBridge replacements for asynchronous/cron workloads (LAJE-126);
- realtime replacement (LAJE-89);
- production database/runtime and final cutover (LAJE-139).

## Security model

- RDS has `publicly_accessible = false`.
- Port `5432` is allowed only from the ECS Security Group.
- PostgreSQL TLS is forced with `rds.force_ssl=1`.
- No database password is stored in Terraform source or GitHub; RDS manages the master credential in Secrets Manager.
- Staging uses a separate VPC/database identity from the current Supabase production environment.

Do not add `0.0.0.0/0` access to port `5432` as a shortcut for migrations.

## Prerequisites

- Terraform `>= 1.16.0, < 1.17.0`;
- authenticated AWS identity with only the permissions required to provision/manage the resources in this stack;
- AWS region `sa-east-1` enabled for the account.

## Staging usage

Copy the example variables only when overrides are needed:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Initialize the remote S3 backend used by this environment:

```bash
terraform init -reconfigure \
  -backend-config="bucket=laje-terraform-state-549243453554-sa-east-1"
```

Then validate and review changes before applying:

```bash
terraform fmt -check
terraform validate
terraform plan
terraform apply
```

`terraform.tfvars`, state files, plans and local Terraform metadata must not be committed.

## Production usage

Production uses the same reviewed resources with a distinct VPC, Terraform state, database identity and Secrets Manager credential. It must not reuse the staging backend key or `terraform.tfvars`.

```bash
terraform init -reconfigure \
  -backend-config="bucket=laje-terraform-state-549243453554-sa-east-1" \
  -backend-config="key=laje/production/terraform.tfstate"
terraform plan -var-file=production.tfvars
```

Create `production.tfvars` from `production.tfvars.example` only after the pre-cutover review has confirmed the remaining AWS credits and the dependencies in LAJE-33, LAJE-37 and LAJE-89. The configuration starts with a private Single-AZ `db.t4g.micro`, 20 GiB gp3, seven automated backup days, deletion protection and final snapshots enabled.

## Database baseline

The RDS instance is private. The PostgreSQL baseline must therefore be applied from a controlled execution path with network access to the VPC, not by temporarily exposing the database publicly.

Use `scripts/apply-rds-baseline.sh` from an approved AWS execution context after loading libpq connection variables from the managed secret. It requires `PGHOST`, `PGUSER`, `PGDATABASE`, `PGPASSWORD`, `PGSSLROOTCERT`, `PGSSLMODE=verify-full`, `MIGRATION_EXECUTION_CONTEXT=controlled` and `MIGRATION_ALLOW_DESTINATION_WRITE=true`. The script refuses a destination whose `public` schema already has tables. It applies:

1. `infra/database/baseline/schema.sql`;
2. `infra/database/baseline/validate.sql`.
3. All incremental SQL migrations in `infra/database/migrations/`.

No database credentials or secret values must be written to documentation, shell history, repository files or pull-request comments.

## Cost controls

The staging defaults intentionally use a small Single-AZ `db.t4g.micro` instance and 20 GiB gp3 storage. Automated backup retention is set to **1 day** in staging because the AWS Free Plan used for this environment rejects the previous 7-day value. The production example requests seven days, deletion protection and a final snapshot. Before `terraform apply`, confirm that the account accepts seven-day retention; if it still uses the Free Plan restriction, review the one-day retention and manual snapshot tradeoff before changing `production.tfvars`. Review the current AWS estimate, active credits and any costs from API, load balancer, network or temporary migration resources.

## Current execution status

LAJE-127 has been provisioned and validated in the AWS staging/integration account in `sa-east-1`.

Verified state:

- current production remains on Supabase and was not modified by this task;
- AWS staging/integration VPC is provisioned;
- private Amazon RDS for PostgreSQL 17 is provisioned and reachable only through the intended VPC/Security Group path;
- the LAJE database baseline was applied from an empty database and `validate.sql` completed successfully;
- Terraform state is stored in the encrypted, versioned S3 backend with Block Public Access enabled;
- the final `terraform plan` after provisioning returned no changes, confirming no known drift between configuration, state and live infrastructure;
- temporary EC2/SSM/IAM resources used only to bootstrap and validate the private RDS were removed after completion;
- on 04/10/2026, a temporary copy of the production configuration passed `terraform validate`; a production `terraform plan` could not complete because local AWS provider credentials were unavailable, so no production resource was created;
- future production infrastructure and the final Supabase -> AWS cutover remain for later migration tasks.

The frontend hosting is not changed by LAJE-127. The current Vercel usage remains under the project-specific authorization previously obtained from the professor; this infrastructure module is limited to the AWS staging/backend migration path.

## Deploying or suspending staging

The GitHub Actions workflow `.github/workflows/deploy-aws.yml` uses GitHub OIDC instead of long-lived AWS keys. A deployment first applies the runtime with zero tasks, publishes an immutable image to ECR, then applies one Fargate task and validates both health endpoints.

Use the manual workflow action `deploy` to start/update staging. Use `suspend` after validation to destroy the billable ALB/API Gateway VPC Link/ECS service while preserving the reproducible low-cost foundation.

No NAT Gateway is part of this design.
