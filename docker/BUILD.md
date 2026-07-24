# Isaac ROS 4.5/Jazzy 이미지 빌드

이 브랜치는 공식 Isaac ROS CLI의 Docker 레이어 시스템을 사용한다. 별도 tar
이미지나 외부 `isaac_ros_common` checkout은 필요하지 않다.

지원 호스트는 Ubuntu 24.04 `x86_64`, NVIDIA Ampere 이상 GPU, NVIDIA 드라이버
580 이상이다.

## 레이어 구성

| 이미지 키 | 제공자 | 내용 |
|---|---|---|
| CLI 기본 키 | NVIDIA Isaac ROS CLI 4.5 | Ubuntu 24.04, ROS 2 Jazzy, CUDA/TensorRT |
| `realsense` | NVIDIA Isaac ROS CLI 4.5 | RealSense 의존성 |
| `perception` | 이 저장소 | FoundationPose, YOLOv8, RealSense와 로컬 설정 |

`setup_jazzy.sh`가 워크스페이스 설정에 `realsense`, `perception` 순서로 키를
등록하고, Docker 검색 경로에 이 저장소의 `docker/`와
`/etc/isaac-ros-cli/docker`를 모두 넣는다.

## 호스트 준비

Ubuntu 24.04에서 저장소 루트의 다음 명령을 실행한다.

```bash
./bootstrap.sh
# Docker 그룹 권한 반영을 위해 로그아웃 후 다시 로그인
export ISAAC_ROS_WS="${ISAAC_ROS_WS:-$HOME/workspaces/isaac_ros-dev}"
docker info >/dev/null
docker run --rm --gpus all ubuntu:24.04 bash -lc 'nvidia-smi >/dev/null'
sudo isaac-ros init docker
./setup_jazzy.sh
./verify_jazzy_setup.sh --host
```

`bootstrap.sh`는 공식
`https://isaac.download.nvidia.com/isaac-ros/release-4.5 noble main`
APT source를 idempotent하게 등록하고 `isaac-ros-cli`를 설치한다.

## 빌드

```bash
export ISAAC_ROS_WS="${ISAAC_ROS_WS:-$HOME/workspaces/isaac_ros-dev}"
isaac-ros activate --build-local
```

CLI가 `Dockerfile.perception`을 찾아 기본 이미지 위에 로컬 레이어를 만든다.
레이어 변경이 없을 때는 다음부터 `isaac-ros activate`로 재사용할 수 있다.

## 컨테이너 검증과 엔진

활성화된 컨테이너 안에서:

```bash
export ISAAC_ROS_WS=/workspaces/isaac_ros-dev
cd "${ISAAC_ROS_WS}/isaac_ros_assets"
./verify_jazzy_setup.sh --container
./launch/build_engines.sh
```

검증은 카메라를 요구하지 않는다. 빌더는 기본 `yolov8s.plan`과 커스텀
`best.plan`을 모두 생성한다. TensorRT 엔진은 GPU/드라이버/CUDA/TensorRT 조합에
종속되므로 대상 머신에서 생성하고 이미지가 바뀌면 다시 빌드한다.

## 문제 해결

- `isaac-ros`를 찾지 못하면 host APT source와 `isaac-ros-cli` 설치를 확인한다.
- `perception` 레이어를 찾지 못하면
  `${ISAAC_ROS_WS}/scripts/.isaac_ros_common-config`에 저장소의 절대
  `docker/` 경로와 `/etc/isaac-ros-cli/docker`가 모두 있는지 확인한다.
- 이미지 키 순서는 `realsense` 다음 `perception`이어야 한다.
- 패키지를 찾지 못하면 `Dockerfile.perception`이 `ros-jazzy-*` 패키지를
  사용하고 공식 release-4.5 source가 컨테이너에 있는지 확인한다.
- 커스텀 YOLO 모델은 `num_classes` 패치와 실행 설정의 클래스 수가 일치해야 한다.
- 8 GB GPU에서는 tracking 엔진 동시 상주가 OOM을 일으킬 수 있으므로
  standalone 추정 모드를 사용한다.
- D435i 펌웨어 5.16.0.1 확인과 업데이트는 호스트에서만 수행한다.
