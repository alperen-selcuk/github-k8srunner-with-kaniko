# ---- Stage 1: build kaniko executor from the maintained Chainguard fork ----
# Google archived GoogleContainerTools/kaniko in June 2025; the fork below is maintained
# by the original authors but publishes no images, so we build the binary ourselves.
ARG GO_VERSION=1.25
# Runs on the build machine's native platform and cross-compiles for the target (no emulation)
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION} AS kaniko
ARG KANIKO_VERSION=v1.25.12
ARG TARGETOS
ARG TARGETARCH
RUN git clone --depth 1 --branch "${KANIKO_VERSION}" https://github.com/chainguard-forks/kaniko.git /src
WORKDIR /src
RUN CGO_ENABLED=0 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" go build -trimpath \
      -ldflags "-s -w -X $(go list -m)/pkg/version.version=${KANIKO_VERSION}" \
      -o /out/executor ./cmd/executor

# ---- Stage 2: runner image ----
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Set automatically by BuildKit from --platform (amd64 | arm64); a default here would override it
ARG TARGETARCH
# Leave empty to use the latest release at build time
ARG RUNNER_VERSION=""
ARG KUBECTL_VERSION=""
ARG HELM_VERSION=v3.16.4

RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y -qq --no-install-recommends \
      ca-certificates \
      curl \
      git \
      iputils-ping \
      jq \
      unzip \
      wget && \
    rm -rf /var/lib/apt/lists/*

# Install GitHub Actions runner into /opt/actions-runner; start.sh copies it to the runner volume
RUN set -eux; \
    case "${TARGETARCH}" in amd64) arch=x64 ;; arm64) arch=arm64 ;; *) echo "unsupported arch ${TARGETARCH}"; exit 1 ;; esac; \
    v="${RUNNER_VERSION:-$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')}"; \
    mkdir -p /opt/actions-runner; \
    curl -fsSL "https://github.com/actions/runner/releases/download/v${v}/actions-runner-linux-${arch}-${v}.tar.gz" \
      | tar -xz -C /opt/actions-runner; \
    /opt/actions-runner/bin/installdependencies.sh; \
    rm -rf /var/lib/apt/lists/*

# Install kubectl (inside a pod it authenticates with the mounted ServiceAccount token)
RUN set -eux; \
    v="${KUBECTL_VERSION:-$(curl -fsSL https://dl.k8s.io/release/stable.txt)}"; \
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${v}/bin/linux/${TARGETARCH}/kubectl"; \
    curl -fsSL "https://dl.k8s.io/release/${v}/bin/linux/${TARGETARCH}/kubectl.sha256" -o /tmp/kubectl.sha256; \
    echo "$(cat /tmp/kubectl.sha256)  /usr/local/bin/kubectl" | sha256sum -c -; \
    chmod +x /usr/local/bin/kubectl; \
    rm /tmp/kubectl.sha256

# Install helm
RUN set -eux; \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" | tar -xz -C /tmp; \
    mv "/tmp/linux-${TARGETARCH}/helm" /usr/local/bin/helm; \
    rm -rf "/tmp/linux-${TARGETARCH}"; \
    kubectl version --client; helm version

# Kaniko
COPY --from=kaniko /out/executor /kaniko/executor
RUN mkdir -p /kaniko/.docker /kaniko/ssl/certs && \
    update-ca-certificates && \
    cat /etc/ssl/certs/*.crt > /kaniko/ssl/certs/ca-certificates.crt

ENV HOME=/root
ENV USER=root
ENV PATH="${PATH}:/kaniko"
ENV SSL_CERT_DIR=/kaniko/ssl/certs
ENV DOCKER_CONFIG=/kaniko/.docker/
# kaniko needs root; the runner refuses root unless this is set
ENV RUNNER_ALLOW_RUNASROOT=1
ENV ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=1

COPY ./start.sh /start.sh
RUN chmod +x /start.sh

ENTRYPOINT [ "/start.sh" ]
