variable "aws_region" {
  type    = string
  default = "ap-south-1"
}
variable "project_name" {
  type    = string
  default = "secure-three-tier"
}
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}
variable "allowed_http_cidr" {
  description = "CIDR allowed to access ALB; use your public IP/32 for a restricted demo."
  type        = string
  default     = "0.0.0.0/0"
}
variable "ec2_instance_type" {
  type    = string
  default = "t3.micro"
}
variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}
variable "db_name" {
  type    = string
  default = "capstone"
}
variable "db_username" {
  type    = string
  default = "appadmin"
}
