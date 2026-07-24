#!/usr/bin/env bash
# Verify the host or container side of the Isaac ROS Jazzy workspace.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: %s [--host|--container]\n' "$(basename "$0")" >&2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    die "required command is unavailable: $1"
}

require_file() {
  [[ -f "$1" ]] || die "required file is missing: $1"
}

require_text() {
  local file="$1"
  local expected="$2"

  grep -Fq -- "$expected" "$file" ||
    die "$(basename "$file") is missing required key: $expected"
}

require_materialized_model() {
  local model="$1"

  require_file "$model"
  [[ "$(wc -c < "$model")" -ge 1000 ]] ||
    die "model is not materialized: $model"
  [[ "$(head -n 1 "$model")" != \
    'version https://git-lfs.github.com/spec/v1' ]] ||
    die "model is still a Git LFS pointer: $model"
}

version_at_least() {
  local actual="$1"
  local required="$2"

  [[ "$(printf '%s\n%s\n' "$required" "$actual" | sort -V | head -n 1)" = \
    "$required" ]]
}

verify_host_prerequisites() {
  local cli_docker_dir=/etc/isaac-ros-cli/docker
  local cli_environment_file=/etc/isaac-ros-cli/environment.conf
  local driver_version
  local host_arch

  if [[ "${JAZZY_VERIFY_TEST_MODE:-0}" = 1 ]]; then
    host_arch="${JAZZY_VERIFY_TEST_ARCH:-}"
    driver_version="${JAZZY_VERIFY_TEST_DRIVER_VERSION:-}"
    cli_docker_dir="${JAZZY_VERIFY_TEST_CLI_DOCKER_DIR:-$cli_docker_dir}"
    cli_environment_file="${JAZZY_VERIFY_TEST_CLI_ENVIRONMENT_FILE:-$cli_environment_file}"
  else
    host_arch="$(uname -m)"
    require_command nvidia-smi
    if ! driver_version="$(
      nvidia-smi --query-gpu=driver_version --format=csv,noheader |
        head -n 1
    )"; then
      die 'unable to query the NVIDIA driver version'
    fi
  fi

  require_command isaac-ros
  [[ "$host_arch" = x86_64 ]] ||
    die "x86_64 architecture is required (current: ${host_arch:-unknown})"
  [[ -n "$driver_version" ]] && version_at_least "$driver_version" 580 ||
    die "NVIDIA driver 580 or newer is required (current: ${driver_version:-unknown})"
  [[ -d "$cli_docker_dir" ]] ||
    die "Isaac ROS CLI Docker system layer is missing: $cli_docker_dir (run: sudo isaac-ros init docker)"
  [[ -f "$cli_environment_file" ]] ||
    die "Isaac ROS CLI environment file is missing: $cli_environment_file (run: sudo isaac-ros init docker)"
  grep -qxF 'ISAAC_ROS_ENVIRONMENT=docker' "$cli_environment_file" ||
    die "Isaac ROS CLI is not initialized in Docker mode: $cli_environment_file (run: sudo isaac-ros init docker)"
}

resolve_host_workspace() {
  local requested="${ISAAC_ROS_WS:-${HOME}/workspaces/isaac_ros-dev}"

  [[ -d "$requested" ]] || die "workspace does not exist: $requested"
  ISAAC_ROS_WS="$(cd "$requested" && pwd -P)"
  export ISAAC_ROS_WS
}

resolve_container_workspace() {
  if [[ "${JAZZY_VERIFY_TEST_MODE:-0}" = 1 ]]; then
    ISAAC_ROS_WS="${JAZZY_VERIFY_TEST_WORKSPACE:?}"
  else
    ISAAC_ROS_WS=/workspaces/isaac_ros-dev
  fi

  [[ -d "$ISAAC_ROS_WS" ]] ||
    die "workspace does not exist: $ISAAC_ROS_WS"
  ISAAC_ROS_WS="$(cd "$ISAAC_ROS_WS" && pwd -P)"
  export ISAAC_ROS_WS
}

verify_host() {
  local common_config
  local cli_config
  local assets
  local source_model
  local copied_model
  local model_count=0

  resolve_host_workspace
  verify_host_prerequisites
  common_config="$ISAAC_ROS_WS/scripts/.isaac_ros_common-config"
  cli_config="$ISAAC_ROS_WS/.isaac-ros-cli/config.yaml"
  assets="$ISAAC_ROS_WS/isaac_ros_assets"

  require_file "$common_config"
  require_text "$common_config" 'CONFIG_DOCKER_SEARCH_DIRS=('
  require_text "$common_config" "$REPO_DIR/docker"
  require_text "$common_config" '/etc/isaac-ros-cli/docker'

  require_file "$cli_config"
  require_text "$cli_config" 'additional_image_keys:'
  require_text "$cli_config" '- realsense'
  require_text "$cli_config" '- perception'

  require_command docker
  docker info >/dev/null ||
    die 'Docker is unavailable without sudo; re-login after joining the docker group'
  docker run --rm --gpus all ubuntu:24.04 \
    bash -lc 'nvidia-smi >/dev/null' >/dev/null ||
    die 'a disposable Ubuntu container cannot access the NVIDIA GPU'

  [[ -d "$REPO_DIR/models" ]] ||
    die "repository model directory is missing: $REPO_DIR/models"
  while IFS= read -r -d '' source_model; do
    model_count=$((model_count + 1))
    require_materialized_model "$source_model"
    copied_model="$assets/${source_model#"$REPO_DIR"/}"
    require_materialized_model "$copied_model"
  done < <(find "$REPO_DIR/models" -type f -name '*.onnx' -print0)
  (( model_count > 0 )) || die 'the repository contains no ONNX models'

  require_file "$assets/isaac_ros_foundationpose/Cup/Cup.obj"
  [[ -s "$assets/isaac_ros_foundationpose/Cup/Cup.obj" ]] ||
    die 'the copied cup mesh is empty'

  printf 'OK: Jazzy host environment verified (%d models)\n' "$model_count"
}

verify_container() {
  local assets
  local package
  local packages=(
    isaac_ros_foundationpose
    isaac_ros_yolov8
    isaac_ros_realsense
    isaac_ros_image_proc
    isaac_ros_tensor_rt
  )

  resolve_container_workspace
  assets="$ISAAC_ROS_WS/isaac_ros_assets"

  [[ "${ROS_DISTRO:-}" = jazzy ]] ||
    die "ROS_DISTRO must be jazzy (current: ${ROS_DISTRO:-unset})"
  require_command nvidia-smi
  nvidia-smi >/dev/null || die 'the NVIDIA GPU is not visible'
  require_command ros2
  ros2 pkg prefix rmw_cyclonedds_cpp >/dev/null ||
    die 'required CycloneDDS RMW package is unavailable: rmw_cyclonedds_cpp'
  for package in "${packages[@]}"; do
    ros2 pkg prefix "$package" >/dev/null ||
      die "required ROS package is unavailable: $package"
  done

  [[ -d "$assets/models" ]] ||
    die "copied model directory is missing: $assets/models"
  require_file "$assets/isaac_ros_foundationpose/Cup/Cup.obj"
  [[ -s "$assets/isaac_ros_foundationpose/Cup/Cup.obj" ]] ||
    die 'the copied cup mesh is empty'

  printf 'OK: Jazzy container environment verified (%d packages)\n' \
    "${#packages[@]}"
}

if (( $# == 0 )); then
  if [[ -f /.dockerenv ]]; then
    mode=--container
  else
    mode=--host
  fi
elif (( $# == 1 )); then
  mode="$1"
else
  usage
  exit 2
fi

case "$mode" in
  --host)
    verify_host
    ;;
  --container)
    verify_container
    ;;
  *)
    usage
    exit 2
    ;;
esac
