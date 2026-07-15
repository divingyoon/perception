#!/usr/bin/env python3
"""라이브 카메라 프레임 1장 + camera_info(yaml) 저장.

extrinsics 캘리브(calibrate_extrinsics.py) 입력 준비용. 컨테이너 안에서 실행.
cv2 미사용(PIL) — 컨테이너 numpy2 충돌 회피.

    python3 tools/grab_frame.py --topic /camera/color/image_raw \
        --out /tmp/calib.png --camera-info-out /tmp/camera_info.yaml
"""

from __future__ import annotations

import argparse
import sys
import time

import numpy as np
import rclpy
from rclpy.node import Node
from sensor_msgs.msg import CameraInfo, Image
from PIL import Image as PImage


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--topic", default="/camera/color/image_raw")
    ap.add_argument("--camera-info-topic", default="/camera/color/camera_info")
    ap.add_argument("--out", default="/tmp/calib.png")
    ap.add_argument("--camera-info-out", default="/tmp/camera_info.yaml")
    ap.add_argument("--timeout", type=float, default=15.0)
    args = ap.parse_args()

    rclpy.init()
    node = Node("grab_frame")
    state = {"img": False, "info": False}

    def on_img(msg: Image):
        if state["img"] or msg.encoding not in ("rgb8", "bgr8"):
            return
        arr = np.frombuffer(msg.data, dtype=np.uint8).reshape(msg.height, msg.width, 3)
        if msg.encoding == "bgr8":
            arr = arr[:, :, ::-1]
        PImage.fromarray(np.ascontiguousarray(arr)).save(args.out)
        node.get_logger().info(f"saved {args.out} ({msg.width}x{msg.height} {msg.encoding})")
        state["img"] = True

    def on_info(msg: CameraInfo):
        if state["info"]:
            return
        import yaml
        with open(args.camera_info_out, "w") as f:
            yaml.safe_dump({"k": [float(v) for v in msg.k],
                            "d": [float(v) for v in msg.d]}, f)
        node.get_logger().info(f"saved {args.camera_info_out}")
        state["info"] = True

    node.create_subscription(Image, args.topic, on_img, 10)
    node.create_subscription(CameraInfo, args.camera_info_topic, on_info, 10)

    t0 = time.time()
    while rclpy.ok() and not (state["img"] and state["info"]) and time.time() - t0 < args.timeout:
        rclpy.spin_once(node, timeout_sec=0.5)
    node.destroy_node()
    rclpy.shutdown()
    sys.exit(0 if state["img"] else 1)


if __name__ == "__main__":
    main()
