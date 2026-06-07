# ─────────────────────────────────────────────────────────────────────────────
# Package Lambda code into a zip automatically on every terraform apply.
# The hash changes only when handler.py changes, so Lambda re-deploys only
# when the code actually changes.
# ─────────────────────────────────────────────────────────────────────────────

data "archive_file" "lambda_enricher" {
  type        = "zip"
  source_file = "${path.module}/../lambda/enricher/handler.py"
  output_path = "${path.module}/../lambda/enricher/enricher.zip"
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM role for Lambda
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "lambda_enricher" {
  name = "${var.project_name}-lambda-enricher-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# CloudWatch Logs — basic execution
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_enricher.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Scoped policy: Athena + Glue + S3 + SNS — nothing else
resource "aws_iam_role_policy" "lambda_finops_access" {
  name = "finops-access"
  role = aws_iam_role.lambda_enricher.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AthenaQuery"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution",
          "athena:ListQueryExecutions"
        ]
        Resource = aws_athena_workgroup.finops.arn
      },
      {
        # Glue doesn't support resource-level permissions for Get* calls
        Sid    = "GlueCatalogRead"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartitions"
        ]
        Resource = "*"
      },
      {
        Sid    = "S3CURRead"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
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
          "s3:GetBucketLocation"  # Athena calls this to verify the output bucket before executing
        ]
        Resource = [
          aws_s3_bucket.athena_results.arn,
          "${aws_s3_bucket.athena_results.arn}/*"
        ]
      },
      {
        Sid      = "SNSPublish"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.cost_alerts.arn
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Lambda function
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_lambda_function" "enricher" {
  function_name    = "${var.project_name}-enricher"
  role             = aws_iam_role.lambda_enricher.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_enricher.output_path
  source_code_hash = data.archive_file.lambda_enricher.output_base64sha256

  # Athena queries can take 10-30 seconds on cold data; 5 min is safe headroom
  timeout     = 300
  memory_size = 256

  environment {
    variables = {
      ATHENA_DATABASE       = aws_glue_catalog_database.cur.name
      ATHENA_TABLE          = "cur_report"
      ATHENA_WORKGROUP      = aws_athena_workgroup.finops.name
      ATHENA_RESULTS_BUCKET = aws_s3_bucket.athena_results.bucket
      SNS_TOPIC_ARN         = aws_sns_topic.cost_alerts.arn
      ANOMALY_THRESHOLD_PCT = tostring(var.anomaly_threshold_pct)
    }
  }
}

resource "aws_cloudwatch_log_group" "lambda_enricher" {
  name              = "/aws/lambda/${aws_lambda_function.enricher.function_name}"
  retention_in_days = 14
}

# ─────────────────────────────────────────────────────────────────────────────
# EventBridge — daily trigger at 08:00 UTC
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_event_rule" "daily_enricher" {
  name                = "${var.project_name}-daily-enricher"
  description         = "Triggers the FinOps enricher Lambda daily at 08:00 UTC"
  schedule_expression = "cron(0 8 * * ? *)"
}

resource "aws_cloudwatch_event_target" "enricher" {
  rule      = aws_cloudwatch_event_rule.daily_enricher.name
  target_id = "finops-enricher-lambda"
  arn       = aws_lambda_function.enricher.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.enricher.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_enricher.arn
}

# ─────────────────────────────────────────────────────────────────────────────
# Outputs
# ─────────────────────────────────────────────────────────────────────────────

output "lambda_function_name" {
  description = "Lambda function name — use this to invoke manually"
  value       = aws_lambda_function.enricher.function_name
}

output "lambda_log_group" {
  description = "CloudWatch log group for Lambda output"
  value       = aws_cloudwatch_log_group.lambda_enricher.name
}
