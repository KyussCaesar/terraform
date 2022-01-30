terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "3.74.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Prefix = var.prefix
      Component = var.component
      Workspace = terraform.workspace
      Region = var.region
    }
  }
}

# VARIABLES

variable "prefix" {
  default = "kyusscaesar"
}

variable "component" {
  default = "terraform"
}

variable "region" {
  default = "ap-southeast-2"
}

# DATA SOURCES

# RESOURCES

resource "aws_s3_bucket" "bucket" {
  bucket = "${var.prefix}-${var.component}-${terraform.workspace}-${var.region}"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    id = "main"
    enabled = true
    abort_incomplete_multipart_upload_days = 14
    transition {
      days = 14
      storage_class = "INTELLIGENT_TIERING"
    }
    noncurrent_version_expiration {
      days = 21
    }
  }

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "aws:kms"
      }
      bucket_key_enabled = true
    }
  }
}

resource "aws_s3_bucket_public_access_block" "bucket" {
  bucket = aws_s3_bucket.bucket.id
  block_public_acls = true
  block_public_policy = true
  ignore_public_acls = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "table" {
  name = "${var.prefix}-${var.component}-${terraform.workspace}"
  billing_mode = "PROVISIONED"
  hash_key = "LockID"
  # just in case account is compromised, attacker cannot cripple me by thrashing Dynamo
  write_capacity = 1
  read_capacity = 1
  attribute {
    name = "LockID"
    type = "S"
  }
}

data "aws_iam_policy_document" "policy" {
  statement {
    actions = [
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.bucket.arn
    ]
  }

  statement {
    actions = [
      "s3:GetObject*",
      "s3:PutObject*",
      "s3:DeleteObject",
    ]
    resources = [
      "${aws_s3_bucket.bucket.arn}/*"
    ]
  }

  statement {
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
    ]
    resources = [
      "${aws_dynamodb_table.table.arn}/*"
    ]
  }
}

resource "aws_iam_user" "user" {
  name = "${var.prefix}-${var.component}-${terraform.workspace}-${var.region}"
}

resource "aws_iam_user_policy" "policy" {
  policy = data.aws_iam_policy_document.policy.json
  user = aws_iam_user.user.name
}

# OUTPUTS

output "user" {
  value = aws_iam_user.user
}

output "backend-bucket" {
  value = aws_s3_bucket.bucket.id
}

output "backend-region" {
  value = var.region
}
