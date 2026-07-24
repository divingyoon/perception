# perception 설치 가이드 — Isaac ROS 4.5/Jazzy

Ubuntu 24.04 NVIDIA GPU 호스트에 perception 환경을 구성하는 순서다. 설치와
컨테이너 검증은 카메라 없이 끝내며, D435i는 마지막 라이브 단계에서만 연결한다.

## 1. 요구사항

- `jazzy` 브랜치
- Ubuntu 24.04 Noble x86_64
- NVIDIA Ampere 이상 GPU
- NVIDIA 드라이버 580 이상
- sudo 권한과 인터넷 연결
- Git LFS로 받은 ONNX 모델

TensorRT 엔진은 GPU와 TensorRT 버전에 종속된다. 다른 머신에서 만든 `.plan`을
재사용하지 않고 실제 실행할 GPU에서 생성한다.

## 2. 호스트 부트스트랩

```bash
git clone <repository-url>
cd perception
git switch jazzy
./bootstrap.sh
```

`bootstrap.sh`는 Docker, NVIDIA Container Toolkit, Git LFS, usbfs/rmem/udev
호스트 설정을 준비하고 공식 `release-4.5` Noble APT 저장소에서
`isaac-ros-cli`를 설치한다. Ubuntu 24.04가 아니면 중단한다.

스크립트가 사용자를 `docker` 그룹에 추가했다면 반드시 로그아웃한 뒤 다시
로그인한다. `newgrp`가 아닌 새 로그인 세션을 권장한다.

새 로그인 셸에서 워크스페이스 변수를 명시하고 Docker/GPU preflight를 통과시킨다.

```bash
export ISAAC_ROS_WS="${ISAAC_ROS_WS:-$HOME/workspaces/isaac_ros-dev}"
docker info >/dev/null
docker run --rm --gpus all ubuntu:24.04 bash -lc 'nvidia-smi >/dev/null'
```

`bootstrap.sh`도 환경을 구분하는 관리 블록을 `~/.bashrc`에 중복 없이 추가한다.
호스트에서는 위 기본값 또는 사용자가 지정한 경로를 유지하고, CLI 컨테이너에서는
항상 `/workspaces/isaac_ros-dev`를 사용한다. 아래 설치 명령과 같은 현재 셸에서는
변수를 명시해 re-source 여부에 의존하지 않는다.

## 3. Isaac ROS CLI 초기화

```bash
sudo isaac-ros init docker
```

이 명령은 머신당 한 번 실행한다. 그 뒤 저장소 루트에서 Jazzy 설정과 자산을
워크스페이스에 배치한다.

```bash
export ISAAC_ROS_WS="${ISAAC_ROS_WS:-$HOME/workspaces/isaac_ros-dev}"
./setup_jazzy.sh
./verify_jazzy_setup.sh --host
```

기본 워크스페이스는 `~/workspaces/isaac_ros-dev`다. `setup_jazzy.sh`는 자식
프로세스이므로 부모 셸의 변수를 export할 수 없다. 다른 위치를 쓸 때는 같은
현재 셸에서 먼저 export하고 이후 모든 명령에 유지한다.

```bash
export ISAAC_ROS_WS="${ISAAC_ROS_WS:-$HOME/workspaces/isaac_ros-dev}"
export ISAAC_ROS_WS=/data/workspaces/isaac_ros-dev
./setup_jazzy.sh
./verify_jazzy_setup.sh --host
```

호스트 검증은 CLI 설정, Docker/GPU 접근, 복사된 모델과 메시를 확인하며 카메라
장치 유무는 검사하지 않는다.

## 4. 이미지 빌드와 컨테이너 검증

```bash
export ISAAC_ROS_WS="${ISAAC_ROS_WS:-$HOME/workspaces/isaac_ros-dev}"
isaac-ros activate --build-local
```

CLI는 `realsense` 다음 `perception` 이미지 키를 적용해
`docker/Dockerfile.perception` 레이어를 로컬 빌드한다. 컨테이너 셸이 열리면:

```bash
export ISAAC_ROS_WS=/workspaces/isaac_ros-dev
cd "${ISAAC_ROS_WS}/isaac_ros_assets"
./verify_jazzy_setup.sh --container
```

컨테이너 검증은 ROS 배포판, GPU, 필수 Isaac ROS 패키지, 모델과 Cup mesh를
확인한다. 이 단계도 D435i 없이 통과해야 한다.

## 5. TensorRT 엔진 생성

컨테이너 안에서 실행한다.

```bash
export ISAAC_ROS_WS=/workspaces/isaac_ros-dev
cd "${ISAAC_ROS_WS}/isaac_ros_assets"
./launch/build_engines.sh
```

기본 COCO 모델의 `yolov8s.plan`, 커스텀 컵 모델의 `best.plan`, FoundationPose
엔진을 현재 GPU에서 새로 생성한다. GPU, CUDA, TensorRT 또는 컨테이너 이미지가
바뀌면 기존 `.plan`을 지우고 다시 빌드한다.

## 6. 선택 사항: D435i 연결과 라이브 실행

설치·컨테이너 검증·엔진 생성을 모두 끝낸 뒤에만 D435i를 USB3 포트에 연결한다.
카메라는 이 선택 사항인 마지막 라이브 단계에만 필요하다.

### 펌웨어 제약

- 검증된 펌웨어는 **5.16.0.1**이다.
- 펌웨어 확인과 업데이트는 호스트의 RealSense 도구에서만 수행한다.
- 컨테이너 안에서 업데이트하면 recovery PID를 놓쳐 카메라가 recovery 모드에
  빠질 수 있다. 이 경우 호스트 `realsense-viewer`로 복구한다.
- color+depth 스트림 오류가 나면 USB3 연결과
  `usbfs_memory_mb=1000` 적용 여부를 먼저 확인한다.

컨테이너 안에서:

```bash
export ISAAC_ROS_WS=/workspaces/isaac_ros-dev
cd "${ISAAC_ROS_WS}/isaac_ros_assets/launch"
./run_cup_pose_standalone.sh
./run_cup_pose_standalone.sh verify
./run_cup_pose_standalone.sh stop
```

라이브 화면은 로컬 디스플레이 권한을 허용한 뒤 `/pose_viz`를 연다.

```bash
DISPLAY=:0 ros2 run rqt_image_view rqt_image_view /pose_viz
```

## 7. 알려진 운영 제약

### YOLO class-count 패치

일부 stock YOLO launch는 `num_classes`를 decoder에 전달하지 않는다. 1-class
모델 출력을 80-class로 해석하면 첫 프레임에서 SIGSEGV(-11)가 날 수 있다.
`launch/patch_yolo_numclasses.py`의 idempotent 패치를 유지하고, 모델을 바꾸면
`YOLO_NUM_CLASSES`와 필터 class ID도 함께 맞춘다. 컨테이너 이미지가 재생성되면
`/opt/ros` 변경은 사라지므로 라이브 스크립트가 매번 패치를 확인한다.

### 8 GB tracking OOM

RTX 3070 8 GB에서는 FoundationPose 추정 엔진과 추적 엔진이 동시에 상주할 때
`NVCV_ERROR_OUT_OF_MEMORY`가 발생한다. 8 GB GPU에서는 검증된
`run_cup_pose_standalone.sh` 추정 모드와 pose smoother를 사용한다.
tracking 모드는 충분한 VRAM이 있는 GPU에서만 사용한다.

### 카메라 fragment 우회

이 D435i에서는 stock fragment가 프레임을 전달하지 못했다. 라이브 경로는 독립
`realsense2_camera` 프로세스와 RGB/depth bridge를 사용하는
`run_cup_pose_standalone.sh`다.

### GPU 프로세스 정리

중단 뒤에도 GPU 메모리가 남으면 먼저 라이브 스크립트의 `stop`을 실행하고
컨테이너 프로세스를 확인한다. 호스트의 다른 GPU 작업까지 종료할 수 있는
무차별 `kill` 명령은 사용하지 않는다.

## 8. 새 YOLO 모델

YOLO는 학습한 물체만 검출한다. 새 모델을 쓸 때:

1. ONNX를 `models/yolov8/`에 배치한다.
2. `./setup_jazzy.sh`로 자산을 다시 복사한다.
3. 대상 GPU에서 `build_engines.sh`를 다시 실행한다.
4. 모델 클래스 수와 `YOLO_NUM_CLASSES`, 필터 class ID를 일치시킨다.

FoundationPose에는 해당 물체의 CAD mesh도 필요하다.

## 9. sim2real 연결

`/output`에서 `/cup_pose`로 변환하려면
`sim2real/config/global_camera_extrinsics.yaml`을 실제 장비에서 보정해야 한다.
컵 CAD 좌표계와 simulation body 좌표계의 정합도 별도로 검증한다.

## 문제 해결 순서

1. 호스트: `./verify_jazzy_setup.sh --host`
2. 컨테이너: `./verify_jazzy_setup.sh --container`
3. TensorRT 엔진이 현재 GPU에서 생성됐는지 확인
4. 라이브 단계에서만 USB3, 펌웨어 5.16.0.1, udev/usbfs 확인
5. 첫 프레임 SIGSEGV면 `num_classes` 패치와 모델 출력 shape 확인
