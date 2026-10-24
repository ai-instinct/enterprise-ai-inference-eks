output "bucket_name" {
  value = aws_s3_bucket.model_store.bucket
}

output "read_policy_arn" {
  value = aws_iam_policy.model_store_read.arn
}
