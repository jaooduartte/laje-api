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

output "staging_api_ecr_repository_url" {
  value       = aws_ecr_repository.api.repository_url
  description = "ECR repository used by the staging laje-api image."
}

output "staging_api_ecs_cluster_name" {
  value       = aws_ecs_cluster.api.name
  description = "ECS cluster used by staging."
}

output "staging_api_https_url" {
  value       = var.staging_api_enabled ? "https://${aws_cloudfront_distribution.api[0].domain_name}" : null
  description = "Public HTTPS URL for staging. Null while the billable staging runtime is suspended."
}

output "staging_api_alb_dns_name" {
  value       = var.staging_api_enabled ? aws_lb.api[0].dns_name : null
  description = "ALB DNS name used only as the CloudFront origin."
}
