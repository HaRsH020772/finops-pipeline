variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name — used as a prefix in all resource names"
  type        = string
  default     = "finops-pipeline"
}

variable "environment" {
  description = "Environment label"
  type        = string
  default     = "demo"
}

variable "cur_s3_prefix" {
  description = "S3 prefix where CUR data is stored (stub or real)"
  type        = string
  default     = "cur/cur_report"
}

variable "athena_query_output_prefix" {
  description = "S3 prefix for Athena query results"
  type        = string
  default     = "query-results"
}

variable "anomaly_threshold_pct" {
  description = "Week-over-week cost increase % that triggers an SNS alert"
  type        = number
  default     = 30
}

variable "alert_email" {
  description = "Email address to receive anomaly alerts"
  type        = string
  default     = "<email>"
}
