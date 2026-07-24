#!/usr/bin/env bash
# ⚠️ [DEPRECATED] fragment realsense 기반 — 이 D435i에서 프레임 delivery 실패로 동작하지 않는다.
#    반드시 run_cup_pose_standalone.sh 사용. 배경: ../SETUP_GUIDE.md §7.2
# 컵 6-DOF pose 라이브 파이프라인 — 컨테이너 안에서 실행.
# YOLO(컵 bbox) → SAM(마스크) → sam_mask_to_mono8(mono8 변환) → FoundationPose(pose)
# 출력: /pose_estimation/pose_matrix_output, /output(Detection3DArray)
#
# 사용: ./run_cup_pose.sh   (백그라운드로 3개 노드 기동, 로그 /tmp/perc_*.log)
#       ./run_cup_pose.sh stop  으로 종료
set -o pipefail   # set -u 는 ROS setup.bash 의 unbound 변수와 충돌하므로 쓰지 않는다

ISAAC_ROS_WS=/workspaces/isaac_ros-dev
A="$ISAAC_ROS_WS/isaac_ros_assets"
M="$A/models"

if [ "${1:-}" = "stop" ]; then
  pkill -f isaac_ros_examples; pkill -f sam_mask_to_mono8; pkill -f foundationpose_node
  echo "stopped"; exit 0
fi

source /opt/ros/jazzy/setup.bash

# 1) RealSense + YOLO + SAM
nohup ros2 launch isaac_ros_examples isaac_ros_examples.launch.py \
  launch_fragments:=realsense_mono_rect_depth,segment_anything,yolov8 \
  interface_specs_file:="$A/isaac_ros_segment_anything/yolo_interface_specs.json" \
  model_file_path:="$M/yolov8/best.onnx" \
  engine_file_path:="$M/yolov8/best.plan" \
  num_classes:=1 \
  sam_model_repository_paths:="[$M]" \
  < /dev/null > /tmp/perc_pipeline.log 2>&1 &
echo "[1/3] YOLO+SAM 파이프라인 기동 (로그 /tmp/perc_pipeline.log)"
sleep 40

# 2) SAM 마스크 → mono8 (/segmentation), timestamp 정렬
nohup python3 "$A/sam_mask_to_mono8.py" --ros-args \
  -p mask_topic:=/segment_anything/raw_segmentation_mask \
  -p reference_image_topic:=/image_rect \
  -p output_topic:=/segmentation \
  -p selection_policy:=largest \
  -p reverse_letterbox:=true \
  -p approximate_sync:=true \
  -p sync_slop_seconds:=0.1 \
  < /dev/null > /tmp/perc_sam.log 2>&1 &
echo "[2/3] sam_mask_to_mono8 기동 (로그 /tmp/perc_sam.log)"
sleep 5

# 3) FoundationPose (컵 CAD)
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
  -r pose_estimation/camera_info:=/camera_info_rect \
  -r pose_estimation/segmentation:=/segmentation \
  -r pose_estimation/output:=/output \
  isaac_ros_foundationpose nvidia::isaac_ros::foundationpose::FoundationPoseNode \
  < /dev/null > /tmp/perc_fp.log 2>&1 &
echo "[3/3] FoundationPose 기동 (로그 /tmp/perc_fp.log)"
echo
echo "확인: ros2 topic echo --once /pose_estimation/pose_matrix_output"
echo "시각화: rviz2 -d \$(ros2 pkg prefix isaac_ros_foundationpose --share)/rviz/foundationpose_realsense.rviz"
echo "sim2real 연결: python3 <sim2real>/scripts/cup_pose_relay.py --in-topic /output --out-topic /cup_pose"
