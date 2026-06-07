#!/usr/bin/env python3
"""
Generates a two-week AWS CUR stub CSV and uploads it to S3.

Data covers:
  - Previous week: May 26–Jun 1, 2026
  - Current week:  Jun 2–Jun 7, 2026

Anomalies baked in (triggers at default 30% threshold):
  - AmazonEC2:  +41% week-over-week  → ALERT
  - AmazonRDS:  +42% week-over-week  → ALERT
  - All others: < 10%                → normal

Usage:
    python3 scripts/generate_stub_data.py <cur-raw-bucket-name>

    # dry run (generates CSV locally, no upload):
    python3 scripts/generate_stub_data.py --dry-run
"""

import csv
import io
import os
import sys
import uuid
import random
import argparse
from datetime import datetime, timedelta, timezone

# ─────────────────────────────────────────────────────────────────────────────
# Service definitions
# daily_cost_prev / daily_cost_curr are baseline daily costs in USD.
# ─────────────────────────────────────────────────────────────────────────────

SERVICES = [
    {
        "product_code":   "AmazonEC2",
        "product_name":   "Amazon Elastic Compute Cloud",
        "usage_type":     "BoxUsage:m5.xlarge",
        "operation":      "RunInstances",
        "team":           "platform",
        "environment":    "production",
        "service_label":  "k8s-nodes",
        "daily_cost_prev": 200.00,  # $1,400/week prev
        "daily_cost_curr": 283.00,  # $1,981/week curr  (+41.5%) ⚠ ANOMALY
    },
    {
        "product_code":   "AmazonRDS",
        "product_name":   "Amazon Relational Database Service",
        "usage_type":     "RDS:db.r5.xlarge",
        "operation":      "CreateDBInstance",
        "team":           "data",
        "environment":    "production",
        "service_label":  "tidb-backend",
        "daily_cost_prev":  50.00,  # $350/week prev
        "daily_cost_curr":  71.00,  # $497/week curr  (+42%) ⚠ ANOMALY
    },
    {
        "product_code":   "AmazonEKS",
        "product_name":   "Amazon Elastic Kubernetes Service",
        "usage_type":     "AmazonEKS-Hours:perCluster",
        "operation":      "CreateCluster",
        "team":           "platform",
        "environment":    "production",
        "service_label":  "eks-cluster",
        "daily_cost_prev":  30.00,  # $210/week prev
        "daily_cost_curr":  32.50,  # $227/week curr  (+8.3%)
    },
    {
        "product_code":   "AmazonS3",
        "product_name":   "Amazon Simple Storage Service",
        "usage_type":     "TimedStorage-ByteHrs",
        "operation":      "GetObject",
        "team":           "platform",
        "environment":    "production",
        "service_label":  "object-storage",
        "daily_cost_prev":   5.00,  # $35/week prev
        "daily_cost_curr":   5.40,  # $37.8/week curr  (+8%)
    },
    {
        "product_code":   "AWSLambda",
        "product_name":   "AWS Lambda",
        "usage_type":     "Lambda-GB-Second",
        "operation":      "Invoke",
        "team":           "backend",
        "environment":    "production",
        "service_label":  "serverless-functions",
        "daily_cost_prev":   2.00,
        "daily_cost_curr":   2.10,  # +5%
    },
    {
        "product_code":   "AmazonCloudFront",
        "product_name":   "Amazon CloudFront",
        "usage_type":     "DataTransfer-Out-Bytes",
        "operation":      "GET",
        "team":           "frontend",
        "environment":    "production",
        "service_label":  "cdn",
        "daily_cost_prev":   8.00,
        "daily_cost_curr":   8.60,  # +7.5%
    },
    {
        "product_code":   "AmazonRoute53",
        "product_name":   "Amazon Route 53",
        "usage_type":     "DNS-Queries",
        "operation":      "DNS Query",
        "team":           "platform",
        "environment":    "production",
        "service_label":  "dns",
        "daily_cost_prev":   1.00,
        "daily_cost_curr":   1.00,  # 0%
    },
    {
        "product_code":   "AWSDataTransfer",
        "product_name":   "AWS Data Transfer",
        "usage_type":     "DataTransfer-Out-Bytes",
        "operation":      "DataTransfer",
        "team":           "platform",
        "environment":    "production",
        "service_label":  "data-transfer",
        "daily_cost_prev":  15.00,
        "daily_cost_curr":  16.00,  # +6.7%
    },
]

ACCOUNT_ID = "989237246761"
REGION     = "us-east-1"

COLUMNS = [
    "identity_line_item_id",
    "bill_billing_period_start_date",
    "line_item_usage_start_date",
    "line_item_usage_end_date",
    "line_item_usage_account_id",
    "line_item_line_item_type",
    "line_item_product_code",
    "line_item_usage_type",
    "line_item_operation",
    "line_item_usage_amount",
    "line_item_unblended_cost",
    "line_item_blended_cost",
    "product_product_name",
    "product_region",
    "resource_tags_user_team",
    "resource_tags_user_environment",
    "resource_tags_user_service",
]

# ─────────────────────────────────────────────────────────────────────────────

def generate_rows(seed: int = 42) -> list[dict]:
    random.seed(seed)  # Reproducible output
    rows = []

    # Both must be Mondays — Athena DATE_TRUNC('week') uses ISO week (Mon start)
    # May 25 = Monday, June 1 = Monday
    prev_week_start = datetime(2026, 5, 25, tzinfo=timezone.utc)
    curr_week_start = datetime(2026, 6,  1, tzinfo=timezone.utc)

    for svc in SERVICES:
        for week_idx, (week_start, cost_key, billing_period) in enumerate([
            (prev_week_start, "daily_cost_prev", "2026-05-01T00:00:00Z"),
            (curr_week_start, "daily_cost_curr", "2026-06-01T00:00:00Z"),
        ]):
            for day_offset in range(7):
                day = week_start + timedelta(days=day_offset)
                jitter = random.uniform(0.96, 1.04)  # ±4% daily variance
                cost   = round(svc[cost_key] * jitter, 4)

                rows.append({
                    "identity_line_item_id":         str(uuid.uuid4()),
                    "bill_billing_period_start_date": billing_period,
                    "line_item_usage_start_date":     day.strftime("%Y-%m-%dT00:00:00Z"),
                    "line_item_usage_end_date":       (day + timedelta(days=1)).strftime("%Y-%m-%dT00:00:00Z"),
                    "line_item_usage_account_id":     ACCOUNT_ID,
                    "line_item_line_item_type":       "Usage",
                    "line_item_product_code":         svc["product_code"],
                    "line_item_usage_type":           svc["usage_type"],
                    "line_item_operation":            svc["operation"],
                    "line_item_usage_amount":         round(cost / 0.05, 2),
                    "line_item_unblended_cost":       cost,
                    "line_item_blended_cost":         cost,
                    "product_product_name":           svc["product_name"],
                    "product_region":                 REGION,
                    "resource_tags_user_team":        svc["team"],
                    "resource_tags_user_environment": svc["environment"],
                    "resource_tags_user_service":     svc["service_label"],
                })

    return rows


def to_csv(rows: list[dict]) -> str:
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=COLUMNS)
    writer.writeheader()
    writer.writerows(rows)
    return buf.getvalue()


def print_summary(rows: list[dict]) -> None:
    from collections import defaultdict
    weekly: dict = defaultdict(lambda: defaultdict(float))
    for r in rows:
        week = r["line_item_usage_start_date"][:10][:8] + "01"  # rough week key
        svc  = r["line_item_product_code"]
        weekly[svc][week[:7]] += r["line_item_unblended_cost"]

    print("\n── Cost summary (weekly totals) ─────────────────────────────")
    print(f"{'Service':<22} {'May-26 week':>14} {'Jun-02 week':>14} {'Change':>8}")
    print("─" * 62)
    for svc in SERVICES:
        code = svc["product_code"]
        prev = svc["daily_cost_prev"] * 7
        curr = svc["daily_cost_curr"] * 7
        pct  = (curr - prev) / prev * 100
        flag = " ⚠ ANOMALY" if pct > 30 else ""
        print(f"{code:<22} ${prev:>12.2f} ${curr:>12.2f} {pct:>+7.1f}%{flag}")
    print("─" * 62)
    print(f"\nTotal rows: {len(rows)}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate CUR stub data")
    parser.add_argument("bucket", nargs="?", help="S3 bucket to upload to")
    parser.add_argument("--dry-run", action="store_true", help="Generate CSV locally only, no upload")
    args = parser.parse_args()

    if not args.dry_run and not args.bucket:
        parser.print_help()
        sys.exit(1)

    rows = generate_rows()
    csv_content = to_csv(rows)

    os.makedirs("sample-data", exist_ok=True)
    local_path = "sample-data/cur_stub_2weeks.csv"
    with open(local_path, "w") as fh:
        fh.write(csv_content)
    print(f"✓ Saved {len(rows)} rows → {local_path}")

    print_summary(rows)

    if args.dry_run:
        print("\nDry run — skipping S3 upload.")
        return

    import boto3
    s3_key = "cur/cur_report/cur_stub_2weeks.csv"
    s3 = boto3.client("s3")
    s3.put_object(
        Bucket=args.bucket,
        Key=s3_key,
        Body=csv_content.encode("utf-8"),
        ContentType="text/csv",
    )
    print(f"\n✓ Uploaded → s3://{args.bucket}/{s3_key}")
    print("\nNext step:")
    print(f"  aws glue start-crawler --name finops-pipeline-cur-crawler")


if __name__ == "__main__":
    main()
