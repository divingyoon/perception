#!/usr/bin/env bash
# TensorRT 엔진(.plan) 생성 — 컨테이너 안에서 실행.
# .plan 은 GPU/TensorRT 버전 종속이라 git 에 넣지 않고 여기서 생성한다.
set -euo pipefail

ISAAC_ROS_WS=/workspaces/isaac_ros-dev
M="$ISAAC_ROS_WS/isaac_ros_assets/models"
TRT=/usr/src/tensorrt/bin/trtexec

temporary_engine=''

cleanup_temporary_engine() {
  if [[ -n "$temporary_engine" ]]; then
    rm -f -- "$temporary_engine"
  fi
}

trap cleanup_temporary_engine EXIT
trap 'exit 130' INT TERM

build_engine() {
  local output="$1"
  local description="$2"
  shift 2

  [[ -s "$output" ]] && return 0

  echo "[engine] $description 생성..."
  temporary_engine="$(mktemp "${output}.tmp.XXXXXX")"
  if ! "$TRT" "$@" --saveEngine="$temporary_engine"; then
    echo "[engine] 실패: $description" >&2
    cleanup_temporary_engine
    temporary_engine=''
    return 1
  fi
  if [[ ! -s "$temporary_engine" ]]; then
    echo "[engine] 빈 엔진이 생성됨: $description" >&2
    cleanup_temporary_engine
    temporary_engine=''
    return 1
  fi
  mv "$temporary_engine" "$output"
  temporary_engine=''
}

# --- YOLOv8 detectors -------------------------------------------------------
build_engine "$M/yolov8/yolov8s.plan" "YOLOv8 yolov8s.plan" \
  --onnx="$M/yolov8/yolov8s.onnx"
build_engine "$M/yolov8/best.plan" "YOLOv8 best.plan" \
  --onnx="$M/yolov8/best.onnx"

# --- FoundationPose refine/score (동적 배치) -------------------------------
build_engine "$M/foundationpose/refine_trt_engine.plan" \
  "FoundationPose refine" \
  --onnx="$M/foundationpose/refine_model.onnx" \
  --minShapes=input1:1x160x160x6,input2:1x160x160x6 \
  --optShapes=input1:1x160x160x6,input2:1x160x160x6 \
  --maxShapes=input1:42x160x160x6,input2:42x160x160x6
build_engine "$M/foundationpose/score_trt_engine.plan" \
  "FoundationPose score" \
  --onnx="$M/foundationpose/score_model.onnx" \
  --minShapes=input1:1x160x160x6,input2:1x160x160x6 \
  --optShapes=input1:1x160x160x6,input2:1x160x160x6 \
  --maxShapes=input1:252x160x160x6,input2:252x160x160x6

# SAM 은 isaac_ros_segment_anything 이 triton(config.pbtxt)으로 로드하며
# 첫 실행 시 자동으로 엔진을 만든다 → 별도 변환 불필요.
echo "[engine] 완료."
