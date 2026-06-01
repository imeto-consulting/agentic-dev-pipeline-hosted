# Remote state in the GCS bucket created by infra/terraform/bootstrap.
# Replace the bucket name with the `tfstate_bucket` output from bootstrap if
# your project ID differs from the example (bucket = "<project_id>-adp-tfstate").
#
#   terraform init \
#     -backend-config="bucket=<project_id>-adp-tfstate"
#
# The bucket name is intentionally left as a placeholder so this repo stays
# project-agnostic; pass it via -backend-config in `terraform init` (the
# terraform-ci / terraform-cd workflows do this from the TF_STATE_BUCKET secret).
terraform {
  required_version = ">= 1.8.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
  backend "gcs" {
    prefix = "infra"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
