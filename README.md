# Agentic Development Pipeline — POC

Claude as maintainer of [`slaktforskning`](https://github.com/jonaseck2/slaktforskning), running on a local k3d cluster.

File an issue → triage agent writes an implementation plan → implementation agent opens a PR → merge → namespace cleaned up. No manual steps between filing and reviewing.

## Bring-up (one-time)

**Prerequisites:** `brew install k3d kubectl kubebuilder helm go gh`

```bash
# 1. Create cluster with Calico
make cluster

# 2. Install CRDs and pipeline components
make install

# 3. Set credentials
export GITHUB_TOKEN=<fine-grained-PAT-for-slaktforskning>
export CLAUDE_TOKEN=<claude-code-oauth-token>
export GIT_AUTHOR_NAME="Your Name"
export GIT_AUTHOR_EMAIL="you@example.com"
make secrets
```

The fine-grained PAT needs: Contents Read+Write, Issues Read+Write, Pull Requests Read+Write.

## Running the operator

```bash
make run
```

Runs the operator locally against the cluster. Leave this terminal open.

## Demo

```bash
make demo
```

Files a real issue with `needs-triage` label. The triage CronJob picks it up within 5 minutes, writes an implementation plan, and applies `ready-for-development`. The operator detects the label within 30 seconds and starts an agent pod to implement it.

## Manual triage trigger

```bash
kubectl create job --from=cronjob/triage-agent triage-manual \
  -n agentic-dev-pipeline-triage
kubectl logs -n agentic-dev-pipeline-triage job/triage-manual --follow
```

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) and [docs/plans/ROADMAP.md](docs/plans/ROADMAP.md).
