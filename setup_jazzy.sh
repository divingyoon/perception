#!/usr/bin/env bash
# Isaac ROS Jazzy용 호스트 워크스페이스를 검증하고 구성한다.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISAAC_ROS_WS="${ISAAC_ROS_WS:-$HOME/workspaces/isaac_ros-dev}"
TEST_MODE="${JAZZY_SETUP_TEST_MODE:-0}"
MODEL_DIR="$REPO_DIR/models"
CLI_DOCKER_DIR=/etc/isaac-ros-cli/docker
CLI_ENVIRONMENT_FILE=/etc/isaac-ros-cli/environment.conf

die() {
  printf '[오류] %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    die "필수 명령을 찾을 수 없습니다: $1"
}

version_at_least() {
  local actual="$1"
  local required="$2"

  [[ "$(printf '%s\n%s\n' "$required" "$actual" | sort -V | head -n 1)" = \
    "$required" ]]
}

if [[ "$TEST_MODE" = 1 ]]; then
  CURRENT_BRANCH="${JAZZY_TEST_BRANCH:-}"
  VERSION_ID="${JAZZY_TEST_OS_RELEASE:-}"
  MODEL_DIR="${JAZZY_TEST_MODELS_DIR:-$MODEL_DIR}"
  HOST_ARCH="${JAZZY_TEST_ARCH:-}"
  NVIDIA_DRIVER_VERSION="${JAZZY_TEST_DRIVER_VERSION:-}"
  CLI_DOCKER_DIR="${JAZZY_TEST_CLI_DOCKER_DIR:-$CLI_DOCKER_DIR}"
  CLI_ENVIRONMENT_FILE="${JAZZY_TEST_CLI_ENVIRONMENT_FILE:-$CLI_ENVIRONMENT_FILE}"
else
  CURRENT_BRANCH="$(git -C "$REPO_DIR" branch --show-current)"
  # shellcheck disable=SC1091
  . /etc/os-release
  HOST_ARCH="$(uname -m)"
fi

[[ "$CURRENT_BRANCH" = jazzy ]] ||
  die "이 스크립트는 jazzy 브랜치 전용입니다 (현재: ${CURRENT_BRANCH:-detached})"
[[ "${VERSION_ID:-}" = 24.04 ]] ||
  die "Ubuntu 24.04가 필요합니다 (현재: ${VERSION_ID:-unknown})"
[[ "${HOST_ARCH:-}" = x86_64 ]] ||
  die "x86_64 아키텍처가 필요합니다 (현재: ${HOST_ARCH:-unknown})"

require_command isaac-ros
require_command docker
require_command nvidia-smi

if [[ "$TEST_MODE" != 1 ]]; then
  if ! NVIDIA_DRIVER_VERSION="$(
    nvidia-smi --query-gpu=driver_version --format=csv,noheader |
      head -n 1
  )"; then
    die "NVIDIA 드라이버 버전을 확인할 수 없습니다"
  fi
fi
[[ -n "${NVIDIA_DRIVER_VERSION:-}" ]] &&
  version_at_least "$NVIDIA_DRIVER_VERSION" 580 ||
  die "NVIDIA 드라이버 580 이상이 필요합니다 (현재: ${NVIDIA_DRIVER_VERSION:-unknown})"
[[ -d "$CLI_DOCKER_DIR" ]] ||
  die "Isaac ROS CLI Docker mode is not initialized: $CLI_DOCKER_DIR (run: sudo isaac-ros init docker)"
[[ -f "$CLI_ENVIRONMENT_FILE" ]] ||
  die "Isaac ROS CLI environment file is missing: $CLI_ENVIRONMENT_FILE (run: sudo isaac-ros init docker)"
grep -qxF 'ISAAC_ROS_ENVIRONMENT=docker' "$CLI_ENVIRONMENT_FILE" ||
  die "Isaac ROS CLI is not initialized in Docker mode: $CLI_ENVIRONMENT_FILE (run: sudo isaac-ros init docker)"

model_count=0
while IFS= read -r -d '' model; do
  model_count=$((model_count + 1))
  [[ "$(stat -c '%s' "$model")" -ge 1000 ]] ||
    die "ONNX 모델이 너무 작습니다. Git LFS를 확인하세요: $model"
  if cmp -s -n 42 <(printf '%s' \
      'version https://git-lfs.github.com/spec/v1') "$model"; then
    die "ONNX 모델이 Git LFS 포인터입니다. git lfs pull을 실행하세요: $model"
  fi
done < <(find "$MODEL_DIR" -type f -name '*.onnx' -print0)
[[ "$model_count" -gt 0 ]] ||
  die "ONNX 모델을 찾을 수 없습니다: $MODEL_DIR"

if [[ "$TEST_MODE" != 1 ]]; then
  docker info >/dev/null 2>&1 ||
    die "Docker에 접근할 수 없습니다. docker 그룹에 사용자를 추가한 뒤 다시 로그인하세요."
  docker run --rm --gpus all ubuntu:24.04 \
    bash -lc 'nvidia-smi >/dev/null' ||
    die "Docker 컨테이너에서 NVIDIA GPU를 사용할 수 없습니다."
fi

mkdir -p "$ISAAC_ROS_WS/scripts" "$ISAAC_ROS_WS/.isaac-ros-cli"
printf 'CONFIG_DOCKER_SEARCH_DIRS=(%s/docker /etc/isaac-ros-cli/docker)\n' \
  "$REPO_DIR" > "$ISAAC_ROS_WS/scripts/.isaac_ros_common-config"
{
  printf '%s\n' \
    'docker:' \
    '  image:' \
    '    additional_image_keys:' \
    '      - realsense' \
    '      - perception'
} > "$ISAAC_ROS_WS/.isaac-ros-cli/config.yaml"

ISAAC_ROS_WS="$ISAAC_ROS_WS" "$REPO_DIR/setup_workspace.sh"

printf '\n[setup] 다음 명령을 실행하세요:\n'
printf 'isaac-ros activate --build-local\n'
