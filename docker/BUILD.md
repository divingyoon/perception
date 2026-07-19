# Docker 이미지 빌드 (21GB tar 대체)

기존엔 완성된 커스텀 이미지(21GB tar)를 `docker load` 했지만, 그 tar 는 **공식 재료를
조합한 스냅샷**일 뿐이라 여기서 `docker build` 로 재현한다. 그러면 tar 를 옮길 필요가 없고
레포에는 이 작은 텍스트 레시피만 남는다.

## 무엇을 조합하나
| 조각 | 출처 | 방식 |
|---|---|---|
| base(CUDA·TensorRT·ROS humble) | NVIDIA `isaac_ros_common` | 표준 layer `Dockerfile.ros2_humble` |
| **librealsense**(SDK, 소스빌드) | Intel | 표준 layer `Dockerfile.realsense` |
| Isaac ROS 패키지(FoundationPose/SAM/YOLOv8/examples 등) | NVIDIA isaac apt repo | `Dockerfile.perception` 가 apt install |
| cyclonedds 설정·env(DOMAIN_ID=126 등) | 우리 | `Dockerfile.perception` |

즉 우리 커스텀은 **`Dockerfile.perception` 레이어 하나**뿐이고, base·librealsense 는
isaac_ros_common 의 표준 layer 가 만든다.

## 사전 준비 (호스트)
- NVIDIA GPU + 드라이버, Docker + `nvidia-container-toolkit`, git, git-lfs.
- `perception/host_setup.sh` 실행(usbfs·rmem_max·udev). rmem_max 는 cyclonedds 10MB 버퍼에 필수.

## 빌드 절차
```bash
# 1) isaac_ros_common 확보 (워크스페이스 src 아래)
mkdir -p ~/workspaces/isaac_ros-dev/src && cd ~/workspaces/isaac_ros-dev/src
git clone https://github.com/NVIDIA-ISAAC-ROS/isaac_ros_common.git

# 2) isaac_ros_common 이 우리 Dockerfile.perception 을 찾도록 설정
#    (isaac_ros_common 을 수정하지 않고 외부 디렉토리를 검색 경로에 추가)
cat > ~/workspaces/isaac_ros-dev/src/isaac_ros_common/scripts/.isaac_ros_common-config <<EOF
CONFIG_IMAGE_KEY=ros2_humble.realsense.perception
CONFIG_DOCKER_SEARCH_DIRS=(<perception_경로>/docker)
EOF
#    <perception_경로> = 이 레포를 clone 한 절대경로 (예: ~/rl_ws/perception)

# 3) 빌드 + 컨테이너 기동 (base → realsense → perception 체인 자동 빌드, 수십 분)
cd ~/workspaces/isaac_ros-dev/src/isaac_ros_common
./scripts/run_dev.sh -d ~/workspaces/isaac_ros-dev
#    최초 실행은 --skip_image_build 없이 → 이미지 빌드. 결과 = isaac_ros_dev-x86_64:latest
#    (이후 실행부터는 --skip_image_build 로 재사용)
```
빌드가 끝나면 이미지 이름이 `isaac_ros_dev-x86_64` 라서 SETUP_GUIDE/RUN.md 의 이후 단계
(`setup_workspace.sh` → `build_engines.sh` → `run_cup_pose_standalone.sh`)가 그대로 이어진다.

## 검증
```bash
docker exec -u admin isaac_ros_dev-x86_64-container bash -lc \
  'which rs-enumerate-devices; ros2 pkg prefix isaac_ros_foundationpose; echo DOMAIN=$ROS_DOMAIN_ID'
# rs-enumerate-devices(librealsense) 경로 + foundationpose 패키지 경로 + DOMAIN=126 나오면 OK
```

## ⚠️ 트러블슈팅 (첫 빌드 = bring-up)
- **isaac apt 패키지 못 찾음**: base layer 가 isaac apt repo 를 설정하는지 확인. 안 되면
  `Dockerfile.perception` 상단에 NVIDIA isaac apt source+key 추가 필요(isaac_ros_common
  문서 참조). 현재 이미지 = 3.2.x 버전대.
- **버전 고정 필요**: 재현성 위해 `ros-humble-isaac-ros-foundationpose=3.2.14-0jammy` 처럼
  버전 pin 가능(현재 이미지 버전은 CHANGELOG/메모리 참조).
- **librealsense 버전**: `.realsense` layer 가 핀한 버전을 따른다(현재 이미지는 2.55.1).
  특정 버전이 필요하면 `Dockerfile.realsense` 의 ARG 확인.
- 빌드가 안 되면 기존 방식(21GB tar `docker load`)으로 폴백 가능 — SETUP_GUIDE §4.

## 참고 — 왜 tar 대신 이걸 쓰나
- 레포가 작게 유지됨(이 레시피는 수 KB). tar 전송(21GB) 불필요.
- 재료가 전부 공식이라 어느 머신에서든 `git clone` → build 로 재현.
- 단점: 첫 빌드에 시간(수십 분)과 네트워크 필요. 급하면 tar `docker load` 가 빠름.

---

## Blackwell(RTX 50/PRO 6000) 대응 — 목표: Isaac ROS release-4.5

**배경**: 전 머신이 Blackwell(5080·5090·server 6000)로 가는데, 현재 이미지(Isaac ROS **3.2**,
Ubuntu 22.04, CUDA 12.x)는 Blackwell(sm_120)을 지원 안 한다. Blackwell 지원은 **release-4.5**부터.

**release-4.5 요구사항** (nvidia-isaac-ros.github.io/getting_started):
| 항목 | 3.2 (현재) | 4.5 (Blackwell) |
|---|---|---|
| CUDA | 12.x | **13.0+** |
| TensorRT | ~8.x | 10.13 |
| 드라이버 | — | **580+** (pc5090=580.159 ✅) |
| OS | 22.04 | **24.04** |
| ROS | **Humble** | **Jazzy** |

**즉 base 태그 교체가 아니라 major 마이그레이션**:
- `isaac_ros_common` → release-4.5 브랜치, run_dev.sh 로 CUDA13/Ubuntu24.04 base 빌드.
- `Dockerfile.perception` 의 `ros-humble-isaac-ros-*` → **`ros-jazzy-isaac-ros-*`** (4.5 버전).
- launch fragment·FoundationPose 노드 파라미터·**num_classes 패치**를 4.5 API 로 재검증.
- 엔진(.plan) TensorRT 10.13 으로 재빌드(build_engines.sh, GPU별).
- 커스텀 rclpy 노드(bbox_depth_mask·pose_overlay·pose_smoother·detection_filter)는 대부분 포팅되나 Jazzy 확인 필요.

**전략**: 4.5/Jazzy 로 레시피를 한 번 맞추면 → 전 Blackwell 머신 동일 이미지 재현(환경별 충돌 최소화).
**검증**: 5090 이 지금 있으니, 3070→5080 교체 전에 5090 에서 4.5 build+run 을 통과시켜 두면 됨.
**주의**: 마이그레이션은 미착수. 위 3.2 레시피는 Ampere(3070) 용으로 계속 유효.
