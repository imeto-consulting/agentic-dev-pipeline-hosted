# Aider agent image for the agentic dev pipeline.
# Talks to an in-cluster vLLM server (OpenAI-compatible) instead of a cloud API.
#
# Build: docker build -f deploy/agent/Dockerfile -t aider-agent:latest deploy/agent/
FROM python:3.12-slim

# System deps: git for repo ops, gh CLI for GitHub API, jq for JSON parsing
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    jq \
    openssh-client \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install aider (latest stable)
RUN pip install --no-cache-dir aider-chat

# Create non-root user (matches the operator's RunAsUser: 1000)
RUN groupadd -g 1000 agent && useradd -u 1000 -g agent -m -s /bin/bash agent

USER agent
WORKDIR /home/agent

# Aider config: disable analytics, auto-commits (we handle git ourselves)
RUN mkdir -p /home/agent/.config/aider && \
    echo "analytics: false" > /home/agent/.config/aider/aider.conf.yml && \
    echo "auto-commits: false" >> /home/agent/.config/aider/aider.conf.yml && \
    echo "git: true" >> /home/agent/.config/aider/aider.conf.yml

ENTRYPOINT ["/bin/bash"]
