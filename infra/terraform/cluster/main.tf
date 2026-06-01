# GKE Autopilot cluster for agent sandboxes.
#
# Separate from shared/ because:
# - Cluster creation takes 5-10 minutes
# - Cluster config changes less frequently than IAM/secrets
# - Easier to destroy/recreate the cluster without touching secrets
#
# Usage:
#   cd infra/terraform/cluster
#   terraform init
#   terraform apply

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
    prefix = "cluster"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ── GKE Autopilot ────────────────────────────────────────────────────────────

resource "google_container_cluster" "agents" {
  name     = "agent-sandbox"
  location = var.region

  # Autopilot mode — no node pools to manage, pay-per-pod.
  enable_autopilot = true

  # Workload Identity is enabled by default on Autopilot.
  # Network policy enforcement is also built-in (no Calico needed).

  # Private cluster: nodes have no public IPs. API server is reachable
  # from authorized networks only.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false # allow kubectl from authorized networks
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  # Allow access from Cloud Shell, CI, and your IP.
  # TODO: Tighten this after initial setup.
  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "0.0.0.0/0"
      display_name = "all-temporary"
    }
  }

  # Release channel — regular gives us recent features without bleeding edge.
  release_channel {
    channel = "REGULAR"
  }

  # Deletion protection — disable for now during setup, enable later.
  deletion_protection = false

  depends_on = [google_project_service.container]
}

resource "google_project_service" "container" {
  service            = "container.googleapis.com"
  disable_on_destroy = false
}

# ── Workload Identity binding ─────────────────────────────────────────────────
# Maps the K8s ServiceAccount (devpipeline-system/operator) to the GCP SA.
# This lets the operator pod authenticate as operator@<project>.iam.gserviceaccount.com
# without any key files.

resource "google_service_account_iam_member" "operator_workload_identity" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/operator@${var.project_id}.iam.gserviceaccount.com"
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[devpipeline-system/operator]"
}

# ── Cloud NAT ─────────────────────────────────────────────────────────────────
# Autopilot private nodes need NAT for egress to GitHub, Anthropic, package registries.

resource "google_compute_router" "nat_router" {
  name    = "agent-nat-router"
  region  = var.region
  network = "default"
}

resource "google_compute_router_nat" "agent_nat" {
  name   = "agent-nat"
  router = google_compute_router.nat_router.name
  region = var.region

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
