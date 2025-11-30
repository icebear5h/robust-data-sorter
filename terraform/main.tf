terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# DynamoDB Table for tenant-isolated logs
resource "aws_dynamodb_table" "tenant_processed_logs" {
  name           = "tenant_processed_logs"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "tenant_pk"
  range_key      = "log_sk"

  attribute {
    name = "tenant_pk"
    type = "S"
  }

  attribute {
    name = "log_sk"
    type = "S"
  }

  tags = {
    Name        = "tenant_processed_logs"
    Environment = var.environment
  }
}

# SQS Queue for log ingestion
resource "aws_sqs_queue" "log_ingest_queue" {
  name                       = "log-ingest-queue"
  visibility_timeout_seconds = 60  # 1 minute, should be >= Lambda timeout
  message_retention_seconds  = 345600  # 4 days
  receive_wait_time_seconds  = 0

  tags = {
    Name        = "log-ingest-queue"
    Environment = var.environment
  }
}

# Dead Letter Queue (optional but recommended)
resource "aws_sqs_queue" "log_ingest_dlq" {
  name                      = "log-ingest-dlq"
  message_retention_seconds = 1209600  # 14 days

  tags = {
    Name        = "log-ingest-dlq"
    Environment = var.environment
  }
}

# Configure DLQ for main queue
resource "aws_sqs_queue_redrive_policy" "log_ingest_queue_redrive" {
  queue_url = aws_sqs_queue.log_ingest_queue.id
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.log_ingest_dlq.arn
    maxReceiveCount     = 3
  })
}

# IAM Role for Ingest Lambda
resource "aws_iam_role" "ingest_lambda_role" {
  name = "ingest-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# IAM Policy for Ingest Lambda
resource "aws_iam_role_policy" "ingest_lambda_policy" {
  name = "ingest-lambda-policy"
  role = aws_iam_role.ingest_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage"
        ]
        Resource = aws_sqs_queue.log_ingest_queue.arn
      }
    ]
  })
}

# Ingest Lambda Function
resource "aws_lambda_function" "ingest_lambda" {
  filename         = var.ingest_lambda_zip
  function_name    = "log-ingest-lambda"
  role            = aws_iam_role.ingest_lambda_role.arn
  handler         = "ingest/handler.handler"
  source_code_hash = filebase64sha256(var.ingest_lambda_zip)
  runtime         = "nodejs20.x"
  timeout         = 30

  environment {
    variables = {
      QUEUE_URL = aws_sqs_queue.log_ingest_queue.url
    }
  }

  tags = {
    Name        = "log-ingest-lambda"
    Environment = var.environment
  }
}

# IAM Role for Worker Lambda
resource "aws_iam_role" "worker_lambda_role" {
  name = "worker-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# IAM Policy for Worker Lambda
resource "aws_iam_role_policy" "worker_lambda_policy" {
  name = "worker-lambda-policy"
  role = aws_iam_role.worker_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.log_ingest_queue.arn
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem"
        ]
        Resource = aws_dynamodb_table.tenant_processed_logs.arn
      }
    ]
  })
}

# Worker Lambda Function
resource "aws_lambda_function" "worker_lambda" {
  filename         = var.worker_lambda_zip
  function_name    = "log-worker-lambda"
  role            = aws_iam_role.worker_lambda_role.arn
  handler         = "worker/handler.handler"
  source_code_hash = filebase64sha256(var.worker_lambda_zip)
  runtime         = "nodejs20.x"
  timeout         = 30   # 30 seconds (sufficient for most processing)

  environment {
    variables = {
      TABLE_NAME        = aws_dynamodb_table.tenant_processed_logs.name
      CRASH_SIMULATION  = var.crash_simulation_enabled
    }
  }

  tags = {
    Name        = "log-worker-lambda"
    Environment = var.environment
  }
}

# SQS Event Source Mapping for Worker Lambda
resource "aws_lambda_event_source_mapping" "sqs_to_worker" {
  event_source_arn = aws_sqs_queue.log_ingest_queue.arn
  function_name    = aws_lambda_function.worker_lambda.arn
  batch_size       = 10
  enabled          = true

  scaling_config {
    maximum_concurrency = 7  # 7 workers, 3 ingest - prioritizes queue drain speed
  }
}

# API Gateway HTTP API
resource "aws_apigatewayv2_api" "log_api" {
  name          = "log-ingestion-api"
  protocol_type = "HTTP"

  tags = {
    Name        = "log-ingestion-api"
    Environment = var.environment
  }
}

# API Gateway Stage
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.log_api.id
  name        = "$default"
  auto_deploy = true

  tags = {
    Name        = "default-stage"
    Environment = var.environment
  }
}

# Lambda Permission for API Gateway
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.log_api.execution_arn}/*/*"
}

# API Gateway Integration
resource "aws_apigatewayv2_integration" "ingest_integration" {
  api_id             = aws_apigatewayv2_api.log_api.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.ingest_lambda.invoke_arn
  integration_method = "POST"
}

# API Gateway Route
resource "aws_apigatewayv2_route" "ingest_route" {
  api_id    = aws_apigatewayv2_api.log_api.id
  route_key = "POST /ingest"
  target    = "integrations/${aws_apigatewayv2_integration.ingest_integration.id}"
}
