variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (e.g., dev, prod)"
  type        = string
  default     = "dev"
}

variable "ingest_lambda_zip" {
  description = "Path to the ingest lambda deployment package"
  type        = string
  default     = "../ingest-lambda.zip"
}

variable "worker_lambda_zip" {
  description = "Path to the worker lambda deployment package"
  type        = string
  default     = "../worker-lambda.zip"
}

variable "crash_simulation_enabled" {
  description = "Enable crash simulation for testing DLQ behavior"
  type        = string
  default     = "true"
}
