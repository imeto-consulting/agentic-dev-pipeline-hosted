# Hosted maintainer infrastructure on GKE.
#
# Provisions: required APIs, a VPC-native network, a GKE Standard cluster with
# Dataplane V2 (NetworkPolicy enforcement) + Workload Identity, a dedicated node
# pool, an Artifact Registry Docker repo, and the IAM the CI SA + in-cluster
# envbuilder Job need.
#
# Cluster shape rationale (see docs/plans): Standard (not Autopilot) keeps
# envbuilder — which builds container images inside a pod — reliable; a public
# cluster avoids Cloud NAT cost while Dataplane V2 still enforces the egress
# NetworkPolicy that is the sandbox's real security boundary.

# ── Required APIs ─────────────────────────────────────────────────────────────
resource "google_project_service" "apis" {
  for_each = toset([
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# ── Network (VPC-native) ──────────────────────────────────────────────────────
resource "google_compute_network" "vpc" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.cluster_name}-subnet"
  ip_cidr_range = "10.10.0.0/20"
  region        = var.region
  network       = google_compute_network.vpc.id

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/20"
  }
}

# ── Dedicated node service account (least privilege) ──────────────────────────
resource "google_service_account" "nodes" {
  account_id   = "${var.cluster_name}-nodes"
  display_name = "GKE node pool SA for ${var.cluster_name}"
}

resource "google_project_iam_member" "nodes_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_project_iam_member" "nodes_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

# ── GKE Standard cluster ──────────────────────────────────────────────────────
# Zonal (location = a zone, not the region): one node, control plane in one zone.
# Cheap for a poll-based maintainer; the only cost is brief control-plane API
# downtime during upgrades, which the workloads tolerate.
resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.zone

  # Manage the node pool separately.
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.subnet.id

  # Dataplane V2 — enforces NetworkPolicy (the sandbox egress allowlist).
  datapath_provider = "ADVANCED_DATAPATH"

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Workload Identity so the envbuilder Job can push to Artifact Registry
  # without a static key.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  deletion_protection = false

  depends_on = [google_project_service.apis]
}

resource "google_container_node_pool" "primary" {
  name     = "primary"
  cluster  = google_container_cluster.primary.id
  location = var.zone

  autoscaling {
    min_node_count = var.node_count_min
    max_node_count = var.node_count_max
  }

  node_config {
    machine_type    = var.node_machine_type
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# ── Artifact Registry ─────────────────────────────────────────────────────────
resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = var.artifact_repo_id
  description   = "Operator image + per-repo devcontainer images for the agentic dev pipeline."
  format        = "DOCKER"

  depends_on = [google_project_service.apis]
}

# Node SA pulls images (agent + triage pods).
resource "google_artifact_registry_repository_iam_member" "nodes_reader" {
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.nodes.email}"
}

# CI SA pushes the operator image.
resource "google_artifact_registry_repository_iam_member" "cicd_writer" {
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${var.cicd_sa_email}"
}

# ── CI SA: manage the cluster + deploy ────────────────────────────────────────
resource "google_project_iam_member" "cicd_container_admin" {
  project = var.project_id
  role    = "roles/container.admin"
  member  = "serviceAccount:${var.cicd_sa_email}"
}

# ── envbuilder Workload Identity ──────────────────────────────────────────────
# The in-cluster envbuilder Job runs as KSA devpipeline-system/envbuilder and
# impersonates this GSA to push the built devcontainer image to Artifact Registry.
resource "google_service_account" "envbuilder" {
  account_id   = "envbuilder"
  display_name = "envbuilder devcontainer builder"
  description  = "Workload-Identity GSA used by the in-cluster envbuilder Job to push devcontainer images to Artifact Registry."
}

resource "google_artifact_registry_repository_iam_member" "envbuilder_writer" {
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.envbuilder.email}"
}

# Bind the in-cluster KSA (devpipeline-system/envbuilder) to the GSA.
resource "google_service_account_iam_member" "envbuilder_wi" {
  service_account_id = google_service_account.envbuilder.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[devpipeline-system/envbuilder]"
}
