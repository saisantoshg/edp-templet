provider "aws"{
  version = "2.33.0"
  region="ap-south-1"
}

resource "aws_s3_bucket" "s3_client_bucket" {
  count      = length(var.s3_client_buckets)
  bucket = var.s3_client_buckets[count.index]
  acl    = "private"

  tags = {
    count      = length(var.s3_client_buckets)
    Name       = var.s3_client_buckets[count.index]
    Environment = var.client_env
  }
  
   versioning {
    enabled = true
  }
  
  lifecycle_rule {
    id      = "clientfiles_storage_rules"
    enabled = true

    transition {
      days          = 30
      storage_class = "STANDARD_IA" # or "ONEZONE_IA"
    }

    transition {
      days          = 60
      storage_class = "GLACIER"
    }

    expiration {
      days = 90
    }
  }

}

resource "aws_s3_bucket_public_access_block" "example" {
  count      = length(var.s3_client_buckets)
  bucket = var.s3_client_buckets[count.index]
  block_public_acls   = true
  block_public_policy = true
}

resource "aws_iam_role" "glue_rds_s3_access_role" {
  name = "glue_rds_s3_access_role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "glue.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF

  tags = {
    tag-key = "tag-value"
  }
}

resource "aws_iam_role_policy_attachment" "glue_role-attach1" {
  role       = aws_iam_role.glue_rds_s3_access_role.name
  count      = length(var.iam_glue_policy_arn)
  policy_arn = var.iam_glue_policy_arn[count.index]
}




locals {
  users_map = { for user in var.client_users_bucket_mapping : user.name => user }
  #users_map = { for user in var.users : user.name => user }

  # Construct list of inline policy maps for use with for_each
  # https://www.terraform.io/docs/configuration/functions/flatten.html#flattening-nested-structures-for-for_each
  inline_policies = flatten([
    for user in var.client_users_bucket_mapping : [
      for inline_policy in lookup(user, "inline_policies", []) : {
        id             = "${user.name}:${inline_policy.name}"
        user_name      = user.name
        policy_name    = inline_policy.name
        template       = inline_policy.template
        template_paths = inline_policy.template_paths
        template_vars  = inline_policy.template_vars
      }
    ]
  ])
}
    

module "inline_policy_documents" {
  source = "../policy_documents"

  create_policy_documents = var.client_users_bucket_mapping

  policies = [
    for policy_map in local.inline_policies : {
      name           = policy_map.id,
      template       = policy_map.template
      template_paths = policy_map.template_paths
      template_vars  = policy_map.template_vars
    }
  ]
}

  
  
# create the IAM users
resource "aws_iam_user" "this" {
  for_each = var.client_users_bucket_mapping ? local.users_map : {}

  name = each.key

  force_destroy        = each.value.force_destroy
  path                 = each.value.path
  permissions_boundary = each.value.permissions_boundary != null ? var.policy_arns[index(var.policy_arns, each.value.permissions_boundary)] : null

  # Merge module-level tags with tags set in the user-schema
  tags = merge(var.tags, lookup(each.value, "tags", {}))
}
  
  
  
# create inline policies for the IAM users
resource "aws_iam_user_policy" "this" {
  for_each = var.client_users_bucket_mapping ? { for policy_map in local.inline_policies : policy_map.id => policy_map } : {}

  name   = each.value.policy_name
  user   = aws_iam_user.this[each.value.user_name].id
  policy = module.inline_policy_documents.policies[each.key]
}