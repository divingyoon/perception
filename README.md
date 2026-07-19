# perception — 컵 6-DOF pose 라이브 인식 (FoundationPose)

> 🚀 **바로 실행하려면 [RUN.md](RUN.md)** (docker 명령·경로 치트시트).

D435i 영상에서 컵의 6-DOF pose를 추정해 sim2real pour 정책의 라이브 입력
(`/cup_pose`)으로 넘기기 위한 지각(perception) 스택. `git clone` 하나로 재현되도록
자산·노드·스크립트를 한 디렉토리에 모았다.

> **➡️ 설치는 [SETUP_GUIDE.md](SETUP_GUIDE.md) 를 따른다.** 새 환경 원샷 설치 런북 +
> 이번 구축에서 겪은 모든 함정(num_classes -11 패치, fragment realsense 우회,
> usbfs/DDS/udev, 좀비 GPU 등)과 해결을 순서대로 담았다. 이 README 는 개요만.

## 파이프라인

```
D435i ─▶ YOLOv8(컵 bbox) ─▶ SAM(마스크) ─▶ sam_mask_to_mono8(mono8+동기화)
                                                          │
                                              ┌───────────┘
                                              ▼
        FoundationPose(컵 CAD + 마스크 + depth) ─▶ /output(6D pose)
                                              │
                                              ▼
                     sim2real/cup_pose_relay.py ─▶ /cup_pose ─▶ pour 정책
```

- **YOLO**만 학습 자산(컵 1-class, `best.onnx`). SAM·FoundationPose는 zero-shot.
- FoundationPose는 컵 CAD(`Cup.obj`)로 pose를 재학습 없이 추정한다.

## 디렉토리

```
perception/
├── models/
│   ├── yolov8/best.onnx          컵 detector (학습본)
│   ├── segment_anything/         SAM (triton: config.pbtxt + 1/model.onnx)
│   └── foundationpose/*.onnx     refine/score
├── assets/Cup/cup.obj            컵 CAD (+ mtl, texture)
├── nodes/sam_mask_to_mono8.py    SAM TensorList → mono8 마스크 변환 노드
├── config/yolo_interface_specs.json
├── launch/
│   ├── build_engines.sh          onnx → TensorRT .plan (GPU 종속, 여기서 생성)
│   └── run_cup_pose.sh           파이프라인 기동/종료
├── setup_workspace.sh            자산을 Isaac ROS 워크스페이스에 배치
└── README.md
```

`.plan`(TensorRT 엔진)은 GPU·버전 종속이라 git에 넣지 않고 `build_engines.sh`로 생성한다.

## 전제

- Isaac ROS FoundationPose 컨테이너 (별도 구축, `foundationpose_docker_image`)
- `usbfs_memory_mb=1000`, RealSense udev, DISPLAY 등 — vision PC 세팅 참조

## 실행 (요약 — 자세히는 SETUP_GUIDE.md)

```bash
# [호스트] 1회 세팅 + 자산 배치
./host_setup.sh                 # usbfs / rmem_max / udev
./setup_workspace.sh            # 자산 → 워크스페이스

# [컨테이너] 엔진 생성(1회) → 전체 파이프라인 기동
launch/build_engines.sh
launch/run_cup_pose_standalone.sh          # 카메라+YOLO+bbox_depth_mask+FoundationPose+pose_overlay
launch/run_cup_pose_standalone.sh verify   # 검증
launch/run_cup_pose_standalone.sh stop     # 종료

# 실시간 보기(arm3070 로컬 xhost +local: 선행):
#   DISPLAY=:0 ros2 run rqt_image_view rqt_image_view /pose_viz          # 컵에 3D 축/박스
#   DISPLAY=:0 ros2 run rqt_image_view rqt_image_view /camera/color/image_raw  # 원본 RGB
#   (rqt_image_view 는 PATH 에 없어 반드시 `ros2 run`. /image_rect·/depth 는 NITROS라 회색)
```

> ⚠️ `launch/run_cup_pose.sh`(구버전, fragment realsense 기반)는 이 D435i에서
> 프레임 delivery 실패로 **동작하지 않는다**. 반드시 `run_cup_pose_standalone.sh` 사용.

## sim2real 연결 (최종 목적)

`/output`(Detection3DArray) 또는 `/pose_estimation/pose_matrix_output`을
`sim2real/scripts/cup_pose_relay.py`가 `/cup_pose`(PoseStamped, base 프레임)로
변환한다. 카메라 extrinsics·컵 CAD↔sim body 정합은
`sim2real/config/global_camera_extrinsics.yaml`에서 보정(실측 필수).

그 `/cup_pose`가 pour 라이브 정책(`sim2real/scripts/pour_inference.py`)의
grasp offset 캡처에 쓰인다 — pour 루프 자체는 FK라 이후 비전 의존 없음.

## 새 물체로 확장

컵 외 새 물체는 `~/yolo_train/`의 YOLOv8 학습 프레임워크로 detector를 학습하고
(`best.onnx` export), 그 물체 CAD를 `assets/`에 넣으면 같은 파이프라인이 돈다.
FoundationPose·SAM은 그대로(zero-shot).

## Docker 이미지
표준 커스텀 이미지는 [docker/BUILD.md](docker/BUILD.md) 로 `docker build` 재현(21GB tar 불필요). 기존 tar `docker load` 방식은 [SETUP_GUIDE.md](SETUP_GUIDE.md) §4.
