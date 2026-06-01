output "cluster_name" {
  value       = google_container_cluster.primary.name
  description = "GKE cluster name (for `gcloud container clusters get-credentials`)."
}

output "cluster_location" {
  value       = google_container_cluster.primary.location
  description = "GKE cluster location/region."
}

output "artifact_registry_repo" {
  value       = "${google_artifact_registry_repository.images.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
  description = "Artifact Registry path. Operator image: <repo>/operator:<tag>; devcontainer: <repo>/<name>-devcontainer:latest."
}

output "envbuilder_gsa_email" {
  value       = google_service_account.envbuilder.email
  description = "GSA the envbuilder KSA impersonates. Annotate the KSA: iam.gke.io/gcp-service-account=<this>."
}

output "node_service_account" {
  value       = google_service_account.nodes.email
  description = "Node pool service account (pulls images from Artifact Registry)."
}
