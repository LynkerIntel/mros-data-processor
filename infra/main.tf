terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      # version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  profile = var.aws_profile
}

#################
# Local variables
#################

locals {
  airtable_lambda_zip = "../deploy/lambda_function.zip"
}

# ####################
# # SECRETS MANAGERS #
# ####################

resource "aws_secretsmanager_secret" "airtable_secret" {
  name_prefix = var.airtable_secret_prefix
  recovery_window_in_days = 0
  description = "Secrets for MROS Airtable"
}

# AWS Secrets Manager Secret Version for Airtable Secrets
resource "aws_secretsmanager_secret_version" "airtable_secret_version" {
  secret_id     = aws_secretsmanager_secret.airtable_secret.id
  secret_string = jsonencode({
    "AIRTABLE_BASE_ID"     = var.airtable_base_id
    "AIRTABLE_TABLE_ID"    = var.airtable_table_id
    "AIRTABLE_API_TOKEN"   = var.airtable_api_token
  })
}
###############################
# S3 bucket for airtable data #
###############################

# s3 bucket for lambda code
resource "aws_s3_bucket" "airtable_s3_bucket" {
  bucket = var.airtable_s3_bucket_name
}

#######################################
# S3 bucket permissions airtable data #
#######################################

# s3 bucket ownership controls
resource "aws_s3_bucket_ownership_controls" "airtable_s3_bucket_ownership_controls" {
  bucket = aws_s3_bucket.airtable_s3_bucket.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

# s3 bucket public access block
resource "aws_s3_bucket_public_access_block" "airtable_s3_public_access_block" {
  bucket = aws_s3_bucket.airtable_s3_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

}

resource "aws_s3_bucket_acl" "airtable_s3_bucket_acl" {
  depends_on = [
    aws_s3_bucket_ownership_controls.airtable_s3_bucket_ownership_controls,
    aws_s3_bucket_public_access_block.airtable_s3_public_access_block,
  ]

  bucket = aws_s3_bucket.airtable_s3_bucket.id
  acl    = "private"
}

data "aws_iam_policy_document" "s3_bucket_policy_document" {
  statement {
    sid = "AllowCurrentAccount"
    effect = "Allow"

    principals {
      type = "AWS"
      identifiers = ["*"]
    }

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket"
    ]

    resources = [
      aws_s3_bucket.airtable_s3_bucket.arn,
      "${aws_s3_bucket.airtable_s3_bucket.arn}/*"
    ]

    condition {
      test = "StringEquals"
      variable = "aws:PrincipalAccount"
      values = [var.aws_account_number]
    }
  }
}

# s3 bucket policy to allow public access
resource "aws_s3_bucket_policy" "airtable_bucket_policy" {
  bucket = aws_s3_bucket.airtable_s3_bucket.id
  policy = data.aws_iam_policy_document.s3_bucket_policy_document.json
  depends_on = [
    aws_s3_bucket_acl.airtable_s3_bucket_acl,
    aws_s3_bucket_ownership_controls.airtable_s3_bucket_ownership_controls,
    aws_s3_bucket_public_access_block.airtable_s3_public_access_block,
  ]
}

####################################
# Upload Lambda function zip to S3 #
####################################

# s3 bucket for lambda code
resource "aws_s3_bucket" "lambda_bucket" {
  bucket = var.lambda_bucket_name
}

# s3 object for lambda code
resource "aws_s3_object" "lambda_code_object" {
  bucket = aws_s3_bucket.lambda_bucket.bucket
  key    = "lambda_function.zip"
  source = local.airtable_lambda_zip
}

##########################
# Lambda Role and Policy #
##########################

# lambda role to assume
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

# Create an IAM role for the lambda to assume role
resource "aws_iam_role" "lambda_role" {
  name               = "mros_airtable_lambda_role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

# Attach necessary policies to the IAM role
resource "aws_iam_role_policy_attachment" "lambda_role_attachment" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  # policy_arn = aws_iam_policy.lambda_policy.arn
}

####################
# Lambda Log Group #
####################

# lambda log group
resource "aws_cloudwatch_log_group" "lambda_log_group" {
  name              = "/aws/lambda/${var.airtable_lambda_function_name}"
  retention_in_days = 14
}

resource "aws_iam_policy" "logging_policy" {
  name   = "mros-airtable-processor-logging-policy"
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        Action : [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Effect : "Allow",
        Resource : "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# Attach the lambda logging IAM policy to the lambda role
resource "aws_iam_role_policy_attachment" "lambda_logs_policy_attachment" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.logging_policy.arn
}

####################################
# Lambda Function (Airtable to S3) #
####################################

# lambda function to process csv file
resource "aws_lambda_function" "airtable_lambda_function" {
  s3_bucket        = aws_s3_bucket.lambda_bucket.bucket
  s3_key           = "lambda_function.zip"
  function_name    = var.airtable_lambda_function_name
  handler          = "app.process_airtable.process_airtable"
  # handler          = "function.name/handler.process_csv_lambda"
  role             = aws_iam_role.lambda_role.arn
  runtime          = "python3.11"
  architectures    = ["x86_64"]
  # architectures    = ["arm64"]

  # Attach the Lambda function to the CloudWatch Logs group
  environment {
    variables = {
        CW_LOG_GROUP = aws_cloudwatch_log_group.lambda_log_group.name,
        BASE_ID = var.airtable_base_id,
        TABLE_ID = var.airtable_table_id,
        AIRTABLE_TOKEN = var.airtable_api_token,
        S3_BUCKET = "s3://${aws_s3_bucket.airtable_s3_bucket.bucket}",
        # S3_BUCKET = var.airtable_s3_bucket_name,
    }

  }

  # timeout in seconds
  timeout         = 180
  
  depends_on = [
    aws_s3_bucket.lambda_bucket,
    aws_s3_object.lambda_code_object,
    aws_iam_role_policy_attachment.lambda_logs_policy_attachment,
    aws_cloudwatch_log_group.lambda_log_group,
  ]

}

# resource "aws_lambda_permission" "lambda_put_to_s3_permission" {
#   statement_id  = "AllowExecutionFromS3"
#   action        = "lambda:InvokeFunction"
#   function_name = aws_lambda_function.airtable_lambda_function.function_name
#   principal     = "s3.amazonaws.com"
#   source_arn    = aws_s3_bucket.airtable_s3_bucket.arn
# }

#####################################
# EventBridge Rule for Lambda Event #
#####################################

# EventBridge rule to trigger lambda function
resource "aws_cloudwatch_event_rule" "airtable_event_rule" {
  name                = "airtable_event_rule"
  description         = "Event rule to trigger lambda function"
  schedule_expression = "rate(2 minutes)"
}

# EventBridge target for lambda function
resource "aws_cloudwatch_event_target" "airtable_event_target" {
  rule      = aws_cloudwatch_event_rule.airtable_event_rule.name
  target_id = "airtable_event_target"
  arn       = aws_lambda_function.airtable_lambda_function.arn
} 

resource "aws_lambda_permission" "cloudwatch_invoke_lambda_permission" {
  statement_id = "AllowExecutionFromCloudWatch"
  action = "lambda:InvokeFunction"
  function_name = aws_lambda_function.airtable_lambda_function.function_name
  principal = "events.amazonaws.com"
  source_arn = aws_cloudwatch_event_rule.airtable_event_rule.arn
}

# data "aws_iam_policy_document" "sns_topic_policy" {
#   statement {
#     effect  = "Allow"
#     actions = ["SNS:Publish"]

#     principals {
#       type        = "Service"
#       identifiers = ["events.amazonaws.com"]
#     }

#     resources = [aws_sns_topic.aws_logins.arn]
#   }
# }

# resource "aws_iam_policy" "eventbridge_lambda_invoke_policy" {
#   name        = "api_gateway_invoke_policy"
#   description = "Policy for API Gateway to invoke Lambda functions"

#   policy = jsonencode({
#     Version = "2012-10-17",
#     Statement = [
#       {
#         Effect = "Allow",
#         Action = "lambda:InvokeFunction",
#         Resource = aws_lambda_function.airtable_lambda_function.arn,
#       },
#     ],
#   })
# }

# resource "aws_iam_role_policy_attachment" "api_gateway_invoke_role_policy_attachment" {
#   policy_arn = aws_iam_policy.api_gateway_invoke_policy.arn
#   role       = aws_iam_role.api_gateway_role.name
# }