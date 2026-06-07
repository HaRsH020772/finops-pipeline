# ─────────────────────────────────────────────────────────────────────────────
# Athena workgroup
# All Lambda and Grafana queries route through this workgroup so costs are
# trackable and query result location is enforced.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_athena_workgroup" "finops" {
  name        = var.project_name
  description = "FinOps cost intelligence — Lambda enrichment and Grafana dashboard queries"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/${var.athena_query_output_prefix}/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Named queries — saved in the Athena console for quick access
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_athena_named_query" "weekly_cost_by_service" {
  name        = "weekly-cost-by-service"
  workgroup   = aws_athena_workgroup.finops.name
  database    = aws_glue_catalog_database.cur.name
  description = "Total cost per service per week — primary source for anomaly detection"

  query = <<-SQL
    SELECT
      line_item_product_code                                                       AS service,
      DATE_TRUNC('week', from_iso8601_timestamp(line_item_usage_start_date))       AS week_start,
      ROUND(SUM(line_item_unblended_cost), 4)                                      AS weekly_cost
    FROM cur_report
    WHERE line_item_line_item_type = 'Usage'
    GROUP BY 1, 2
    ORDER BY 1, 2;
  SQL
}

resource "aws_athena_named_query" "cost_by_team" {
  name        = "cost-by-team"
  workgroup   = aws_athena_workgroup.finops.name
  database    = aws_glue_catalog_database.cur.name
  description = "Cost broken down by team tag — for Grafana team dashboard"

  query = <<-SQL
    SELECT
      resource_tags_user_team                                                      AS team,
      DATE_TRUNC('week', from_iso8601_timestamp(line_item_usage_start_date))       AS week_start,
      ROUND(SUM(line_item_unblended_cost), 4)                                      AS weekly_cost
    FROM cur_report
    WHERE line_item_line_item_type = 'Usage'
      AND resource_tags_user_team != ''
    GROUP BY 1, 2
    ORDER BY 1, 2;
  SQL
}

resource "aws_athena_named_query" "top5_cost_drivers" {
  name        = "top5-cost-drivers"
  workgroup   = aws_athena_workgroup.finops.name
  database    = aws_glue_catalog_database.cur.name
  description = "Top 5 most expensive services this week"

  query = <<-SQL
    SELECT
      line_item_product_code  AS service,
      resource_tags_user_team AS team,
      ROUND(SUM(line_item_unblended_cost), 4) AS total_cost
    FROM cur_report
    WHERE line_item_line_item_type = 'Usage'
      AND from_iso8601_timestamp(line_item_usage_start_date)
          >= DATE_TRUNC('week', CURRENT_TIMESTAMP)
    GROUP BY 1, 2
    ORDER BY 3 DESC
    LIMIT 5;
  SQL
}
