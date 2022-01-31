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

data "aws_vpc" "default" {
  tags = {
    Name = "aws-controltower-VPC"
  }
}

data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
  filter {
    name = "tag:Name"
    values = [
      "aws-controltower-PrivateSubnet1A"
    ]
  }
}

# RESOURCES

locals {
  global_name = "${var.prefix}-${var.component}-${terraform.workspace}-${var.region}"
  name = "${var.prefix}-${var.component}-${terraform.workspace}"
}

resource "aws_s3_bucket" "bucket" {
  bucket = local.global_name

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
  name = "${var.component}"
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

locals {
  backend_configuration_file_name = "backend.tf"
}

resource "aws_s3_bucket_object" "backend" {
  bucket = aws_s3_bucket.bucket.id
  key = local.backend_configuration_file_name
  content = <<EOF
region = "${var.region}"
bucket = "${aws_s3_bucket.bucket.id}"
dynamodb_table = "${aws_dynamodb_table.table.id}"
  EOF
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
  name = local.global_name
}

resource "aws_iam_user_policy" "policy" {
  policy = data.aws_iam_policy_document.policy.json
  user = aws_iam_user.user.name
}

data "aws_iam_policy_document" "packer" {
  statement {
    actions = [
      "sts:AssumeRole"
    ]

    principals {
      type = "Service"
      identifiers = [
        "ec2.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_role" "packer" {
  name = "${local.name}-packer"
  assume_role_policy = data.aws_iam_policy_document.packer.json
  managed_policy_arns = [
    # copied from quick start role
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/AmazonSSMPatchAssociation"
  ]
}

resource "aws_iam_instance_profile" "packer" {
  name = "${local.name}-packer"
  role = aws_iam_role.packer.name
}

resource "aws_security_group" "packer" {
  ingress {
    from_port = 443
    to_port = 443
    protocol = "tcp"
    cidr_blocks = [
      data.aws_vpc.default.cidr_block
    ]
  }
  name = "${local.name}-packer"
  vpc_id = data.aws_vpc.default.id
}

resource "aws_vpc_endpoint" "packer" {
  for_each = toset([
    "ssm", "ec2messages", "ec2", "ssmmessages", "kms", "logs"
  ])
  service_name = "com.amazonaws.${var.region}.${each.value}"
  vpc_id = data.aws_vpc.default.id
  private_dns_enabled = true
  subnet_ids = data.aws_subnet_ids.default.ids
  security_group_ids = [
    aws_security_group.packer.id
  ]
  vpc_endpoint_type = "Interface"
}

# OUTPUTS
