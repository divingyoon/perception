# perception — Isaac ROS 4.5/Jazzy 컵 6-DOF pose

D435i 영상에서 컵의 6-DOF pose를 추정해 sim2real pour 정책의 `/cup_pose`
입력으로 전달하는 지각 스택이다. 이 `jazzy` 브랜치는 Ubuntu 24.04와 공식
Isaac ROS 4.5 CLI Docker 환경만 지원한다. 카메라는 설치 검증에 필요하지 않다.
지원 하드웨어는 `x86_64`, NVIDIA Ampere 이상 GPU, NVIDIA 드라이버 580 이상이다.

## 빠른 시작

```bash
./bootstrap.sh
# Docker 그룹 권한 반영을 위해 로그아웃 후 다시 로그인
export ISAAC_ROS_WS="${ISAAC_ROS_WS:-$HOME/workspaces/isaac_ros-dev}"
docker info >/dev/null
docker run --rm --gpus all ubuntu:24.04 bash -lc 'nvidia-smi >/dev/null'
sudo isaac-ros init docker
./setup_jazzy.sh
./verify_jazzy_setup.sh --host
isaac-ros activate --build-local
```

컨테이너가 열리면 다음을 실행한다.

```bash
export ISAAC_ROS_WS=/workspaces/isaac_ros-dev
cd "${ISAAC_ROS_WS}/isaac_ros_assets"
./verify_jazzy_setup.sh --container
./launch/build_engines.sh
```

여기까지는 D435i 없이 완료할 수 있다. 카메라는 선택 사항인 마지막 라이브 단계에서만
연결한다. 컨테이너 안에서 D435i를 USB3에 연결한 뒤 라이브 파이프라인을 실행한다.

```bash
cd "${ISAAC_ROS_WS}/isaac_ros_assets/launch"
./run_cup_pose_standalone.sh
./run_cup_pose_standalone.sh verify
./run_cup_pose_standalone.sh stop
```

전체 설치 설명은 [SETUP_GUIDE.md](SETUP_GUIDE.md), 이미지 레이어 설명은
[docker/BUILD.md](docker/BUILD.md)에 있다.

## 파이프라인

```text
D435i → RGB/depth bridge → YOLOv8 bbox → depth mask
      → FoundationPose(CAD + mask + depth) → /output
      → cup_pose_relay.py → /cup_pose → pour policy
```

- YOLO만 학습 자산이며 `best.onnx`는 컵 1-class 모델이다.
- FoundationPose는 `assets/Cup/cup.obj`를 사용한다.
- TensorRT `.plan` 파일은 GPU, TensorRT 버전, 빌드 환경에 종속된다. 저장소에
  넣거나 다른 GPU에서 복사하지 말고 대상 머신에서 `build_engines.sh`로 만든다.

## 주요 파일

```text
bootstrap.sh                  Docker/toolkit/LFS/Isaac ROS CLI 설치
setup_jazzy.sh                CLI 이미지 설정과 자산 배치
verify_jazzy_setup.sh         카메라 독립 host/container 검증
docker/Dockerfile.perception  Jazzy perception 이미지 레이어
launch/build_engines.sh       ONNX → TensorRT 엔진
launch/run_cup_pose_standalone.sh
models/ assets/ nodes/ config/
```

## 운영 주의사항

- 8 GB GPU에서는 FoundationPose tracking의 추정/추적 엔진 동시 상주가 OOM을
  일으킨다. `run_cup_pose_standalone.sh`의 추정 모드를 사용한다.
- 커스텀 YOLO 모델은 클래스 수가 디코더까지 전달되어야 한다.
  `patch_yolo_numclasses.py`의 idempotent `num_classes` 패치를 유지하고 모델의
  클래스 수와 실행 설정을 맞춘다.
- D435i 펌웨어는 호스트에서 확인한다. 검증된 버전은 5.16.0.1이며 컨테이너
  안에서 펌웨어를 업데이트하면 recovery 모드에 빠질 수 있다.
- 기존 fragment 기반 `run_cup_pose.sh`는 이 D435i에서 프레임 전달에 실패했다.
  Jazzy 라이브 기본 경로는 `run_cup_pose_standalone.sh`다.

## sim2real 연결

`/output` 또는 `/pose_estimation/pose_matrix_output`을
`sim2real/scripts/cup_pose_relay.py`가 `/cup_pose`로 변환한다.
`sim2real/config/global_camera_extrinsics.yaml`의 카메라 extrinsics와
컵 CAD↔simulation body 정합은 실제 장비에서 반드시 보정해야 한다.
