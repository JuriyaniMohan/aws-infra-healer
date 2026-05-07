# ====================================================================
# monitoring.tf — CloudWatch agent + alarm
# ====================================================================

# The agent's configuration. Read top to bottom — this is the actual
# JSON that decides what metrics get collected.
locals {
  cw_agent_config = jsonencode({
    agent = {
      metrics_collection_interval = 60   # collect every 60 seconds
      run_as_user                 = "cwagent"
    }

    metrics = {
      namespace = "SelfHealingLab"        # custom namespace in CloudWatch
      append_dimensions = {
        InstanceId = "$${aws:InstanceId}"  # tag every metric with the instance ID
      }

      metrics_collected = {
        # Memory metrics (the whole reason we need an agent)
        mem = {
          measurement = ["mem_used_percent"]
        }

        # Disk metrics — per filesystem
        disk = {
          measurement = ["used_percent"]
          resources   = ["/"]              # only the root filesystem for now
          drop_device = true               # cleaner dimensions
        }

        # CPU — note: AWS already has CPUUtilization built in,
        # but the agent gives us per-core, per-mode breakdown if we want it
        cpu = {
          totalcpu = true
          measurement = [
            "cpu_usage_idle",
            "cpu_usage_iowait",
            "cpu_usage_user",
            "cpu_usage_system"
          ]
        }
      }
    }
  })
}

# Store the config in SSM Parameter Store.
# The agent will fetch it from here at install time.
resource "aws_ssm_parameter" "cw_agent_config" {
  name        = "/${var.project_name}/cloudwatch-agent/config"
  description = "CloudWatch agent config for self-healing lab"
  type        = "String"
  value       = local.cw_agent_config
  tier        = "Standard"
}

# ====================================================================
# SSM document — installs and starts the CloudWatch agent
# ====================================================================

resource "aws_ssm_document" "install_cw_agent" {
  name            = "${var.project_name}-install-cw-agent"
  document_type   = "Command"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "Install and configure the CloudWatch agent"

    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "installAgent"
        inputs = {
          runCommand = [
            "set -euo pipefail",
            "echo '== Installing CloudWatch agent =='",
            "dnf install -y amazon-cloudwatch-agent",
            "echo '== Fetching config from Parameter Store =='",
            "/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \\",
            "  -a fetch-config \\",
            "  -m ec2 \\",
            "  -c ssm:${aws_ssm_parameter.cw_agent_config.name} \\",
            "  -s",
            "echo '== Verifying agent status =='",
            "systemctl status amazon-cloudwatch-agent --no-pager"
          ]
        }
      }
    ]
  })
}
# ====================================================================
# CloudWatch alarm — fires when CPU is sustained above 70%
# ====================================================================

resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name        = "${var.project_name}-high-cpu"
  alarm_description = "EC2 CPU > 70% for 2 minutes — triggers self-healing"

  # Which metric to watch
  namespace   = "AWS/EC2"                      # using AWS's built-in CPU
  metric_name = "CPUUtilization"
  statistic   = "Average"

  # Filter to just our lab instance
  dimensions = {
    InstanceId = aws_instance.lab.id
  }

  # The math: average over each 60s period, evaluate 2 periods,
  # alarm if both periods exceed 70%
  period              = 60                      # 60-second metric resolution
  evaluation_periods  = 2                       # need 2 consecutive bad periods
  threshold           = 70
  comparison_operator = "GreaterThanThreshold"

  # What to do when no data arrives (e.g., instance is stopped)
  treat_missing_data = "notBreaching"           # don't false-alarm on missing data

  # Actions are empty for now — Session 3 will wire EventBridge here
  alarm_actions = []
  ok_actions    = []
}

