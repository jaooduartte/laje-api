# LAJE AWS integration/staging infrastructure

This directory contains the Terraform baseline for **LAJE-127**. It prepares the AWS integration/staging environment defined by the architecture decision in LAJE-82.

## Scope

The current Terraform creates:

- one dedicated VPC in `sa-east-1`;
- two public subnets reserved for the future Application Load Balancer;
- two private application subnets reserved for ECS/Fargate;
- two private database subnets for Amazon RDS;
- Security Groups implementing `ALB -> ECS -> RDS` least-privilege ingress;
- an RDS subnet group;
- a PostgreSQL 17 parameter group with `rds.force_ssl=1`;
- one private, Single-AZ RDS for PostgreSQL 17 staging instance;
- encrypted gp3 storage and automated backups;
- PostgreSQL logs exported to CloudWatch Logs;
- the RDS master password generated and managed by AWS Secrets Manager.

The current Supabase production environment is not modified by this stack.

## Deliberately not provisioned yet

The following components belong to later tasks and are intentionally not created here:

- ECS/Fargate service and task definition;
- ECR image/repository configuration used by the final deployment;
- Application Load Balancer and ACM certificate;
- NAT Gateway or VPC endpoints for ECS egress;
- production RDS;
- final GitHub Actions -> AWS OIDC deployment role;
- SQS/EventBridge replacements for asynchronous/cron workloads;
- final production cutover from Supabase to AWS.

Security Groups and subnets for the future ALB/ECS path are created now so the database can be provisioned without later reopening PostgreSQL to the Internet.

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

## Usage

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

## Database baseline

The RDS instance is private. The PostgreSQL baseline must therefore be applied from a controlled execution path with network access to the VPC, not by temporarily exposing the database publicly.

Use `scripts/apply-rds-baseline.sh` from an approved AWS execution context after exporting a TLS-validated `DATABASE_URL` and the RDS CA certificate path. The script applies:

1. `infra/database/baseline/schema.sql`;
2. `infra/database/baseline/validate.sql`.

No database credentials or secret values must be written to documentation, shell history, repository files or pull-request comments.

## Cost controls

The staging defaults intentionally use a small Single-AZ `db.t4g.micro` instance and 20 GiB gp3 storage. Automated backup retention is set to **1 day** in staging because the AWS Free Plan used for this environment rejects the previous 7-day value. Production sizing and production backup policy are explicitly outside LAJE-127 and must be reviewed separately before cutover.

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
- future production infrastructure and the final Supabase -> AWS cutover remain for later migration tasks.

The frontend hosting is not changed by LAJE-127. The current Vercel usage remains under the project-specific authorization previously obtained from the professor; this infrastructure module is limited to the AWS staging/backend migration path.
