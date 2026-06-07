output "cur_raw_bucket" {
  description = "S3 bucket for raw CUR data — pass to generate_stub_data.py"
  value       = aws_s3_bucket.cur_raw.bucket
}

output "athena_results_bucket" {
  description = "S3 bucket for Athena query results"
  value       = aws_s3_bucket.athena_results.bucket
}

output "glue_database" {
  description = "Glue catalog database name — use in Athena queries"
  value       = aws_glue_catalog_database.cur.name
}

output "glue_crawler_name" {
  description = "Glue crawler — run this after uploading stub data"
  value       = aws_glue_crawler.cur.name
}

output "athena_workgroup" {
  description = "Athena workgroup name — use in boto3 calls and Grafana datasource"
  value       = aws_athena_workgroup.finops.name
}

output "account_id" {
  description = "AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  description = "AWS region"
  value       = data.aws_region.current.region
}

output "phase1_summary" {
  description = "Quick reference for Phase 2 inputs"
  value = {
    cur_bucket      = aws_s3_bucket.cur_raw.bucket
    results_bucket  = aws_s3_bucket.athena_results.bucket
    glue_database   = aws_glue_catalog_database.cur.name
    glue_table      = "cur_report"
    athena_workgroup = aws_athena_workgroup.finops.name
    cur_s3_prefix   = var.cur_s3_prefix
  }
}
