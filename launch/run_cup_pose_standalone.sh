#!/usr/bin/env bash
# 컵 6-DOF pose 라이브 파이프라인 — 컨테이너 안에서 실행.
# 두 가지를 우회한다:
#   (1) fragment realsense 가 이 D435i에서 프레임을 안 내보냄
#       → standalone realsense + 카메라 브리지 (cup_pose_standalone_cam.launch.py)
#   (2) 8GB GPU(RTX 3070)에 SAM(~3.5GB)+FoundationPose(~5GB)가 동시에 안 올라감
#       → SAM 제거, YOLO bbox + depth 로 마스크 생성 (bbox_depth_mask.py)
# 파이프라인:
#   standalone realsense + 브리지 → YOLO(컵 bbox) → detection_filter
#     → bbox_depth_mask(마스크) → FoundationPose(pose) → pose_overlay(시각화)
# 출력: /output(Detection3DArray, position=컵 위치[m]), /pose_viz(RGB+3D축/박스 오버레이)
#
# 사용: ./run_cup_pose_standalone.sh          기동 (로그 /tmp/perc_logs_<uid>/*.log)
#       ./run_cup_pose_standalone.sh stop     종료
#       ./run_cup_pose_standalone.sh verify   각 단계 프레임/검출/pose 확인
set -o pipefail   # set -u 는 ROS setup.bash 의 unbound 변수와 충돌하므로 쓰지 않는다

ISAAC_ROS_WS="${ISAAC_ROS_WS:-/workspaces/isaac_ros-dev}"
A="$ISAAC_ROS_WS/isaac_ros_assets"
M="$A/models"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 로그는 사용자별 디렉토리로 — root/admin 등 다른 사용자로 번갈아 돌려도 권한 충돌 없게.
LOGDIR="${PERC_LOG_DIR:-/tmp/perc_logs_$(id -u)}"
mkdir -p "$LOGDIR" 2>/dev/null

# YOLO 모델 선택 — 기본은 stock COCO yolov8s + cup/bottle 필터(재학습 없이 임의 색 컵).
# 커스텀 1-class 모델로 바꾸려면 기동 전:
#   export YOLO_MODEL=best.onnx YOLO_ENGINE=best.plan YOLO_NUM_CLASSES=1 FILTER_CLASS_IDS=0
YOLO_MODEL="${YOLO_MODEL:-yolov8s.onnx}"
YOLO_ENGINE="${YOLO_ENGINE:-yolov8s.plan}"
YOLO_NUM_CLASSES="${YOLO_NUM_CLASSES:-80}"
FILTER_CLASS_IDS="${FILTER_CLASS_IDS:-39,41}"   # COCO: 39=bottle, 41=cup
# depth 마스크 대역(±m). 박스 내 median depth 기준 이 대역만 전경으로.
MASK_DEPTH_BAND_M="${MASK_DEPTH_BAND_M:-0.06}"
# pose 안정화 필터(EMA+slerp). SMOOTH=0 이면 끔. 켜면 소비 토픽=/output_smooth.
SMOOTH="${SMOOTH:-1}"
SMOOTH_ALPHA="${SMOOTH_ALPHA:-0.3}"

source /opt/ros/humble/setup.bash

# 0) isaac_ros_yolov8 launch 에 num_classes 배선 패치 (idempotent, 매 기동 시 적용).
#    stock launch 는 num_classes 를 YoloV8DecoderNode 에 전달하지 않아 디코더가
#    기본값 80 을 쓴다. 1-class 커스텀 컵 모델([1,5,8400])에서 디코더가
#    [1,84,8400] 을 가정하고 out-of-bounds 로 첫 프레임에 SIGSEGV(-11) 로 죽는다.
#    (COCO 80-class 는 기본값과 같아 없어도 되지만, 커스텀 모델 지원 위해 유지.)
#    /opt/ros 는 컨테이너 재생성 시 원복되므로 기동마다 재적용한다(admin sudo 필요).
PATCH="$HERE/patch_yolo_numclasses.py"
if [ "${1:-}" != "stop" ] && [ "${1:-}" != "verify" ] && [ -f "$PATCH" ]; then
  sudo python3 "$PATCH" || echo "[warn] yolov8 num_classes 패치 실패 — 디코더 -11 가능"
fi

if [ "${1:-}" = "stop" ]; then
  pkill -f cup_pose_standalone_cam; pkill -f realsense2_camera
  pkill -f perception_camera_bridge; pkill -f isaac_ros_examples
  pkill -f detection_filter; pkill -f bbox_depth_mask; pkill -f foundationpose_node
  pkill -f pose_smoother; pkill -f pose_overlay; pkill -f rqt_image_view
  echo "stopped"; exit 0
fi

if [ "${1:-}" = "verify" ]; then
  # NITROS 토픽(/image_rect,/depth)은 echo/hz 거짓음성 → plain 토픽·검출 결과로 판별.
  # ros2 CLI 는 daemon staleness 로 "not published" 오탐이 잦다 → 먼저 daemon stop.
  ros2 daemon stop >/dev/null 2>&1; sleep 1
  echo "[1] RGB 원본 (plain, 신뢰) /camera/color/image_raw:"
  timeout 5 ros2 topic hz /camera/color/image_raw 2>&1 | grep -E "average|does not" | head -1
  echo "[2] aligned depth /camera/aligned_depth_to_color/image_raw:"
  timeout 5 ros2 topic hz /camera/aligned_depth_to_color/image_raw 2>&1 | grep -E "average|does not" | head -1
  echo "[3] YOLO 검출 /detections_output (컵을 카메라 30cm 정면에 두고):"
  timeout 8 ros2 topic echo --once /detections_output 2>&1 | grep -E "class_id|score" | head -4
  echo "[3b] 필터 후 컵 검출 /detections_cup (cup/bottle 만):"
  timeout 8 ros2 topic echo --once /detections_cup 2>&1 | grep -E "class_id|size_x" | head -4
  echo "[4] depth 마스크 /segmentation (mono8):"
  timeout 6 ros2 topic hz /segmentation 2>&1 | grep -E "average|does not" | head -1
  echo "[5] 컵 pose /output (position=컵 위치[m], z=카메라앞 거리):"
  timeout 10 ros2 topic echo --once /output 2>&1 | grep -E "position|z:" | head -4
  echo "[6] pose 오버레이 /pose_viz (rqt_image_view 로 축/박스 확인):"
  timeout 8 ros2 topic hz /pose_viz 2>&1 | grep -E "average|does not" | head -1
  exit 0
fi

# 1) standalone realsense + 카메라 브리지 (fragment realsense 대체)
nohup ros2 launch "$HERE/cup_pose_standalone_cam.launch.py" \
  < /dev/null > $LOGDIR/cam.log 2>&1 &
echo "[1/4] standalone 카메라 + 브리지 기동 (로그 $LOGDIR/cam.log)"
sleep 25   # realsense 초기화(+reset) 여유

# 2) YOLO 만 (SAM 제외 — 8GB GPU 메모리 절약). 이미지 입력은 브리지의 /image_rect.
nohup ros2 launch isaac_ros_examples isaac_ros_examples.launch.py \
  launch_fragments:=yolov8 \
  interface_specs_file:="$A/isaac_ros_segment_anything/yolo_interface_specs.json" \
  model_file_path:="$M/yolov8/$YOLO_MODEL" \
  engine_file_path:="$M/yolov8/$YOLO_ENGINE" \
  num_classes:="$YOLO_NUM_CLASSES" \
  image_input_topic:=/image_rect \
  camera_info_input_topic:=/camera/color/camera_info \
  < /dev/null > $LOGDIR/pipeline.log 2>&1 &
echo "[2/4] YOLO 기동 model=$YOLO_MODEL nc=$YOLO_NUM_CLASSES (로그 $LOGDIR/pipeline.log)"
sleep 30

# 2.5) 검출 필터 — 지정 클래스(cup/bottle)만 남겨 최고점수 1개를 /detections_cup 로.
nohup python3 "$A/detection_filter.py" --ros-args \
  -p input_topic:=/detections_output \
  -p output_topic:=/detections_cup \
  -p keep_class_ids:="$FILTER_CLASS_IDS" \
  -p min_confidence:=0.1 \
  -p keep_best:=true \
  < /dev/null > $LOGDIR/filter.log 2>&1 &
echo "[2.5] detection_filter 기동 keep=$FILTER_CLASS_IDS (로그 $LOGDIR/filter.log)"
sleep 3

# 3) bbox + depth → mono8 마스크 (/segmentation). SAM 대체.
#    depth 프레임마다 최신 bbox 를 적용 → 마스크 stamp=depth stamp → FP 동기화.
nohup python3 "$A/bbox_depth_mask.py" --ros-args \
  -p detection_topic:=/detections_cup \
  -p depth_topic:=/camera/aligned_depth_to_color/image_raw \
  -p output_topic:=/segmentation \
  -p depth_band_m:="$MASK_DEPTH_BAND_M" \
  < /dev/null > $LOGDIR/mask.log 2>&1 &
echo "[3/4] bbox_depth_mask 기동 band=${MASK_DEPTH_BAND_M}m (로그 $LOGDIR/mask.log)"
sleep 5

# 4) FoundationPose (컵 CAD). SAM 제거로 6GB+ 여유 → score 엔진은 원본(max batch 252).
nohup ros2 component standalone -n foundationpose_node \
  -p mesh_file_path:="$A/isaac_ros_foundationpose/Cup/Cup.obj" \
  -p refine_model_file_path:="$M/foundationpose/refine_model.onnx" \
  -p refine_engine_file_path:="$M/foundationpose/refine_trt_engine.plan" \
  -p score_model_file_path:="$M/foundationpose/score_model.onnx" \
  -p score_engine_file_path:="$M/foundationpose/score_trt_engine.plan" \
  -p refine_input_tensor_names:='["input_tensor1","input_tensor2"]' \
  -p refine_input_binding_names:='["input1","input2"]' \
  -p refine_output_tensor_names:='["output_tensor1","output_tensor2"]' \
  -p refine_output_binding_names:='["output1","output2"]' \
  -p score_input_tensor_names:='["input_tensor1","input_tensor2"]' \
  -p score_input_binding_names:='["input1","input2"]' \
  -p score_output_tensor_names:='["output_tensor"]' \
  -p score_output_binding_names:='["output1"]' \
  -r pose_estimation/image:=/image_rect \
  -r pose_estimation/depth_image:=/depth \
  -r pose_estimation/camera_info:=/camera/color/camera_info \
  -r pose_estimation/segmentation:=/segmentation \
  -r pose_estimation/output:=/output \
  isaac_ros_foundationpose nvidia::isaac_ros::foundationpose::FoundationPoseNode \
  < /dev/null > $LOGDIR/fp.log 2>&1 &
echo "[4/5] FoundationPose 기동 (로그 $LOGDIR/fp.log)"
sleep 8

# 4.5) pose 안정화 필터(선택). /output → /output_smooth. 하류(overlay/relay)가 이걸 소비.
POSE_TOPIC=/output
if [ "$SMOOTH" != "0" ]; then
  nohup python3 "$A/pose_smoother.py" --ros-args \
    -p input_topic:=/output \
    -p output_topic:=/output_smooth \
    -p alpha:="$SMOOTH_ALPHA" \
    < /dev/null > $LOGDIR/smooth.log 2>&1 &
  POSE_TOPIC=/output_smooth
  echo "[4.5] pose_smoother 기동 alpha=$SMOOTH_ALPHA → /output_smooth (로그 $LOGDIR/smooth.log)"
  sleep 2
fi

# 5) pose 오버레이 — pose 를 RGB 에 투영해 3D 축/박스를 /pose_viz 로.
#    PIL 사용(cv2/numpy2 충돌 회피). rqt_image_view /pose_viz 로 실시간 확인.
nohup python3 "$A/pose_overlay.py" --ros-args \
  -p image_topic:=/camera/color/image_raw \
  -p camera_info_topic:=/camera/color/camera_info \
  -p pose_topic:="$POSE_TOPIC" \
  -p output_topic:=/pose_viz \
  < /dev/null > $LOGDIR/viz.log 2>&1 &
echo "[5/5] pose_overlay 기동 pose=$POSE_TOPIC → /pose_viz (로그 $LOGDIR/viz.log)"
echo
echo "확인: bash $(basename "${BASH_SOURCE[0]}") verify"
echo "실시간 시각화: DISPLAY=:0 ros2 run rqt_image_view rqt_image_view /pose_viz  # 컵에 축/박스"
echo "  (arm3070 로컬서 xhost +local: 선행. plain RGB 만 볼 땐 /camera/color/image_raw)"
echo "sim2real 연결: python3 <sim2real>/scripts/cup_pose_relay.py --in-topic $POSE_TOPIC --out-topic /cup_pose"
