# ====================================================================
# reaction.tf — EventBridge + Lambda + SNS (Session 3)
# ====================================================================
# This file wires the REACTION layer:
#   CloudWatch Alarm → EventBridge Rule → Lambda + SNS
#
# Design principle: fan-out. One event triggers both an automated
# response (Lambda) and a human notification (SNS). Neither knows
# about the other — that's the decoupling power of event-driven arch.
# ====================================================================


# ─────────────────────────────────────────────────────────────────────
# SNS TOPIC — human notification channel
# ─────────────────────────────────────────────────────────────────────

resource "aws_sns_topic" "alarm_notifications" {
  name = "${var.project_name}-alarm-notifications"

  tags = {
    Project = var.project_name
    Session = "phase1-session3"
  }
}

# Email subscription — you'll get a confirmation email after apply.
# IMPORTANT: You must click the confirmation link or SNS won't deliver.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alarm_notifications.arn
  protocol  = "email"
  endpoint  = var.notification_email
}


# ─────────────────────────────────────────────────────────────────────
# LAMBDA — the reaction brain
# ─────────────────────────────────────────────────────────────────────

# Package the Python code into a ZIP for Lambda
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/lambda/handler.zip"
}

# IAM role that Lambda assumes when it runs
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-reaction-lambda-role"

  # Trust policy: "Only Lambda can assume this role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
    Session = "phase1-session3"
  }
}

# Permission: Lambda can write logs to CloudWatch Logs
# This is the bare minimum — every Lambda needs this
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# The Lambda function itself
resource "aws_lambda_function" "reaction" {
  function_name    = "${var.project_name}-reaction"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60  # seconds — plenty for logging, tight for production
  memory_size      = 128 # MB — minimum, sufficient for this function

  role = aws_iam_role.lambda_role.arn

  environment {
    variables = {
      PROJECT_NAME = var.project_name
      ENVIRONMENT  = "lab"
    }
  }

  tags = {
    Project = var.project_name
    Session = "phase1-session3"
  }
}


# ─────────────────────────────────────────────────────────────────────
# EVENTBRIDGE — the event router
# ─────────────────────────────────────────────────────────────────────

# Rule: match CloudWatch alarm state changes for our specific alarm
resource "aws_cloudwatch_event_rule" "alarm_state_change" {
  name        = "${var.project_name}-alarm-reaction"
  description = "Triggers when self-healing alarms enter ALARM state"

  # This is the EVENT PATTERN — the core of EventBridge.
  # It pattern-matches against events on the default bus.
  # Read it as: "source must be aws.cloudwatch AND detail-type must be
  # CloudWatch Alarm State Change AND the alarm name must start with
  # our project prefix AND the new state must be ALARM"
  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [{
        prefix = var.project_name
      }]
      state = {
        value = ["ALARM"]
      }
    }
  })

  tags = {
    Project = var.project_name
    Session = "phase1-session3"
  }
}

# Target 1: Lambda
resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.alarm_state_change.name
  target_id = "reaction-lambda"
  arn       = aws_lambda_function.reaction.arn
}

# Permission: Allow EventBridge to invoke our Lambda
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.reaction.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.alarm_state_change.arn
}

# Target 2: SNS (human notification)
resource "aws_cloudwatch_event_target" "sns_target" {
  rule      = aws_cloudwatch_event_rule.alarm_state_change.name
  target_id = "alarm-notification"
  arn       = aws_sns_topic.alarm_notifications.arn
}

# Permission: Allow EventBridge to publish to our SNS topic
resource "aws_sns_topic_policy" "allow_eventbridge" {
  arn = aws_sns_topic.alarm_notifications.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridgePublish"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.alarm_notifications.arn
      }
    ]
  })
}

# Permission: Lambda can send SSM Run Commands to our EC2
# This is the Session 4 addition — scoped to ONLY our instance
resource "aws_iam_role_policy" "lambda_ssm_policy" {
  name = "${var.project_name}-lambda-ssm"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSSMSendCommand"
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation"
        ]
        # Scoped to our specific instance — not all EC2s in the account
        Resource = [
          "arn:aws:ec2:${var.aws_region}:*:instance/${aws_instance.lab.id}",
          "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript"
        ]
      }
    ]
  })
}
