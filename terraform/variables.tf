variable "aws_region" {
  description = "AWS region where the EC2 pool is created."
  type        = string
}

variable "name_prefix" {
  description = "Name prefix for EC2 instances and IAM resources."
  type        = string
  default     = "aws-side-poc"
}

variable "instance_count" {
  description = "Number of EC2 instances in the stopped/running pool."
  type        = number
  default     = 2

  validation {
    condition     = var.instance_count >= 0
    error_message = "instance_count must be zero or greater."
  }
}

variable "instance_type" {
  description = "EC2 instance type. t4g.micro is the smallest practical kubeadm worker; t4g.nano is cheaper but very tight."
  type        = string
  default     = "t4g.micro"
}

variable "ami_architecture" {
  description = "AMI CPU architecture: arm64 for t4g.*, x86_64 for t3/t3a."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.ami_architecture)
    error_message = "ami_architecture must be arm64 or x86_64."
  }
}

variable "create_vpc" {
  description = "Create a minimal public VPC for the EC2 pool. Set false to use subnet_id and vpc_security_group_ids."
  type        = bool
  default     = true
}

variable "vpc_cidr" {
  description = "CIDR block for the POC VPC."
  type        = string
  default     = "10.80.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet used by the EC2 pool."
  type        = string
  default     = "10.80.1.0/24"
}

variable "availability_zone" {
  description = "Optional availability zone for the public subnet. Null selects the first available AZ."
  type        = string
  default     = null
}

variable "subnet_id" {
  description = "Existing subnet id. Required only when create_vpc is false."
  type        = string
  default     = null
}

variable "vpc_security_group_ids" {
  description = "Existing security groups for the EC2 instances. Required only when create_vpc is false."
  type        = list(string)
  default     = []
}

variable "allowed_ssh_cidrs" {
  description = "Optional CIDRs allowed to SSH to the EC2 workers. Empty keeps inbound access closed."
  type        = list(string)
  default     = []
}

variable "allowed_wireguard_cidrs" {
  description = "CIDRs allowed to reach the worker WireGuard UDP port. WireGuard authenticates peers, but restrict this when possible."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "associate_public_ip_address" {
  description = "Whether to assign a public IP. Disable it when the subnet has NAT or S3/API VPC endpoints."
  type        = bool
  default     = true
}

variable "key_name" {
  description = "Optional EC2 key pair name for SSH."
  type        = string
  default     = null
}

variable "root_volume_size_gb" {
  description = "Root EBS size in GiB. Keep enough space for the ZIP plus OS."
  type        = number
  default     = 8

  validation {
    condition     = var.root_volume_size_gb >= 8
    error_message = "root_volume_size_gb must be at least 8."
  }
}

variable "create_bootstrap_bucket" {
  description = "Create a private S3 bucket and random ZIP used by the EC2 first-boot bootstrap."
  type        = bool
  default     = true
}

variable "bootstrap_bucket_name" {
  description = "Optional explicit bucket name when create_bootstrap_bucket is true. Null creates a unique name."
  type        = string
  default     = null
}

variable "bootstrap_zip_key" {
  description = "S3 key for the generated bootstrap ZIP when create_bootstrap_bucket is true."
  type        = string
  default     = "bootstrap/random-payload.zip"
}

variable "bootstrap_zip_storage_class" {
  description = "Storage class for the generated bootstrap ZIP. GLACIER_IR keeps first boot fast while using a Glacier class."
  type        = string
  default     = "GLACIER_IR"

  validation {
    condition = contains([
      "STANDARD",
      "STANDARD_IA",
      "ONEZONE_IA",
      "INTELLIGENT_TIERING",
      "GLACIER_IR",
      "GLACIER",
      "DEEP_ARCHIVE"
    ], var.bootstrap_zip_storage_class)
    error_message = "bootstrap_zip_storage_class must be a valid S3 storage class for this POC."
  }
}

variable "s3_bucket" {
  description = "Existing S3 bucket that contains the bootstrap ZIP. Required only when create_bootstrap_bucket is false."
  type        = string
  default     = null
}

variable "s3_key" {
  description = "Existing S3 key for the bootstrap ZIP. Required only when create_bootstrap_bucket is false."
  type        = string
  default     = null
}

variable "home_user" {
  description = "Linux user whose home receives the ZIP."
  type        = string
  default     = "ec2-user"
}

variable "download_filename" {
  description = "Filename to create in the user's home. Empty means basename(s3_key)."
  type        = string
  default     = ""
}

variable "worker_wireguard_enabled" {
  description = "Install WireGuard on each EC2 worker and expose a per-worker tunnel endpoint."
  type        = bool
  default     = true
}

variable "worker_wireguard_cidr" {
  description = "WireGuard tunnel CIDR. .1 is reserved for the local cluster node; workers start at .11."
  type        = string
  default     = "10.90.0.0/24"
}

variable "worker_wireguard_port" {
  description = "UDP port where workers listen for WireGuard."
  type        = number
  default     = 51820
}

variable "local_wireguard_public_key" {
  description = "Public key of the local cluster node WireGuard peer."
  type        = string
  default     = ""
}

variable "local_wireguard_endpoint" {
  description = "Optional public host:port for the local WireGuard peer. When set, EC2 workers initiate the tunnel."
  type        = string
  default     = ""
}

variable "worker_wireguard_persistent_keepalive_seconds" {
  description = "PersistentKeepalive used by EC2 workers when local_wireguard_endpoint is set. Use 0 to omit it."
  type        = number
  default     = 25
}

variable "worker_wireguard_private_keys" {
  description = "WireGuard private keys for workers, one per instance. Stored in Terraform state for this POC."
  type        = list(string)
  default     = []
  sensitive   = true
}

variable "worker_wireguard_public_keys" {
  description = "WireGuard public keys for workers, one per instance. Used for local config generation/output."
  type        = list(string)
  default     = []
}

variable "local_cluster_allowed_cidrs" {
  description = "CIDRs routed from EC2 workers through WireGuard to the local cluster node."
  type        = list(string)
  default = [
    "10.90.0.1/32",
    "192.168.1.56/32",
    "10.96.0.0/12",
    "10.244.0.0/16"
  ]
}

variable "kubernetes_worker_enabled" {
  description = "Install containerd, kubelet, kubeadm and join each EC2 as a Kubernetes worker."
  type        = bool
  default     = true
}

variable "kubernetes_minor_version" {
  description = "Kubernetes package minor version repository, matching the control plane."
  type        = string
  default     = "v1.35"
}

variable "kubeadm_join_command" {
  description = "Output of kubeadm token create --print-join-command. Leave empty to install packages without joining."
  type        = string
  default     = ""
  sensitive   = true
}

variable "kubernetes_node_labels" {
  description = "Labels added by kubeadm join to EC2 workers."
  type        = map(string)
  default = {
    "underpass.ai/node-pool" = "aws-poc"
    "underpass.ai/phase"     = "phase1"
  }
}

variable "kubernetes_node_taints" {
  description = "Optional kubelet taints for EC2 workers, for example dedicated=aws-poc:NoSchedule."
  type        = list(string)
  default     = []
}

variable "restore_tier" {
  description = "Glacier restore tier: Expedited, Standard or Bulk."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Expedited", "Standard", "Bulk"], var.restore_tier)
    error_message = "restore_tier must be Expedited, Standard or Bulk."
  }
}

variable "restore_days" {
  description = "Days to keep the temporary restored copy available for GLACIER/DEEP_ARCHIVE."
  type        = number
  default     = 1

  validation {
    condition     = var.restore_days >= 1
    error_message = "restore_days must be at least 1."
  }
}

variable "restore_poll_seconds" {
  description = "Seconds between S3 restore status checks."
  type        = number
  default     = 300

  validation {
    condition     = var.restore_poll_seconds >= 30
    error_message = "restore_poll_seconds must be at least 30."
  }
}

variable "restore_max_wait_seconds" {
  description = "Maximum wait for Glacier restore. Use 0 to wait indefinitely."
  type        = number
  default     = 0

  validation {
    condition     = var.restore_max_wait_seconds >= 0
    error_message = "restore_max_wait_seconds must be zero or greater."
  }
}

variable "tags" {
  description = "Additional tags applied to instances and IAM resources."
  type        = map(string)
  default     = {}
}

# --- Pool de workers GPU (g5g.xlarge, T4G). Separado del pool t4g.micro. ---

variable "gpu_instance_count" {
  description = "Numero de workers GPU (g5g). 0 = no se crea ningun recurso GPU (pool t4g intacto)."
  type        = number
  default     = 0

  validation {
    condition     = var.gpu_instance_count >= 0
    error_message = "gpu_instance_count must be zero or greater."
  }
}

variable "gpu_instance_type" {
  description = "Tipo EC2 GPU. g5g.xlarge = T4G (16GB, ARM/Graviton2, mismo arm64). g6/g6e son x86_64."
  type        = string
  default     = "g5g.xlarge"
}

variable "gpu_install_driver" {
  description = "Instalar el driver NVIDIA (host) en cloud-init del worker GPU. El GPU Operator pone toolkit+device-plugin."
  type        = bool
  default     = true
}

variable "gpu_root_volume_size_gb" {
  description = "EBS root de los workers GPU. Mayor que el de t4g: driver + modelos (~13GB) + margen."
  type        = number
  default     = 60

  validation {
    condition     = var.gpu_root_volume_size_gb >= 30
    error_message = "gpu_root_volume_size_gb must be at least 30."
  }
}

variable "gpu_worker_wireguard_private_keys" {
  description = "Claves privadas WireGuard de los workers GPU, una por instancia. En state para esta POC."
  type        = list(string)
  default     = []
  sensitive   = true
}

variable "gpu_worker_wireguard_public_keys" {
  description = "Claves publicas WireGuard de los workers GPU. Para config local/output."
  type        = list(string)
  default     = []
}

variable "gpu_llm_models_prefix" {
  description = "Prefijo S3 (en el bucket bootstrap) con los .tar de modelos LLM que el worker GPU descarga."
  type        = string
  default     = "models"
}
