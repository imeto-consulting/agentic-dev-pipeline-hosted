terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  backend "gcs" {
    bucket = "agentic-dev-pipeline-tfstate"
    prefix = "shared"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ── Required APIs ─────────────────────────────────────────────────────────────
locals {
  required_apis = [
    "container.googleapis.com",        # GKE
    "run.googleapis.com",              # Cloud Run
    "artifactregistry.googleapis.com", # Container images
    "secretmanager.googleapis.com",    # Secrets
    "pubsub.googleapis.com",           # Webhook fan-out
    "compute.googleapis.com",          # Cloud NAT, networking
    "logging.googleapis.com",          # Cloud Logging
    "monitoring.googleapis.com",       # Cloud Monitoring
  ]
}

resource "google_project_service" "apis" {
  for_each           = toset(local.required_apis)
  service            = each.value
  disable_on_destroy = false
}

# ── Artifact Registry ─────────────────────────────────────────────────────────
# Two repos: one for the operator image, one for devcontainer layer cache.

resource "google_artifact_registry_repository" "operator" {
  location      = var.region
  repository_id = "operator"
  description   = "Operator controller-manager images"
  format        = "DOCKER"

  depends_on = [google_project_service.apis["artifactregistry.googleapis.com"]]
}

resource "google_artifact_registry_repository" "devcontainer_cache" {
  location      = var.region
  repository_id = "devcontainer-cache"
  description   = "envbuilder layer cache for target repo devcontainers"
  format        = "DOCKER"

  depends_on = [google_project_service.apis["artifactregistry.googleapis.com"]]
}

# ── Service Accounts ──────────────────────────────────────────────────────────

# Operator SA — runs the controller in GKE via Workload Identity.
resource "google_service_account" "operator" {
  account_id   = "operator"
  display_name = "DevTask Operator"
  description  = "GKE Workload Identity for the devtask-operator. Reads secrets, manages namespaces."
}

# CI/CD SA — GitHub Actions pushes images and deploys to GKE.
resource "google_service_account" "cicd" {
  account_id   = "github-actions"
  display_name = "GitHub Actions CI/CD"
  description  = "Pushes images to AR, deploys to GKE. Authenticated via Workload Identity Federation."
}

# ── Secret Manager ────────────────────────────────────────────────────────────
# Secrets are created empty — values populated manually after first apply.
#
#   gcloud secrets versions add github-app-id --data-file=- <<< "123456"
#   gcloud secrets versions add github-app-installation-id --data-file=- <<< "987654"
#   gcloud secrets versions add github-app-key --data-file=path/to/private-key.pem
#   gcloud secrets versions add anthropic-api-key --data-file=- <<< "sk-ant-..."
#   gcloud secrets versions add webhook-secret --data-file=- <<< "$(openssl rand -hex 20)"

locals {
  secrets = [
    "github-app-id",
    "github-app-installation-id",
    "github-app-key",
    "anthropic-api-key",
    "webhook-secret",
  ]
}

resource "google_secret_manager_secret" "pipeline" {
  for_each  = toset(local.secrets)
  secret_id = each.value

  labels = {
    purpose    = "agentic-pipeline"
    managed_by = "terraform"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis["secretmanager.googleapis.com"]]
}

# Operator SA can read all pipeline secrets.
resource "google_secret_manager_secret_iam_member" "operator_accessor" {
  for_each  = google_secret_manager_secret.pipeline
  secret_id = each.value.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.operator.email}"
}

# ── IAM: CI/CD permissions ────────────────────────────────────────────────────

# CI/CD can push to both AR repos.
resource "google_artifact_registry_repository_iam_member" "cicd_operator_writer" {
  location   = google_artifact_registry_repository.operator.location
  repository = google_artifact_registry_repository.operator.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.cicd.email}"
}

resource "google_artifact_registry_repository_iam_member" "cicd_cache_writer" {
  location   = google_artifact_registry_repository.devcontainer_cache.location
  repository = google_artifact_registry_repository.devcontainer_cache.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.cicd.email}"
}

# CI/CD can deploy to GKE.
resource "google_project_iam_member" "cicd_container_admin" {
  project = var.project_id
  role    = "roles/container.admin"
  member  = "serviceAccount:${google_service_account.cicd.email}"
}

# CI/CD needs actAs on the operator SA to deploy workloads running as it.
resource "google_service_account_iam_member" "cicd_acts_as_operator" {
  service_account_id = google_service_account.operator.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.cicd.email}"
}

# ── Pub/Sub: GitHub webhook fan-out ───────────────────────────────────────────

resource "google_pubsub_topic" "github_webhooks" {
  name       = "github-webhooks"
  depends_on = [google_project_service.apis["pubsub.googleapis.com"]]

  labels = {
    purpose    = "github-webhook-fanout"
    managed_by = "terraform"
  }
}

# Operator SA subscribes to webhook events.
resource "google_project_iam_member" "operator_pubsub_subscriber" {
  project = var.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.operator.email}"
}

# Operator SA also publishes (for the broadcaster service running as operator SA).
resource "google_project_iam_member" "operator_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.operator.email}"
}

# ── IAM: Operator permissions on GKE ─────────────────────────────────────────
# The operator manages namespaces, pods, secrets, and network policies inside
# the cluster. With Workload Identity, it authenticates as this SA automatically.
# Actual RBAC inside the cluster is handled by the kubebuilder-generated
# ClusterRole — this GCP IAM just lets the SA exist and be used.

# Operator SA can pull from both AR repos (for envbuilder + its own image).
resource "google_artifact_registry_repository_iam_member" "operator_pulls_operator" {
  location   = google_artifact_registry_repository.operator.location
  repository = google_artifact_registry_repository.operator.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.operator.email}"
}

resource "google_artifact_registry_repository_iam_member" "operator_pulls_cache" {
  location   = google_artifact_registry_repository.devcontainer_cache.location
  repository = google_artifact_registry_repository.devcontainer_cache.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.operator.email}"
}
