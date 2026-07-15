# CHANGELOG — perception (D435i + FoundationPose 라이브 컵 pose)

설치·연결은 [SETUP_GUIDE.md](SETUP_GUIDE.md), 개요는 [README.md](README.md) 참조.
이 문서는 **무엇을·왜 바꿨는지**의 이력.

## 2026-07-15 (후속) — 시각화 정밀화 + pose 안정화 + extrinsics 캘리브 도구

### 박스 CAD 정합 (#3)
- `pose_overlay.py`: 박스를 컵 CAD(`Cup.obj`) 실측 AABB(min/max, mesh 원점 기준)로 그림.
  실측 = X 9cm × Y 17.8cm × Z 9cm(원점 비대칭). `box_min_m`/`box_max_m` 파라미터.

### pose 안정화 필터 (#2, 즉시 적용분)
- `nodes/pose_smoother.py` (신규): `/output` → 위치 EMA + 자세 slerp + 튐(outlier) 제거
  → `/output_smooth`. 단일 FoundationPose(추정모드)의 프레임간 지터를 바로 완화.
  `alpha`(기본 0.3), `jump_reject_m`(0.15), 연속 튐 시 리셋. slerp/EMA 수식 자체검증(오차 1e-15).
- run 스크립트 4.5 단계로 편입(`SMOOTH=1` 기본). 켜면 overlay/relay 소비 토픽=`/output_smooth`.
- **정석 Isaac tracking 은 별도 TODO(GPU 세션 필요)**: `foundationpose_tracking_core.launch.py`
  구조 = `Selector`(reset_period 로 추정↔추적 라우팅) + `FoundationPoseNode`(추정) +
  `FoundationPoseTrackingNode`(추적, refine 만) + `Detection2DToMask`(내장 마스크). 3노드를 한
  컨테이너에 내부 토픽으로 묶어야 하고 메모리 재확인 필요 → GPU 붙여 배선·튜닝.

### tracking 모드 CLI + 실측 = 8GB OOM (#2 후속)
- `launch/cup_pose_tracking.launch.py` + `launch/run_cup_pose_tracking.sh` (신규):
  Selector+FoundationPoseNode(추정)+FoundationPoseTrackingNode(추적) 3노드 컨테이너에
  기존 /image_rect·/depth·/segmentation 공급. **실측 결과 3070 8GB 에서 OOM**
  (`NVCV_ERROR_OUT_OF_MEMORY`, 두 FP 노드 엔진 동시 상주, 컨테이너 exit -6).
- 교훈: tracking 은 **연산 사용률은 낮으나 VRAM footprint 는 더 큼**(엔진 2벌). 8GB 불가,
  ≥큰 VRAM(server RTX PRO 6000) 필요. score batch 축소는 추정 노드 satisfyProfile 오류라 불가.
- 3070 권장 경로 = 추정모드 + pose_smoother(검증됨). tracking CLI 는 큰 GPU 용으로 보존.

### extrinsics 캘리브 도구 (#1)
- **릴레이는 이미 존재**(`sim2real/scripts/cup_pose_relay.py`): `T_base_body =
  T_base_cam ∘ T_cam_cad ∘ T_cad_body` 로 `/output`→`/cup_pose`(base 프레임). 빈 건
  `sim2real/config/global_camera_extrinsics.yaml` 의 `camera:`(T_base_cam, 현재 PLACEHOLDER).
- `tools/calibrate_extrinsics.py` (신규): ArUco 마커 기반 1회 캘리브.
  `T_base_cam = T_base_marker ∘ inv(T_cam_marker)`. 마커를 로봇 기준 아는 위치에 두고 1장 찍으면
  yaml `camera:` 블록 자동 갱신(`--write`). **변환 수식 200회 합성검증(오차 1e-15).**
- `tools/grab_frame.py` (신규): 라이브 프레임 + camera_info(yaml) 저장(PIL, cv2 없이). 캘리브 입력용.
- `docs/EXTRINSICS_CALIBRATION.md` (신규): 마커 배치·절차·검증 런북. QR 아닌 **ArUco** 권장.
- setup_workspace 에 tools/ 배치 추가.

## 2026-07-15 — 컵 pose 라이브 파이프라인 end-to-end 완성 (SAM 제거)

카메라 재연결 후 실검증하며 마지막 두 벽을 뚫어 **FoundationPose 6-DOF 컵 pose 실출력**까지 완성.

### 결과 (arm3070 RTX 3070 단독, 실측)
- `카메라(15Hz) → YOLO 컵(15Hz) → detection_filter → bbox_depth_mask(15Hz) → FoundationPose`
- `/output` position z≈0.31m 로 컵을 **안정 추적** (여러 샘플 0.309~0.310 일관).
- GPU 7.3GB/8GB. `./run_cup_pose_standalone.sh verify` 전 단계 그린.

### 뚫은 벽 2개
1. **SAM 마스크 노드가 조용히 죽어 있었음 (cv2 + NumPy 2.x 충돌)**
   `sam_mask_to_mono8.py` 가 `import cv2` 에서 `_ARRAY_API not found` 로 크래시 →
   `/segmentation` 이 아예 안 나와 FP 가 입력을 못 받고 있었음(이전 세션 "미검증"의 진짜 원인).
   cv2 는 nearest-neighbor resize 한 곳에만 쓰여서, numpy 전용 `_nearest_resize` 로 대체.

2. **8GB GPU 에 SAM(~3.5GB)+FoundationPose(~5GB) 동시 상주 불가**
   score 엔진 batch 축소(252→42)로 score OOM 은 없앴으나 FP **렌더러**가 OOM →
   illegal memory access. FP hypothesis 수(252)는 GXF 코델릿에 박혀 파라미터로 못 줄임.
   **해결: SAM 자체를 제거**하고 YOLO bbox + depth 임계로 마스크 생성(`bbox_depth_mask.py`).
   SAM 3.5GB 통째로 확보 → FP 단독으로 여유롭게 상주. 마스크도 SAM 2.9Hz → 15Hz 로 개선.

### 구조 변경
- `launch/run_cup_pose_standalone.sh`: `launch_fragments:=yolov8`(SAM 제외),
  `image_input_topic:=/image_rect`, step3 를 sam_mask_to_mono8 → **bbox_depth_mask** 로 교체.
  stop/verify 갱신. `MASK_DEPTH_BAND_M`(기본 0.06) 노출.
- `nodes/bbox_depth_mask.py` (신규): detection_filter 의 bbox 를 letterbox(640²) 역변환 후
  aligned depth(16UC1 mm) 에서 median±band 로 mono8 마스크 생성. depth 프레임 stamp 사용
  → FP 동기화 보장. detection_timeout 지나면 빈 마스크.
- `nodes/sam_mask_to_mono8.py`: cv2 → numpy `_nearest_resize`. (SAM 경로 fallback 으로 보존)
- `setup_workspace.sh`: bbox_depth_mask.py 배치 추가.
- FoundationPose score 엔진은 **원본 max batch 252** 유지(SAM 제거로 축소 불필요).
  코델릿이 score 를 252 배치 한 번에 돌려서, 42 로 줄이면 satisfyProfile 오류.

### pose 시각화 편입 (pose_overlay)
- `nodes/pose_overlay.py` (신규): `/output`(Detection3DArray)의 6-DOF pose 를
  카메라 K 로 RGB 에 투영 → 3D 축(X 빨강/Y 초록/Z 파랑)+3D 박스+z거리 텍스트를
  `/pose_viz`(rgb8) 로 발행. **PIL(ImageDraw) 사용 — cv2/numpy2 충돌 회피.**
  최신 RGB+최신 pose 합성(정밀 sync 불필요, 시각화용). 박스는 bbox.size, 0이면
  기본 8×8×12cm. `run_cup_pose_standalone.sh` step5 로 정식 편입(기동 1번에 다 뜸).
- 실시간 보기: arm3070 로컬 `xhost +local:` 후
  `DISPLAY=:0 ros2 run rqt_image_view rqt_image_view /pose_viz`.
  ⚠️rqt_image_view 는 PATH 에 없음 → `ros2 run` 으로. 컨테이너 안에서 실행
  (호스트엔 ROS 없어 토픽 안 보임). NITROS 토픽(/image_rect)은 회색.

### 운영 함정 추가
- ros2 CLI `topic hz/echo` 가 daemon staleness 로 "not published" 오탐 빈번 →
  확인 전 `ros2 daemon stop`. (verify 서브커맨드에 반영)
- 컨테이너 in-container root 가 admin 소유 /tmp 로그에 못 씀(userns remap 추정).
  stale 로그는 `rm -f` 후 재기동. setsid nohup + disown 으로 프로세스 분리(ssh 타임아웃에 안 죽게).

## 2026-07-14 — 초기 구축 + 라이브 파이프라인 안정화

### 추가된 산출물
| 파일 | 역할 |
|---|---|
| `SETUP_GUIDE.md` | 새 환경 원샷 설치 런북 + 트러블슈팅 |
| `host_setup.sh` | 호스트 1회 세팅(usbfs / rmem_max / udev / DISPLAY) |
| `setup_workspace.sh` | 레포 자산 → Isaac ROS 워크스페이스 배치 |
| `launch/cup_pose_standalone_cam.launch.py` | 단독 realsense + 카메라 브리지(rgb8 /image_rect, /depth) |
| `launch/run_cup_pose_standalone.sh` | 전체 파이프라인 오케스트레이션(패치 자동 + stop/verify) |
| `launch/patch_yolo_numclasses.py` | ⭐ yolov8 디코더 num_classes 배선 패치 |
| `launch/build_engines.sh` | GPU별 TensorRT `.plan` 생성 |
| `nodes/sam_mask_to_mono8.py` | SAM TensorList → mono8 마스크 |
| `nodes/detection_filter.py` | COCO 검출 → cup/bottle만 최고1개 → /detections_cup |
| `config/yolo_interface_specs.json` | 인터페이스 스펙(camera_resolution 등 + prompt=/detections_cup) |

### 해결한 핵심 이슈 (다른 환경 이식 시 동일하게 필요)

1. **⭐ yolov8 디코더 SIGSEGV(-11) — num_classes 미배선**
   stock `isaac_ros_yolov8_core.launch.py` 가 `num_classes` 를 `YoloV8DecoderNode`
   에 전달하지 않아, 커스텀 N-class 모델의 출력 텐서를 기본 80클래스로 오해 →
   out-of-bounds → 첫 프레임에 즉사. gdb 코어덤프로 확정.
   → `patch_yolo_numclasses.py` 로 배선(run 스크립트가 기동마다 sudo 자동 적용).

2. **fragment realsense 프레임 delivery 실패 → 단독 realsense 우회**
   stock `realsense_mono_rect_depth` fragment 의 realsense 가 이 D435i에서
   `/image_rect` 로 프레임을 안 보냄(FW/IMU/QoS 무관). → 단독 `realsense2_camera`
   + `ImageFormatConverterNode(rgb8)` + `ConvertMetricNode` 로 우회.
   ⚠️ Intel realsense 는 NITROS-native 가 아니므로 encoder 와 억지로 한 컨테이너에
   넣지 말 것(intra-process 로 안 붙음). 별도 프로세스(DDS)→converter→encoder.

3. **interface_specs 키 누락 KeyError**
   fragment realsense 를 빼면 그것이 주던 `camera_resolution`/`camera_frame`/
   `focal_length` 가 사라져 sam/yolov8 fragment 가 KeyError. → json 에 명시.

4. **탐지 경로: 재학습 없이 임의 색 컵 — stock COCO + 필터**
   커스텀 1-class 모델은 학습 색(빨강)만 검출. 대신 stock COCO `yolov8s` 사용
   (cup=41/bottle=39, 색 무관) + `detection_filter.py` 로 컵 계열만 남겨
   FoundationPose 프롬프트로. 실제 pose 는 우리 `Cup.obj` CAD 가 계산하므로
   탐지기는 위치만 잡으면 됨. run 스크립트 기본값 = COCO(env 로 커스텀 전환 가능).

### 검증 상태
- ✅ RGB 라이브(`/camera/color/image_raw` 14.5~15Hz, rqt 확인)
- ✅ 파이프라인 크래시 없이 end-to-end 가동(YOLO+SAM+FP, GPU ~6.5GB/8GB)
- ✅ `/detections_output` 15~18Hz 발행(bag/live)
- ⚠️ 실제 컵 pose 미검증: (1) 밝은 배경 필요(어두운 장면선 COCO도 약함),
  (2) 카메라 extrinsics 캘리브(sim2real, PLACEHOLDER) 미완.

### 알려진 운영 함정 (SETUP_GUIDE §8 상세)
- 좀비 GPU 프로세스는 **호스트**에서 kill(`nvidia-smi` PID). 컨테이너 pkill 은 PID 네임스페이스 분리로 실패.
- realsense 반복 재시작 → USB 먹통(`set_xu failed`/EAGAIN). **물리 재연결**이 답. usbfs_memory_mb=1000 필수.
- `ros2 topic hz/list` daemon stale → `--no-daemon`. NITROS 토픽(/image_rect)은 rqt 회색(정상) → plain `/camera/color/image_raw` 로 확인.

### DEPRECATED
- `launch/run_cup_pose.sh` — fragment realsense 기반, 이 D435i에서 미동작.
  `run_cup_pose_standalone.sh` 사용.
