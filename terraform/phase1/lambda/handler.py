"""
Self-Healing Reaction Lambda — Phase 1 Session 3

This function is triggered by EventBridge when a CloudWatch alarm
enters the ALARM state. Right now it just logs and extracts context.
In Session 4, we'll add the SSM remediation call here.

Architecture position: REACT stage of the Observe → Detect → React → Remediate → Learn loop.
"""

import json
import logging
import os
from datetime import datetime, timezone

# Set up structured logging — CloudWatch Logs will capture this
logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event, context):
    """
    Entry point. EventBridge sends the full alarm state-change event.

    Event structure (the important fields):
    {
        "source": "aws.cloudwatch",
        "detail-type": "CloudWatch Alarm State Change",
        "detail": {
            "alarmName": "infra-healer-cpu-high",
            "state": {
                "value": "ALARM",
                "reason": "Threshold Crossed: 2 out of 2 datapoints..."
            },
            "previousState": {
                "value": "OK"
            },
            "configuration": {
                "metrics": [...]
            }
        }
    }
    """
    logger.info("=== SELF-HEALING REACTION TRIGGERED ===")
    logger.info(f"Raw event: {json.dumps(event, indent=2)}")

    # ── Extract the fields we care about ──
    detail = event.get("detail", {})
    alarm_name = detail.get("alarmName", "UNKNOWN")
    new_state = detail.get("state", {}).get("value", "UNKNOWN")
    reason = detail.get("state", {}).get("reason", "No reason provided")
    previous_state = detail.get("previousState", {}).get("value", "UNKNOWN")
    timestamp = event.get("time", datetime.now(timezone.utc).isoformat())

    # ── Extract the instance ID from alarm dimensions ──
    # The alarm's metric has InstanceId as a dimension — we need it for remediation
    instance_id = "UNKNOWN"
    try:
        metrics = detail.get("configuration", {}).get("metrics", [])
        for metric in metrics:
            metric_stat = metric.get("metricStat", {}).get("metric", {})
            dimensions = metric_stat.get("dimensions", {})
            if "InstanceId" in dimensions:
                instance_id = dimensions["InstanceId"]
                break
    except (KeyError, TypeError, IndexError) as e:
        logger.warning(f"Could not extract InstanceId from alarm dimensions: {e}")

    # ── Build a structured summary ──
    summary = {
        "action": "ALARM_RECEIVED",
        "alarm_name": alarm_name,
        "instance_id": instance_id,
        "transition": f"{previous_state} → {new_state}",
        "reason": reason,
        "timestamp": timestamp,
        "session": "Phase1-Session3",
        "remediation_status": "PENDING"  # Session 4 will change this
    }

    logger.info(f"Alarm summary: {json.dumps(summary, indent=2)}")

    # ── Decision point (Session 4 will expand this) ──
    if new_state == "ALARM":
        logger.info(
            f"🚨 ALARM on instance {instance_id}: {reason}"
        )
        logger.info(
            "Remediation not yet wired — will be added in Session 4 (SSM Automation)."
        )
        # TODO Session 4: Call SSM Automation to kill high-CPU processes
    elif new_state == "OK":
        logger.info(
            f"✅ RECOVERED: {alarm_name} on {instance_id} is back to OK."
        )
    else:
        logger.info(f"ℹ️ Alarm state is {new_state} — no action taken.")

    return {
        "statusCode": 200,
        "body": json.dumps(summary)
    }
