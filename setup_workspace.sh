#!/usr/bin/env bash
# perception 자산을 Isaac ROS 컨테이너 워크스페이스에 배치한다.
# git clone 후 1회 실행. perception/ 이 원본, 워크스페이스는 파생(복사본)이다.
#
# 호스트에서 실행 (컨테이너 밖). ISAAC_ROS_WS 는 Isaac ROS CLI가 마운트하는 경로.
set -euo pipefail

PERCEPTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISAAC_ROS_WS="${ISAAC_ROS_WS:-$HOME/workspaces/isaac_ros-dev}"
ASSETS="$ISAAC_ROS_WS/isaac_ros_assets"

echo "[setup] perception=$PERCEPTION_DIR"
echo "[setup] target assets=$ASSETS"

# --- 모델 (onnx) -----------------------------------------------------------
mkdir -p "$ASSETS/models/yolov8" "$ASSETS/models/segment_anything/1" \
         "$ASSETS/models/foundationpose"
cp -f "$PERCEPTION_DIR"/models/yolov8/*.onnx            "$ASSETS/models/yolov8/"
cp -f "$PERCEPTION_DIR"/models/segment_anything/config.pbtxt "$ASSETS/models/segment_anything/"
cp -f "$PERCEPTION_DIR"/models/segment_anything/1/model.onnx  "$ASSETS/models/segment_anything/1/"
cp -f "$PERCEPTION_DIR"/models/foundationpose/*.onnx    "$ASSETS/models/foundationpose/"

# --- 컵 CAD (FoundationPose 는 Cup/Cup.obj 이름을 기대) ---------------------
mkdir -p "$ASSETS/isaac_ros_foundationpose/Cup"
cp -f "$PERCEPTION_DIR/assets/Cup/cup.obj"     "$ASSETS/isaac_ros_foundationpose/Cup/Cup.obj"
cp -f "$PERCEPTION_DIR/assets/Cup/cup.mtl"     "$ASSETS/isaac_ros_foundationpose/Cup/Cup.mtl" 2>/dev/null || true
cp -f "$PERCEPTION_DIR/assets/Cup/texture.png" "$ASSETS/isaac_ros_foundationpose/Cup/" 2>/dev/null || true

# --- interface specs / 커스텀 노드 ----------------------------------------
mkdir -p "$ASSETS/isaac_ros_segment_anything"
cp -f "$PERCEPTION_DIR/config/yolo_interface_specs.json" "$ASSETS/isaac_ros_segment_anything/"
# 순수 python 노드들 → 워크스페이스에 두고 python3 로 직접 실행
cp -f "$PERCEPTION_DIR/nodes/sam_mask_to_mono8.py"       "$ASSETS/"
cp -f "$PERCEPTION_DIR/nodes/detection_filter.py"        "$ASSETS/"
cp -f "$PERCEPTION_DIR/nodes/bbox_depth_mask.py"         "$ASSETS/"
cp -f "$PERCEPTION_DIR/nodes/pose_overlay.py"            "$ASSETS/"
cp -f "$PERCEPTION_DIR/nodes/pose_smoother.py"           "$ASSETS/"
# 캘리브/유틸 도구
mkdir -p "$ASSETS/tools"
cp -f "$PERCEPTION_DIR/tools/"*.py "$ASSETS/tools/" 2>/dev/null || true

# --- 실행/launch 진입점 ----------------------------------------------------
mkdir -p "$ASSETS/launch"
cp -pf "$PERCEPTION_DIR"/launch/*.sh "$ASSETS/launch/"
cp -pf "$PERCEPTION_DIR"/launch/*.py "$ASSETS/launch/"
cp -pf "$PERCEPTION_DIR/verify_jazzy_setup.sh" "$ASSETS/"

echo "[setup] 자산 배치 완료."
echo "[setup] 다음: 컨테이너 안에서 launch/build_engines.sh 로 TensorRT 엔진(.plan) 생성"
echo "        (best.plan 등은 GPU 종속이라 이 머신에서 새로 만들어야 함)"
