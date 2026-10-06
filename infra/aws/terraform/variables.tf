variable "aws_region" {
  description = "AWS region used by the LAJE environment."
  type        = string
  default     = "sa-east-1"
}

variable "project_name" {
  description = "Project tag/name prefix."
  type        = string
  default     = "laje"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "staging"
}

variable "vpc_cidr" {
  description = "CIDR block for the LAJE VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "app_port" {
  description = "Port exposed by the future laje-api ECS tasks."
  type        = number
  default     = 3000
}

variable "postgres_engine_version" {
  description = "RDS PostgreSQL major version. AWS resolves the latest compatible minor release."
  type        = string
  default     = "17"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_name" {
  description = "Initial logical PostgreSQL database."
  type        = string
  default     = "laje_staging"
}

variable "db_master_username" {
  description = "RDS master username. Password is generated and managed by AWS Secrets Manager."
  type        = string
  default     = "laje_admin"
}

variable "backup_retention_days" {
  description = "Automated backup retention period."
  type        = number
  default     = 1
}

variable "deletion_protection" {
  description = "Prevents deletion of the RDS instance through Terraform."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Controls whether RDS creates a final snapshot before deletion."
  type        = bool
  default     = true
}

variable "final_snapshot_identifier" {
  description = "Final snapshot identifier used when skip_final_snapshot is false."
  type        = string
  default     = null
  nullable    = true
}

variable "jira_issue_key" {
  description = "Jira issue that owns this environment configuration."
  type        = string
  default     = "LAJE-127"
}

variable "staging_api_enabled" {
  description = "Creates the billable staging API runtime (ALB, CloudFront and ECS service). Keep false when staging is suspended."
  type        = bool
  default     = false
}

variable "staging_api_desired_count" {
  description = "Number of Fargate tasks for staging. Use 0 while publishing the first image and 1 only while staging is active."
  type        = number
  default     = 0

  validation {
    condition     = var.staging_api_desired_count >= 0 && var.staging_api_desired_count <= 1
    error_message = "staging_api_desired_count must be 0 or 1 for the low-cost staging environment."
  }
}

variable "staging_api_image_tag" {
  description = "Immutable ECR image tag deployed to the staging task definition."
  type        = string
  default     = "staging"
}

variable "staging_api_cors_origins" {
  description = "Comma-separated browser origins allowed to call the staging API."
  type        = string
  default     = "https://laje-tcc.vercel.app"
}

variable "staging_auth_jwt_secret_name" {
  description = "Secrets Manager name containing the dedicated auth JWT signing secret for staging."
  type        = string
  default     = "laje/staging/auth-jwt"
}

variable "staging_api_log_retention_days" {
  description = "CloudWatch Logs retention for the staging API."
  type        = number
  default     = 7
}
