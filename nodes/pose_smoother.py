#!/usr/bin/env python3

# SPDX-License-Identifier: Apache-2.0
#
# FoundationPose 출력(/output) 시간 안정화 필터.
# 단일 FoundationPose 노드(추정 모드)는 매 프레임 독립 추정이라 pose 가 흔들린다.
# 이 노드가 위치 EMA + 자세 slerp + 튐(outlier) 제거로 매끄럽게 만들어 재발행한다.
# (정석 해법은 Isaac ROS FoundationPose tracking 파이프라인이지만, 이 필터는
#  현재 파이프라인 그대로에 바로 얹혀 지터를 크게 줄인다.)
#
#   /output → pose_smoother → /output_smooth (같은 Detection3DArray 구조)
# cup_pose_relay 와 pose_overlay 는 --in-topic/pose_topic 을 /output_smooth 로.

import numpy as np
import rclpy
from rclpy.node import Node
from vision_msgs.msg import Detection3DArray


def quat_normalize(q):
    n = np.linalg.norm(q)
    return q / n if n > 1e-9 else np.array([0.0, 0.0, 0.0, 1.0])


def quat_slerp(q0, q1, t):
    """xyzw 쿼터니언 slerp. q0,q1 정규화 가정."""
    q0 = quat_normalize(q0)
    q1 = quat_normalize(q1)
    dot = float(np.dot(q0, q1))
    if dot < 0.0:            # 최단 경로
        q1 = -q1
        dot = -dot
    if dot > 0.9995:         # 거의 같으면 선형 보간 후 정규화
        return quat_normalize(q0 + t * (q1 - q0))
    theta0 = np.arccos(np.clip(dot, -1.0, 1.0))
    theta = theta0 * t
    q2 = quat_normalize(q1 - q0 * dot)
    return q0 * np.cos(theta) + q2 * np.sin(theta)


class PoseSmoother(Node):
    """위치 EMA + 자세 slerp + outlier 제거로 pose 안정화."""

    def __init__(self):
        super().__init__('pose_smoother')
        self.declare_parameter('input_topic', '/output')
        self.declare_parameter('output_topic', '/output_smooth')
        # EMA 계수(0~1). 클수록 새 측정 반영↑(빠름/덜 매끄러움), 작을수록 매끄러움↑/지연↑.
        self.declare_parameter('alpha', 0.3)
        # 새 위치가 스무딩값에서 이 거리(m) 이상 튀면 1회 무시(급격한 오검 방지).
        self.declare_parameter('jump_reject_m', 0.15)
        # 연속 무시가 이 횟수 넘으면 튄 값을 실제 이동으로 받아들여 리셋.
        self.declare_parameter('reject_reset_count', 5)

        self.alpha = float(self.get_parameter('alpha').value)
        self.jump_reject = float(self.get_parameter('jump_reject_m').value)
        self.reject_reset = int(self.get_parameter('reject_reset_count').value)

        self._pos = None       # 스무딩된 위치
        self._quat = None      # 스무딩된 자세(xyzw)
        self._reject_streak = 0

        self.pub = self.create_publisher(
            Detection3DArray, self.get_parameter('output_topic').value, 10)
        self.create_subscription(
            Detection3DArray, self.get_parameter('input_topic').value,
            self._on_pose, 10)
        self.get_logger().info(
            'pose_smoother ready (alpha=%.2f jump=%.2fm)' % (self.alpha, self.jump_reject))

    def _on_pose(self, msg: Detection3DArray):
        if not msg.detections or not msg.detections[0].results:
            return
        res = msg.detections[0].results[0]
        p = res.pose.pose.position
        q = res.pose.pose.orientation
        pos = np.array([p.x, p.y, p.z])
        quat = np.array([q.x, q.y, q.z, q.w])

        sp, sq = self._update(pos, quat)
        if sp is None:
            return

        # 스무딩값을 원 메시지에 써서 재발행(구조/헤더/score/bbox 보존).
        res.pose.pose.position.x = float(sp[0])
        res.pose.pose.position.y = float(sp[1])
        res.pose.pose.position.z = float(sp[2])
        res.pose.pose.orientation.x = float(sq[0])
        res.pose.pose.orientation.y = float(sq[1])
        res.pose.pose.orientation.z = float(sq[2])
        res.pose.pose.orientation.w = float(sq[3])
        self.pub.publish(msg)

    def _update(self, pos, quat):
        if self._pos is None:          # 첫 측정 = 그대로 채택
            self._pos, self._quat = pos, quat_normalize(quat)
            self._reject_streak = 0
            return self._pos, self._quat

        if np.linalg.norm(pos - self._pos) > self.jump_reject:
            self._reject_streak += 1
            if self._reject_streak < self.reject_reset:
                return None            # 튐 무시
            # 연속으로 튀면 실제 이동 → 리셋해서 따라감
            self._pos, self._quat = pos, quat_normalize(quat)
            self._reject_streak = 0
            return self._pos, self._quat

        self._reject_streak = 0
        self._pos = self.alpha * pos + (1.0 - self.alpha) * self._pos
        self._quat = quat_slerp(self._quat, quat, self.alpha)
        return self._pos, self._quat


def main(args=None):
    rclpy.init(args=args)
    node = PoseSmoother()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
