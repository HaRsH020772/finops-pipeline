# FinOps Cloud Cost Intelligence Pipeline

> Automatically ingest AWS Cost & Usage Reports, detect cost anomalies week-over-week, and surface them in Grafana with SNS alerts — all serverless, all Terraform-managed, under $1/month (excluding Grafana).

## Architecture

```
AWS CUR (daily) → S3 → Glue Crawler → Athena ← Grafana
                             EventBridge → Lambda → SNS
```

## Stack

| Layer | Tool |
|---|---|
| Infrastructure | Terraform ≥ 1.5 |
| Data catalog | AWS Glue |
| Query engine | AWS Athena (engine v3) |
| Enrichment + detection | Lambda Python 3.12 |
| Scheduling | EventBridge cron |
| Alerting | SNS → email |
| Dashboards | Amazon Managed Grafana |

## Prerequisites

- AWS CLI configured
- Terraform ≥ 1.5
- Python 3.9+ with boto3 (`pip install boto3`)
- IAM Identity Center enabled (required for AMG login)

## Regions

Core infra (S3, Glue, Athena, Lambda, SNS) deploys to `ap-south-1`.
Grafana workspace deploys to `ap-southeast-1` — AMG is not available in ap-south-1.

## Quick Start

```bash
# 1. Apply infra
cd terraform
terraform init
terraform apply

# 2. Upload stub data
BUCKET=$(terraform output -raw cur_raw_bucket)
cd ..
python3 scripts/generate_stub_data.py $BUCKET

# 3. Run Glue crawler
aws glue start-crawler \
  --name $(cd terraform && terraform output -raw glue_crawler_name)

# 4. Verify Athena (run in console, workgroup: finops-pipeline)
# SELECT line_item_product_code, DATE_TRUNC('week', from_iso8601_timestamp(line_item_usage_start_date)), ROUND(SUM(line_item_unblended_cost),2)
# FROM finops_pipeline_cur.cur_report WHERE line_item_line_item_type='Usage' GROUP BY 1,2 ORDER BY 1,2;

# 5. Test Lambda
aws lambda invoke \
  --function-name finops-pipeline-enricher \
  --log-type Tail --query 'LogResult' --output text \
  /tmp/out.json | base64 -d && cat /tmp/out.json

# 6. Add SNS subscription (managed outside Terraform — avoids PendingConfirmation loop)
TOPIC_ARN=$(cd terraform && terraform output -raw sns_topic_arn)
aws sns subscribe --topic-arn $TOPIC_ARN --protocol email \
  --notification-endpoint your@email.com
# Click confirmation link in email immediately

# 7. Associate yourself as Grafana admin
WORKSPACE_ID=$(cd terraform && terraform output -raw grafana_workspace_id)
IDENTITY_STORE_ID=$(aws sso-admin list-instances --query 'Instances[0].IdentityStoreId' --output text)
USER_ID=$(aws identitystore list-users --identity-store-id $IDENTITY_STORE_ID --query 'Users[0].UserId' --output text)
aws grafana update-permissions --workspace-id $WORKSPACE_ID \
  --update-instruction-batch "[{\"action\":\"ADD\",\"role\":\"ADMIN\",\"users\":[{\"id\":\"$USER_ID\",\"type\":\"SSO_USER\"}]}]"

# 8. Enable Athena plugin in AMG
aws grafana update-workspace-configuration \
  --workspace-id $WORKSPACE_ID \
  --configuration '{"plugins":{"pluginAdminEnabled":true}}' \
  --region ap-southeast-1

# 9. Log into Grafana, install Amazon Athena plugin, configure datasource, import dashboard JSON
```

## Grafana Datasource Config

| Field | Value |
|---|---|
| Authentication | AWS SDK Default |
| Endpoint | `https://athena.ap-south-1.amazonaws.com` |
| Default Region | ap-south-1 |
| Data source | AwsDataCatalog |
| Database | finops_pipeline_cur |
| Workgroup | finops-pipeline |

## Enabling Real CUR (after stub testing)

```bash
aws cur put-report-definition \
  --report-definition '{
    "ReportName": "finops-pipeline-cur",
    "TimeUnit": "DAILY",
    "Format": "textORcsv",
    "Compression": "GZIP",
    "AdditionalSchemaElements": ["RESOURCES"],
    "S3Bucket": "'$(cd terraform && terraform output -raw cur_raw_bucket)'",
    "S3Prefix": "cur/cur_report",
    "S3Region": "ap-south-1",
    "ReportVersioning": "OVERWRITE_REPORT"
  }' --region us-east-1
```

Real CUR data appears within 24h.

## Anomaly Detection

Lambda compares total weekly spend per service. If any service increases by more than `ANOMALY_THRESHOLD_PCT` (default 30%), an SNS alert fires.

Stub data includes two baked-in anomalies to demonstrate end-to-end:
- AmazonEC2: +41.5%
- AmazonRDS: +42%

## Pipeline Cost

| Resource | Monthly |
|---|---|
| Lambda | Free tier |
| Athena | ~$0.02 |
| Glue | ~$0.05 |
| S3 | ~$0.10 |
| SNS | Negligible |
| Amazon Managed Grafana | $9/editor |
| **Total** | **~$9.20** |
