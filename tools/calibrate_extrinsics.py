#!/usr/bin/env python3
r"""글로벌 카메라 extrinsics 1회 캘리브레이션 (ArUco 마커 기반).

로봇 base 프레임의 알려진 위치에 ArUco 마커를 두고 카메라로 한 장 찍으면,
카메라 optical 프레임의 base 프레임 상 pose(T_base_cam)를 계산해
sim2real/config/global_camera_extrinsics.yaml 의 `camera:` 블록에 넣을 값을 출력한다.

수식:
    T_base_cam = T_base_marker ∘ inv(T_cam_marker)
  - T_cam_marker : ArUco 검출(solvePnP)로 카메라가 본 마커 pose
  - T_base_marker: 마커를 로봇 기준 어디에 뒀는지 (사용자 측정값, --marker-pose)

절차:
  1. ArUco 마커(예: DICT_4X4_50, id 0)를 로봇 base 기준 알려진 위치/자세에 평평히 둔다.
     (가장 쉬운 배치: 마커 평면을 base 의 XY 평면과 평행, 마커 +Z=위, 마커 중심의
      base 좌표를 측정. 이 경우 --marker-pose 는 위치만, 자세는 기본 정렬 사용 가능.)
  2. 파이프라인의 /camera/color/image_raw 를 한 장 저장한다:
        python3 tools/grab_frame.py --topic /camera/color/image_raw --out /tmp/calib.png
  3. 이 스크립트 실행:
        python3 tools/calibrate_extrinsics.py \
            --image /tmp/calib.png \
            --camera-info /tmp/camera_info.yaml \   # 또는 --fx --fy --cx --cy [--dist ...]
            --marker-length 0.10 --marker-id 0 --aruco-dict DICT_4X4_50 \
            --marker-pos 0.40 0.00 0.00 --marker-rpy 0 0 0 \
            --write ../sim2real/config/global_camera_extrinsics.yaml

의존성: opencv-contrib-python (cv2.aruco), numpy, pyyaml. (컨테이너 밖 host 에서 실행 권장.)
"""

from __future__ import annotations

import argparse
import sys

import numpy as np

try:
    import cv2
except ImportError:
    sys.exit("cv2(opencv-contrib-python) 필요: pip install opencv-contrib-python")


# --- 회전/쿼터니언 유틸 -----------------------------------------------------

def rpy_to_R(roll: float, pitch: float, yaw: float) -> np.ndarray:
    cr, sr = np.cos(roll), np.sin(roll)
    cp, sp = np.cos(pitch), np.sin(pitch)
    cy, sy = np.cos(yaw), np.sin(yaw)
    Rx = np.array([[1, 0, 0], [0, cr, -sr], [0, sr, cr]])
    Ry = np.array([[cp, 0, sp], [0, 1, 0], [-sp, 0, cp]])
    Rz = np.array([[cy, -sy, 0], [sy, cy, 0], [0, 0, 1]])
    return Rz @ Ry @ Rx


def R_to_quat_wxyz(R: np.ndarray) -> np.ndarray:
    tr = np.trace(R)
    if tr > 0:
        s = np.sqrt(tr + 1.0) * 2
        w = 0.25 * s
        x = (R[2, 1] - R[1, 2]) / s
        y = (R[0, 2] - R[2, 0]) / s
        z = (R[1, 0] - R[0, 1]) / s
    elif R[0, 0] > R[1, 1] and R[0, 0] > R[2, 2]:
        s = np.sqrt(1.0 + R[0, 0] - R[1, 1] - R[2, 2]) * 2
        w = (R[2, 1] - R[1, 2]) / s
        x = 0.25 * s
        y = (R[0, 1] + R[1, 0]) / s
        z = (R[0, 2] + R[2, 0]) / s
    elif R[1, 1] > R[2, 2]:
        s = np.sqrt(1.0 + R[1, 1] - R[0, 0] - R[2, 2]) * 2
        w = (R[0, 2] - R[2, 0]) / s
        x = (R[0, 1] + R[1, 0]) / s
        y = 0.25 * s
        z = (R[1, 2] + R[2, 1]) / s
    else:
        s = np.sqrt(1.0 + R[2, 2] - R[0, 0] - R[1, 1]) * 2
        w = (R[1, 0] - R[0, 1]) / s
        x = (R[0, 2] + R[2, 0]) / s
        y = (R[1, 2] + R[2, 1]) / s
        z = 0.25 * s
    q = np.array([w, x, y, z])
    return q / np.linalg.norm(q)


# --- 카메라 intrinsics 로딩 -------------------------------------------------

def load_intrinsics(args):
    if args.camera_info:
        import yaml
        with open(args.camera_info) as f:
            info = yaml.safe_load(f)
        k = info.get('k') or info.get('K') or info['camera_matrix']['data']
        k = np.array(k, dtype=np.float64).reshape(3, 3)
        d = info.get('d') or info.get('D')
        dist = np.array(d, dtype=np.float64) if d is not None else np.zeros(5)
        return k, dist
    if None in (args.fx, args.fy, args.cx, args.cy):
        sys.exit("--camera-info 또는 --fx/--fy/--cx/--cy 필요")
    k = np.array([[args.fx, 0, args.cx], [0, args.fy, args.cy], [0, 0, 1]])
    dist = np.array(args.dist, dtype=np.float64) if args.dist else np.zeros(5)
    return k, dist


# --- ArUco 검출 → T_cam_marker ----------------------------------------------

def detect_marker(image, K, dist, aruco_dict_name, marker_id, marker_length):
    dict_id = getattr(cv2.aruco, aruco_dict_name)
    aruco_dict = cv2.aruco.getPredefinedDictionary(dict_id)
    # opencv >=4.7 (ArucoDetector) / 구버전(detectMarkers) 모두 지원.
    try:
        detector = cv2.aruco.ArucoDetector(aruco_dict, cv2.aruco.DetectorParameters())
        corners, ids, _ = detector.detectMarkers(image)
    except AttributeError:
        corners, ids, _ = cv2.aruco.detectMarkers(image, aruco_dict)
    if ids is None or marker_id not in ids.flatten():
        sys.exit(f"마커 id {marker_id} 미검출 (검출된 id={None if ids is None else ids.flatten()})")
    idx = int(np.where(ids.flatten() == marker_id)[0][0])
    # 마커 로컬 3D 코너 (중심 원점, +Z 법선). 순서=검출 코너 순서와 일치.
    h = marker_length / 2.0
    obj = np.array([[-h, h, 0], [h, h, 0], [h, -h, 0], [-h, -h, 0]], dtype=np.float64)
    ok, rvec, tvec = cv2.solvePnP(obj, corners[idx][0], K, dist,
                                  flags=cv2.SOLVEPNP_IPPE_SQUARE)
    if not ok:
        sys.exit("solvePnP 실패")
    R_cm, _ = cv2.Rodrigues(rvec)
    return R_cm, tvec.reshape(3)


def main():
    ap = argparse.ArgumentParser(description="글로벌 카메라 extrinsics 캘리브(ArUco)")
    ap.add_argument("--image", required=True, help="마커가 보이는 카메라 프레임(png)")
    ap.add_argument("--camera-info", help="camera_info yaml (k, d)")
    ap.add_argument("--fx", type=float); ap.add_argument("--fy", type=float)
    ap.add_argument("--cx", type=float); ap.add_argument("--cy", type=float)
    ap.add_argument("--dist", type=float, nargs="*")
    ap.add_argument("--marker-length", type=float, required=True, help="마커 한 변(m)")
    ap.add_argument("--marker-id", type=int, default=0)
    ap.add_argument("--aruco-dict", default="DICT_4X4_50")
    ap.add_argument("--marker-pos", type=float, nargs=3, required=True,
                    help="마커 중심의 robot base 좌표 [x y z] (m)")
    ap.add_argument("--marker-rpy", type=float, nargs=3, default=[0, 0, 0],
                    help="마커 프레임의 base 기준 roll pitch yaw (rad). 기본=정렬")
    ap.add_argument("--base-frame", default="base_link")
    ap.add_argument("--write", help="이 경로의 global_camera_extrinsics.yaml camera 블록을 갱신")
    args = ap.parse_args()

    image = cv2.imread(args.image)
    if image is None:
        sys.exit(f"이미지 로드 실패: {args.image}")
    K, dist = load_intrinsics(args)

    R_cm, t_cm = detect_marker(image, K, dist, args.aruco_dict,
                               args.marker_id, args.marker_length)
    # inv(T_cam_marker) = T_marker_cam
    R_mc = R_cm.T
    t_mc = -R_mc @ t_cm
    # T_base_marker
    R_bm = rpy_to_R(*args.marker_rpy)
    t_bm = np.array(args.marker_pos, dtype=np.float64)
    # T_base_cam = T_base_marker ∘ T_marker_cam
    R_bc = R_bm @ R_mc
    t_bc = R_bm @ t_mc + t_bm
    q_bc = R_to_quat_wxyz(R_bc)

    print("=== T_base_cam (robot base ← camera_color_optical_frame) ===")
    print("camera:")
    print("  frame: camera_color_optical_frame")
    print("  position: [%.6f, %.6f, %.6f]" % tuple(t_bc))
    print("  orientation_wxyz: [%.6f, %.6f, %.6f, %.6f]" % tuple(q_bc))
    print("base_frame: %s" % args.base_frame)
    dist_cam = float(np.linalg.norm(t_cm))
    print(f"\n[검증] 카메라~마커 거리 = {dist_cam:.3f} m (실제 거리와 비슷해야 함)")

    if args.write:
        import yaml
        with open(args.write) as f:
            cfg = yaml.safe_load(f)
        cfg["camera"] = {
            "frame": "camera_color_optical_frame",
            "position": [float(v) for v in t_bc],
            "orientation_wxyz": [float(v) for v in q_bc],
        }
        with open(args.write, "w") as f:
            yaml.safe_dump(cfg, f, sort_keys=False, allow_unicode=True)
        print(f"\n[기록] {args.write} 의 camera 블록 갱신 완료.")


if __name__ == "__main__":
    main()
