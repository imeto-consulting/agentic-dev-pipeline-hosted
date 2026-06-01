output "operator_sa_email" {
  value       = google_service_account.operator.email
  description = "Operator service account — use for Workload Identity binding in GKE"
}

output "cicd_sa_email" {
  value       = google_service_account.cicd.email
  description = "CI/CD service account — use for GitHub Actions Workload Identity Federation"
}

output "operator_ar_repo" {
  value       = "${google_artifact_registry_repository.operator.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.operator.repository_id}"
  description = "Full path for docker push of operator image"
}

output "devcontainer_cache_ar_repo" {
  value       = "${google_artifact_registry_repository.devcontainer_cache.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.devcontainer_cache.repository_id}"
  description = "Full path for envbuilder ENVBUILDER_CACHE_REPO"
}

output "pubsub_topic" {
  value       = google_pubsub_topic.github_webhooks.id
  description = "Pub/Sub topic for GitHub webhook events"
}
