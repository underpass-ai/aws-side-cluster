data "aws_partition" "current" {}

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-*-${var.ami_architecture}"]
  }

  filter {
    name   = "architecture"
    values = [var.ami_architecture]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  common_tags = merge(
    {
      Project   = "aws-side-cluster"
      Role      = "worker"
      ManagedBy = "terraform"
      POC       = "true"
    },
    var.tags
  )

  bootstrap_bucket     = var.create_bootstrap_bucket ? aws_s3_bucket.bootstrap[0].bucket : var.s3_bucket
  bootstrap_s3_key     = var.create_bootstrap_bucket ? aws_s3_object.bootstrap_zip[0].key : var.s3_key
  download_filename    = var.download_filename != "" ? var.download_filename : basename(local.bootstrap_s3_key)
  s3_object_arn        = "arn:${data.aws_partition.current.partition}:s3:::${local.bootstrap_bucket}/${local.bootstrap_s3_key}"
  s3_bucket_arn        = "arn:${data.aws_partition.current.partition}:s3:::${local.bootstrap_bucket}"
  base_node_label_args = join(",", [for key, value in var.kubernetes_node_labels : "${key}=${value}"])
  node_taint_args      = join(",", var.kubernetes_node_taints)
  llm_models_path      = "/opt/llm-models/hub"
  # Labels del pool GPU: base + node-pool=aws-gpu (el GPU Operator/GFD anade las nvidia.com/gpu.* solo)
  gpu_node_label_args = join(",", compact([local.base_node_label_args, "underpass.ai/node-pool=aws-gpu"]))
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "bootstrap_s3" {
  statement {
    sid = "ReadAndRestoreBootstrapObject"
    actions = [
      "s3:GetObject",
      "s3:RestoreObject"
    ]
    resources = [local.s3_object_arn]
  }

  statement {
    sid       = "ListBootstrapObjectPrefix"
    actions   = ["s3:ListBucket"]
    resources = [local.s3_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = [local.bootstrap_s3_key, "${var.gpu_llm_models_prefix}/*"]
    }
  }

  # Workers GPU: leer los .tar de modelos bajo models/* (mismo bucket bootstrap).
  statement {
    sid       = "ReadGPUModels"
    actions   = ["s3:GetObject"]
    resources = ["${local.s3_bucket_arn}/${var.gpu_llm_models_prefix}/*"]
  }
}

resource "aws_iam_role" "worker" {
  name               = "${var.name_prefix}-worker"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "bootstrap_s3" {
  name   = "${var.name_prefix}-bootstrap-s3"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.bootstrap_s3.json
}

resource "aws_iam_instance_profile" "worker" {
  name = "${var.name_prefix}-worker"
  role = aws_iam_role.worker.name
  tags = local.common_tags
}

resource "aws_instance" "worker" {
  count = var.instance_count

  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = var.instance_type
  subnet_id                   = local.selected_subnet_id
  vpc_security_group_ids      = local.selected_security_group_ids
  associate_public_ip_address = var.associate_public_ip_address
  key_name                    = var.key_name
  iam_instance_profile        = aws_iam_instance_profile.worker.name
  user_data_replace_on_change = false

  user_data = templatefile("${path.module}/cloud-init/bootstrap.sh.tftpl", {
    aws_region               = replace(var.aws_region, "'", "'\"'\"'")
    s3_bucket                = replace(local.bootstrap_bucket, "'", "'\"'\"'")
    s3_key                   = replace(local.bootstrap_s3_key, "'", "'\"'\"'")
    home_user                = replace(var.home_user, "'", "'\"'\"'")
    download_filename        = replace(local.download_filename, "'", "'\"'\"'")
    restore_tier             = replace(var.restore_tier, "'", "'\"'\"'")
    restore_days             = var.restore_days
    restore_poll_seconds     = var.restore_poll_seconds
    restore_max_wait_seconds = var.restore_max_wait_seconds
    worker_wireguard_enabled = var.worker_wireguard_enabled ? "true" : "false"
    worker_wireguard_port    = var.worker_wireguard_port
    worker_wireguard_address = var.worker_wireguard_enabled ? cidrhost(var.worker_wireguard_cidr, count.index + 11) : ""
    worker_wireguard_private_key = (
      var.worker_wireguard_enabled && length(var.worker_wireguard_private_keys) > count.index
      ? replace(var.worker_wireguard_private_keys[count.index], "'", "'\"'\"'")
      : ""
    )
    local_wireguard_public_key                    = replace(var.local_wireguard_public_key, "'", "'\"'\"'")
    local_wireguard_endpoint                      = replace(var.local_wireguard_endpoint, "'", "'\"'\"'")
    worker_wireguard_persistent_keepalive_seconds = var.worker_wireguard_persistent_keepalive_seconds
    local_cluster_allowed_ips                     = replace(join(",", var.local_cluster_allowed_cidrs), "'", "'\"'\"'")
    kubernetes_worker_enabled                     = var.kubernetes_worker_enabled ? "true" : "false"
    kubernetes_minor_version                      = replace(var.kubernetes_minor_version, "'", "'\"'\"'")
    kubeadm_join_command                          = replace(local.effective_join_command, "'", "'\"'\"'")
    kubelet_node_ip                               = var.worker_wireguard_enabled ? cidrhost(var.worker_wireguard_cidr, count.index + 11) : ""
    node_label_args                               = replace(join(",", compact([local.base_node_label_args, "underpass.ai/worker-index=${count.index + 1}"])), "'", "'\"'\"'")
    node_taint_args                               = replace(local.node_taint_args, "'", "'\"'\"'")
    node_name                                     = "aws-worker-${count.index + 1}"
    gpu_worker_enabled                            = "false"
    gpu_install_driver                            = "false"
    llm_models_bucket                             = ""
    llm_models_prefix                             = var.gpu_llm_models_prefix
    llm_models_path                               = local.llm_models_path
  })

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size           = var.root_volume_size_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
    tags                  = local.common_tags
  }

  tags = merge(
    local.common_tags,
    {
      Name                        = format("%s-%02d", var.name_prefix, count.index + 1)
      "aws-side:index"            = tostring(count.index + 1)
      "aws-side:autostart"        = "true"
      "underpass.ai/node-pool"    = "aws-poc"
      "underpass.ai/worker-index" = tostring(count.index + 1)
    }
  )

  # El bootstrap token debe existir en el cluster antes de que el EC2 haga join.
  depends_on = [kubernetes_secret.bootstrap_token]

  lifecycle {
    # La subnet ya hace map_public_ip_on_launch=true; el atributo a nivel de
    # instancia se lee como false en el state -> evitar replace perpetuo.
    ignore_changes = [associate_public_ip_address]

    precondition {
      condition     = !var.worker_wireguard_enabled || var.local_wireguard_public_key != ""
      error_message = "local_wireguard_public_key is required when worker_wireguard_enabled is true. Run scripts/generate-worker-secrets.sh first."
    }

    precondition {
      condition     = !var.worker_wireguard_enabled || length(var.worker_wireguard_private_keys) >= var.instance_count
      error_message = "worker_wireguard_private_keys must contain at least instance_count keys when worker_wireguard_enabled is true."
    }

    precondition {
      condition     = var.create_bootstrap_bucket || (var.s3_bucket != null && var.s3_key != null)
      error_message = "s3_bucket and s3_key are required when create_bootstrap_bucket is false."
    }
  }
}

# --- Pool de workers GPU (g5g.xlarge / T4G). Mismo patron WireGuard + join + S3,
# pero instala el driver NVIDIA y descarga modelos. WG IP en .21+ para no chocar
# con el pool t4g (.11+). Solo se crea si gpu_instance_count > 0. ---
resource "aws_instance" "gpu_worker" {
  count = var.gpu_instance_count

  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = var.gpu_instance_type
  subnet_id                   = local.selected_subnet_id
  vpc_security_group_ids      = local.selected_security_group_ids
  associate_public_ip_address = var.associate_public_ip_address
  key_name                    = var.key_name
  iam_instance_profile        = aws_iam_instance_profile.worker.name
  user_data_replace_on_change = false

  user_data = templatefile("${path.module}/cloud-init/bootstrap.sh.tftpl", {
    aws_region               = replace(var.aws_region, "'", "'\"'\"'")
    s3_bucket                = replace(local.bootstrap_bucket, "'", "'\"'\"'")
    s3_key                   = replace(local.bootstrap_s3_key, "'", "'\"'\"'")
    home_user                = replace(var.home_user, "'", "'\"'\"'")
    download_filename        = replace(local.download_filename, "'", "'\"'\"'")
    restore_tier             = replace(var.restore_tier, "'", "'\"'\"'")
    restore_days             = var.restore_days
    restore_poll_seconds     = var.restore_poll_seconds
    restore_max_wait_seconds = var.restore_max_wait_seconds
    worker_wireguard_enabled = var.worker_wireguard_enabled ? "true" : "false"
    worker_wireguard_port    = var.worker_wireguard_port
    worker_wireguard_address = var.worker_wireguard_enabled ? cidrhost(var.worker_wireguard_cidr, count.index + 21) : ""
    worker_wireguard_private_key = (
      var.worker_wireguard_enabled && length(var.gpu_worker_wireguard_private_keys) > count.index
      ? replace(var.gpu_worker_wireguard_private_keys[count.index], "'", "'\"'\"'")
      : ""
    )
    local_wireguard_public_key                    = replace(var.local_wireguard_public_key, "'", "'\"'\"'")
    local_wireguard_endpoint                      = replace(var.local_wireguard_endpoint, "'", "'\"'\"'")
    worker_wireguard_persistent_keepalive_seconds = var.worker_wireguard_persistent_keepalive_seconds
    local_cluster_allowed_ips                     = replace(join(",", var.local_cluster_allowed_cidrs), "'", "'\"'\"'")
    kubernetes_worker_enabled                     = var.kubernetes_worker_enabled ? "true" : "false"
    kubernetes_minor_version                      = replace(var.kubernetes_minor_version, "'", "'\"'\"'")
    kubeadm_join_command                          = replace(local.effective_join_command, "'", "'\"'\"'")
    kubelet_node_ip                               = var.worker_wireguard_enabled ? cidrhost(var.worker_wireguard_cidr, count.index + 21) : ""
    node_label_args                               = replace(join(",", compact([local.gpu_node_label_args, "underpass.ai/gpu-index=${count.index + 1}"])), "'", "'\"'\"'")
    node_taint_args                               = replace(local.node_taint_args, "'", "'\"'\"'")
    node_name                                     = "aws-gpu-worker-${count.index + 1}"
    gpu_worker_enabled                            = "true"
    gpu_install_driver                            = var.gpu_install_driver ? "true" : "false"
    llm_models_bucket                             = replace(local.bootstrap_bucket, "'", "'\"'\"'")
    llm_models_prefix                             = replace(var.gpu_llm_models_prefix, "'", "'\"'\"'")
    llm_models_path                               = local.llm_models_path
  })

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size           = var.gpu_root_volume_size_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
    tags                  = local.common_tags
  }

  tags = merge(
    local.common_tags,
    {
      Name                     = format("%s-gpu-%02d", var.name_prefix, count.index + 1)
      "aws-side:index"         = tostring(count.index + 21)
      "aws-side:autostart"     = "true"
      "underpass.ai/node-pool" = "aws-gpu"
      "underpass.ai/gpu-index" = tostring(count.index + 1)
    }
  )

  depends_on = [kubernetes_secret.bootstrap_token]

  lifecycle {
    ignore_changes = [associate_public_ip_address]

    precondition {
      condition     = !var.worker_wireguard_enabled || var.local_wireguard_public_key != ""
      error_message = "local_wireguard_public_key is required when worker_wireguard_enabled is true."
    }

    precondition {
      condition     = !var.worker_wireguard_enabled || length(var.gpu_worker_wireguard_private_keys) >= var.gpu_instance_count
      error_message = "gpu_worker_wireguard_private_keys must contain at least gpu_instance_count keys. Run scripts/generate-worker-secrets.sh."
    }
  }
}
