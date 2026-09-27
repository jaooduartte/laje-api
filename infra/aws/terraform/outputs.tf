output "aws_region" {
  value       = var.aws_region
  description = "AWS region used by staging."
}

output "vpc_id" {
  value       = aws_vpc.this.id
  description = "LAJE staging VPC ID."
}

output "public_subnet_ids" {
  value       = aws_subnet.public[*].id
  description = "Public subnet IDs reserved for the future ALB."
}

output "app_private_subnet_ids" {
  value       = aws_subnet.app_private[*].id
  description = "Private application subnet IDs reserved for ECS/Fargate."
}

output "db_private_subnet_ids" {
  value       = aws_subnet.db_private[*].id
  description = "Private database subnet IDs used by RDS."
}

output "alb_security_group_id" {
  value       = aws_security_group.alb.id
  description = "Security Group for the future staging ALB."
}

output "ecs_security_group_id" {
  value       = aws_security_group.ecs.id
  description = "Security Group for the future staging ECS service."
}

output "rds_security_group_id" {
  value       = aws_security_group.rds.id
  description = "Security Group attached to the staging RDS instance."
}

output "rds_endpoint" {
  value       = aws_db_instance.staging.address
  description = "Private DNS endpoint of the staging RDS instance."
}

output "rds_port" {
  value       = aws_db_instance.staging.port
  description = "PostgreSQL port."
}

output "rds_database_name" {
  value       = aws_db_instance.staging.db_name
  description = "Initial logical database name."
}

output "rds_master_secret_arn" {
  value       = try(aws_db_instance.staging.master_user_secret[0].secret_arn, null)
  description = "Secrets Manager ARN managed automatically by RDS for the master credential."
  sensitive   = true
}
