#!/bin/bash
set -euo pipefail

# This script provisions ONLY the resources required for the v2 application.
# It intentionally avoids stopping/removing the shared Jenkins container or the
# v1 application so both pipelines can share the same Jenkins+ngrok endpoint.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NETWORK_NAME="${NETWORK_NAME:-mlops-net}"
APP_NAME="${APP_NAME:-data-cleaner-v2}"
APP_IMAGE="${APP_IMAGE:-${APP_NAME}:local}"
APP_CONTAINER="${APP_CONTAINER:-${APP_NAME}}"
APP_PORT="${APP_PORT:-8001}"          # host port dedicated to the v2 service
JENKINS_CONTAINER="${JENKINS_CONTAINER:-jenkins}"

log() {
  echo "==== $1 ===="
}

ensure_docker() {
  if docker info >/dev/null 2>&1; then
    return
  fi

  log "Docker daemon not reachable. Launching Docker Desktop..."
  if command -v open >/dev/null 2>&1; then
    open -a Docker || true
  fi

  until docker info >/dev/null 2>&1; do
    sleep 2
    echo "Waiting for Docker to start..."
  done
  log "Docker is ready."
}

ensure_network() {
  if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
    log "Docker network ${NETWORK_NAME} already exists."
  else
    log "Creating docker network ${NETWORK_NAME}"
    docker network create "${NETWORK_NAME}"
  fi
}

build_v2_image() {
  log "Building ${APP_IMAGE} from ${REPO_ROOT}/version2"
  docker build -t "${APP_IMAGE}" "${REPO_ROOT}/version2"
}

deploy_v2_container() {
  if docker ps -a --format '{{.Names}}' | grep -qx "${APP_CONTAINER}"; then
    log "Removing existing container ${APP_CONTAINER} to redeploy v2 app"
    docker rm -f "${APP_CONTAINER}"
  fi

  log "Starting ${APP_CONTAINER} on port ${APP_PORT}"
  docker run -d --name "${APP_CONTAINER}" \
    --network "${NETWORK_NAME}" \
    -p "${APP_PORT}:8000" \
    "${APP_IMAGE}"
}

patch_jenkins_network() {
  if docker ps --format '{{.Names}}' | grep -qx "${JENKINS_CONTAINER}"; then
    log "Jenkins container (${JENKINS_CONTAINER}) detected. Ensuring it is connected to ${NETWORK_NAME}"
    docker network connect "${NETWORK_NAME}" "${JENKINS_CONTAINER}" 2>/dev/null || true
  else
    log "Jenkins container (${JENKINS_CONTAINER}) not running. Skipping Jenkins setup."
  fi
}

ensure_jenkins_python_tools() {
  if ! docker ps --format '{{.Names}}' | grep -qx "${JENKINS_CONTAINER}"; then
    log "Jenkins container (${JENKINS_CONTAINER}) not running. Skipping python-venv install."
    return
  fi

  log "Ensuring python3 + venv tooling is present inside ${JENKINS_CONTAINER}"
  docker exec -u root "${JENKINS_CONTAINER}" bash -lc "
    set -e
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv python3-pip
  "
}

ensure_jenkins_docker_access() {
  if ! docker ps --format '{{.Names}}' | grep -qx "${JENKINS_CONTAINER}"; then
    log "Jenkins container (${JENKINS_CONTAINER}) not running. Skipping docker CLI install."
    return
  fi

  log "Installing docker CLI and wiring permissions inside ${JENKINS_CONTAINER}"
  docker exec -u root "${JENKINS_CONTAINER}" bash -lc "
    set -e
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
    groupadd -f docker
    usermod -aG docker jenkins
    chgrp docker /var/run/docker.sock || true
    chmod g+rw /var/run/docker.sock || true
  "

  log "Restarting ${JENKINS_CONTAINER} to pick up docker group membership"
  docker restart "${JENKINS_CONTAINER}"
}

ensure_jenkins_kubectl() {
  if ! docker ps --format '{{.Names}}' | grep -qx "${JENKINS_CONTAINER}"; then
    log "Jenkins container (${JENKINS_CONTAINER}) not running. Skipping kubectl install."
    return
  fi

  log "Installing kubectl CLI inside ${JENKINS_CONTAINER}"
  docker exec -u root "${JENKINS_CONTAINER}" bash -lc "
    set -e
    apt-get update
    apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    sed -i '/kubernetes/d' /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources || true
    rm -f /etc/apt/sources.list.d/kubernetes.list
    rm -f /etc/apt/keyrings/kubernetes-archive-keyring.gpg /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo \"deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /\" > /etc/apt/sources.list.d/kubernetes.list
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y kubectl
  "
}

verify_app() {
  log "Current v2 container status"
  docker ps --filter "name=${APP_CONTAINER}"

  local health_url="http://localhost:${APP_PORT}/health"
  log "Attempting health check on ${health_url}"
  for attempt in {1..10}; do
    if curl -fsS "${health_url}" >/dev/null; then
      log "Health check passed on attempt ${attempt}"
      return
    fi
    sleep 2
  done
  echo "Health check failed after multiple attempts; inspect logs with: docker logs ${APP_CONTAINER}"
}

main() {
  ensure_docker
  ensure_network
  build_v2_image
  deploy_v2_container
  patch_jenkins_network
  ensure_jenkins_python_tools
  ensure_jenkins_docker_access
  ensure_jenkins_kubectl
  verify_app

  log "Done. Jenkins + ngrok setup stays untouched; v2 app runs independently on port ${APP_PORT}."
}

main "$@"
