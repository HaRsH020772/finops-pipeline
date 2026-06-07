"""
FinOps Enricher Lambda
──────────────────────
Triggered daily by EventBridge. Queries Athena for the two most recent weeks
of cost data, compares them per service, and publishes an SNS alert for any
service whose week-over-week spend exceeds ANOMALY_THRESHOLD_PCT.

No external dependencies — only boto3 which is built into the Lambda runtime.
"""

import json
import os
import time
import logging
from collections import defaultdict
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ATHENA_DATABASE       = os.environ["ATHENA_DATABASE"]
ATHENA_TABLE          = os.environ["ATHENA_TABLE"]
ATHENA_WORKGROUP      = os.environ["ATHENA_WORKGROUP"]
SNS_TOPIC_ARN         = os.environ["SNS_TOPIC_ARN"]
ANOMALY_THRESHOLD_PCT = float(os.environ.get("ANOMALY_THRESHOLD_PCT", "30"))


# ─────────────────────────────────────────────────────────────────────────────
# Athena helpers
# ─────────────────────────────────────────────────────────────────────────────

def run_query(athena, query: str) -> list[list[str]]:
    """Execute a query and return all rows (first row is header)."""
    resp = athena.start_query_execution(
        QueryString=query,
        QueryExecutionContext={"Database": ATHENA_DATABASE},
        WorkGroup=ATHENA_WORKGROUP,
    )
    qid = resp["QueryExecutionId"]
    logger.info(f"Query started: {qid}")

    # Poll until terminal state
    while True:
        status = athena.get_query_execution(QueryExecutionId=qid)
        state = status["QueryExecution"]["Status"]["State"]
        if state == "SUCCEEDED":
            break
        if state in ("FAILED", "CANCELLED"):
            reason = status["QueryExecution"]["Status"].get("StateChangeReason", "unknown")
            raise RuntimeError(f"Athena query {qid} {state}: {reason}")
        time.sleep(3)

    logger.info(f"Query succeeded: {qid}")

    # Paginate results
    paginator = athena.get_paginator("get_query_results")
    rows = []
    for page in paginator.paginate(QueryExecutionId=qid):
        for row in page["ResultSet"]["Rows"]:
            rows.append([col.get("VarCharValue", "") for col in row["Data"]])

    return rows  # rows[0] = header


def fetch_weekly_costs(athena) -> list[list[str]]:
    """
    Returns weekly cost totals per service, team, and environment.
    Ordered newest week first so Python can cleanly pick the last two.
    """
    query = f"""
    SELECT
      line_item_product_code                                                  AS service,
      resource_tags_user_team                                                 AS team,
      resource_tags_user_environment                                          AS environment,
      DATE_TRUNC('week', from_iso8601_timestamp(line_item_usage_start_date))  AS week_start,
      ROUND(SUM(line_item_unblended_cost), 4)                                 AS weekly_cost
    FROM {ATHENA_TABLE}
    WHERE line_item_line_item_type = 'Usage'
    GROUP BY 1, 2, 3, 4
    ORDER BY week_start DESC;
    """
    return run_query(athena, query)


# ─────────────────────────────────────────────────────────────────────────────
# Enrichment + anomaly detection
# ─────────────────────────────────────────────────────────────────────────────

def detect_anomalies(rows: list[list[str]]) -> list[dict]:
    """
    Compare the two most recent weeks per service.
    Returns anomalies sorted by % change descending.
    """
    if len(rows) <= 1:
        logger.warning("No data rows returned from Athena")
        return []

    # Build: { service -> { week_start -> {cost, team, env} } }
    by_service: dict = defaultdict(dict)
    all_weeks: set = set()

    for row in rows[1:]:  # skip header
        service, team, env, week_start, cost_str = row
        cost = float(cost_str) if cost_str else 0.0
        by_service[service][week_start] = {
            "cost": cost,
            "team": team or "untagged",
            "environment": env or "untagged",
        }
        all_weeks.add(week_start)

    sorted_weeks = sorted(all_weeks)
    if len(sorted_weeks) < 2:
        logger.warning(f"Only {len(sorted_weeks)} week(s) of data — need at least 2 to compare")
        return []

    prev_week = sorted_weeks[-2]
    curr_week = sorted_weeks[-1]
    logger.info(f"Comparing week {prev_week} vs {curr_week}")

    anomalies = []

    for service, weeks in by_service.items():
        prev = weeks.get(prev_week, {})
        curr = weeks.get(curr_week, {})

        prev_cost = prev.get("cost", 0.0)
        curr_cost = curr.get("cost", 0.0)

        if prev_cost == 0:
            continue  # New service this week — skip (no baseline)

        pct_change = ((curr_cost - prev_cost) / prev_cost) * 100

        # Enrich: attach team/env from the current week (fall back to prev if missing)
        team = curr.get("team") or prev.get("team", "untagged")
        env  = curr.get("environment") or prev.get("environment", "untagged")

        logger.info(f"{service}: ${prev_cost:.2f} → ${curr_cost:.2f} ({pct_change:+.1f}%)")

        if pct_change > ANOMALY_THRESHOLD_PCT:
            anomalies.append({
                "service":    service,
                "team":       team,
                "environment": env,
                "prev_week":  prev_week,
                "curr_week":  curr_week,
                "prev_cost":  prev_cost,
                "curr_cost":  curr_cost,
                "pct_change": round(pct_change, 2),
            })

    return sorted(anomalies, key=lambda x: x["pct_change"], reverse=True)


# ─────────────────────────────────────────────────────────────────────────────
# Alert formatting
# ─────────────────────────────────────────────────────────────────────────────

def format_alert(anomalies: list[dict]) -> tuple[str, str]:
    """Returns (subject, message) for SNS."""
    count = len(anomalies)
    subject = f"[FinOps Alert] {count} cost anomal{'y' if count == 1 else 'ies'} detected (>{ANOMALY_THRESHOLD_PCT:.0f}% spike)"

    lines = [
        "FINOPS COST ANOMALY ALERT",
        "=" * 50,
        f"Threshold:   >{ANOMALY_THRESHOLD_PCT:.0f}% week-over-week increase",
        f"Detected:    {count} service(s) above threshold",
        f"Run time:    {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}",
        "",
    ]

    for a in anomalies:
        lines += [
            f"  Service:     {a['service']}",
            f"  Team:        {a['team']} / {a['environment']}",
            f"  Prev week:   ${a['prev_cost']:>10,.2f}   ({a['prev_week'][:10]})",
            f"  Curr week:   ${a['curr_cost']:>10,.2f}   ({a['curr_week'][:10]})",
            f"  Change:      +{a['pct_change']}%  ← ANOMALY",
            "",
        ]

    lines += [
        "─" * 50,
        "Review in AWS Cost Explorer:",
        "https://console.aws.amazon.com/cost-management/home#/cost-explorer",
        "",
        "This alert was generated by the FinOps Cost Intelligence Pipeline.",
    ]

    return subject, "\n".join(lines)


# ─────────────────────────────────────────────────────────────────────────────
# Handler
# ─────────────────────────────────────────────────────────────────────────────

def handler(event, context):
    import boto3
    athena = boto3.client("athena")
    sns    = boto3.client("sns")

    logger.info("FinOps enricher started")
    logger.info(f"Config: database={ATHENA_DATABASE}, table={ATHENA_TABLE}, workgroup={ATHENA_WORKGROUP}, threshold={ANOMALY_THRESHOLD_PCT}%")

    # 1. Query Athena
    rows = fetch_weekly_costs(athena)
    logger.info(f"Athena returned {len(rows) - 1} data rows")

    # 2. Detect anomalies
    anomalies = detect_anomalies(rows)
    logger.info(f"Anomalies detected: {len(anomalies)}")

    # 3. Alert via SNS if any anomalies found
    if anomalies:
        subject, message = format_alert(anomalies)
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=subject,
            Message=message,
        )
        logger.info(f"SNS alert published: {subject}")
    else:
        logger.info("No anomalies — no alert sent")

    return {
        "statusCode": 200,
        "anomalies_detected": len(anomalies),
        "anomalies": anomalies,
    }
