#!/usr/bin/env python3

# SPDX-License-Identifier: Apache-2.0
#
# YOLO bbox + aligned depth 로 FoundationPose 용 mono8 마스크를 생성한다.
# SAM 대체 — 8GB GPU 에서 SAM(~3.5GB)과 FoundationPose 를 동시에 못 올리는
# 문제를 우회하기 위해, 검출 박스 안에서 depth 를 임계로 잘라 마스크를 만든다.
#
# 입력:
#   detection_topic (vision_msgs/Detection2DArray) — YOLO letterbox(640x640) 좌표 bbox
#   depth_topic     (sensor_msgs/Image, 16UC1 mm)  — aligned depth, 카메라 해상도
# 출력:
#   output_topic    (sensor_msgs/Image, mono8)     — depth 프레임 타임스탬프로 stamp
#
# 매 depth 프레임마다 "최신 bbox" 를 적용해 마스크를 발행한다. 이렇게 하면
# 마스크 타임스탬프 == depth 타임스탬프 가 되어 FoundationPose 동기화가 맞는다.

import threading

import numpy as np
import rclpy
from rclpy.node import Node
from sensor_msgs.msg import Image
from vision_msgs.msg import Detection2DArray


class BboxDepthMask(Node):
    """검출 박스 + depth 임계로 mono8 마스크를 만든다 (SAM 대체)."""

    def __init__(self):
        super().__init__('bbox_depth_mask')

        self.declare_parameter('detection_topic', '/detections_cup')
        self.declare_parameter('depth_topic', '/camera/aligned_depth_to_color/image_raw')
        self.declare_parameter('output_topic', '/segmentation')
        # YOLO 입력(정사각) 크기 — letterbox 역변환용.
        self.declare_parameter('model_size', 640)
        # depth 임계 대역(±m). 박스 내 median depth 기준 이 대역만 전경으로 취급.
        self.declare_parameter('depth_band_m', 0.06)
        # 검출 후 이 시간(s) 넘게 갱신 없으면 마스크를 비운다(빈 마스크 발행).
        self.declare_parameter('detection_timeout_s', 1.0)
        # 박스 안쪽으로 살짝 수축(px) — 테이블/배경 가장자리 오염 억제.
        self.declare_parameter('box_shrink_px', 4)

        self.model_size = int(self.get_parameter('model_size').value)
        self.depth_band_mm = float(self.get_parameter('depth_band_m').value) * 1000.0
        self.detection_timeout_s = float(self.get_parameter('detection_timeout_s').value)
        self.box_shrink_px = int(self.get_parameter('box_shrink_px').value)

        self._lock = threading.Lock()
        self._bbox = None            # (cx, cy, sx, sy) in model_size letterbox space
        self._bbox_stamp = None      # rclpy time (float sec)

        self.pub = self.create_publisher(
            Image, self.get_parameter('output_topic').value, 10)
        self.create_subscription(
            Detection2DArray, self.get_parameter('detection_topic').value,
            self._on_detection, 10)
        self.create_subscription(
            Image, self.get_parameter('depth_topic').value, self._on_depth, 10)

        self.get_logger().info('bbox_depth_mask ready (SAM 대체 모드)')

    def _on_detection(self, msg: Detection2DArray) -> None:
        if not msg.detections:
            with self._lock:
                self._bbox = None
            return
        det = msg.detections[0]        # detection_filter 가 최고점수 1개만 발행
        b = det.bbox
        with self._lock:
            self._bbox = (b.center.position.x, b.center.position.y,
                          b.size_x, b.size_y)
            self._bbox_stamp = self._now_sec()

    def _on_depth(self, msg: Image) -> None:
        height, width = msg.height, msg.width
        mask = np.zeros((height, width), dtype=np.uint8)

        bbox = self._current_bbox()
        if bbox is not None:
            depth_mm = self._decode_depth_mm(msg)
            if depth_mm is not None:
                self._fill_mask(mask, depth_mm, bbox, width, height)

        self._publish(mask, msg.header)

    def _current_bbox(self):
        with self._lock:
            if self._bbox is None or self._bbox_stamp is None:
                return None
            if self._now_sec() - self._bbox_stamp > self.detection_timeout_s:
                return None
            return self._bbox

    def _decode_depth_mm(self, msg: Image):
        # aligned depth 는 16UC1(mm). 다른 인코딩이면 스킵.
        if msg.encoding not in ('16UC1', 'mono16'):
            self.get_logger().warn(
                f'depth encoding {msg.encoding} 미지원 — 마스크 생략', once=True)
            return None
        arr = np.frombuffer(msg.data, dtype=np.uint16)
        if arr.size != msg.height * msg.width:
            return None
        return arr.reshape(msg.height, msg.width)

    def _fill_mask(self, mask, depth_mm, bbox, width, height):
        cx, cy, sx, sy = bbox
        # letterbox(model_size) → 카메라 해상도 역변환.
        scale = min(self.model_size / width, self.model_size / height)
        pad_x = (self.model_size - width * scale) / 2.0
        pad_y = (self.model_size - height * scale) / 2.0
        rcx = (cx - pad_x) / scale
        rcy = (cy - pad_y) / scale
        rsx = sx / scale
        rsy = sy / scale

        shrink = self.box_shrink_px
        x0 = int(max(rcx - rsx / 2 + shrink, 0))
        x1 = int(min(rcx + rsx / 2 - shrink, width))
        y0 = int(max(rcy - rsy / 2 + shrink, 0))
        y1 = int(min(rcy + rsy / 2 - shrink, height))
        if x1 <= x0 or y1 <= y0:
            return

        roi = depth_mm[y0:y1, x0:x1]
        valid = roi[roi > 0]
        if valid.size < 20:
            return
        median = float(np.median(valid))
        keep = (roi > 0) & (np.abs(roi.astype(np.float32) - median) < self.depth_band_mm)
        mask[y0:y1, x0:x1][keep] = 255

    def _publish(self, mask, header):
        out = Image()
        out.header = header          # depth 타임스탬프/frame_id 그대로 → FP 동기화
        out.height, out.width = mask.shape
        out.encoding = 'mono8'
        out.is_bigendian = 0
        out.step = mask.shape[1]
        out.data = np.ascontiguousarray(mask).tobytes()
        self.pub.publish(out)

    def _now_sec(self) -> float:
        return self.get_clock().now().nanoseconds * 1e-9


def main(args=None):
    rclpy.init(args=args)
    node = BboxDepthMask()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
