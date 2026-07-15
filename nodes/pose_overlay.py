#!/usr/bin/env python3

# SPDX-License-Identifier: Apache-2.0
#
# FoundationPose 의 6-DOF pose(/output, Detection3DArray)를 RGB 위에 투영해
# 3D 축(빨강=X, 초록=Y, 파랑=Z)과 3D 바운딩박스를 그려 /pose_viz 로 발행한다.
# rqt_image_view /pose_viz 로 "컵에 축이 붙어 도는" 것을 실시간 확인용.
#
# cv2 대신 PIL(ImageDraw) 사용 — 컨테이너 NumPy 2.x + cv2 충돌 회피.
# 최신 RGB + 최신 pose 를 합쳐 pose 수신 시마다 그린다(정밀 sync 불필요, 시각화용).

import numpy as np
import rclpy
from rclpy.node import Node
from sensor_msgs.msg import CameraInfo, Image
from vision_msgs.msg import Detection3DArray
from PIL import Image as PImage
from PIL import ImageDraw


def quat_to_rot(x, y, z, w):
    n = (x * x + y * y + z * z + w * w) ** 0.5
    if n < 1e-9:
        return np.eye(3)
    x, y, z, w = x / n, y / n, z / n, w / n
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ], dtype=np.float64)


class PoseOverlay(Node):
    """FoundationPose pose 를 RGB 에 투영해 축/박스 오버레이 발행."""

    # 3D 박스 12 엣지 (8 코너 인덱스 쌍)
    BOX_EDGES = [(0, 1), (1, 3), (3, 2), (2, 0),
                 (4, 5), (5, 7), (7, 6), (6, 4),
                 (0, 4), (1, 5), (2, 6), (3, 7)]

    def __init__(self):
        super().__init__('pose_overlay')
        self.declare_parameter('image_topic', '/camera/color/image_raw')
        self.declare_parameter('camera_info_topic', '/camera/color/camera_info')
        self.declare_parameter('pose_topic', '/output')
        self.declare_parameter('output_topic', '/pose_viz')
        self.declare_parameter('axis_length_m', 0.05)   # 축 길이(m)
        # 컵 CAD(Cup.obj) 의 AABB (mesh 원점 기준, m). FoundationPose pose 는 mesh
        # 원점 pose 이므로 이 min/max 를 pose 로 변환하면 박스가 컵에 정확히 맞는다.
        # 기본값 = assets/Cup/cup.obj 실측(9×17.8×9cm, 원점 비대칭).
        self.declare_parameter('box_min_m', [-0.0463, -0.0773, -0.0440])
        self.declare_parameter('box_max_m', [0.0437, 0.1003, 0.0460])

        self.axis_len = float(self.get_parameter('axis_length_m').value)
        self.box_min = np.array(self.get_parameter('box_min_m').value, dtype=np.float64)
        self.box_max = np.array(self.get_parameter('box_max_m').value, dtype=np.float64)

        self._img = None          # (H, W, 3) uint8 rgb
        self._K = None            # (fx, fy, cx, cy)

        self.pub = self.create_publisher(
            Image, self.get_parameter('output_topic').value, 10)
        self.create_subscription(
            Image, self.get_parameter('image_topic').value, self._on_img, 10)
        self.create_subscription(
            CameraInfo, self.get_parameter('camera_info_topic').value,
            self._on_info, 10)
        self.create_subscription(
            Detection3DArray, self.get_parameter('pose_topic').value,
            self._on_pose, 10)
        self.get_logger().info('pose_overlay ready → /pose_viz')

    def _on_info(self, msg: CameraInfo) -> None:
        k = msg.k
        self._K = (k[0], k[4], k[2], k[5])   # fx, fy, cx, cy

    def _on_img(self, msg: Image) -> None:
        if msg.encoding not in ('rgb8', 'bgr8'):
            return
        arr = np.frombuffer(msg.data, dtype=np.uint8)
        if arr.size != msg.height * msg.width * 3:
            return
        img = arr.reshape(msg.height, msg.width, 3)
        if msg.encoding == 'bgr8':
            img = img[:, :, ::-1]
        self._img = np.ascontiguousarray(img)

    def _on_pose(self, msg: Detection3DArray) -> None:
        if self._img is None or self._K is None or not msg.detections:
            return
        det = msg.detections[0]
        if not det.results:
            return

        pose = det.results[0].pose.pose
        t = np.array([pose.position.x, pose.position.y, pose.position.z])
        R = quat_to_rot(pose.orientation.x, pose.orientation.y,
                        pose.orientation.z, pose.orientation.w)

        pil = PImage.fromarray(self._img.copy())
        draw = ImageDraw.Draw(pil)
        self._draw_axes(draw, t, R)
        self._draw_box(draw, t, R)
        draw.text((6, 6), 'z=%.3f m' % t[2], fill=(255, 255, 0))

        self._publish(np.asarray(pil), msg.header)

    def _project(self, pts_cam):
        # pts_cam: (N,3) 카메라 좌표 → (N,2) 픽셀. Z<=0 은 None.
        fx, fy, cx, cy = self._K
        out = []
        for X, Y, Z in pts_cam:
            if Z <= 1e-6:
                out.append(None)
            else:
                out.append((fx * X / Z + cx, fy * Y / Z + cy))
        return out

    def _draw_axes(self, draw, t, R):
        ends = np.stack([
            t,
            t + R @ np.array([self.axis_len, 0, 0]),
            t + R @ np.array([0, self.axis_len, 0]),
            t + R @ np.array([0, 0, self.axis_len]),
        ])
        p = self._project(ends)
        colors = [(255, 0, 0), (0, 255, 0), (0, 128, 255)]   # X R, Y G, Z B
        if p[0] is None:
            return
        for i, c in enumerate(colors, start=1):
            if p[i] is not None:
                draw.line([p[0], p[i]], fill=c, width=3)

    def _draw_box(self, draw, t, R):
        # CAD AABB(mesh 원점 기준) 8 코너를 pose 로 변환.
        mn, mx = self.box_min, self.box_max
        corners = []
        for cx in (mn[0], mx[0]):
            for cy in (mn[1], mx[1]):
                for cz in (mn[2], mx[2]):
                    corners.append(t + R @ np.array([cx, cy, cz]))
        p = self._project(np.stack(corners))
        for a, b in self.BOX_EDGES:
            if p[a] is not None and p[b] is not None:
                draw.line([p[a], p[b]], fill=(255, 255, 0), width=2)

    def _publish(self, img, header):
        out = Image()
        out.header = header
        out.height, out.width = img.shape[0], img.shape[1]
        out.encoding = 'rgb8'
        out.is_bigendian = 0
        out.step = img.shape[1] * 3
        out.data = np.ascontiguousarray(img, dtype=np.uint8).tobytes()
        self.pub.publish(out)


def main(args=None):
    rclpy.init(args=args)
    node = PoseOverlay()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
