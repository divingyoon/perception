#!/usr/bin/env python3
"""COCO YOLOv8 검출을 컵 계열 클래스만 남겨 FoundationPose 프롬프트로 넘기는 필터.

stock COCO yolov8s 는 80클래스를 모두 검출한다. SAM/FoundationPose 는 우리 컵
하나만 프롬프트로 받아야 하므로, cup(41)/bottle(39) 등 지정 클래스만 걸러
(옵션으로 최고 confidence 1개만) 재발행한다. 재학습 없이 임의 색 컵을 잡기 위한
경로 — 자세한 배경은 SETUP_GUIDE.md §9 참조.

params:
  input_topic      (기본 /detections_output)   YOLOv8 디코더 출력
  output_topic     (기본 /detections_cup)       SAM prompt 로 연결
  keep_class_ids   (기본 "39,41")               bottle, cup (COCO index, 쉼표구분)
  min_confidence   (기본 0.1)
  keep_best        (기본 True)                  True 면 최고 점수 1개만 발행
"""
import rclpy
from rclpy.node import Node
from vision_msgs.msg import Detection2DArray


class DetectionFilter(Node):
    def __init__(self):
        super().__init__('detection_filter')
        self.declare_parameter('input_topic', '/detections_output')
        self.declare_parameter('output_topic', '/detections_cup')
        self.declare_parameter('keep_class_ids', '39,41')
        self.declare_parameter('min_confidence', 0.1)
        self.declare_parameter('keep_best', True)

        self.in_topic = self.get_parameter('input_topic').value
        self.out_topic = self.get_parameter('output_topic').value
        raw = str(self.get_parameter('keep_class_ids').value)
        self.keep = {c.strip() for c in raw.split(',') if c.strip()}
        self.min_conf = float(self.get_parameter('min_confidence').value)
        self.keep_best = bool(self.get_parameter('keep_best').value)

        self.pub = self.create_publisher(Detection2DArray, self.out_topic, 10)
        self.sub = self.create_subscription(
            Detection2DArray, self.in_topic, self._cb, 10)
        self.get_logger().info(
            f'detection_filter: {self.in_topic} -> {self.out_topic} '
            f'keep={sorted(self.keep)} min_conf={self.min_conf} best={self.keep_best}')

    @staticmethod
    def _top(det):
        """최상위 hypothesis (class_id, score) 반환. 없으면 None."""
        if not det.results:
            return None
        best = max(det.results, key=lambda r: r.hypothesis.score)
        return best.hypothesis.class_id, best.hypothesis.score

    def _cb(self, msg):
        kept = []
        for det in msg.detections:
            top = self._top(det)
            if top is None:
                continue
            cid, score = top
            if cid in self.keep and score >= self.min_conf:
                kept.append((score, det))

        out = Detection2DArray()
        out.header = msg.header
        if kept:
            kept.sort(key=lambda x: x[0], reverse=True)
            out.detections = [kept[0][1]] if self.keep_best else [d for _, d in kept]
        # 비어도 발행(하류가 프레임 동기를 유지하도록 헤더만 실린 빈 배열)
        self.pub.publish(out)


def main():
    rclpy.init()
    node = DetectionFilter()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
