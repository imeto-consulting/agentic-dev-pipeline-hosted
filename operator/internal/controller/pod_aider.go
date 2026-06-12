/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package controller

import (
	"fmt"
	"os"
	"strings"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	devpipelinev1alpha1 "github.com/jonaseck2/agentic-dev-pipeline/operator/api/v1alpha1"
)

// agentBackend returns "aider" or "claude" depending on AGENT_BACKEND env var.
// Default is "claude" for backward compat — set AGENT_BACKEND=aider to use the
// self-hosted LLM path.
func agentBackend() string {
	if v := os.Getenv("AGENT_BACKEND"); v != "" {
		return strings.ToLower(v)
	}
	return "claude"
}

// inferenceEndpoint returns the in-cluster vLLM endpoint URL.
func inferenceEndpoint() string {
	if v := os.Getenv("INFERENCE_ENDPOINT"); v != "" {
		return v
	}
	return "http://llm-api.llm-inference.svc.cluster.local:8000/v1"
}

// inferenceModel returns the model name to pass to aider's --model flag.
func inferenceModel() string {
	if v := os.Getenv("INFERENCE_MODEL"); v != "" {
		return v
	}
	return "openai/qwen3-32b-awq"
}

// aiderAgentImage returns the image to use for aider-based agent pods.
func aiderAgentImage() string {
	if v := os.Getenv("AIDER_AGENT_IMAGE"); v != "" {
		return v
	}
	return "localhost:5000/aider-agent:latest"
}

// buildAiderScript generates the wrapper script for an aider-based agent run.
// Unlike claude -p which handles everything autonomously, aider needs a wrapper
// that orchestrates: clone → branch → read issue → run aider → commit → push → PR.
func buildAiderScript(task *devpipelinev1alpha1.DevTask) string {
	repo := repoName(task.Spec.Repo)
	return fmt.Sprintf(`#!/bin/bash
set -e
export HOME=/home/agent

# ── Git credentials ──────────────────────────────────────────────────────────
git config --global credential.helper store
echo "https://x-access-token:${GITHUB_PERSONAL_ACCESS_TOKEN}@github.com" > /home/agent/.git-credentials
git config --global --add safe.directory /workspaces/%[1]s
git config --global user.name "${GIT_AUTHOR_NAME}"
git config --global user.email "${GIT_AUTHOR_EMAIL}"

# ── Clone ────────────────────────────────────────────────────────────────────
git clone https://github.com/%[2]s /workspaces/%[1]s
cd /workspaces/%[1]s

# ── Branch (reuse existing or create new) ────────────────────────────────────
EXISTING_BRANCH=$(git ls-remote --heads origin "claude/issue-%[3]d" "claude/issue-%[3]d-*" 2>/dev/null | head -1 | awk '{print $2}' | sed 's|refs/heads/||')
if [ -n "$EXISTING_BRANCH" ]; then
  git checkout "$EXISTING_BRANCH"
else
  SLUG=$(gh issue view %[3]d -R %[2]s --json title --jq '.title | ascii_downcase | gsub("[^a-z0-9]+"; "-") | ltrimstr("-") | rtrimstr("-") | .[0:40]')
  git checkout -b "claude/issue-%[3]d-${SLUG}"
fi

# ── Read issue ───────────────────────────────────────────────────────────────
ISSUE_BODY=$(gh issue view %[3]d -R %[2]s --json title,body --jq '"# " + .title + "\n\n" + .body')

# ── Run aider ────────────────────────────────────────────────────────────────
# Aider edits files based on the issue description. We add all tracked files
# so aider has full context, then let it decide which to modify.
aider \
  --model "${AIDER_MODEL}" \
  --openai-api-base "${OPENAI_API_BASE}" \
  --openai-api-key "not-needed" \
  --no-auto-commits \
  --yes \
  --no-suggest-shell-commands \
  --message "You are working on GitHub issue #%[3]d. Implement the fix described below. Make all necessary file changes.\n\n${ISSUE_BODY}"

# ── Commit + push + PR ──────────────────────────────────────────────────────
git add -A
if git diff --cached --quiet; then
  echo "No changes made by aider — exiting"
  exit 1
fi

git commit -s -m "fix: implement issue #%[3]d" -m "Closes #%[3]d" -m "Changes applied by aider agent using self-hosted LLM"
git push -u origin HEAD

# Create PR if one doesn't already exist for this branch
EXISTING_PR=$(gh pr list -R %[2]s --head "$(git branch --show-current)" --json number --jq '.[0].number // empty')
if [ -z "$EXISTING_PR" ]; then
  gh pr create --base main --fill-first
fi
`, repo, task.Spec.Repo, task.Spec.IssueNumber)
}

// buildAiderRevisionScript generates the wrapper for addressing PR review feedback.
func buildAiderRevisionScript(task *devpipelinev1alpha1.DevTask) string {
	repo := repoName(task.Spec.Repo)
	return fmt.Sprintf(`#!/bin/bash
set -e
export HOME=/home/agent

# ── Git credentials ──────────────────────────────────────────────────────────
git config --global credential.helper store
echo "https://x-access-token:${GITHUB_PERSONAL_ACCESS_TOKEN}@github.com" > /home/agent/.git-credentials
git config --global --add safe.directory /workspaces/%[1]s
git config --global user.name "${GIT_AUTHOR_NAME}"
git config --global user.email "${GIT_AUTHOR_EMAIL}"

# ── Clone + checkout PR branch ───────────────────────────────────────────────
git clone https://github.com/%[2]s /workspaces/%[1]s
cd /workspaces/%[1]s
git checkout "$(gh pr view %[4]d -R %[2]s --json headRefName --jq .headRefName)"

# ── Read review feedback ─────────────────────────────────────────────────────
REVIEW_BODY=$(gh pr view %[4]d -R %[2]s --json reviews,comments --jq '{reviews: [.reviews[] | {author: .author.login, body: .body, state: .state}], comments: [.comments[] | {author: .author.login, body: .body}]}')

# ── Run aider with review context ───────────────────────────────────────────
aider \
  --model "${AIDER_MODEL}" \
  --openai-api-base "${OPENAI_API_BASE}" \
  --openai-api-key "not-needed" \
  --no-auto-commits \
  --yes \
  --no-suggest-shell-commands \
  --message "You are addressing PR review feedback on PR #%[4]d for issue #%[3]d. Make ALL requested changes.\n\nReview feedback:\n${REVIEW_BODY}"

# ── Commit + push ────────────────────────────────────────────────────────────
git add -A
if git diff --cached --quiet; then
  echo "No changes from review — exiting"
  exit 0
fi

git commit -s -m "fix: address review feedback" -m "Refs #%[3]d" -m "Review feedback addressed by aider agent"
git push --force-with-lease
`, repo, task.Spec.Repo, task.Spec.IssueNumber, task.Status.PRNumber)
}

// agentPodAider creates an agent pod that uses aider + self-hosted LLM
// instead of claude -p + Anthropic API.
func agentPodAider(task *devpipelinev1alpha1.DevTask) *corev1.Pod {
	ns := taskNamespace(task)
	runScript := buildAiderScript(task)

	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      agentPodName,
			Namespace: ns,
			Labels:    map[string]string{"devpipeline.local/task": task.Name},
		},
		Spec: corev1.PodSpec{
			RestartPolicy:         corev1.RestartPolicyNever,
			ActiveDeadlineSeconds: int64Ptr(3600), // Aider + self-hosted LLM is slower
			SecurityContext: &corev1.PodSecurityContext{
				RunAsUser:    int64Ptr(1000),
				RunAsGroup:   int64Ptr(1000),
				FSGroup:      int64Ptr(1000),
				RunAsNonRoot: boolPtr(true),
				SeccompProfile: &corev1.SeccompProfile{
					Type: corev1.SeccompProfileTypeRuntimeDefault,
				},
			},
			InitContainers: []corev1.Container{{
				Name:    "write-script",
				Image:   "busybox",
				Command: []string{"sh", "-c", "printf '%s' \"$SCRIPT\" > /tmp/run-agent.sh && chmod +x /tmp/run-agent.sh"},
				Env:     []corev1.EnvVar{{Name: "SCRIPT", Value: runScript}},
				SecurityContext: &corev1.SecurityContext{
					AllowPrivilegeEscalation: boolPtr(false),
					ReadOnlyRootFilesystem:   boolPtr(true),
					Capabilities:             &corev1.Capabilities{Drop: []corev1.Capability{"ALL"}},
				},
				VolumeMounts: []corev1.VolumeMount{
					{Name: "tmp", MountPath: "/tmp"},
				},
			}},
			Containers: []corev1.Container{{
				Name:    "agent",
				Image:   aiderAgentImage(),
				Command: []string{"/bin/bash", "/tmp/run-agent.sh"},
				SecurityContext: &corev1.SecurityContext{
					AllowPrivilegeEscalation: boolPtr(false),
					Capabilities:             &corev1.Capabilities{Drop: []corev1.Capability{"ALL"}},
				},
				Resources: corev1.ResourceRequirements{
					Requests: corev1.ResourceList{
						corev1.ResourceMemory: resource.MustParse("512Mi"),
					},
				},
				Env: []corev1.EnvVar{
					{Name: "GITHUB_PERSONAL_ACCESS_TOKEN", ValueFrom: secretRef(task, "github-token")},
					{Name: "GITHUB_TOKEN", ValueFrom: secretRef(task, "github-token")},
					{Name: "GIT_AUTHOR_NAME", ValueFrom: secretRef(task, "git-author-name")},
					{Name: "GIT_AUTHOR_EMAIL", ValueFrom: secretRef(task, "git-author-email")},
					{Name: "GIT_COMMITTER_NAME", ValueFrom: secretRef(task, "git-author-name")},
					{Name: "GIT_COMMITTER_EMAIL", ValueFrom: secretRef(task, "git-author-email")},
					// vLLM endpoint — aider speaks OpenAI-compatible API
					{Name: "OPENAI_API_BASE", Value: inferenceEndpoint()},
					{Name: "OPENAI_API_KEY", Value: "not-needed"},
					{Name: "AIDER_MODEL", Value: inferenceModel()},
				},
				VolumeMounts: []corev1.VolumeMount{
					{Name: "workdir", MountPath: "/workspaces"},
					{Name: "tmp", MountPath: "/tmp"},
					{Name: "home", MountPath: "/home/agent"},
				},
			}},
			Volumes: []corev1.Volume{
				{Name: "workdir", VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}},
				{Name: "tmp", VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}},
				{Name: "home", VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}},
			},
		},
	}
}

// agentPodAiderRevision creates an agent pod for addressing PR review feedback.
func agentPodAiderRevision(task *devpipelinev1alpha1.DevTask) *corev1.Pod {
	pod := agentPodAider(task)
	pod.Name = "agent-rev"
	pod.Spec.InitContainers[0].Env[0].Value = buildAiderRevisionScript(task)
	return pod
}
