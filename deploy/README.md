# Deployment Guide

Self-contained deployment of the Agentic Dev Pipeline on GKE.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ GKE Cluster (Dataplane V2 — enforces NetworkPolicy)             │
│                                                                 │
│  ┌──────────────────┐   ┌──────────────────────────────────┐   │
│  │ llm-inference    │   │ devpipeline-system               │   │
│  │  vLLM (L4 GPU)   │◄──│  controller-manager (operator)   │   │
│  │  Qwen3-14B-AWQ   │   │  pipeline-creds Secret           │   │
│  └───────▲──────────┘   └──────────────┬───────────────────┘   │
│          │                             │ creates per-issue      │
│          │                             ▼                        │
│  ┌───────┴──────────┐   ┌──────────────────────────────────┐   │
│  │ triage namespace │   │ devtask-N  (one per issue)       │   │
│  │  CronJob: triage │   │  agent pod (Aider + vLLM)        │   │
│  │  calls vLLM for  │   │  NetworkPolicy: DNS+443+8000     │   │
│  │  classification   │   └──────────────────────────────────┘   │
│  └──────────────────┘                                           │
└─────────────────────────────────────────────────────────────────┘
```

## Automated Deployment (Recommended)

Run the GitHub Actions workflow — it handles everything:

```
Actions → "GKE · Deploy maintainer" → Run workflow
```

Required inputs:
- `target_repo`: e.g. `imeto-consulting/sig-lake-light-house`
- `agent_backend`: `aider`
- `github_token`: Classic PAT with `repo` scope
- `git_author_name` / `git_author_email`: Git identity for commits

Required repository secrets:
- `GKE_GCP_SA_KEY`: GCP service account JSON key (CI SA from bootstrap)
- `GKE_GCP_PROJECT_ID`: GCP project ID

## Manual Deployment

### Prerequisites

- GKE cluster with Dataplane V2 (for NetworkPolicy enforcement)
- GPU node pool: `g2-standard-8` with NVIDIA L4 (24GB)
- Artifact Registry repository
- `kubectl`, `docker`, `gcloud` CLI tools

### 1. Build & push images

```bash
# Set your registry
AR="europe-west4-docker.pkg.dev/YOUR_PROJECT/YOUR_REPO"

# Operator
docker build operator/ --platform linux/amd64 -t ${AR}/operator:latest
docker push ${AR}/operator:latest

# Aider agent
docker build deploy/agent/ --platform linux/amd64 -t ${AR}/aider-agent:latest
docker push ${AR}/aider-agent:latest

# Triage agent
docker build deploy/triage/ --platform linux/amd64 -t ${AR}/triage-agent:latest
docker push ${AR}/triage-agent:latest
```

### 2. Deploy inference (vLLM)

```bash
kubectl apply -k deploy/inference
# Wait for model download + load (~5-10 min on first deploy)
kubectl rollout status deployment/vllm -n llm-inference --timeout=900s
```

### 3. Deploy namespaces and triage

```bash
kubectl apply -f deploy/system/namespace.yaml
kubectl apply -f deploy/triage/namespace.yaml
kubectl apply -f deploy/triage/networkpolicy.yaml
kubectl apply -f deploy/triage/rbac.yaml
kubectl apply -f deploy/triage/configmap-prompt.yaml
kubectl apply -f deploy/triage/cronjob.yaml
```

### 4. Create secrets

```bash
# devpipeline-system: operator reads these and copies to agent pods
kubectl create secret generic pipeline-creds \
  --namespace devpipeline-system \
  --from-literal=github-token="YOUR_GITHUB_PAT" \
  --from-literal=git-author-name="Agentic Dev Pipeline" \
  --from-literal=git-author-email="bot@example.com" \
  --from-literal=claude-token="unused" \
  --from-literal=claude-auth-mode="api"

# triage namespace: needs github token for gh CLI
kubectl create secret generic pipeline-creds \
  --namespace agentic-dev-pipeline-triage \
  --from-literal=github-token="YOUR_GITHUB_PAT" \
  --from-literal=claude-token="unused" \
  --from-literal=claude-auth-mode="api"
```

### 5. Deploy operator

```bash
# Set image in kustomization
cd deploy/operator
kustomize edit set image controller=${AR}/operator:latest
cd ../..

kubectl apply -k deploy/operator

# Configure runtime env
kubectl set env deployment/controller-manager -n devpipeline-system \
  PIPELINE_REPOS="owner/repo" \
  AGENT_BACKEND="aider" \
  AIDER_AGENT_IMAGE="${AR}/aider-agent:latest" \
  INFERENCE_ENDPOINT="http://llm-api.llm-inference.svc.cluster.local:8000/v1" \
  INFERENCE_MODEL="openai/Qwen/Qwen3-14B-AWQ"
```

### 6. Verify

```bash
# Operator running and polling
kubectl logs deployment/controller-manager -n devpipeline-system --tail=5

# Triage CronJob scheduled
kubectl get cronjob -n agentic-dev-pipeline-triage

# vLLM responding
kubectl exec -n devpipeline-system deployment/controller-manager -- \
  wget -qO- http://llm-api.llm-inference.svc.cluster.local:8000/v1/models
```

## How it works (end-to-end flow)

1. Create a GitHub issue with label `needs-triage`
2. **Triage CronJob** (every 5 min) reads issue → calls vLLM → labels `ready-for-development`
3. **Operator poller** (every 30s) sees label → creates `DevTask` CR
4. **DevTask reconcile** → creates `devtask-N` namespace → NetworkPolicy → agent pod
5. **Agent pod** (Aider) → clones repo → calls vLLM → generates code → pushes branch → creates PR
6. DevTask transitions to `Completed` with PR number

## Secrets Reference

| Secret | Namespace | Key | Purpose |
|--------|-----------|-----|---------|
| `pipeline-creds` | `devpipeline-system` | `github-token` | PAT with `repo` scope for PR creation |
| `pipeline-creds` | `devpipeline-system` | `git-author-name` | Commit author name |
| `pipeline-creds` | `devpipeline-system` | `git-author-email` | Commit author email |
| `pipeline-creds` | `devpipeline-system` | `claude-token` | Unused for aider backend |
| `pipeline-creds` | `devpipeline-system` | `claude-auth-mode` | `api` (unused for aider) |
| `pipeline-creds` | `agentic-dev-pipeline-triage` | `github-token` | Same PAT for triage `gh` CLI |
| `inference-creds` | `llm-inference` | `hf-token` | (Optional) HuggingFace token for gated models |

## NetworkPolicy Design

- **Agent pods** (`devtask-N`): DNS (53) + HTTPS (443) + vLLM (8000 to `llm-inference`)
- **Triage pods**: DNS (53) + HTTPS (443) + vLLM (8000 to `llm-inference`)
- **vLLM ingress**: Only accepts from namespaces with `part-of: agentic-dev-pipeline`, `devpipeline-system`, or `agentic-dev-pipeline-triage`
- All other traffic is denied (Dataplane V2 / Calico enforcement)

## Changing the model

1. Edit `deploy/inference/deployment.yaml` (model name, quantization, context length)
2. Update `deploy/triage/cronjob.yaml` `INFERENCE_MODEL` env var
3. Update `operator/config/manager/manager.yaml` `INFERENCE_MODEL` env var
4. Rebuild + push operator image
5. Redeploy: `kubectl apply -k deploy/inference && kubectl apply -k deploy/operator`
