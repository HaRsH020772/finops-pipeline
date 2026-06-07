# ─────────────────────────────────────────────────────────────────────────────
# CUR raw data bucket
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "cur_raw" {
  bucket = "${var.project_name}-cur-raw-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "cur_raw" {
  bucket = aws_s3_bucket.cur_raw.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cur_raw" {
  bucket = aws_s3_bucket.cur_raw.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cur_raw" {
  bucket                  = aws_s3_bucket.cur_raw.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Required policy for AWS Billing to deliver real CUR files.
# Already included here so enabling real CUR later is a one-liner.
resource "aws_s3_bucket_policy" "cur_raw" {
  bucket = aws_s3_bucket.cur_raw.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBillingAcl"
        Effect = "Allow"
        Principal = {
          Service = "billingreports.amazonaws.com"
        }
        Action   = ["s3:GetBucketAcl", "s3:GetBucketPolicy"]
        Resource = aws_s3_bucket.cur_raw.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "AllowBillingPut"
        Effect = "Allow"
        Principal = {
          Service = "billingreports.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cur_raw.arn}/${var.cur_s3_prefix}/*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Athena query results bucket
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "athena_results" {
  bucket = "${var.project_name}-athena-results-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Auto-expire query results after 30 days — Athena results accumulate fast
resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    id     = "expire-query-results"
    status = "Enabled"
    expiration {
      days = 30
    }
  }
}
