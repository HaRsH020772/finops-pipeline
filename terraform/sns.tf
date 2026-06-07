# ─────────────────────────────────────────────────────────────────────────────
# SNS topic — cost anomaly alerts
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_sns_topic" "cost_alerts" {
  name         = "${var.project_name}-cost-alerts"
  display_name = "FinOps Cost Alerts"
}

# Email subscription is intentionally managed outside Terraform.
# Terraform recreates email subscriptions on every apply when they are in
# PendingConfirmation state, which breaks the confirmation flow.
# Create it once manually with the commands in README and it stays permanently.
#
# resource "aws_sns_topic_subscription" "email" {
#   topic_arn = aws_sns_topic.cost_alerts.arn
#   protocol  = "email"
#   endpoint  = var.alert_email
# }

output "sns_topic_arn" {
  description = "SNS topic ARN for cost alerts"
  value       = aws_sns_topic.cost_alerts.arn
}
