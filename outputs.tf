output "application_url" { value = "http://${aws_lb.alb.dns_name}" }
output "alb_dns_name" { value = aws_lb.alb.dns_name }
output "app_instance_id" { value = aws_instance.app.id }
output "rds_endpoint" { value = aws_db_instance.db.address }
output "flow_logs_group" { value = aws_cloudwatch_log_group.flow.name }
output "cloudtrail_bucket" { value = aws_s3_bucket.trail.bucket }
