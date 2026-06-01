# Hosting the maintainer on GCP (GKE)

This provisions the GCP infrastructure that hosts the agentic dev pipeline as a
long-running maintainer, plus the GitHub Actions that deploy it.

The runtime is faithful to the local POC: the Go operator, `DevTask` CRD, triage
CronJob, envbuilder, and the NetworkPolicy sandbox all run **in-cluster** on GKE
instead of on a laptop against k3d.

> **Two deployment paths, one repo.** This `gke/` tree is the GKE topology. The
> Cloud Run topology lives alongside under `infra/terraform/cloudrun/` with its
> own `cloudrun-*` workflows. They target **separate GCP projects** and separate
> state buckets / CI service accounts — nothing is shared, so the two can be
> developed and deployed independently.

```
infra/terraform/gke/bootstrap   run once, locally → GCS state bucket + CI service account
infra/terraform/gke/            APIs, VPC, GKE Standard (Dataplane V2 + Workload Identity),
                                Artifact Registry, IAM
.github/workflows/
  gke-terraform-ci.yml          plan on PR (comments the plan)
  gke-terraform-cd.yml          apply on merge to main
  gke-deploy-maintainer.yml     parameterized: build/push operator image, deploy operator +
                                triage, write credential Secrets, build devcontainer, configure
```

## Cluster shape

**GKE Standard, zonal, single node pool, private nodes, Dataplane V2** in
`europe-north1` (zone `europe-north1-b`). Standard (not Autopilot) keeps
envbuilder — which builds container images inside a pod and needs root —
reliable. **Zonal** (not regional) keeps it to a single node; the only cost is
brief control-plane API downtime during upgrades, which a poll-based maintainer
tolerates. **Private nodes** have no public IPs and egress through **Cloud NAT**;
the control-plane endpoint stays public-but-credential-gated so GitHub Actions +
kubectl can reach the API (a fully private endpoint would need a bastion/VPN and
break the deploy workflow). Dataplane V2 enforces the egress NetworkPolicy that
is the sandbox's real security boundary. Est. ~$60–75/mo (one node + Cloud NAT +
free cluster-management tier) plus per-task usage.

## One-time bootstrap

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project YOUR_PROJECT

# 0. Enable the APIs bootstrap itself needs (root TF enables the rest)
gcloud services enable \
  cloudresourcemanager.googleapis.com iam.googleapis.com storage.googleapis.com

# 1. State bucket + CI service account (local state)
cd infra/terraform/gke/bootstrap
terraform init
terraform apply -var="project_id=YOUR_PROJECT"

# 2. Mint a JSON key for the CI SA and store it as the GKE_GCP_SA_KEY GitHub secret
gcloud iam service-accounts keys create key.json \
  --iam-account=github-actions@YOUR_PROJECT.iam.gserviceaccount.com
gh secret set GKE_GCP_SA_KEY < key.json && rm key.json
```

Then set the remaining GitHub **repo secrets**. They're `GKE_`-prefixed so the
Cloud Run path (which uses `CLOUDRUN_`-prefixed secrets for its own project) can
coexist in this repo without collision:

| Secret | Value |
|---|---|
| `GKE_GCP_SA_KEY` | CI service-account JSON key (above) |
| `GKE_GCP_PROJECT_ID` | your GKE GCP project ID |
| `GKE_GCP_CICD_SA_EMAIL` | `github-actions@YOUR_PROJECT.iam.gserviceaccount.com` (bootstrap `ci_service_account_email`) |
| `GKE_TF_STATE_BUCKET` | `YOUR_PROJECT-adp-tfstate` (bootstrap `tfstate_bucket`) |

## Provision infrastructure

> **Run the first apply manually.** The minimal bootstrap grants the CI SA only
> state-bucket access. The root apply creates a VPC, GKE, Artifact Registry,
> service accounts, and project IAM bindings — which need broad admin roles. Run
> the first `terraform apply` as a project Owner (below). Before relying on
> `gke-terraform-cd.yml` for unattended applies, grant the CI SA the matching
> roles (`serviceusage.serviceUsageAdmin`, `compute.networkAdmin`,
> `container.admin`, `artifactregistry.admin`, `iam.serviceAccountAdmin`,
> `resourcemanager.projectIamAdmin`) — or keep applying manually.

```bash
cd infra/terraform/gke
terraform init -backend-config="bucket=YOUR_PROJECT-adp-tfstate"
terraform apply \
  -var="project_id=YOUR_PROJECT" \
  -var="cicd_sa_email=github-actions@YOUR_PROJECT.iam.gserviceaccount.com"
```

This creates the GKE cluster, Artifact Registry, IAM, and the envbuilder
Workload Identity binding. `gke-terraform-cd.yml` re-applies on merges to `main`
that touch `infra/terraform/gke/**` (once the CI SA has the roles above).

## Deploy the maintainer at a repo

Run the **GKE · Deploy maintainer** workflow (`workflow_dispatch`) with inputs:

- `target_repo` — `owner/name` to maintain
- `claude_auth_mode` — `oauth` (subscription) or `api`
- `claude_token` — matching token
- `github_token` — fine-grained PAT for the target repo
- `git_author_name` / `git_author_email` — commit identity

It builds and pushes the operator image, deploys the CRD + operator (into
`devpipeline-system`) + triage CronJob, writes the `pipeline-creds` Secrets from
the inputs, runs the in-cluster envbuilder Job to build the target repo's
devcontainer into Artifact Registry, sets `PIPELINE_REPOS` / `AGENT_IMAGE`, and
restarts the operator.

## Verify

```bash
gcloud container clusters get-credentials agentic-dev-pipeline --location europe-north1-b
kubectl get deploy -n devpipeline-system          # controller-manager Ready
kubectl get cronjob -n agentic-dev-pipeline-triage
kubectl get devtask -A                            # appears once an issue is labeled

# end to end: file a needs-triage issue on the target repo, then watch
kubectl get devtask -A --watch
```

> **Note:** region / zone / cluster name / Artifact Registry repo ID default to
> `europe-north1` / `europe-north1-b` / `agentic-dev-pipeline` /
> `agentic-dev-pipeline`. If you change the Terraform variables, update the
> matching `env:` block in `.github/workflows/gke-deploy-maintainer.yml`.
