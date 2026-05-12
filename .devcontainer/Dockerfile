# syntax=docker/dockerfile:1.7
# Devcontainer for homelab — pinned toolchain + Claude Code.
# Renovate updates ARG pins via inline `# renovate:` annotations.

# ---------- stage: build terraform-mcp-server from source ----------
# Distributed only as a Docker image upstream, so we build the Go binary
# in an ephemeral stage and copy it into the final image.
# renovate: datasource=docker depName=golang versioning=docker
ARG GO_BUILD_IMAGE=golang:1.26-bookworm
FROM ${GO_BUILD_IMAGE} AS terraform-mcp-build
# renovate: datasource=github-releases depName=hashicorp/terraform-mcp-server
ARG TERRAFORM_MCP_VERSION=v0.5.2
RUN git clone --depth 1 --branch ${TERRAFORM_MCP_VERSION} \
      https://github.com/hashicorp/terraform-mcp-server.git /src \
 && cd /src \
 && CGO_ENABLED=0 go build -ldflags="-s -w" \
      -o /out/terraform-mcp-server ./cmd/terraform-mcp-server

# ---------- final image ----------
FROM mcr.microsoft.com/devcontainers/base:bookworm

# renovate: datasource=github-releases depName=kubernetes/kubernetes
ARG KUBECTL_VERSION=v1.31.4
# renovate: datasource=github-releases depName=helm/helm
ARG HELM_VERSION=v3.16.4
# renovate: datasource=github-releases depName=siderolabs/talos
ARG TALOSCTL_VERSION=v1.9.1
# renovate: datasource=github-releases depName=hashicorp/terraform
ARG TERRAFORM_VERSION=1.10.0
# renovate: datasource=github-releases depName=hashicorp/vault
ARG VAULT_VERSION=1.20.4
# renovate: datasource=github-releases depName=argoproj/argo-cd
ARG ARGOCD_VERSION=v3.1.9
# renovate: datasource=github-releases depName=gitleaks/gitleaks
ARG GITLEAKS_VERSION=v8.30.1
# renovate: datasource=github-releases depName=cli/cli
ARG GH_VERSION=2.92.0
# renovate: datasource=pypi depName=pre-commit
ARG PRE_COMMIT_VERSION=4.0.1
# renovate: datasource=npm depName=@anthropic-ai/claude-code
ARG CLAUDE_CODE_VERSION=latest

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg unzip wget less \
      git openssh-client \
      jq yamllint \
      python3 python3-yaml python3-pip \
      postgresql-client \
      zsh age \
 && rm -rf /var/lib/apt/lists/* \
 && chsh -s /usr/bin/zsh vscode

# Node.js 22 (Nodesource) — required by npx-based MCP servers and claude-code
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
 && npm cache clean --force

# kubectl
RUN arch="$(dpkg --print-architecture)" \
 && curl -fsSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" \
 && chmod +x /usr/local/bin/kubectl

# helm
RUN arch="$(dpkg --print-architecture)" \
 && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz" \
      | tar -xz -C /tmp \
 && install -m 0755 "/tmp/linux-${arch}/helm" /usr/local/bin/helm \
 && rm -rf "/tmp/linux-${arch}"

# talosctl
RUN arch="$(dpkg --print-architecture)" \
 && curl -fsSL -o /usr/local/bin/talosctl \
      "https://github.com/siderolabs/talos/releases/download/${TALOSCTL_VERSION}/talosctl-linux-${arch}" \
 && chmod +x /usr/local/bin/talosctl

# terraform — zip ships LICENSE.txt next to binary; extract only the binary
# so successive HashiCorp installs don't fight over LICENSE.txt in /usr/local/bin.
RUN arch="$(dpkg --print-architecture)" \
 && curl -fsSL -o /tmp/terraform.zip \
      "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${arch}.zip" \
 && unzip -j -o /tmp/terraform.zip terraform -d /usr/local/bin \
 && chmod +x /usr/local/bin/terraform \
 && rm /tmp/terraform.zip

# vault — same LICENSE.txt collision; extract only the binary.
RUN arch="$(dpkg --print-architecture)" \
 && curl -fsSL -o /tmp/vault.zip \
      "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_${arch}.zip" \
 && unzip -j -o /tmp/vault.zip vault -d /usr/local/bin \
 && chmod +x /usr/local/bin/vault \
 && rm /tmp/vault.zip

# argocd
RUN arch="$(dpkg --print-architecture)" \
 && curl -fsSL -o /usr/local/bin/argocd \
      "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-${arch}" \
 && chmod +x /usr/local/bin/argocd

# gitleaks
RUN arch="$(dpkg --print-architecture)" \
 && case "${arch}" in \
      amd64) gl_arch="x64" ;; \
      arm64) gl_arch="arm64" ;; \
      *) echo "unsupported arch: ${arch}"; exit 1 ;; \
    esac \
 && version_stripped="${GITLEAKS_VERSION#v}" \
 && curl -fsSL -o /tmp/gitleaks.tgz \
      "https://github.com/gitleaks/gitleaks/releases/download/${GITLEAKS_VERSION}/gitleaks_${version_stripped}_linux_${gl_arch}.tar.gz" \
 && tar -xzf /tmp/gitleaks.tgz -C /tmp gitleaks \
 && install -m 0755 /tmp/gitleaks /usr/local/bin/gitleaks \
 && rm /tmp/gitleaks.tgz /tmp/gitleaks

# gh CLI
RUN arch="$(dpkg --print-architecture)" \
 && curl -fsSL -o /tmp/gh.tgz \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${arch}.tar.gz" \
 && tar -xzf /tmp/gh.tgz -C /tmp \
 && install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${arch}/bin/gh" /usr/local/bin/gh \
 && rm -rf /tmp/gh.tgz "/tmp/gh_${GH_VERSION}_linux_${arch}"

# terraform-mcp-server (from build stage above)
COPY --from=terraform-mcp-build /out/terraform-mcp-server /usr/local/bin/terraform-mcp-server

# pre-commit (pip; --break-system-packages because Debian PEP-668)
RUN pip install --no-cache-dir --break-system-packages \
      "pre-commit==${PRE_COMMIT_VERSION}"

# chezmoi (dotfiles manager) — installed from upstream script to /usr/local/bin
RUN sh -c "$(curl -fsLS get.chezmoi.io)" -- -b /usr/local/bin

USER vscode
WORKDIR /workspaces/homelab
