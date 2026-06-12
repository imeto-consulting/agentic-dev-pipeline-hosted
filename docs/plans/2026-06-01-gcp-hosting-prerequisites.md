# GCP Hosting Prerequisites — Agentic Dev Pipeline

> Step 1: Inventory what needs to exist before deploying the pipeline to GCP.
> Goal: multi-repo instancing, reachable by authorized users, no local k3d dependency.

---

## Architecture Decision: GKE vs Cloud Run

The pipeline has two distinct layers with different compute needs:

| Layer | What it does | Compute model |
|-------|-------------|---------------|
| **Control plane** | Webhook ingress, event routing, task dispatch, state machine | Stateless HTTP — fits **Cloud Run** |
| **Agent sandbox** | Builds devcontainers, runs `claude -p` in isolation for 5-30 min | Long-running, needs namespace isolation — fits **GKE Autopilot** |

**Recommendation:** Hybrid. Steal the Cloud Run orchestrator pattern from sig-lake-light-house for the control plane. Use GKE Autopilot for the sandboxed agent pods (preserves the per-namespace isolation, NetworkPolicy, and envbuilder model that already works).

---

## Prerequisites Checklist

### 1. GCP Project & Foundation

- [ ] Dedicated GCP project (e.g. `agentic-dev-pipeline`) — separate from sig-lake-light-house
- [ ] Billing account linked
- [ ] Required APIs enabled:
  - `container.googleapis.com` (GKE)
  - `run.googleapis.com` (Cloud Run)
  - `artifactregistry.googleapis.com`
  - `secretmanager.googleapis.com`
  - `pubsub.googleapis.com`
  - `iam.googleapis.com`
  - `cloudresourcemanager.googleapis.com`
- [ ] Terraform state bucket (GCS) — steal bootstrap pattern from sig-lake-light-house

### 2. Container Registry

- [ ] Artifact Registry repo for the **operator image** (Go binary, already has a Dockerfile)
- [ ] Artifact Registry repo for **devcontainer layer cache** (replaces k3d local registry)
  - envbuilder pushes cached layers here instead of `localhost:5000`
  - One cache repo per target repo, or a shared repo with per-repo prefixes

### 3. GKE Autopilot Cluster

- [ ] GKE Autopilot cluster (no node management, pay-per-pod)
  - Autopilot enforces pod security by default (no privileged containers)
  - NetworkPolicy enforcement is built-in (no Calico install needed)
- [ ] Workload Identity Federation — pods authenticate as GCP SAs without key files
- [ ] Node auto-provisioning with enough headroom for agent pods (2-4 vCPU, 4-8 GB RAM each)
- [ ] Private cluster with Cloud NAT for egress control (alternative to NetworkPolicy CIDR allowlists)

### 4. Identity & Access

- [ ] **Service Accounts:**
  - `operator-sa` — runs the operator Deployment; needs GKE workload identity, Secret Manager access
  - `agent-dispatcher-sa` — (can reuse sig-lake-light-house pattern) impersonates per-repo SAs
  - `cicd-sa` — GitHub Actions deploys operator image + CRDs
- [ ] **Workload Identity bindings:**
  - `operator-sa` → K8s ServiceAccount `devpipeline-system/operator`
  - Per-task pods don't need GCP identity (they talk to GitHub/Anthropic only)
- [ ] **IAM roles:**
  - operator-sa: `roles/secretmanager.secretAccessor`, `roles/container.developer` (for managing namespaces/pods)
  - cicd-sa: `roles/artifactregistry.writer`, `roles/container.admin`

### 5. Secrets Management

- [ ] Migrate from K8s `pipeline-creds` Secret to **Secret Manager**:
  - `github-app-key` (PEM)
  - `github-app-id`
  - `github-app-installation-id`
  - `anthropic-api-key`
  - `webhook-secret` (if using webhook ingress)
- [ ] Operator reads from Secret Manager → injects into per-task K8s Secrets (same pattern as today, just sourced from SM instead of a manually-created K8s secret)
- [ ] Per-repo credentials if multi-repo (GitHub App installation tokens are already per-repo-scoped)

### 6. GitHub App (replaces PAT)

- [ ] Register a GitHub App (Phase 5 Task 3 already specifies this)
  - Permissions: Contents RW, Issues RW, Pull Requests RW, Metadata R
  - Webhook URL → Cloud Run broadcaster (or direct to GKE ingress)
- [ ] Install on target repos (or org-wide with repo selection)
- [ ] Store App credentials in Secret Manager (see above)
- [ ] Operator mints installation tokens per-task (short-lived, repo-scoped)

### 7. Networking & Ingress

- [ ] **Webhook ingress** — two options:
  - *Option A (sig-lake-light-house pattern):* Cloud Run `gh-event-broadcaster` → Pub/Sub → operator subscribes
  - *Option B:* GKE Ingress with Cloud Armor WAF → operator webhook endpoint
  - Option A is better for multi-repo (decouples webhook receipt from processing)
- [ ] **Agent egress** — NetworkPolicy on GKE Autopilot:
  - Same allowlist: `api.github.com`, `api.anthropic.com`, DNS, package registries
  - Cloud NAT gives a stable egress IP if GitHub IP allowlisting is needed
- [ ] **No public access to the operator itself** — internal only

### 8. CI/CD Pipeline

- [ ] GitHub Actions workflow:
  - Build operator image → push to Artifact Registry
  - `kubectl apply` CRDs + operator Deployment (or use Kustomize/Helm)
  - Workload Identity Federation for keyless auth from GitHub Actions
- [ ] Steal the `cloud-run-cd.yml` pattern from sig-lake-light-house for the broadcaster service

### 9. Observability (day-2 but plan for it now)

- [ ] Cloud Logging (GKE pods log to stdout → automatic)
- [ ] Cloud Monitoring alerts: pod OOMKilled, task stuck > 30 min, GitHub API rate limit
- [ ] Structured JSON logs from the operator (already outputs via controller-runtime logger)

### 10. Multi-Repo Instancing (the long-term goal)

- [ ] **Repo registry** — a config (ConfigMap, Firestore doc, or CRD) listing:
  - repo name
  - GitHub App installation ID
  - devcontainer cache image path
  - allowed egress domains (per-repo package registries)
  - resource limits (CPU/memory/timeout per task)
- [ ] **Tenant isolation:**
  - Each repo gets its own namespace prefix (`devtask-<repo>-<issue>`)
  - NetworkPolicy scoped per-repo (different repos may need different package registries)
  - Resource quotas per-repo to prevent one noisy repo from starving others

---

## What We Can Steal from sig-lake-light-house

| Component | sig-lake-light-house | Adaptation needed |
|-----------|---------------------|-------------------|
| Terraform bootstrap | `infra/terraform/bootstrap/main.tf` | Change project ID |
| Secret Manager + GitHub App secrets | `infra/terraform/shared/main.tf` | Same pattern, add `anthropic-api-key` |
| Artifact Registry | `orchestrator.tf` | Rename repo, add devcontainer cache repo |
| Cloud Run broadcaster | `orchestrator.tf` (gh-event-broadcaster) | Reuse as-is, different image |
| Pub/Sub webhook fan-out | `shared/main.tf` | Same topic structure |
| Service account + impersonation model | `shared/main.tf` + `variables.tf` | Same dispatcher pattern |
| Workload Identity for CI | Already has `cicd_sa_email` | Add GKE deploy permissions |
| IAM impersonation for local dev | `dispatcher_impersonators` variable | Same team list |

---

## What's New (not in sig-lake-light-house)

- GKE Autopilot cluster (sig-lake-light-house is pure Cloud Run)
- Workload Identity Federation for K8s pods
- envbuilder → Artifact Registry cache (replaces local registry)
- CRD deployment pipeline (kubebuilder manifests → GKE)
- Per-task namespace lifecycle on a real cluster
- Cloud NAT for predictable egress IPs

---

## Suggested Execution Order

1. **Terraform bootstrap** — GCS state bucket, enable APIs
2. **Artifact Registry** — operator image repo + devcontainer cache repo
3. **GKE Autopilot cluster** — with Workload Identity enabled
4. **Secret Manager** — GitHub App + Anthropic key
5. **Service accounts + IAM** — operator-sa, cicd-sa, Workload Identity bindings
6. **CI/CD workflow** — build & deploy operator to GKE
7. **Cloud Run broadcaster** — webhook ingress → Pub/Sub
8. **Operator adaptation** — read secrets from SM, use AR for cache, Pub/Sub subscription for events
9. **NetworkPolicy + egress** — validate on Autopilot
10. **Multi-repo config** — repo registry, per-repo isolation

---

## Cost Estimate (ballpark)

| Resource | Monthly cost (low usage) |
|----------|------------------------|
| GKE Autopilot (idle) | ~$70 (cluster management fee) |
| Agent pods (10 tasks/day, 15 min avg) | ~$15-30 (pay-per-pod) |
| Cloud Run broadcaster + orchestrator | ~$5 (near-zero at low volume) |
| Artifact Registry | ~$1-5 (storage) |
| Cloud NAT | ~$5 + egress |
| Secret Manager | <$1 |
| **Total** | **~$100-120/month at low scale** |

The GKE management fee is the floor cost. If that's too steep for experimentation, an alternative is to run the operator on Cloud Run Jobs (loses CRD model but cheaper idle). Worth revisiting after validating the architecture works.

> Note: `europe-north1` pricing is comparable to `us-central1` for GKE and Cloud Run. Egress to GitHub/Anthropic (US-based APIs) adds marginal latency (~100ms) but no meaningful cost difference.

---

## Decisions (confirmed 2026-06-01)

1. **Separate GCP project** — own project, not shared with sig-lake-light-house. Cleaner for multi-tenant instancing and billing isolation.
2. **Region: `europe-north1`** — lower latency, data stays in EU.
3. **Separate GitHub App** — different permissions profile from sig-lake-light-house (this one needs Contents RW on arbitrary repos).
4. **Shared Anthropic API key** — single key for now, track usage via request metadata (user-id / repo headers). Revisit per-repo keys if cost attribution becomes important.
