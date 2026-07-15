# FoundationPose tracking 컨테이너 (Selector + 추정 + 추적).
#
# ⚠️ EXPERIMENTAL — GPU bring-up 필요. Isaac stock tracking(RT-DETR 프론트엔드)의
# Selector+FoundationPoseNode+FoundationPoseTrackingNode 3노드만 떼어와, 우리
# 파이프라인이 이미 내는 /image_rect · /depth · /camera_info · /segmentation 을 먹인다.
# (마스크는 bbox_depth_mask 가 만든 /segmentation 을 그대로 재사용 — Detection2DToMask/
#  resize_mask 는 생략.)
#
# Selector: reset_period 마다 추정(FoundationPoseNode)으로 리셋, 그 외에는
# 추적(FoundationPoseTrackingNode)으로 이어가 프레임간 매끄럽고 가볍게.
#
# 경로는 ISAAC_ROS_WS(기본 /workspaces/isaac_ros-dev) 기준.
# ⚠️ 메모리: 추정(FoundationPoseNode)+추적(FoundationPoseTrackingNode) 엔진이 동시에
#    상주해 8GB(3070)에서 OOM 가능. score 엔진 batch 축소는 추정 노드가 satisfyProfile
#    오류를 내므로 불가(252 유지 필수). OOM 이면 8GB 로는 tracking 이 안 맞는 것 →
#    추정모드(run_cup_pose_standalone.sh + pose_smoother)로 회귀하거나 더 큰 GPU 사용.

import os

from launch import LaunchDescription
from launch_ros.actions import ComposableNodeContainer
from launch_ros.descriptions import ComposableNode

WS = os.environ.get('ISAAC_ROS_WS', '/workspaces/isaac_ros-dev')
A = os.path.join(WS, 'isaac_ros_assets')
M = os.path.join(A, 'models', 'foundationpose')
MESH = os.path.join(A, 'isaac_ros_foundationpose', 'Cup', 'Cup.obj')
TEXTURE = os.path.join(A, 'isaac_ros_foundationpose', 'Cup', 'texture.png')
RESET_PERIOD_MS = int(os.environ.get('TRACK_RESET_PERIOD_MS', '4000'))


def generate_launch_description():
    refine_engine = os.path.join(M, 'refine_trt_engine.plan')
    score_engine = os.path.join(M, 'score_trt_engine.plan')
    texture = TEXTURE if os.path.exists(TEXTURE) else ''

    selector = ComposableNode(
        name='selector_node',
        package='isaac_ros_foundationpose',
        plugin='nvidia::isaac_ros::foundationpose::Selector',
        parameters=[{'reset_period': RESET_PERIOD_MS}],
        remappings=[
            ('image', '/image_rect'),
            ('camera_info', '/camera/color/camera_info'),
            ('depth_image', '/depth'),
        ],
    )

    fp_node = ComposableNode(
        name='foundationpose_node',
        package='isaac_ros_foundationpose',
        plugin='nvidia::isaac_ros::foundationpose::FoundationPoseNode',
        parameters=[{
            'mesh_file_path': MESH,
            'texture_path': texture,
            'refine_engine_file_path': refine_engine,
            'refine_input_tensor_names': ['input_tensor1', 'input_tensor2'],
            'refine_input_binding_names': ['input1', 'input2'],
            'refine_output_tensor_names': ['output_tensor1', 'output_tensor2'],
            'refine_output_binding_names': ['output1', 'output2'],
            'score_engine_file_path': score_engine,
            'score_input_tensor_names': ['input_tensor1', 'input_tensor2'],
            'score_input_binding_names': ['input1', 'input2'],
            'score_output_tensor_names': ['output_tensor'],
            'score_output_binding_names': ['output1'],
        }],
        remappings=[('pose_estimation/output', '/output')],
    )

    tracking_node = ComposableNode(
        name='foundationpose_tracking_node',
        package='isaac_ros_foundationpose',
        plugin='nvidia::isaac_ros::foundationpose::FoundationPoseTrackingNode',
        parameters=[{
            'mesh_file_path': MESH,
            'texture_path': texture,
            'refine_engine_file_path': refine_engine,
            'refine_input_tensor_names': ['input_tensor1', 'input_tensor2'],
            'refine_input_binding_names': ['input1', 'input2'],
            'refine_output_tensor_names': ['output_tensor1', 'output_tensor2'],
            'refine_output_binding_names': ['output1', 'output2'],
        }],
    )

    container = ComposableNodeContainer(
        package='rclcpp_components',
        name='foundationpose_tracking_container',
        namespace='',
        executable='component_container_mt',
        composable_node_descriptions=[selector, fp_node, tracking_node],
        output='screen',
    )
    return LaunchDescription([container])
