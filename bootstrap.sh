#!/usr/bin/env bash
# Jazzy 브랜치용 Isaac ROS 4.5 호스트 부트스트랩.
# Docker, NVIDIA Container Toolkit, Git LFS, 호스트 설정과 Isaac ROS CLI를
# Ubuntu 24.04 호스트에 설치한다. sudo 권한과 네트워크 연결이 필요하다.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. /etc/os-release

if [[ "${ID:-}" != ubuntu || "${VERSION_ID:-}" != 24.04 ]]; then
  printf '[bootstrap] Ubuntu 24.04가 필요합니다 (현재: %s %s)\n' \
    "${ID:-unknown}" "${VERSION_ID:-unknown}" >&2
  exit 1
fi
printf '[bootstrap] Ubuntu 24.04 / Isaac ROS 4.5 / ROS 2 Jazzy\n'

need() {
  command -v "$1" >/dev/null 2>&1
}

current_user="${SUDO_USER:-${USER:-$(id -un)}}"

# Keep the CLI workspace available both now and in future login shells.
workspace_block_begin='# >>> perception ISAAC_ROS_WS >>>'
workspace_block_end='# <<< perception ISAAC_ROS_WS <<<'
legacy_workspace_export='export ISAAC_ROS_WS="$HOME/workspaces/isaac_ros-dev"'
bashrc_file="$HOME/.bashrc"
if [[ -L "$bashrc_file" ]]; then
  if ! bashrc_target="$(readlink -e -- "$bashrc_file")" ||
    [[ ! -f "$bashrc_target" ]]; then
    printf '[bootstrap] symlinked .bashrc target must be an existing regular file: %s\n' \
      "$bashrc_file" >&2
    exit 1
  fi
elif [[ -e "$bashrc_file" ]]; then
  if [[ ! -f "$bashrc_file" ]]; then
    printf '[bootstrap] .bashrc must be a regular file: %s\n' \
      "$bashrc_file" >&2
    exit 1
  fi
  bashrc_target="$bashrc_file"
else
  touch "$bashrc_file"
  bashrc_target="$bashrc_file"
fi

if ! awk \
  -v block_begin="$workspace_block_begin" \
  -v block_end="$workspace_block_end" \
  '
    BEGIN {
      valid = 1
    }
    $0 == block_begin {
      if (begin_count > 0 || end_count > 0 || in_workspace_block) {
        valid = 0
      }
      begin_count++
      in_workspace_block = 1
    }
    $0 == block_end {
      if (!in_workspace_block || end_count > 0) {
        valid = 0
      }
      end_count++
      in_workspace_block = 0
    }
    END {
      if (begin_count != end_count || in_workspace_block ||
          begin_count > 1 || end_count > 1) {
        valid = 0
      }
      exit(valid ? 0 : 1)
    }
  ' "$bashrc_target"; then
  printf '[bootstrap] malformed perception ISAAC_ROS_WS block in %s; refusing to modify it\n' \
    "$bashrc_file" >&2
  exit 1
fi

bashrc_candidate="$(mktemp "${bashrc_target}.XXXXXX")"
awk \
  -v block_begin="$workspace_block_begin" \
  -v block_end="$workspace_block_end" \
  -v legacy_export="$legacy_workspace_export" \
  '
    $0 == block_begin { in_workspace_block = 1; next }
    $0 == block_end { in_workspace_block = 0; next }
    in_workspace_block { next }
    $0 == legacy_export { next }
    { print }
  ' "$bashrc_target" > "$bashrc_candidate"
cat >> "$bashrc_candidate" <<'EOF'
# >>> perception ISAAC_ROS_WS >>>
if [[ -f /.dockerenv ]]; then
  export ISAAC_ROS_WS=/workspaces/isaac_ros-dev
else
  export ISAAC_ROS_WS="${ISAAC_ROS_WS:-$HOME/workspaces/isaac_ros-dev}"
fi
# <<< perception ISAAC_ROS_WS <<<
EOF
chmod --reference="$bashrc_target" "$bashrc_candidate"
if cmp -s "$bashrc_candidate" "$bashrc_target"; then
  rm -f "$bashrc_candidate"
else
  mv "$bashrc_candidate" "$bashrc_target"
fi
export ISAAC_ROS_WS="${ISAAC_ROS_WS:-$HOME/workspaces/isaac_ros-dev}"

# Official repository prerequisites and UTF-8 locale.
sudo apt-get update
sudo apt-get install -y locales curl gnupg software-properties-common
if ! locale -a | grep -Eqi '^en_US\.utf-?8$'; then
  sudo locale-gen en_US en_US.UTF-8
fi
sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
if [[ "$(locale charmap)" != UTF-8 ]]; then
  printf '[bootstrap] UTF-8 locale를 구성할 수 없습니다\n' >&2
  exit 1
fi

temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

# --- 1) Docker --------------------------------------------------------------
if need docker; then
  printf '[bootstrap] docker 있음: %s\n' "$(docker --version)"
else
  printf '[bootstrap] docker 설치...\n'
  curl -fsSL https://get.docker.com | sudo sh
fi
if ! groups "$current_user" | tr ' ' '\n' | grep -qx docker; then
  printf '[bootstrap] %s를 docker 그룹에 추가 (재로그인 필요)\n' "$current_user"
  sudo usermod -aG docker "$current_user"
fi

# --- 2) NVIDIA Container Toolkit -------------------------------------------
if need nvidia-ctk; then
  printf '[bootstrap] nvidia-container-toolkit 있음: %s\n' \
    "$(nvidia-ctk --version | head -1)"
else
  printf '[bootstrap] nvidia-container-toolkit 설치...\n'
  toolkit_keyring=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  toolkit_keyring_candidate="$temporary_directory/nvidia-container-toolkit.gpg"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey |
    gpg --dearmor > "$toolkit_keyring_candidate"
  if ! sudo cmp -s "$toolkit_keyring_candidate" "$toolkit_keyring"; then
    sudo install -m 0644 "$toolkit_keyring_candidate" "$toolkit_keyring"
  fi
  curl -sSL \
    https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
    sed "s#deb https://#deb [signed-by=$toolkit_keyring] https://#g" |
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y nvidia-container-toolkit
fi

# Recover a partial install where nvidia-ctk exists but Docker is unconfigured.
docker_runtime_before="$(
  sudo sha256sum /etc/docker/daemon.json 2>/dev/null || true
)"
sudo nvidia-ctk runtime configure --runtime=docker
docker_runtime_after="$(
  sudo sha256sum /etc/docker/daemon.json 2>/dev/null || true
)"
if [[ "$docker_runtime_before" != "$docker_runtime_after" ]]; then
  sudo systemctl restart docker
fi

# Preflight only when this shell already has effective Docker group membership.
if id -nG | tr ' ' '\n' | grep -qx docker; then
  printf '[bootstrap] Docker/GPU preflight...\n'
  docker info >/dev/null
  docker run --rm --gpus all ubuntu:24.04 bash -lc 'nvidia-smi >/dev/null'
else
  printf '[bootstrap] Docker/GPU preflight는 재로그인 후 실행하세요\n'
fi

# --- 3) Git LFS -------------------------------------------------------------
if need git-lfs; then
  printf '[bootstrap] git-lfs 있음\n'
else
  printf '[bootstrap] git-lfs 설치...\n'
  sudo apt-get update
  sudo apt-get install -y git-lfs
fi
git lfs install >/dev/null 2>&1 || true
if [[ -f "$HERE/models/yolov8/best.onnx" ]] &&
  [[ "$(wc -c < "$HERE/models/yolov8/best.onnx")" -lt 1000 ]]; then
  printf '[bootstrap] Git LFS 모델 받는 중...\n'
  (cd "$HERE" && git lfs pull)
fi

# --- 4) 호스트 설정 (usbfs / rmem_max / udev) -------------------------------
if [[ -x "$HERE/host_setup.sh" ]]; then
  printf '[bootstrap] host_setup.sh 실행 (usbfs/rmem/udev)\n'
  "$HERE/host_setup.sh" ||
    printf '[warn] host_setup.sh 일부 실패 — 로그를 확인하세요\n' >&2
fi

# --- 5) 공식 Isaac ROS release-4.5 Noble APT 저장소와 CLI -------------------
printf '[bootstrap] Isaac ROS release-4.5 APT 저장소 설정...\n'
sudo add-apt-repository -y universe

isaac_keyring=/usr/share/keyrings/nvidia-isaac-ros.gpg
temporary_keyring="$temporary_directory/nvidia-isaac-ros.gpg"
curl -fsSL https://isaac.download.nvidia.com/isaac-ros/repos.key |
  gpg --dearmor > "$temporary_keyring"
if ! sudo cmp -s "$temporary_keyring" "$isaac_keyring"; then
  sudo install -m 0644 "$temporary_keyring" "$isaac_keyring"
fi

isaac_source_file=/etc/apt/sources.list.d/nvidia-isaac-ros.list
isaac_source="deb [signed-by=$isaac_keyring] https://isaac.download.nvidia.com/isaac-ros/release-4.5 noble main"
sudo touch "$isaac_source_file"
if ! sudo grep -qxF "$isaac_source" "$isaac_source_file"; then
  printf '%s\n' "$isaac_source" | sudo tee -a "$isaac_source_file" >/dev/null
fi
sudo apt-get update
sudo apt-get install -y isaac-ros-cli

cat <<'EOF'

==========================================================
[bootstrap] 호스트 준비 완료.
Docker 그룹 권한 반영을 위해 로그아웃한 뒤 다시 로그인하고 실행하세요:

export ISAAC_ROS_WS="${ISAAC_ROS_WS:-$HOME/workspaces/isaac_ros-dev}"
docker info >/dev/null
docker run --rm --gpus all ubuntu:24.04 bash -lc 'nvidia-smi >/dev/null'
sudo isaac-ros init docker
./setup_jazzy.sh
./verify_jazzy_setup.sh --host
isaac-ros activate --build-local
==========================================================
EOF
