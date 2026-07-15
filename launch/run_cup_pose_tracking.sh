#!/usr/bin/env bash
# ⚠️ EXPERIMENTAL — 컵 pose 라이브 (tracking 모드). GPU bring-up 필요.
#
# 추정(estimation) 모드인 run_cup_pose_standalone.sh 와 앞단(카메라·YOLO·필터·마스크)은
# 같고, 뒷단만 FoundationPose 단일 노드 → Selector+FoundationPoseNode+FoundationPoseTrackingNode
# (cup_pose_tracking.launch.py)로 교체한다. Selector 가 reset_period 마다 추정으로
# 리셋하고 그 사이는 추적으로 이어가 GPU 부하↓·rate↑·지터↓ 를 노린다.
#
# ⚠️ 주의(첫 실행 = bring-up):
#   - 추정+추적 FP 엔진 동시 상주라 8GB(3070)에서 OOM 가능. score batch 축소는
#     추정 노드가 satisfyProfile 오류를 내 불가(252 필수). OOM 이면 tracking 이
#     8GB 에 안 맞는 것 → 추정모드(run_cup_pose_standalone.sh + pose_smoother)로 회귀.
#   - Selector 내부 토픽/마스크 정합이 이 구성에서 처음이라 $LOGDIR/tracking.log 확인.
#
# 사용: ./run_cup_pose_tracking.sh          기동
#       ./run_cup_pose_tracking.sh stop     종료
#       ./run_cup_pose_tracking.sh verify   확인
set -o pipefail

ISAAC_ROS_WS="${ISAAC_ROS_WS:-/workspaces/isaac_ros-dev}"
A="$ISAAC_ROS_WS/isaac_ros_assets"
M="$A/models"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGDIR="${PERC_LOG_DIR:-/tmp/perc_logs_$(id -u)}"
mkdir -p "$LOGDIR" 2>/dev/null

YOLO_MODEL="${YOLO_MODEL:-yolov8s.onnx}"
YOLO_ENGINE="${YOLO_ENGINE:-yolov8s.plan}"
YOLO_NUM_CLASSES="${YOLO_NUM_CLASSES:-80}"
FILTER_CLASS_IDS="${FILTER_CLASS_IDS:-39,41}"
MASK_DEPTH_BAND_M="${MASK_DEPTH_BAND_M:-0.06}"
# Selector 리셋 주기(ms). 짧을수록 자주 재추정(견고/무겁), 길수록 추적 위주(가벼움).
export TRACK_RESET_PERIOD_MS="${TRACK_RESET_PERIOD_MS:-4000}"

source /opt/ros/humble/setup.bash

PATCH="$HERE/patch_yolo_numclasses.py"
if [ "${1:-}" != "stop" ] && [ "${1:-}" != "verify" ] && [ -f "$PATCH" ]; then
  sudo python3 "$PATCH" || echo "[warn] yolov8 num_classes 패치 실패"
fi

if [ "${1:-}" = "stop" ]; then
  pkill -f cup_pose_standalone_cam; pkill -f realsense2_camera
  pkill -f perception_camera_bridge; pkill -f isaac_ros_examples
  pkill -f detection_filter; pkill -f bbox_depth_mask
  pkill -f foundationpose_tracking_container; pkill -f component_container
  pkill -f foundationpose; pkill -f pose_overlay; pkill -f rqt_image_view
  echo "stopped"; exit 0
fi

if [ "${1:-}" = "verify" ]; then
  ros2 daemon stop >/dev/null 2>&1; sleep 1
  echo "[1] RGB /camera/color/image_raw:"
  timeout 5 ros2 topic hz /camera/color/image_raw 2>&1 | grep -E "average|does not" | head -1
  echo "[2] /segmentation:"
  timeout 6 ros2 topic hz /segmentation 2>&1 | grep -E "average|does not" | head -1
  echo "[3] 컵 pose /output (tracking → rate 가 추정모드보다 높아야 함):"
  timeout 8 ros2 topic hz /output 2>&1 | grep -E "average|does not" | head -1
  timeout 8 ros2 topic echo --once /output 2>&1 | grep -E "position|z:" | head -3
  echo "[4] /pose_viz:"
  timeout 6 ros2 topic hz /pose_viz 2>&1 | grep -E "average|does not" | head -1
  exit 0
fi

# 1) 카메라 + 브리지
nohup ros2 launch "$HERE/cup_pose_standalone_cam.launch.py" \
  < /dev/null > $LOGDIR/cam.log 2>&1 &
echo "[1/5] 카메라 + 브리지 (로그 $LOGDIR/cam.log)"; sleep 25

# 2) YOLO
nohup ros2 launch isaac_ros_examples isaac_ros_examples.launch.py \
  launch_fragments:=yolov8 \
  interface_specs_file:="$A/isaac_ros_segment_anything/yolo_interface_specs.json" \
  model_file_path:="$M/yolov8/$YOLO_MODEL" \
  engine_file_path:="$M/yolov8/$YOLO_ENGINE" \
  num_classes:="$YOLO_NUM_CLASSES" \
  image_input_topic:=/image_rect \
  camera_info_input_topic:=/camera/color/camera_info \
  < /dev/null > $LOGDIR/pipeline.log 2>&1 &
echo "[2/5] YOLO (로그 $LOGDIR/pipeline.log)"; sleep 30

# 3) 필터 + 마스크
nohup python3 "$A/detection_filter.py" --ros-args \
  -p input_topic:=/detections_output -p output_topic:=/detections_cup \
  -p keep_class_ids:="$FILTER_CLASS_IDS" -p min_confidence:=0.1 -p keep_best:=true \
  < /dev/null > $LOGDIR/filter.log 2>&1 &
echo "[3/5] detection_filter + bbox_depth_mask"; sleep 2
nohup python3 "$A/bbox_depth_mask.py" --ros-args \
  -p detection_topic:=/detections_cup \
  -p depth_topic:=/camera/aligned_depth_to_color/image_raw \
  -p output_topic:=/segmentation -p depth_band_m:="$MASK_DEPTH_BAND_M" \
  < /dev/null > $LOGDIR/mask.log 2>&1 &
sleep 5

# 4) tracking 컨테이너 (Selector + 추정 + 추적)
nohup ros2 launch "$HERE/cup_pose_tracking.launch.py" \
  < /dev/null > $LOGDIR/tracking.log 2>&1 &
echo "[4/5] tracking 컨테이너 reset=${TRACK_RESET_PERIOD_MS}ms (로그 $LOGDIR/tracking.log)"
echo "      ⚠️ OOM/에러면 로그 확인. 안 되면 run_cup_pose_standalone.sh(추정모드)로."
sleep 12

# 5) pose 오버레이 (tracking 은 자체로 매끄러워 smoother 불필요 → /output 직접)
nohup python3 "$A/pose_overlay.py" --ros-args \
  -p image_topic:=/camera/color/image_raw \
  -p camera_info_topic:=/camera/color/camera_info \
  -p pose_topic:=/output -p output_topic:=/pose_viz \
  < /dev/null > $LOGDIR/viz.log 2>&1 &
echo "[5/5] pose_overlay → /pose_viz"
echo
echo "확인: ./run_cup_pose_tracking.sh verify   (rate 가 추정모드 3.5Hz 보다 높으면 tracking 동작)"
echo "화면: DISPLAY=:0 ros2 run rqt_image_view rqt_image_view /pose_viz"
echo "종료: ./run_cup_pose_tracking.sh stop"
