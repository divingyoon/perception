#!/usr/bin/env bash
# TensorRT 엔진(.plan) 생성 — 컨테이너 안에서 실행.
# .plan 은 GPU/TensorRT 버전 종속이라 git 에 넣지 않고 여기서 생성한다.
set -euo pipefail

ISAAC_ROS_WS="${ISAAC_ROS_WS:-/workspaces/isaac_ros-dev}"
M="$ISAAC_ROS_WS/isaac_ros_assets/models"
TRT=/usr/src/tensorrt/bin/trtexec

# --- YOLOv8 컵 detector ----------------------------------------------------
if [ ! -f "$M/yolov8/best.plan" ]; then
  echo "[engine] YOLOv8 best.plan 생성..."
  "$TRT" --onnx="$M/yolov8/best.onnx" --saveEngine="$M/yolov8/best.plan"
fi

# --- FoundationPose refine/score (동적 배치) -------------------------------
if [ ! -f "$M/foundationpose/refine_trt_engine.plan" ]; then
  echo "[engine] FoundationPose refine..."
  "$TRT" --onnx="$M/foundationpose/refine_model.onnx" \
    --saveEngine="$M/foundationpose/refine_trt_engine.plan" \
    --minShapes=input1:1x160x160x6,input2:1x160x160x6 \
    --optShapes=input1:1x160x160x6,input2:1x160x160x6 \
    --maxShapes=input1:42x160x160x6,input2:42x160x160x6
fi
if [ ! -f "$M/foundationpose/score_trt_engine.plan" ]; then
  echo "[engine] FoundationPose score..."
  "$TRT" --onnx="$M/foundationpose/score_model.onnx" \
    --saveEngine="$M/foundationpose/score_trt_engine.plan" \
    --minShapes=input1:1x160x160x6,input2:1x160x160x6 \
    --optShapes=input1:1x160x160x6,input2:1x160x160x6 \
    --maxShapes=input1:252x160x160x6,input2:252x160x160x6
fi

# SAM 은 isaac_ros_segment_anything 이 triton(config.pbtxt)으로 로드하며
# 첫 실행 시 자동으로 엔진을 만든다 → 별도 변환 불필요.
echo "[engine] 완료."
