terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

# Default provider — ap-south-1 for all core resources
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = "harsh"
    }
  }
}

# Grafana provider alias — ap-southeast-1 (Singapore)
# Amazon Managed Grafana is not available in ap-south-1 (Mumbai).
# ap-southeast-1 is the closest supported region.
provider "aws" {
  alias  = "grafana"
  region = "ap-southeast-1"

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = "harsh"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
