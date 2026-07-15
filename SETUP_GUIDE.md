# perception 설치 가이드 — D435i + FoundationPose 라이브 컵 pose

새 비전 PC(예: RTX 3070)에서 이 레포를 **한 번에** 세팅하기 위한 런북.
2026-07 s2r 구축에서 실제로 막혔던 함정과 해결을 순서대로 담았다.
막히면 먼저 [§8 트러블슈팅](#8-트러블슈팅)을 본다.

> **핵심 요약(먼저 읽기)**
> 1. 이 스택은 NVIDIA stock 이 아니라 **커스텀 Isaac ROS 컨테이너 이미지**(FoundationPose+YOLO+SAM 3단)를 쓴다.
> 2. 카메라는 **stock fragment realsense 를 쓰지 않는다** — 이 D435i에서 프레임 delivery 실패. **단독 realsense2_camera + 브리지**로 우회한다(`cup_pose_standalone_cam.launch.py`).
> 3. **stock isaac_ros_yolov8 launch 는 num_classes 를 디코더에 배선하지 않는 버그**가 있어 커스텀 N-class 모델이 첫 프레임에 SIGSEGV(-11) 로 죽는다. → 기동 스크립트가 자동 패치(`patch_yolo_numclasses.py`).
> 4. YOLO 는 **학습한 물체만** 검출한다(zero-shot 아님). 학습 대상과 실물 색/모양이 다르면 검출 0.

---

## 0. 아키텍처

```
D435i ─▶ [단독 realsense2_camera]  /camera/color/image_raw (rgb8, plain)
              │                     /camera/aligned_depth_to_color/image_raw
              ▼  (카메라 브리지, in-process 아님/별도 컨테이너)
     ImageFormatConverter(rgb8) ─▶ /image_rect
     ConvertMetric(uint16 mm→m) ─▶ /depth
              │
              ▼
   YOLOv8(컵 bbox) ─▶ SAM(마스크) ─▶ sam_mask_to_mono8 ─▶ /segmentation
              │                                              │
              └───────────────┬──────────────────────────────┘
                              ▼
        FoundationPose(Cup.obj + 마스크 + depth) ─▶ /output(Detection3DArray)
                              │
                              ▼
      sim2real/cup_pose_relay.py ─▶ /cup_pose ─▶ pour 정책(pour_inference)
```

- **YOLO만 학습 자산**(컵 1-class, `best.onnx`). SAM·FoundationPose 는 zero-shot.
- 파이프라인은 크래시 없이 돌지만, **실제 pose 는 학습한 컵이 시야에 있어야** 나온다.

---

## 1. 전제

| 항목 | 값/비고 |
|---|---|
| 비전 PC | NVIDIA RTX GPU (3070 8GB 검증). YOLO+SAM+FP 동시 ~6.5GB |
| OS | Ubuntu 22.04, Docker, NVIDIA Container Toolkit |
| 드라이버 | NVIDIA 580 계열 |
| 카메라 | Intel RealSense D435i, **USB3**, 펌웨어 **5.16.0.1**(안정) |
| 컨테이너 이미지 | 커스텀 `isaac_ros_dev-x86_64-container` (별도 tar, ~21GB) |
| TensorRT | 컨테이너 내 v10.3 (엔진은 GPU별 재생성) |

준비물(레포 밖, 별도 전달):
- **커스텀 컨테이너 이미지 tar** (`foundationpose_docker_image/*.tar`)
- **best.onnx** (학습된 컵 detector) — 없으면 §7로 학습
- 컵 CAD, SAM/FP onnx 는 레포 `models/`·`assets/` 에 포함

---

## 2. 호스트 준비 (재부팅 전 1회)

```bash
cd perception
./host_setup.sh          # usbfs / rmem_max / udev / DISPLAY 안내
```

`host_setup.sh` 가 처리/안내하는 것과 **왜 필요한지**:

| 설정 | 안 하면 생기는 증상 |
|---|---|
| `usbfs_memory_mb=1000` (GRUB 영구화) | RealSense color+depth 동시 스트림서 `control_transfer EAGAIN` / `stream start failure` |
| `net.core.rmem_max=2147483647` | cyclonedds 10MB 소켓버퍼 요구 → `rmw handle invalid` 로 **노드 생성 실패** |
| RealSense udev rules | 컨테이너 비-root 가 USB 못 엶 (`RS2_USB_STATUS_ACCESS`) |
| `xhost +local:` + `DISPLAY=:0` | rqt/rviz 가 이 PC 모니터에 안 뜸 |

> usbfs 영구화는 `/etc/default/grub` 수정 + `update-grub` + **재부팅**이 필요.

---

## 3. RealSense 펌웨어 (⚠️ 반드시 호스트에서)

- 권장 안정 버전 **5.16.0.1**. `rs-fw-update` 또는 realsense-viewer 로 확인/설치.
- **컨테이너 안에서 FW 업데이트 금지**: 컨테이너 USB passthrough 가 업데이트 중 recovery PID(0adb) 를 못 잡아 카메라가 **recovery 모드**에 빠진다.
- recovery 로 빠지면: realsense-viewer 가 "D4XX Recovery" 로 잡아 5.16.0.1 로 복구.

확인:
```bash
docker exec -u admin <컨테이너> rs-enumerate-devices -s   # FW 버전/USB 속도
```

---

## 4. 컨테이너 이미지 로드 & 실행

```bash
# 1) 이미지 로드 + run_dev.sh 가 기대하는 이름으로 태그
docker load -i /path/to/isaac_ros_dev-x86_64-container_image.tar
docker tag <로드된 이미지>:latest isaac_ros_dev-x86_64:latest

# 2) 워크스페이스 마운트 준비 (호스트) — 이미지의 /workspaces 는 비어있고 마운트 기대
mkdir -p ~/workspaces/isaac_ros-dev

# 3) 컨테이너 진입 (DISPLAY 로 GUI 확인 가능하게)
export DISPLAY=:0                       # (로컬 모니터 세션에서 xhost +local: 선행)
cd ~/workspaces/isaac_ros-dev/src/isaac_ros_common
./scripts/run_dev.sh --skip_image_build -d ~/workspaces/isaac_ros-dev
#   --skip_image_build 필수 (재빌드 방지). 컨테이너 유저 = admin(passwordless sudo).
```

이후 컨테이너 id 확인: `docker ps -q --filter ancestor=isaac_ros_dev-x86_64`

---

## 5. 자산 배치 & 엔진 빌드

```bash
# [호스트] 레포 자산 → 워크스페이스 마운트로 복사 (1회)
cd perception && ./setup_workspace.sh
#   models(best.onnx/SAM/FP onnx) + Cup.obj + sam_mask_to_mono8.py
#   + yolo_interface_specs.json + launch/* 를 배치

# [컨테이너] TensorRT 엔진 생성 (GPU별, 수 분) — best.plan / FP refine·score
docker exec -u admin <컨테이너> bash -c \
  'export ISAAC_ROS_WS=/workspaces/isaac_ros-dev; \
   /workspaces/isaac_ros-dev/isaac_ros_assets/launch/build_engines.sh'
```

> `.plan` 은 GPU·TRT 버전 종속이라 git 에 넣지 않는다(→ `.gitignore`). 환경마다 재생성.

---

## 6. 파이프라인 실행 & 검증

```bash
# [컨테이너] 전체 우회 파이프라인 기동 (카메라+YOLO+bbox_depth_mask+FoundationPose+pose_overlay)
docker exec -u admin -d <컨테이너> bash -c \
  'export ISAAC_ROS_WS=/workspaces/isaac_ros-dev; \
   /workspaces/isaac_ros-dev/isaac_ros_assets/launch/run_cup_pose_standalone.sh'

# 약 95초 후 검증
docker exec -u admin <컨테이너> bash -c \
  'source /opt/ros/humble/setup.bash; \
   /workspaces/isaac_ros-dev/isaac_ros_assets/launch/run_cup_pose_standalone.sh verify'

# 종료
docker exec -u admin <컨테이너> bash -c \
  '/workspaces/isaac_ros-dev/isaac_ros_assets/launch/run_cup_pose_standalone.sh stop'
```

`run_cup_pose_standalone.sh` 가 자동으로 하는 것:
0. **num_classes 패치 적용**(sudo, idempotent) — §7 참조
1. 단독 realsense + 카메라 브리지 (fragment realsense 우회)
2. YOLO 만 (SAM 제외 — 8GB GPU 절약), 입력 /image_rect
2.5. detection_filter (/detections_output → cup/bottle 만 → /detections_cup)
3. bbox_depth_mask (bbox+depth → /segmentation, SAM 대체)
4. FoundationPose (/output = 컵 6-DOF pose)
5. pose_overlay (/output → RGB 에 3D 축/박스 투영 → /pose_viz)

**RGB 눈으로 확인**(가장 확실):
```bash
# arm3070 로컬 모니터에서 xhost +local: 선행. rqt_image_view 는 PATH 에 없어 `ros2 run` 으로.
docker exec -u admin <컨테이너> bash -c 'source /opt/ros/humble/setup.bash; \
  DISPLAY=:0 ros2 run rqt_image_view rqt_image_view /pose_viz'   # 컵에 3D 축/박스(pose 확인)
#   원본 RGB 만: 끝 토픽을 /camera/color/image_raw 로. /image_rect·/depth 는 NITROS 라 회색.
```

정상 신호:
- `/detections_output` 15~18Hz 발행 (컵 검출 시 box 포함)
- `/pose_estimation/pose_matrix_output` 에 4x4 pose

---

## 7. ⭐ 자동 처리되는 알려진 함정 (배경 이해용)

### 7.1 num_classes 미배선 → 디코더 SIGSEGV (-11)  [자동 패치됨]
- **증상**: 카메라/bag 프레임이 흐르는 순간 컨테이너가 `-11` 로 즉사. gdb 백트레이스 = `YoloV8DecoderNode::InputCallback`.
- **원인**: stock `isaac_ros_yolov8_core.launch.py` 가 `num_classes` 를 `YoloV8DecoderNode` 에 **전달하지 않는다**. 디코더는 하드코딩 기본 80 사용 → 1-class 모델 출력 `[1,5,8400]` 을 `[1,84,8400]` 으로 오해하고 out-of-bounds 읽음.
- **수정**: `launch/patch_yolo_numclasses.py` (idempotent). `/opt/ros` 는 컨테이너 재생성 시 원복되므로 **`run_cup_pose_standalone.sh` 가 기동마다 sudo 로 재적용**.
- **이식 시 주의**: 커스텀 클래스 수 YOLO 를 isaac_ros 에 올릴 때 항상 이 패치 필요. 클래스 수가 다르면 `num_classes:=N` 을 스크립트에서 맞춘다.

### 7.2 fragment realsense 프레임 delivery 실패 → 단독 realsense 우회  [해결됨]
- stock `realsense_mono_rect_depth` fragment 의 realsense(RealSenseNodeFactory)가 이 D435i에서 `/image_rect` 로 프레임을 안 보낸다(FW/IMU/QoS 무관).
- 우회: `cup_pose_standalone_cam.launch.py` = 단독 `realsense2_camera` + `ImageFormatConverterNode(rgb8)` + `ConvertMetricNode`.
- **주의**: 카메라 브리지와 encoder 를 억지로 한 컨테이너에 넣지 말 것. Intel realsense 는 NITROS-native 가 아니라 intra-process 로 안 붙는다. **별도 프로세스(DDS) → converter → encoder** 구조가 맞다.

### 7.3 interface_specs 키 누락 → launch KeyError  [해결됨]
- fragment realsense 를 빼면 그것이 주던 `camera_resolution`/`camera_frame`/`focal_length` spec 이 사라져 sam/yolov8 fragment 가 `'camera_resolution'` KeyError.
- `config/yolo_interface_specs.json` 에 이 키들을 넣어 자립하게 함(이미 반영).

---

## 8. 트러블슈팅

| 증상 | 원인 / 해결 |
|---|---|
| 프레임 흐르면 컨테이너 `-11` 즉사 | num_classes 미배선(§7.1). 패치 적용 확인: `grep num_classes /opt/ros/humble/share/isaac_ros_yolov8/launch/isaac_ros_yolov8_core.launch.py` |
| rqt 에서 `/image_rect` 회색 | NITROS 토픽이라 정상. RGB 는 plain `/camera/color/image_raw` 로 본다 |
| `ros2 topic list`/`hz` 빈 결과 | daemon stale. `ros2 daemon stop` 후 `--no-daemon`. image 토픽 hz 는 sensor QoS 라 거짓음성 |
| RealSense `control_transfer EAGAIN` | usbfs_memory_mb 기본 16MB. `echo 1000 > /sys/module/usbcore/parameters/usbfs_memory_mb` (§2) |
| 노드 생성 시 `rmw handle invalid` | cyclonedds 소켓버퍼. `sysctl -w net.core.rmem_max=2147483647` (§2) |
| GPU 프로세스가 안 죽음(좀비) | 컨테이너 `pkill` 로는 안 죽음(PID 네임스페이스 분리). **호스트**에서 `kill -9 $(nvidia-smi --query-compute-apps=pid --format=csv,noheader)` |
| realsense `failed to set power state` | composable realsense 가 USB 물고 있음. 컨테이너 ROS 프로세스 전부 kill 후 재시도 |
| 카메라 recovery 모드 | FW 를 컨테이너서 만졌기 때문(§3). realsense-viewer 로 5.16.0.1 복구 |
| `matplotlib _ARRAY_API` numpy 충돌 | `pip install --user "matplotlib>=3.8"` |
| 파이프라인 도는데 detection=0 | **학습한 물체가 시야에 없음/색·모양 불일치**(§9). 버그 아님 |
| OOM/`-11` (진짜 메모리) | 좀비로 GPU 꽉 참. 위 좀비 kill 로 정리(8GB 에 YOLO+SAM+FP ~6.5GB 는 정상) |

---

## 9. 새 물체 학습 / 컵 교체

YOLO 는 **학습한 물체만** 검출한다(FoundationPose 는 pose 만 zero-shot, detection 은 아님).

- 실물 컵과 학습 대상이 다르면(예: 학습=빨강, 실물=남색) 검출 0.
- **해결 A**: 학습 대상과 같은 컵 사용.
- **해결 B**: 새 물체 학습 —
  ```
  ~/yolo_train/  (ultralytics)  → 데이터셋 YOLO 포맷 → train → export imgsz640 opset16
  → best.onnx 를 perception/models/yolov8/ 로 교체 → setup_workspace.sh → build_engines.sh
  → run 스크립트의 num_classes 를 클래스 수에 맞춤
  ```
- 새 물체의 CAD 를 `assets/` 에 넣으면 FoundationPose 는 그대로 pose 추정.

---

## 10. sim2real(pour) 연결 — 남은 작업

`/output`(Detection3DArray) → `sim2real/scripts/cup_pose_relay.py` → `/cup_pose`(base 프레임) → `pour_inference.py`.

아직 필요한 것(이 가이드 범위 밖):
- **카메라 extrinsics 캘리브레이션**: `sim2real/config/global_camera_extrinsics.yaml` 이 PLACEHOLDER. hand-eye 캘리브 전엔 `/cup_pose` 가 로봇 좌표계와 안 맞는다.
- **검출되는 컵**(§9) — pose 자체가 나와야 relay 가 의미 있음.
- 관련: `live-pour-sim2real-plan` (pour 루프는 FK 라 grasp 캡처 순간에만 비전 필요).

---

## 부록: 파일 맵

```
perception/
├── host_setup.sh                     호스트 1회 세팅 (usbfs/rmem/udev)
├── setup_workspace.sh                자산 → 워크스페이스 배치
├── SETUP_GUIDE.md                    (이 문서)
├── README.md                         개요
├── models/  assets/  nodes/  config/ 자산·커스텀노드·specs
└── launch/
    ├── cup_pose_standalone_cam.launch.py   단독 realsense + 브리지 (fragment 우회)
    ├── run_cup_pose_standalone.sh          전체 파이프라인 (num_classes 패치 자동)
    ├── patch_yolo_numclasses.py            디코더 -11 수정 패치
    └── build_engines.sh                    GPU별 .plan 생성
```
