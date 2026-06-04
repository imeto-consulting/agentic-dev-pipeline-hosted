variable "project_id" {
  type        = string
  description = "GCP project ID that hosts the maintainer."
}

variable "region" {
  type        = string
  description = "GCP region for Artifact Registry and the state bucket."
  default     = "europe-west4"
}

variable "zone" {
  type        = string
  description = "GCP zone for the (zonal) GKE cluster + node pool. Zonal keeps it to a single node — cheap for a poll-based maintainer. Must be within var.region."
  default     = "europe-west4-a"
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

# ── GPU inference node pool ───────────────────────────────────────────────────
variable "gpu_machine_type" {
  type        = string
  description = "Machine type for the GPU node pool. Must support the chosen accelerator."
  default     = "g2-standard-8"
}

variable "gpu_accelerator_type" {
  type        = string
  description = "GPU accelerator type to attach to inference nodes."
  default     = "nvidia-l4"
}

variable "gpu_accelerator_count" {
  type        = number
  description = "Number of GPUs per node."
  default     = 1
}

variable "gpu_node_count_min" {
  type        = number
  description = "Minimum GPU nodes (0 = scale-to-zero when idle)."
  default     = 0
}

variable "gpu_node_count_max" {
  type        = number
  description = "Maximum GPU nodes."
  default     = 1
}

variable "gpu_spot" {
  type        = bool
  description = "Use spot (preemptible) VMs for GPU nodes. ~60-70% cheaper but can be evicted."
  default     = true
}
