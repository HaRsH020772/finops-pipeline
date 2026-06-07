# ─────────────────────────────────────────────────────────────────────────────
# IAM role for Amazon Managed Grafana
# IAM is global — no provider alias needed here.
# Scoped to read CUR data via Athena + both S3 buckets only.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "grafana" {
  name = "${var.project_name}-grafana-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "grafana.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
        StringLike = {
          # Workspace lives in ap-southeast-1 (AMG not available in ap-south-1)
          "aws:SourceArn" = "arn:aws:grafana:ap-southeast-1:${data.aws_caller_identity.current.account_id}:/workspaces/*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "grafana_data_access" {
  name = "athena-cur-readonly"
  role = aws_iam_role.grafana.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AthenaAccess"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution",
          "athena:GetWorkGroup",
          "athena:GetDatabase",
          "athena:GetTableMetadata",
          "athena:ListDatabases",
          "athena:ListTableMetadata",
          "athena:ListWorkGroups",
          "athena:ListQueryExecutions",
          "athena:ListDataCatalogs"
        ]
        Resource = "*"
      },
      {
        Sid    = "GlueCatalogRead"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartitions"
        ]
        Resource = "*"
      },
      {
        Sid    = "S3CURRead"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [
          aws_s3_bucket.cur_raw.arn,
          "${aws_s3_bucket.cur_raw.arn}/*"
        ]
      },
      {
        Sid    = "S3AthenaResults"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.athena_results.arn,
          "${aws_s3_bucket.athena_results.arn}/*"
        ]
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Amazon Managed Grafana workspace — ap-southeast-1 (Singapore)
# Uses the "grafana" provider alias defined in main.tf.
# Cross-region Athena queries work fine — just set region = ap-south-1
# when configuring the Athena datasource inside Grafana.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_grafana_workspace" "finops" {
  provider = aws.grafana

  name                     = var.project_name
  description              = "FinOps Cost Intelligence — service spend, team budgets, anomaly detection"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "CUSTOMER_MANAGED"
  role_arn                 = aws_iam_role.grafana.arn
  grafana_version          = "10.4"

  # Enables the Athena plugin inside the workspace.
  # Without this, AMG blocks plugin installation from the UI.
  data_sources = ["ATHENA"]
}

# ─────────────────────────────────────────────────────────────────────────────
# Outputs
# ─────────────────────────────────────────────────────────────────────────────

output "grafana_workspace_id" {
  description = "Workspace ID — needed to associate your SSO user as admin"
  value       = aws_grafana_workspace.finops.id
}

output "grafana_workspace_url" {
  description = "Grafana URL — log in with IAM Identity Center credentials"
  value       = "https://${aws_grafana_workspace.finops.endpoint}"
}
