# 실행 치트시트 (arm3070 에서)

컵 6-DOF pose 라이브 파이프라인을 **docker 컨테이너 안에서** 돌린다.
설치는 [SETUP_GUIDE.md](SETUP_GUIDE.md), 원리는 [README.md](README.md) 참조.

- **컨테이너 이름**: `isaac_ros_dev-x86_64-container`
- **컨테이너 안 작업 경로**: `/workspaces/isaac_ros-dev/isaac_ros_assets`
- **실행 스크립트**: `.../isaac_ros_assets/launch/run_cup_pose_standalone.sh`
- 명령은 전부 **arm3070 본체 터미널**에서 (ssh 로 하면 rqt 화면이 안 뜬다).

---

## 0. (매번) 화면 출력 권한 — arm3070 로컬 터미널에서 1줄
```bash
xhost +local:
```
> rqt/rviz 가 arm3070 모니터에 뜨게 하는 X 권한. 재부팅하면 다시.

## 1. 컨테이너가 떠 있는지 확인
```bash
docker ps --format '{{.Names}}  {{.Status}}' | grep isaac_ros_dev
```
- `Up ...` 이면 그대로 2번으로.
- 안 보이면(정지 상태) 시작:
  ```bash
  docker start isaac_ros_dev-x86_64-container
  ```
- 컨테이너 자체가 없으면(재설치/재부팅 후 최초) run_dev.sh 로 생성:
  ```bash
  cd ~/workspaces/isaac_ros-dev/src/isaac_ros_common
  ./scripts/run_dev.sh --skip_image_build -d ~/workspaces/isaac_ros-dev
  ```
  (이 경우 자산 배치·엔진이 없으면 아래 "재설치 후 1회" 먼저.)

## 2. 파이프라인 기동  ← 이 한 줄이면 카메라~pose~오버레이 전부 뜬다
```bash
docker exec -u admin -it isaac_ros_dev-x86_64-container bash -lc \
  'cd /workspaces/isaac_ros-dev/isaac_ros_assets/launch && ./run_cup_pose_standalone.sh'
```
약 80초 걸린다(카메라 25s + YOLO 30s + …). 뜨는 것:
1 카메라+브리지 → 2 YOLO(컵) → 2.5 필터 → 3 depth 마스크 → 4 FoundationPose
→ 4.5 pose_smoother(안정화) → 5 pose_overlay(`/pose_viz`)

> 로그: 컨테이너 안 `/tmp/perc_*.log`. "Permission denied" 나오면 이전 로그가 남은 것:
> `docker exec -u admin isaac_ros_dev-x86_64-container bash -lc 'rm -f /tmp/perc_*.log'` 후 재기동.

## 3. 잘 나오는지 검증 (숫자로)
```bash
docker exec -u admin -it isaac_ros_dev-x86_64-container bash -lc \
  'source /opt/ros/humble/setup.bash; \
   /workspaces/isaac_ros-dev/isaac_ros_assets/launch/run_cup_pose_standalone.sh verify'
```
기대: [1]RGB ~15Hz, [2]depth ~15Hz, [3]YOLO class_id 41(cup), [3b]/detections_cup,
[4]/segmentation ~15Hz, [5]/output z=거리(m), [6]/pose_viz.

## 4. 실시간 화면 보기 (컵에 3D 축/박스)
```bash
docker exec -u admin -it isaac_ros_dev-x86_64-container bash -lc \
  'source /opt/ros/humble/setup.bash; \
   DISPLAY=:0 ros2 run rqt_image_view rqt_image_view /pose_viz'
```
- 창이 arm3070 모니터에 뜬다. 안정화된 pose 를 보려면 그대로 `/pose_viz`.
- 원본 RGB 만: 끝 토픽을 `/camera/color/image_raw` 로.
- ⚠️ `rqt_image_view` 는 PATH 에 없어 반드시 `ros2 run` 으로. `/image_rect`·`/depth` 는
  NITROS 라 rqt 에서 회색 — 이미지로 보려면 위 두 토픽만.

## 5. 종료
```bash
docker exec -u admin isaac_ros_dev-x86_64-container bash -lc \
  '/workspaces/isaac_ros-dev/isaac_ros_assets/launch/run_cup_pose_standalone.sh stop'
```
GPU 까지 확실히 비우려면(좀비 남을 때) **호스트에서**:
```bash
for p in $(nvidia-smi --query-compute-apps=pid --format=csv,noheader); do kill -9 $p; done
```

---

## 옵션 / 튜닝 (기동 전 env)
```bash
# pose 안정화 끄기 / 세기 조절 (alpha 클수록 반응↑·덜 매끄러움)
SMOOTH=0 ./run_cup_pose_standalone.sh
SMOOTH_ALPHA=0.5 ./run_cup_pose_standalone.sh
# depth 마스크 대역(±m) — 컵이 잘 안 잡히면 키우고, 배경 섞이면 줄임
MASK_DEPTH_BAND_M=0.08 ./run_cup_pose_standalone.sh
# 커스텀 YOLO(빨강 컵 1-class) 로 전환
YOLO_MODEL=best.onnx YOLO_ENGINE=best.plan YOLO_NUM_CLASSES=1 FILTER_CLASS_IDS=0 ./run_cup_pose_standalone.sh
```

## tracking 모드 (⚠️ 3070 8GB 에서는 OOM — 안 됨)

> **실측 결과(2026-07-15): 3070 8GB 에서 OOM 으로 죽음.** 추정 노드(~7GB)+추적 노드
> 엔진이 동시에 안 올라감 (`NVCV_ERROR_OUT_OF_MEMORY`, 컨테이너 exit -6). tracking 은
> **더 큰 VRAM GPU(예: server RTX PRO 6000 48GB)에서만** 쓸 것. 3070 에서는 검증된
> **추정모드(`run_cup_pose_standalone.sh` + pose_smoother)** 를 사용. 아래 명령은 큰 GPU 용.


추정모드 대신 Selector+추정+추적 3노드로 돌려 GPU 부하↓·rate↑·지터↓ 를 노린다.
**FP 엔진 2개 동시 상주라 8GB(3070)에서 OOM 가능** — 안 뜨면 추정모드로 회귀.

```bash
# 기동 (추정모드 스크립트와 별개 파일)
docker exec -u admin -it isaac_ros_dev-x86_64-container bash -lc \
  'cd /workspaces/isaac_ros-dev/isaac_ros_assets/launch && ./run_cup_pose_tracking.sh'

# 확인 (rate 가 추정모드 3.5Hz 보다 높으면 tracking 동작)
docker exec -u admin -it isaac_ros_dev-x86_64-container bash -lc \
  'source /opt/ros/humble/setup.bash; \
   /workspaces/isaac_ros-dev/isaac_ros_assets/launch/run_cup_pose_tracking.sh verify'

# 종료
docker exec -u admin isaac_ros_dev-x86_64-container bash -lc \
  '/workspaces/isaac_ros-dev/isaac_ros_assets/launch/run_cup_pose_tracking.sh stop'
```
- 화면: `... rqt_image_view /pose_viz` (추정모드와 동일).
- 리셋 주기 조절: 기동 전 `TRACK_RESET_PERIOD_MS=6000` (길수록 추적 위주=가벼움).
- **OOM/에러 나면** `$LOGDIR/tracking.log`(=`/tmp/perc_logs_<uid>/tracking.log`) 확인,
  안 되면 추정모드 `run_cup_pose_standalone.sh` 로 회귀(안정적으로 검증된 경로).

## 재설치 후 1회 (자산/엔진 없을 때)
```bash
# [호스트] 자산 → 워크스페이스
cd ~/rl_ws/perception && ./host_setup.sh && ./setup_workspace.sh
# [컨테이너] TensorRT 엔진 생성 (GPU 종속, 여기서 생성)
docker exec -u admin isaac_ros_dev-x86_64-container bash -lc \
  '/workspaces/isaac_ros-dev/isaac_ros_assets/launch/build_engines.sh'
```

## extrinsics 캘리브 (로봇 좌표로 pose 내려면, 마커 준비 후)
[docs/EXTRINSICS_CALIBRATION.md](docs/EXTRINSICS_CALIBRATION.md) 참조.
요약: 파이프라인 기동 → `tools/grab_frame.py` 로 마커 프레임 저장 →
`tools/calibrate_extrinsics.py --write .../global_camera_extrinsics.yaml`.
