resource "random_id" "bootstrap_bucket" {
  count = var.create_bootstrap_bucket && var.bootstrap_bucket_name == null ? 1 : 0

  byte_length = 4
}

resource "random_id" "bootstrap_payload" {
  count = var.create_bootstrap_bucket ? 1 : 0

  byte_length = 128
}

locals {
  normalized_name_prefix = replace(lower(var.name_prefix), "/[^a-z0-9.-]/", "-")
  bootstrap_bucket_name  = var.bootstrap_bucket_name != null ? var.bootstrap_bucket_name : "${local.normalized_name_prefix}-bootstrap-${random_id.bootstrap_bucket[0].hex}"
  bootstrap_payload_dir  = "${path.module}/generated"
  bootstrap_payload_file = "${local.bootstrap_payload_dir}/random-payload.txt"
  bootstrap_archive_file = "${local.bootstrap_payload_dir}/random-payload.zip"
  bootstrap_payload_text = "aws-side-cluster random payload\nrandom_hex=${random_id.bootstrap_payload[0].hex}\ncreated_by=terraform\n"
}

resource "local_file" "bootstrap_payload" {
  count = var.create_bootstrap_bucket ? 1 : 0

  filename        = local.bootstrap_payload_file
  content         = local.bootstrap_payload_text
  file_permission = "0644"
}

data "archive_file" "bootstrap_zip" {
  count = var.create_bootstrap_bucket ? 1 : 0

  type        = "zip"
  source_file = local_file.bootstrap_payload[0].filename
  output_path = local.bootstrap_archive_file
}

resource "aws_s3_bucket" "bootstrap" {
  count = var.create_bootstrap_bucket ? 1 : 0

  bucket        = local.bootstrap_bucket_name
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = local.bootstrap_bucket_name
  })
}

resource "aws_s3_bucket_public_access_block" "bootstrap" {
  count = var.create_bootstrap_bucket ? 1 : 0

  bucket                  = aws_s3_bucket.bootstrap[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bootstrap" {
  count = var.create_bootstrap_bucket ? 1 : 0

  bucket = aws_s3_bucket.bootstrap[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "bootstrap" {
  count = var.create_bootstrap_bucket ? 1 : 0

  bucket = aws_s3_bucket.bootstrap[0].id

  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_object" "bootstrap_zip" {
  count = var.create_bootstrap_bucket ? 1 : 0

  bucket        = aws_s3_bucket.bootstrap[0].id
  key           = var.bootstrap_zip_key
  source        = data.archive_file.bootstrap_zip[0].output_path
  source_hash   = data.archive_file.bootstrap_zip[0].output_base64sha256
  storage_class = var.bootstrap_zip_storage_class
  content_type  = "application/zip"

  tags = local.common_tags
}
