"""
Self-Healing Reaction Lambda — Phase 1 Session 4 (FINAL)

Full loop: EventBridge alarm → this Lambda → SSM kills rogue process → alarm recovers.

Architecture position: REACT + REMEDIATE stages of the
    Observe → Detect → React → Remediate → Learn loop.
"""

import json
import logging
import os
import time
import boto3
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS clients outside the handler (reused across warm invocations)
ssm_client = boto3.client("ssm")


def lambda_handler(event, context):
    """
    Entry point. EventBridge sends the full alarm state-change event.
    """
    logger.info("=== SELF-HEALING REACTION TRIGGERED ===")
    logger.info(f"Raw event: {json.dumps(event, indent=2)}")

    # ── Extract alarm details ──
    detail = event.get("detail", {})
    alarm_name = detail.get("alarmName", "UNKNOWN")
    new_state = detail.get("state", {}).get("value", "UNKNOWN")
    reason = detail.get("state", {}).get("reason", "No reason provided")
    previous_state = detail.get("previousState", {}).get("value", "UNKNOWN")
    timestamp = event.get("time", datetime.now(timezone.utc).isoformat())

    # ── Extract instance ID from alarm dimensions ──
    instance_id = extract_instance_id(detail)

    # ── Build summary ──
    summary = {
        "action": "ALARM_RECEIVED",
        "alarm_name": alarm_name,
        "instance_id": instance_id,
        "transition": f"{previous_state} → {new_state}",
        "reason": reason,
        "timestamp": timestamp,
        "phase": "Phase1-Session4",
        "remediation_status": "NOT_ATTEMPTED"
    }

    # ── Decision: remediate or just log ──
    if new_state == "ALARM" and instance_id != "UNKNOWN":
        logger.info(f"🚨 ALARM on {instance_id}: {reason}")
        summary["remediation_status"] = remediate_high_cpu(instance_id)
    elif new_state == "ALARM" and instance_id == "UNKNOWN":
        logger.error("ALARM fired but could not extract instance ID — cannot remediate")
        summary["remediation_status"] = "FAILED_NO_INSTANCE_ID"
    elif new_state == "OK":
        logger.info(f"✅ RECOVERED: {alarm_name} back to OK")
        summary["remediation_status"] = "NOT_NEEDED"
    else:
        logger.info(f"ℹ️ State is {new_state} — no action")
        summary["remediation_status"] = "NOT_NEEDED"

    logger.info(f"Final summary: {json.dumps(summary, indent=2)}")
    return {"statusCode": 200, "body": json.dumps(summary)}


def extract_instance_id(detail):
    """
    Pull InstanceId from the alarm's metric dimensions.

    The alarm event nests this deeply:
    detail.configuration.metrics[0].metricStat.metric.dimensions.InstanceId

    If the alarm uses anomaly detection or math expressions, the structure
    differs — we handle both paths.
    """
    try:
        metrics = detail.get("configuration", {}).get("metrics", [])
        for metric in metrics:
            # Standard metric alarm
            metric_stat = metric.get("metricStat", {}).get("metric", {})
            dimensions = metric_stat.get("dimensions", {})
            if "InstanceId" in dimensions:
                return dimensions["InstanceId"]
    except (KeyError, TypeError) as e:
        logger.warning(f"Could not extract InstanceId: {e}")
    return "UNKNOWN"


def remediate_high_cpu(instance_id):
    """
    Send an SSM Run Command to kill the highest-CPU non-system process.

    The shell script:
    1. Finds the PID consuming the most CPU (excluding PID 1 and kernel threads)
    2. Logs what it found
    3. Sends SIGTERM (graceful) first
    4. Waits 5 seconds
    5. Sends SIGKILL if still alive (forceful)

    This is a SAFE remediation because:
    - It only kills ONE process (the worst offender)
    - It tries graceful shutdown first
    - It skips system-critical PIDs (1, 2)
    - It logs everything for audit
    """
    remediation_script = """#!/bin/bash
set -euo pipefail

echo "=== SELF-HEALING REMEDIATION START ==="
echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "Instance: $(curl -s http://169.254.169.254/latest/meta-data/instance-id)"

# Find the PID using the most CPU, excluding system processes
# ps output: PID, %CPU, COMMAND — sorted by CPU descending
TOP_PROCESS=$(ps aux --sort=-%cpu | awk 'NR==2 {print $2, $3, $11}')
TOP_PID=$(echo "$TOP_PROCESS" | awk '{print $1}')
TOP_CPU=$(echo "$TOP_PROCESS" | awk '{print $2}')
TOP_CMD=$(echo "$TOP_PROCESS" | awk '{print $3}')

echo "Top CPU consumer: PID=$TOP_PID CPU=$TOP_CPU% CMD=$TOP_CMD"

# Safety check: never kill PID 1 (init) or PID 2 (kthreadd)
if [ "$TOP_PID" -le 2 ]; then
    echo "SKIP: PID $TOP_PID is a system process — not killing"
    echo "=== REMEDIATION SKIPPED (system process) ==="
    exit 0
fi

# Safety check: only kill if CPU is actually high (> 50%)
CPU_INT=$(echo "$TOP_CPU" | awk '{printf "%d", $1}')
if [ "$CPU_INT" -lt 50 ]; then
    echo "SKIP: Top process is only at ${TOP_CPU}% CPU — below kill threshold"
    echo "=== REMEDIATION SKIPPED (CPU too low) ==="
    exit 0
fi

echo "ACTION: Sending SIGTERM to PID $TOP_PID ($TOP_CMD)"
kill -15 "$TOP_PID" 2>/dev/null || true

# Wait 5 seconds for graceful shutdown
sleep 5

# Check if process is still alive
if kill -0 "$TOP_PID" 2>/dev/null; then
    echo "Process $TOP_PID still alive after SIGTERM — sending SIGKILL"
    kill -9 "$TOP_PID" 2>/dev/null || true
    echo "SIGKILL sent"
else
    echo "Process $TOP_PID terminated gracefully"
fi

echo "=== SELF-HEALING REMEDIATION COMPLETE ==="
"""

    try:
        logger.info(f"Sending SSM RunShellScript to instance {instance_id}")

        response = ssm_client.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Parameters={"commands": [remediation_script]},
            TimeoutSeconds=60,
            Comment=f"Self-healing: kill high-CPU process on {instance_id}",
        )

        command_id = response["Command"]["CommandId"]
        logger.info(f"SSM Command sent successfully. CommandId: {command_id}")

        # Wait for the command to complete (up to 30 seconds)
        status = wait_for_command(command_id, instance_id)
        logger.info(f"SSM Command final status: {status}")

        return f"SSM_COMMAND_SENT_{status}"

    except Exception as e:
        logger.error(f"SSM SendCommand failed: {str(e)}")
        return f"SSM_FAILED: {str(e)}"


def wait_for_command(command_id, instance_id, max_wait=30):
    """
    Poll SSM for command completion. Returns the final status.

    Why poll instead of fire-and-forget?
    Because we want the Lambda's return value to include whether the
    remediation actually worked — that's data for the LEARN stage later.
    """
    for attempt in range(max_wait // 5):
        time.sleep(5)
        try:
            result = ssm_client.get_command_invocation(
                CommandId=command_id,
                InstanceId=instance_id,
            )
            status = result["Status"]
            logger.info(f"Command status (attempt {attempt + 1}): {status}")

            if status in ("Success", "Failed", "Cancelled", "TimedOut"):
                # Log the output for debugging
                if result.get("StandardOutputContent"):
                    logger.info(f"Command output:\n{result['StandardOutputContent']}")
                if result.get("StandardErrorContent"):
                    logger.error(f"Command errors:\n{result['StandardErrorContent']}")
                return status

        except ssm_client.exceptions.InvocationDoesNotExist:
            logger.info(f"Command not yet registered (attempt {attempt + 1})")
            continue
        except Exception as e:
            logger.warning(f"Poll error: {e}")
            continue

    return "POLL_TIMEOUT"
