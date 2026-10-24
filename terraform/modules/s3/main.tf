
resource "aws_s3_bucket" "model_store" {
  bucket_prefix = "${var.project}-model-store-"
}

resource "aws_s3_bucket_versioning" "model_store" {
  bucket = aws_s3_bucket.model_store.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "model_store" {
  bucket = aws_s3_bucket.model_store.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "model_store" {
  bucket = aws_s3_bucket.model_store.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_iam_policy" "model_store_read" {
  name        = "${var.project}-model-store-read"
  description = "Read-only access to the model weight bucket for GPU nodes"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.model_store.arn, "${aws_s3_bucket.model_store.arn}/*"]
      }
    ]
  })
}

resource "helm_release" "mountpoint_s3_csi" {
  name       = "aws-mountpoint-s3-csi-driver"
  namespace  = "kube-system"
  repository = "https://awslabs.github.io/mountpoint-s3-csi-driver"
  chart      = "aws-mountpoint-s3-csi-driver"
  version    = "1.11.0"

  values = [yamlencode({
    node = {
      tolerateAllTaints = true
    }
  })]

}
