# ─────────────────────────────────────────────────────────────────────────────
# Glue catalog database
# ─────────────────────────────────────────────────────────────────────────────

locals {
  glue_database_name = replace("${var.project_name}_cur", "-", "_")
}

resource "aws_glue_catalog_database" "cur" {
  name        = local.glue_database_name
  description = "AWS Cost & Usage Report schema catalog for FinOps pipeline"
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM role for Glue crawler
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "glue_crawler" {
  name = "${var.project_name}-glue-crawler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_crawler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3_read" {
  name = "s3-cur-read"
  role = aws_iam_role.glue_crawler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ]
      Resource = [
        aws_s3_bucket.cur_raw.arn,
        "${aws_s3_bucket.cur_raw.arn}/*"
      ]
    }]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Glue crawler
# Crawls the CUR prefix in S3, infers the schema, and creates/updates the
# Athena-queryable table in the Glue catalog. Run manually after first data
# upload, then on a weekly cadence via the EventBridge rule below.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_glue_crawler" "cur" {
  database_name = aws_glue_catalog_database.cur.name
  name          = "${var.project_name}-cur-crawler"
  role          = aws_iam_role.glue_crawler.arn
  description   = "Crawls CUR CSV stub (or real CUR) and registers schema in Glue catalog"

  s3_target {
    path = "s3://${aws_s3_bucket.cur_raw.bucket}/${var.cur_s3_prefix}/"
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
  }

  # Preserve partition layout; don't add extra partition columns
  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
      Tables     = { AddOrUpdateBehavior = "MergeNewColumns" }
    }
    Grouping = {
      TableGroupingPolicy = "CombineCompatibleSchemas"
    }
  })
}

# Optional: run the crawler every Sunday night so new CUR data is cataloged
# before the Monday Lambda enrichment run. Uncomment when moving to real CUR.
#
# resource "aws_glue_trigger" "cur_weekly" {
#   name     = "${var.project_name}-cur-crawler-weekly"
#   type     = "SCHEDULED"
#   schedule = "cron(0 1 ? * SUN *)"  # 01:00 UTC every Sunday
#
#   actions {
#     crawler_name = aws_glue_crawler.cur.name
#   }
# }
