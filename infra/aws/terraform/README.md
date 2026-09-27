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

The production Supabase environment is not modified by this stack.

## Deliberately not provisioned yet

The following components belong to later tasks and are intentionally not created here:

- ECS/Fargate service and task definition;
- ECR image/repository configuration used by the final deployment;
- Application Load Balancer and ACM certificate;
- NAT Gateway or VPC endpoints for ECS egress;
- production RDS;
- final GitHub Actions -> AWS OIDC deployment role;
- SQS/EventBridge replacements for asynchronous/cron workloads.

Security Groups and subnets for the future ALB/ECS path are created now so the database can be provisioned without later reopening PostgreSQL to the Internet.

## Security model

- RDS has `publicly_accessible = false`.
- Port `5432` is allowed only from the ECS Security Group.
- PostgreSQL TLS is forced with `rds.force_ssl=1`.
- No database password is stored in Terraform source or GitHub; RDS manages the master credential in Secrets Manager.
- Staging uses a separate VPC/database identity from the legacy Supabase production environment.

Do not add `0.0.0.0/0` access to port `5432` as a shortcut for migrations.

## Usage

Prerequisites:

- Terraform >= 1.8;
- authenticated AWS identity with only the permissions required to provision the resources in this stack;
- AWS region `sa-east-1` enabled for the account.

Copy the example variables only when overrides are needed:

```bash
cp terraform.tfvars.example terraform.tfvars
terraform init
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

The output of the validation must be recorded in LAJE-127 before the task can be considered complete.

## Cost controls

The staging defaults intentionally use a small Single-AZ instance class and 20 GiB gp3 storage. Before `terraform apply`, review the current AWS pricing for `sa-east-1` and confirm that the selected instance class is orderable for PostgreSQL 17. Production sizing is explicitly outside LAJE-127.

## Current execution status

The Terraform definition is versioned and can be validated without AWS credentials. Actual account provisioning and baseline execution are separate evidence gates for LAJE-127 and must not be marked complete unless the AWS calls and PostgreSQL validation have actually succeeded.
