#!/usr/bin/env bash
# perception 원샷 부트스트랩 — git clone 뒤 이거 하나로 호스트 준비.
#
#   docker + nvidia-container-toolkit + 호스트 설정(usbfs/rmem/udev) + git-lfs 를 설치하고,
#   호스트 OS 에 맞는 Isaac ROS 버전(22.04→3.2 / 24.04→4.5)을 감지해 다음 단계를 안내한다.
#   3.2·4.5 를 호스트별로 나눠 쓰는 구성(사용자 방침) 지원.
#
# 사용:  ./bootstrap.sh            # 호스트 OS 로 버전 자동 감지
#        ISAAC_ROS_VERSION=3.2 ./bootstrap.sh   # 강제 지정
#        ISAAC_ROS_VERSION=4.5 ./bootstrap.sh
#
# sudo 가 필요하다(docker/toolkit 설치). 실행 계정에 sudo 권한 필요.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. /etc/os-release
UBU="${VERSION_ID:-unknown}"

# --- Isaac ROS 버전 결정 ----------------------------------------------------
# 22.04 → 3.2(Ampere, Humble) / 24.04 → 4.5(Ampere~Blackwell, Jazzy).
if [ -z "${ISAAC_ROS_VERSION:-}" ]; then
  case "$UBU" in
    22.04) ISAAC_ROS_VERSION=3.2 ;;
    24.04) ISAAC_ROS_VERSION=4.5 ;;
    *) echo "[bootstrap] 미지원 Ubuntu $UBU — ISAAC_ROS_VERSION 을 직접 지정하세요"; exit 1 ;;
  esac
fi
echo "[bootstrap] Ubuntu $UBU → Isaac ROS $ISAAC_ROS_VERSION"

need() { command -v "$1" >/dev/null 2>&1; }

# --- 1) Docker --------------------------------------------------------------
if need docker; then
  echo "[bootstrap] docker 있음: $(docker --version)"
else
  echo "[bootstrap] docker 설치..."
  curl -fsSL https://get.docker.com | sudo sh
fi
if ! groups "$USER" | tr ' ' '\n' | grep -qx docker; then
  echo "[bootstrap] $USER 를 docker 그룹에 추가 (재로그인/newgrp 필요)"
  sudo usermod -aG docker "$USER"
fi

# --- 2) NVIDIA Container Toolkit --------------------------------------------
if need nvidia-ctk; then
  echo "[bootstrap] nvidia-container-toolkit 있음: $(nvidia-ctk --version | head -1)"
else
  echo "[bootstrap] nvidia-container-toolkit 설치..."
  KR=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o "$KR"
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed "s#deb https://#deb [signed-by=$KR] https://#g" \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y nvidia-container-toolkit
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
fi

# --- 3) git-lfs (onnx 모델 LFS) ---------------------------------------------
if need git-lfs; then
  echo "[bootstrap] git-lfs 있음"
else
  echo "[bootstrap] git-lfs 설치..."
  sudo apt-get install -y git-lfs
fi
git lfs install >/dev/null 2>&1 || true
# 이 레포가 LFS 로 clone 됐는데 onnx 가 포인터면 실제 파일 받기
if [ -f "$HERE/models/yolov8/yolov8s.onnx" ] && [ "$(wc -c < "$HERE/models/yolov8/yolov8s.onnx")" -lt 1000 ]; then
  echo "[bootstrap] LFS onnx 받는 중..."; (cd "$HERE" && git lfs pull) || true
fi

# --- 4) 호스트 설정 (usbfs / rmem_max / udev) -------------------------------
if [ -x "$HERE/host_setup.sh" ]; then
  echo "[bootstrap] host_setup.sh 실행 (usbfs/rmem/udev)"
  "$HERE/host_setup.sh" || echo "[warn] host_setup.sh 일부 실패 — 로그 확인"
fi

# --- 5) Isaac ROS 이미지 단계 안내 (버전별) ---------------------------------
echo ""
echo "=========================================================="
echo "[bootstrap] 호스트 준비 완료. 다음 = Isaac ROS $ISAAC_ROS_VERSION 이미지."
echo "=========================================================="
if [ "$ISAAC_ROS_VERSION" = "3.2" ]; then
  cat <<EOF
[3.2 / Ampere / Humble]  (검증된 경로)
  A) 완성 이미지 tar 가 있으면 (가장 빠름):
       docker load -i /path/to/isaac_ros_dev-x86_64-container_image.tar
       docker tag <loaded>:latest isaac_ros_dev-x86_64:latest
  B) 소스 빌드: docker/BUILD.md 의 3.2 절차 (isaac_ros_common release-3.2 + Dockerfile.perception)
  이후: setup_workspace.sh → launch/build_engines.sh → launch/run_cup_pose_standalone.sh
  자세히: SETUP_GUIDE.md §4, RUN.md
EOF
else
  cat <<EOF
[4.5 / Ampere~Blackwell / Jazzy]  (⚠️ 24.04 필요, 첫 셋업은 bring-up)
  1) isaac-ros apt repo + CLI:
       sudo apt-get install -y isaac-ros-cli   # (repo 추가는 docker/BUILD.md 4.5 절 참조)
  2) sudo isaac-ros init docker                 # base [noble, ros2_jazzy]
  3) 커스텀 perception key 등록(CLI YAML) + Dockerfile.perception(Jazzy) → isaac-ros activate --build-local
  4) setup_workspace.sh → 엔진 재빌드 → 실행
  ⚠️ 4.5 레시피(Jazzy 이식)는 아직 미검증 — 첫 24.04 머신에서 확정 예정. docker/BUILD.md 참조.
EOF
fi
echo ""
echo "[bootstrap] docker 그룹 반영이 안 됐으면: newgrp docker  (또는 재로그인)"
