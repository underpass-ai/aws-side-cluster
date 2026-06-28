# Orquestación del join en Terraform: token bootstrap generado por el provider
# kubernetes (sin paste manual ni caducidad sorpresa) + sync WireGuard PC->EC2
# como parte del apply. El lado-PC (config wg + reglas NAT/forward) sigue fuera.

variable "kubeconfig_path" {
  description = "Kubeconfig usado por el provider kubernetes para crear el bootstrap token."
  type        = string
  default     = "~/.kube/config"
}

variable "kubeadm_join_endpoint" {
  description = "host:port del API server en el kubeadm join generado."
  type        = string
  default     = "192.168.1.56:6443"
}

variable "discovery_ca_cert_hash" {
  description = <<-EOT
    Hash sha256 (hex, sin prefijo) de la clave pública del CA del cluster, para
    --discovery-token-ca-cert-hash. Estable por cluster. Calcular con:
    kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
      | base64 -d | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der \
      | openssl dgst -sha256
  EOT
  type        = string
}

# Token bootstrap: id [a-z0-9]{6}, secret [a-z0-9]{16}. random_string es estable
# en el state (no rota en cada apply salvo recreación).
resource "random_string" "bootstrap_token_id" {
  length  = 6
  upper   = false
  special = false
}

resource "random_string" "bootstrap_token_secret" {
  length  = 16
  upper   = false
  special = false
}

resource "kubernetes_secret" "bootstrap_token" {
  count = var.kubernetes_worker_enabled && var.kubeadm_join_command == "" ? 1 : 0

  metadata {
    name      = "bootstrap-token-${random_string.bootstrap_token_id.result}"
    namespace = "kube-system"
  }

  type = "bootstrap.kubernetes.io/token"

  data = {
    "token-id"                       = random_string.bootstrap_token_id.result
    "token-secret"                   = random_string.bootstrap_token_secret.result
    "usage-bootstrap-authentication" = "true"
    "usage-bootstrap-signing"        = "true"
    "auth-extra-groups"              = "system:bootstrappers:kubeadm:default-node-token"
  }
}

locals {
  generated_join_command = "kubeadm join ${var.kubeadm_join_endpoint} --token ${random_string.bootstrap_token_id.result}.${random_string.bootstrap_token_secret.result} --discovery-token-ca-cert-hash sha256:${var.discovery_ca_cert_hash}"
  # Si se define var.kubeadm_join_command se usa como override; si no, el generado por TF.
  effective_join_command = var.kubeadm_join_command != "" ? var.kubeadm_join_command : local.generated_join_command
}

# Tras crear/cambiar instancias: fija endpoints PC->EC2 (sudo wg, NOPASSWD) y
# espera a que los nodos lleguen a Ready. Hace el apply autocontenido.
resource "null_resource" "wg_sync" {
  count = var.worker_wireguard_enabled ? 1 : 0

  triggers = {
    instances = join(",", concat(aws_instance.worker[*].id, aws_instance.gpu_worker[*].id))
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/.."
    interpreter = ["/bin/bash", "-c"]
    environment = {
      AWS_REGION    = var.aws_region
      WG_INTERFACE  = "aws-workers"
      EXPECT_READY  = tostring(var.instance_count + var.gpu_instance_count)
      WAIT_SECONDS  = "1200"
      NODE_SELECTOR = "underpass.ai/node-pool=aws-poc"
    }
    command = "scripts/wg-sync-and-wait.sh"
  }

  depends_on = [aws_instance.worker, aws_instance.gpu_worker]
}
