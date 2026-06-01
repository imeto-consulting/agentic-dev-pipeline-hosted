# Bootstrap — run ONCE manually to create the prerequisites the rest of the
# Terraform (and the GitHub Actions) depend on:
#   1. a GCS bucket for the remote Terraform state used by infra/terraform/
#   2. the github-actions CI service account that the workflows authenticate as
#
# This config intentionally uses LOCAL state (no backend block) — it is the
# thing that creates the remote-state bucket, so it cannot store its own state
# there. Mirrors imeto-consulting/sig-lake-light-house/infra/terraform/bootstrap.
#
# Usage:
#   cd infra/terraform/bootstrap
#   terraform init
#   terraform apply -var="project_id=YOUR_PROJECT"
#
# After apply, mint a JSON key for the CI SA and store it as the GCP_SA_KEY
# GitHub Actions secret (see README / the `key_command` output):
#   gcloud iam service-accounts keys create key.json \
#     --iam-account=github-actions@YOUR_PROJECT.iam.gserviceaccount.com
#   gh secret set GCP_SA_KEY < key.json && rm key.json

terraform {
  required_version = ">= 1.8.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" {
  type        = string
  description = "GCP project ID that will host the maintainer."
}

variable "region" {
  type        = string
  description = "Default GCP region."
  default     = "europe-north1"
}

# ── Remote Terraform state bucket ─────────────────────────────────────────────
resource "google_storage_bucket" "tfstate" {
  name     = "${var.project_id}-adp-tfstate"
  location = var.region

  versioning {
    enabled = true
  }

  uniform_bucket_level_access = true

  lifecycle {
    prevent_destroy = true
  }
}

# ── CI service account for GitHub Actions ─────────────────────────────────────
# Authenticated via a JSON key stored as the GCP_SA_KEY GitHub secret (the
# user's chosen auth model). The roles it needs to (a) run Terraform and (b)
# deploy the maintainer are granted in infra/terraform/ once the remote state
# exists; here we only create the identity + grant state-bucket access so the
# very first `terraform-cd` run can read/write state.
resource "google_service_account" "github_actions" {
  account_id   = "github-actions"
  display_name = "GitHub Actions CI"
  description  = "Identity the agentic-dev-pipeline GitHub Actions authenticate as (Terraform + deploy)."
}

# Let the CI SA read/write the remote Terraform state.
resource "google_storage_bucket_iam_member" "ci_state_admin" {
  bucket = google_storage_bucket.tfstate.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.github_actions.email}"
}

output "tfstate_bucket" {
  value       = google_storage_bucket.tfstate.name
  description = "GCS bucket for remote Terraform state. Set this as the `bucket` in infra/terraform/backend.tf."
}

output "ci_service_account_email" {
  value       = google_service_account.github_actions.email
  description = "CI service account email. Pass to infra/terraform as var.cicd_sa_email."
}

output "key_command" {
  value       = "gcloud iam service-accounts keys create key.json --iam-account=${google_service_account.github_actions.email} && gh secret set GCP_SA_KEY < key.json && rm key.json"
  description = "Run this to mint a JSON key and store it as the GCP_SA_KEY GitHub secret."
}
