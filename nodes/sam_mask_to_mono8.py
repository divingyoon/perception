#!/usr/bin/env python3

# SPDX-FileCopyrightText: NVIDIA CORPORATION & AFFILIATES
# Copyright (c) 2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0

from isaac_ros_tensor_list_interfaces.msg import TensorList
from message_filters import ApproximateTimeSynchronizer, Subscriber, TimeSynchronizer
import numpy as np
import rclpy
from rclpy.node import Node
from sensor_msgs.msg import Image


class SamMaskToMono8(Node):
    """Convert SAM TensorList masks to a mono8 image mask for FoundationPose."""

    UINT8_DATA_TYPE = 2

    def __init__(self):
        super().__init__('sam_mask_to_mono8')

        self.declare_parameter('mask_topic', 'segment_anything/raw_segmentation_mask')
        self.declare_parameter('reference_image_topic', '/image_rect')
        self.declare_parameter('output_topic', 'segmentation')
        self.declare_parameter('selection_policy', 'largest')
        self.declare_parameter('threshold', 0)
        self.declare_parameter('reverse_letterbox', True)
        self.declare_parameter('approximate_sync', False)
        self.declare_parameter('sync_queue_size', 20)
        self.declare_parameter('sync_slop_seconds', 0.1)

        mask_topic = self.get_parameter('mask_topic').value
        reference_image_topic = self.get_parameter('reference_image_topic').value
        output_topic = self.get_parameter('output_topic').value
        self.selection_policy = self.get_parameter('selection_policy').value
        self.threshold = self.get_parameter('threshold').value
        self.reverse_letterbox = self.get_parameter('reverse_letterbox').value
        approximate_sync = self.get_parameter('approximate_sync').value
        sync_queue_size = self.get_parameter('sync_queue_size').value
        sync_slop_seconds = self.get_parameter('sync_slop_seconds').value

        if self.selection_policy not in ('largest', 'first', 'union'):
            raise ValueError('selection_policy must be one of: largest, first, union')

        self.mask_sub = Subscriber(self, TensorList, mask_topic)
        self.reference_image_sub = Subscriber(self, Image, reference_image_topic)
        self.mask_pub = self.create_publisher(Image, output_topic, 10)

        if approximate_sync:
            self.sync = ApproximateTimeSynchronizer(
                [self.mask_sub, self.reference_image_sub],
                sync_queue_size,
                sync_slop_seconds)
        else:
            self.sync = TimeSynchronizer(
                [self.mask_sub, self.reference_image_sub],
                sync_queue_size)
        self.sync.registerCallback(self.callback)

    def callback(self, masks_msg, reference_image_msg):
        if not masks_msg.tensors:
            self.get_logger().warn('Received TensorList with no tensors')
            return

        tensor = masks_msg.tensors[0]
        dims = list(tensor.shape.dims)

        if tensor.data_type != self.UINT8_DATA_TYPE:
            self.get_logger().error(
                f'Expected uint8 Tensor data_type=2, received {tensor.data_type}')
            return
        if tensor.shape.rank != 4 or len(dims) != 4 or dims[1] != 1:
            self.get_logger().error(
                f'Expected mask tensor shape [N, 1, H, W], received {dims}')
            return

        expected_length = int(np.prod(dims))
        if len(tensor.data) != expected_length:
            self.get_logger().error(
                f'Unexpected tensor data length {len(tensor.data)}, expected {expected_length}')
            return

        masks = np.asarray(tensor.data, dtype=np.uint8).reshape(dims)
        selected_mask = self.select_mask(masks)

        output_width = reference_image_msg.width
        output_height = reference_image_msg.height
        output_mask = self.restore_to_reference_size(
            selected_mask,
            output_width,
            output_height)

        image_msg = Image()
        image_msg.header = reference_image_msg.header
        image_msg.height = output_height
        image_msg.width = output_width
        image_msg.encoding = 'mono8'
        image_msg.is_bigendian = 0
        image_msg.step = output_width
        image_msg.data = output_mask.tobytes()
        self.mask_pub.publish(image_msg)

    def select_mask(self, masks):
        binary_masks = masks[:, 0, :, :] > self.threshold

        if self.selection_policy == 'first':
            selected = binary_masks[0]
        elif self.selection_policy == 'union':
            selected = np.any(binary_masks, axis=0)
        else:
            areas = np.count_nonzero(binary_masks, axis=(1, 2))
            selected = binary_masks[int(np.argmax(areas))]

        return selected.astype(np.uint8) * 255

    def restore_to_reference_size(self, mask, output_width, output_height):
        mask_height, mask_width = mask.shape

        if self.reverse_letterbox:
            scale = min(mask_width / output_width, mask_height / output_height)
            scaled_width = int(round(output_width * scale))
            scaled_height = int(round(output_height * scale))
            offset_x = max((mask_width - scaled_width) // 2, 0)
            offset_y = max((mask_height - scaled_height) // 2, 0)
            mask = mask[
                offset_y:offset_y + scaled_height,
                offset_x:offset_x + scaled_width]

        if mask.shape[1] != output_width or mask.shape[0] != output_height:
            mask = _nearest_resize(mask, output_width, output_height)

        return np.ascontiguousarray(mask.astype(np.uint8))


def _nearest_resize(mask, out_w, out_h):
    """nearest-neighbor resize (numpy only, numpy2 compatible)."""
    in_h, in_w = mask.shape[0], mask.shape[1]
    if in_w == out_w and in_h == out_h:
        return mask
    ys = (np.arange(out_h) * in_h // out_h).astype(np.intp)
    xs = (np.arange(out_w) * in_w // out_w).astype(np.intp)
    return mask[ys[:, None], xs[None, :]]


def main(args=None):
    rclpy.init(args=args)
    node = SamMaskToMono8()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
