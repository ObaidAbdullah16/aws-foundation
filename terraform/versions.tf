terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial backend config: bucket/key/region are passed by scripts/bootstrap.sh
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "aws-foundation"
      Owner     = var.owner_tag
      ManagedBy = "terraform"
      Repo      = "${var.github_owner}/aws-foundation"
    }
  }
}
