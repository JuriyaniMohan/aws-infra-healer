output "instance_id" {
  description = "EC2 instance ID — use this for SSM"
  value       = aws_instance.lab.id
}

output "instance_public_ip" {
  description = "Public IP (informational only — we won't SSH)"
  value       = aws_instance.lab.public_ip
}

output "ssm_session_command" {
  description = "Copy-paste this to connect"
  value       = "aws ssm start-session --target ${aws_instance.lab.id} --region ${var.aws_region}"
}

output "vpc_id" {
  description = "VPC ID for reference"
  value       = aws_vpc.main.id
}
# ── Session 3 outputs ──

output "lambda_function_name" {
  description = "Name of the reaction Lambda"
  value       = aws_lambda_function.reaction.function_name
}

output "sns_topic_arn" {
  description = "SNS topic ARN for alarm notifications"
  value       = aws_sns_topic.alarm_notifications.arn
}

output "eventbridge_rule_name" {
  description = "EventBridge rule name"
  value       = aws_cloudwatch_event_rule.alarm_state_change.name
}
