# Outputs for development environment

output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "IDs of private subnets"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "IDs of public subnets"
  value       = module.vpc.public_subnets
}

output "security_group_id" {
  description = "ID of the application security group"
  value       = aws_security_group.app.id
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket"
  value       = aws_s3_bucket.app_data.id
}

output "instance_ids" {
  description = "IDs of EC2 instances"
  value       = aws_instance.app[*].id
}

output "cloudwatch_log_group" {
  description = "Name of CloudWatch log group"
  value       = aws_cloudwatch_log_group.app.name
}
