# Bootstrap — run once manually to create the GCS bucket for Terraform remote state.
# This config intentionally uses local state (no backend block).
#
# Usage:
#   cd infra/terraform/bootstrap
#   terraform init
#   terraform apply
#
# After this succeeds, the shared/ and cluster/ configs can use the GCS backend.

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = "agentic-dev-pipeline"
  region  = "europe-north1"
}

resource "google_storage_bucket" "tfstate" {
  name     = "agentic-dev-pipeline-tfstate"
  location = "EU"

  versioning {
    enabled = true
  }

  uniform_bucket_level_access = true

  lifecycle {
    prevent_destroy = true
  }
}

# Enable the APIs needed before any other Terraform can run.
# These are the "chicken" APIs — everything else depends on them.
locals {
  bootstrap_apis = [
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "serviceusage.googleapis.com",
  ]
}

resource "google_project_service" "bootstrap" {
  for_each           = toset(local.bootstrap_apis)
  service            = each.value
  disable_on_destroy = false
}
