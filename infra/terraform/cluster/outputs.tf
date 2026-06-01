output "cluster_name" {
  value = google_container_cluster.agents.name
}

output "cluster_endpoint" {
  value     = google_container_cluster.agents.endpoint
  sensitive = true
}

output "cluster_ca_certificate" {
  value     = google_container_cluster.agents.master_auth[0].cluster_ca_certificate
  sensitive = true
}

output "nat_ip" {
  value       = google_compute_router_nat.agent_nat.nat_ips
  description = "Egress IPs — use for GitHub IP allowlisting if needed"
}
