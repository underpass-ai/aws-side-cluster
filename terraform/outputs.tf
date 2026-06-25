output "instance_ids" {
  description = "EC2 instance ids in the pool."
  value       = aws_instance.worker[*].id
}

output "instance_private_ips" {
  description = "Private IPs for the pool."
  value       = aws_instance.worker[*].private_ip
}

output "instance_public_ips" {
  description = "Public IPs for the pool, when public IP association is enabled."
  value       = aws_instance.worker[*].public_ip
}

output "vpc_id" {
  description = "Created VPC id, or null when using an existing VPC."
  value       = try(aws_vpc.this[0].id, null)
}

output "public_subnet_id" {
  description = "Subnet used by the EC2 pool."
  value       = local.selected_subnet_id
}

output "security_group_ids" {
  description = "Security groups used by the EC2 pool."
  value       = local.selected_security_group_ids
}

output "worker_wireguard_peers" {
  description = "WireGuard peer data for the local cluster node."
  value = [
    for index, instance in aws_instance.worker : {
      index      = index + 1
      name       = instance.tags["Name"]
      public_ip  = instance.public_ip
      wg_address = var.worker_wireguard_enabled ? cidrhost(var.worker_wireguard_cidr, index + 11) : null
      public_key = length(var.worker_wireguard_public_keys) > index ? var.worker_wireguard_public_keys[index] : null
    }
  ]
}

output "instance_profile_name" {
  description = "IAM instance profile attached to workers."
  value       = aws_iam_instance_profile.worker.name
}

output "bootstrap_s3_bucket" {
  description = "S3 bucket used by EC2 first-boot bootstrap."
  value       = local.bootstrap_bucket
}

output "bootstrap_s3_key" {
  description = "S3 key used by EC2 first-boot bootstrap."
  value       = local.bootstrap_s3_key
}

output "pool_tags" {
  description = "Tags used by scripts/ec2-pool.sh."
  value = {
    Project = local.common_tags.Project
    Role    = local.common_tags.Role
  }
}
