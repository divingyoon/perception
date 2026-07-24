# 글로벌 카메라 extrinsics 캘리브레이션 (ArUco)

FoundationPose 는 컵 pose 를 **카메라 optical 프레임**으로 낸다. 로봇이 쓰려면
**robot base 프레임**으로 바꿔야 하고, 그 변환이 `T_base_cam` 이다.
이 값은 `sim2real/config/global_camera_extrinsics.yaml` 의 `camera:` 블록에 들어가며,
`cup_pose_relay.py` 가 읽어 `/output`(카메라 프레임) → `/cup_pose`(base 프레임)로 변환한다.

지금 이 값은 **PLACEHOLDER(단위행렬)** 이라, 캘리브 전에는 `/cup_pose` 가 로봇 좌표로 맞지 않는다.

## 준비물
- ArUco 마커 1장 (예: `DICT_4X4_50`, id 0). A4 로 인쇄, 한 변 길이를 정확히 잰다(예 0.10 m).
  - 생성: https://chev.me/arucogen/ 또는 `cv2.aruco.generateImageMarker`.
- 마커를 **로봇 base 기준 아는 위치**에 평평히 고정 (움직이지 않게).
- opencv-contrib-python (host 에 설치): `pip install opencv-contrib-python`.

## 마커 배치 (가장 쉬운 방법)
마커 평면을 **로봇 base 의 XY 평면과 평행**하게, 마커 +Z 가 위를 향하게 테이블에 둔다.
마커 **중심**의 base 좌표 `[x y z]`(m)만 측정하면 자세(rpy)는 기본 정렬(0 0 0)로 둘 수 있다.
(로봇 TCP 로 마커 중심을 터치해 좌표를 읽는 게 가장 정확.)

축이 어긋난 위치에 둬야 하면 `--marker-rpy roll pitch yaw`(rad)로 마커 프레임의
base 기준 회전을 준다.

## 절차

호스트의 저장소 루트에서 CLI 컨테이너를 연다.

```bash
export ISAAC_ROS_WS="${ISAAC_ROS_WS:-$HOME/workspaces/isaac_ros-dev}"
isaac-ros activate
```

열린 CLI 컨테이너에서 Jazzy 환경과 마운트된 워크스페이스를 사용한다.

```bash
export ISAAC_ROS_WS=/workspaces/isaac_ros-dev
source /opt/ros/jazzy/setup.bash
cd "${ISAAC_ROS_WS}/isaac_ros_assets"

# 1) 파이프라인 기동(카메라 살아있어야 함)
./launch/run_cup_pose_standalone.sh

# 2) 마커가 보이는 프레임 + camera_info를 호스트와 공유되는 경로에 저장
python3 ./tools/grab_frame.py \
  --out ./calib.png --camera-info-out ./camera_info.yaml
```

계산은 호스트의 저장소 루트에서 실행한다. 위 두 파일은
`${ISAAC_ROS_WS}/isaac_ros_assets`에 있으므로 필요하면 현재 저장소로 복사한다.

```bash
# 3) extrinsics 계산 + yaml 기록 (호스트, opencv 있는 곳)
python3 tools/calibrate_extrinsics.py \
    --image "${ISAAC_ROS_WS}/isaac_ros_assets/calib.png" \
    --camera-info "${ISAAC_ROS_WS}/isaac_ros_assets/camera_info.yaml" \
    --marker-length 0.10 --marker-id 0 --aruco-dict DICT_4X4_50 \
    --marker-pos 0.40 0.00 0.00 \
    --write <path>/sim2real/config/global_camera_extrinsics.yaml
```
`--marker-pos` = 마커 중심의 base 좌표. `--write` 를 주면 yaml 의 `camera:` 블록을 자동 갱신.

## 검증
- 출력의 `[검증] 카메라~마커 거리` 가 실제 줄자 거리와 비슷한지 확인(수 cm 이내).
- 캘리브 후 컵을 base 원점 근처 아는 위치에 두고 `/cup_pose` 값이 그 위치와 맞는지 교차 확인.
- 오차 크면: 마커 길이(`--marker-length`) 정확한지, 마커가 평평/고정인지, 마커-base 측정값 재확인.

## 참고
- 카메라를 옮기면 재캘리브 필요(T_base_cam 이 바뀜).
- `cad_to_body`(컵 CAD 메시 → sim body 프레임 보정)는 별개 값 — 컵 CAD 원점이 sim 규약
  (원점=바닥중심, +z=위)과 다르면 그 블록도 채운다. 현재 Cup.obj 는 Y 축이 높이(-0.077~0.100),
  sim 은 +z 가 높이라 축 정합(예: x=+90° 회전)이 필요할 수 있음 — 실기 정합 시 확인.
- QR 코드가 아니라 **ArUco** 를 쓴다(QR 은 6D pose 정밀도가 낮음). AprilTag 도 대안.
