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
