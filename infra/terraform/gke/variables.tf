variable "project_id" {
  type        = string
  description = "GCP project ID that hosts the maintainer."
}

variable "region" {
  type        = string
  description = "GCP region for Artifact Registry and the state bucket."
  default     = "europe-north1"
}

variable "zone" {
  type        = string
  description = "GCP zone for the (zonal) GKE cluster + node pool. Zonal keeps it to a single node — cheap for a poll-based maintainer. Must be within var.region."
  default     = "europe-north1-b"
}

variable "cluster_name" {
  type        = string
  description = "GKE cluster name."
  default     = "agentic-dev-pipeline"
}

variable "node_machine_type" {
  type        = string
  description = "Machine type for the single node pool. envbuilder builds images in-pod, so give it some headroom."
  default     = "e2-standard-2"
}

variable "node_count_min" {
  type        = number
  description = "Minimum nodes (autoscaling)."
  default     = 1
}

variable "node_count_max" {
  type        = number
  description = "Maximum nodes (autoscaling)."
  default     = 3
}

variable "artifact_repo_id" {
  type        = string
  description = "Artifact Registry Docker repository ID (holds the operator image + per-repo devcontainer images)."
  default     = "agentic-dev-pipeline"
}

variable "cicd_sa_email" {
  type        = string
  description = "Email of the GitHub Actions CI service account created by infra/terraform/bootstrap. Granted GKE + Artifact Registry roles here."
}
