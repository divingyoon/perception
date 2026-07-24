# Isaac ROS 4.5/Jazzy 실행 치트시트

설치가 끝나지 않았다면 [SETUP_GUIDE.md](SETUP_GUIDE.md)를 먼저 따른다. 설치와
환경 검증은 카메라 없이 수행하고, 라이브 단계에서만 D435i를 연결한다.

## 새 머신 1회

```bash
./bootstrap.sh
# 로그아웃 후 다시 로그인
export ISAAC_ROS_WS="${ISAAC_ROS_WS:-$HOME/workspaces/isaac_ros-dev}"
docker info >/dev/null
docker run --rm --gpus all ubuntu:24.04 bash -lc 'nvidia-smi >/dev/null'
sudo isaac-ros init docker
./setup_jazzy.sh
./verify_jazzy_setup.sh --host
isaac-ros activate --build-local
```

컨테이너 안에서:

```bash
export ISAAC_ROS_WS=/workspaces/isaac_ros-dev
cd "${ISAAC_ROS_WS}/isaac_ros_assets"
./verify_jazzy_setup.sh --container
./launch/build_engines.sh
```

`.plan`은 GPU와 TensorRT 버전에 종속된다. GPU나 이미지가 바뀌면 엔진을 다시
생성한다.

## 컨테이너 다시 열기

저장소 루트의 호스트 셸에서:

```bash
export ISAAC_ROS_WS="${ISAAC_ROS_WS:-$HOME/workspaces/isaac_ros-dev}"
isaac-ros activate
```

이미지 레이어를 변경했으면 `--build-local`을 다시 붙인다.

## 선택 사항: D435i 라이브 실행

D435i는 이 선택 사항인 마지막 단계에서 USB3에 연결한다. 먼저 호스트에서
펌웨어 5.16.0.1과 udev/usbfs 설정을 확인한다. 펌웨어 업데이트는 컨테이너 안에서
하지 않는다.

컨테이너 안에서:

```bash
export ISAAC_ROS_WS=/workspaces/isaac_ros-dev
cd "${ISAAC_ROS_WS}/isaac_ros_assets/launch"
./run_cup_pose_standalone.sh
```

검증과 종료:

```bash
./run_cup_pose_standalone.sh verify
./run_cup_pose_standalone.sh stop
```

로컬 화면:

```bash
DISPLAY=:0 ros2 run rqt_image_view rqt_image_view /pose_viz
```

## 자주 쓰는 옵션

```bash
SMOOTH=0 ./run_cup_pose_standalone.sh
SMOOTH_ALPHA=0.5 ./run_cup_pose_standalone.sh
MASK_DEPTH_BAND_M=0.08 ./run_cup_pose_standalone.sh
YOLO_MODEL=best.onnx YOLO_ENGINE=best.plan \
  YOLO_NUM_CLASSES=1 FILTER_CLASS_IDS=0 ./run_cup_pose_standalone.sh
```

커스텀 YOLO의 class count가 decoder까지 전달되지 않으면 첫 프레임에
SIGSEGV(-11)가 날 수 있다. `patch_yolo_numclasses.py` 패치를 유지하고
`YOLO_NUM_CLASSES`를 모델과 맞춘다.

## tracking

RTX 3070 8 GB에서는 추정·추적 엔진 동시 상주가 OOM을 일으킨다. 8 GB
머신에서는 standalone 추정 모드를 사용한다. tracking은 충분한 VRAM이 있는
GPU에서만 실행한다.

```bash
./run_cup_pose_tracking.sh
./run_cup_pose_tracking.sh verify
./run_cup_pose_tracking.sh stop
```

문제가 생기면 먼저 현재 모드의 `stop`을 실행하고 로그와 GPU 프로세스를
확인한다.
