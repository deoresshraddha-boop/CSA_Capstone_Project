data "aws_availability_zones" "available" { state = "available" }
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
data "aws_caller_identity" "current" {}

resource "random_id" "bucket_suffix" { byte_length = 4 }

locals {
  az1 = data.aws_availability_zones.available.names[0]
  az2 = data.aws_availability_zones.available.names[1]
  tags = {
    Project = var.project_name
    ManagedBy = "Terraform"
    Environment = "Capstone"
  }
}

module "network" {
  source = "./modules/network"
  name = var.project_name
  vpc_cidr = var.vpc_cidr
  az1 = local.az1
  az2 = local.az2
  tags = local.tags
}

module "security" {
  source = "./modules/security"
  name = var.project_name
  vpc_id = module.network.vpc_id
  allowed_http_cidr = var.allowed_http_cidr
  tags = local.tags
}

resource "aws_db_subnet_group" "db" {
  name = "${var.project_name}-db-subnets"
  subnet_ids = module.network.db_subnet_ids
  tags = local.tags
}

resource "aws_db_instance" "db" {
  identifier = "${var.project_name}-mysql"
  engine = "mysql"
  instance_class = var.db_instance_class
  allocated_storage = 20
  max_allocated_storage = 50
  db_name = var.db_name
  username = var.db_username
  manage_master_user_password = true
  db_subnet_group_name = aws_db_subnet_group.db.name
  vpc_security_group_ids = [module.security.db_sg_id]
  publicly_accessible = false
  storage_encrypted = true
  backup_retention_period = 1
  deletion_protection = false
  skip_final_snapshot = true
  tags = local.tags
}

resource "aws_iam_role" "app" {
  name = "${var.project_name}-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "app_secret" {
  name = "${var.project_name}-read-rds-secret"
  role = aws_iam_role.app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue"]
      Resource = aws_db_instance.db.master_user_secret[0].secret_arn
    }]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.project_name}-instance-profile"
  role = aws_iam_role.app.name
}

resource "aws_instance" "app" {
  ami = data.aws_ssm_parameter.al2023.value
  instance_type = var.ec2_instance_type
  subnet_id = module.network.app_subnet_id
  vpc_security_group_ids = [module.security.app_sg_id]
  iam_instance_profile = aws_iam_instance_profile.app.name
  associate_public_ip_address = false
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    db_host = aws_db_instance.db.address
    db_name = var.db_name
    db_secret_arn = aws_db_instance.db.master_user_secret[0].secret_arn
    aws_region = var.aws_region
  })
  user_data_replace_on_change = true
  depends_on = [aws_db_instance.db, aws_iam_role_policy.app_secret]
  tags = merge(local.tags, { Name = "${var.project_name}-private-app" })
}

resource "aws_lb" "alb" {
  name = substr("${var.project_name}-alb", 0, 32)
  internal = false
  load_balancer_type = "application"
  security_groups = [module.security.alb_sg_id]
  subnets = module.network.public_subnet_ids
  tags = local.tags
}

resource "aws_lb_target_group" "app" {
  name = substr("${var.project_name}-tg", 0, 32)
  port = 80
  protocol = "HTTP"
  vpc_id = module.network.vpc_id
  health_check {
    path = "/health"
    matcher = "200"
  }
  tags = local.tags
}

resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id = aws_instance.app.id
  port = 80
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port = 80
  protocol = "HTTP"
  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_cloudwatch_log_group" "flow" {
  name = "/aws/vpc/flowlogs/${var.project_name}"
  retention_in_days = 7
  tags = local.tags
}

resource "aws_iam_role" "flow" {
  name = "${var.project_name}-flowlogs-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "flow" {
  name = "${var.project_name}-flowlogs-policy"
  role = aws_iam_role.flow.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.flow.arn}:*"
    }]
  })
}

resource "aws_flow_log" "vpc" {
  vpc_id = module.network.vpc_id
  traffic_type = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination = aws_cloudwatch_log_group.flow.arn
  iam_role_arn = aws_iam_role.flow.arn
  depends_on = [aws_iam_role_policy.flow]
  tags = local.tags
}

resource "aws_s3_bucket" "trail" {
  bucket = "${var.project_name}-trail-${random_id.bucket_suffix.hex}"
  force_destroy = true
  tags = local.tags
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket = aws_s3_bucket.trail.id
  block_public_acls = true
  block_public_policy = true
  ignore_public_acls = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid = "CloudTrailAclCheck"
        Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.trail.arn
      },
      {
        Sid = "CloudTrailWrite"
        Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action = "s3:PutObject"
        Resource = "${aws_s3_bucket.trail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      }
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.trail]
}

resource "aws_cloudtrail" "trail" {
  name = "${var.project_name}-trail"
  s3_bucket_name = aws_s3_bucket.trail.id
  include_global_service_events = true
  is_multi_region_trail = true
  enable_logging = true
  depends_on = [aws_s3_bucket_policy.trail, aws_s3_bucket_server_side_encryption_configuration.trail]
  tags = local.tags
}
