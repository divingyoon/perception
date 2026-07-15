# 우회 카메라 launch — fragment의 realsense(RealSenseNodeFactory)가 이 D435i에서
# 프레임을 안 내보내는 문제를 우회한다. 검증된 standalone realsense2_camera 로
# 프레임을 받고(=RGB /camera/color/image_raw 14.5Hz 확인됨), 그 raw color 를
# 명시적 rgb8 NITROS /image_rect 로, aligned depth 를 float32 m /depth 로 변환해
# 하류(yolov8 / segment_anything / FoundationPose)가 기대하는 토픽을 공급한다.
#
# 발행 토픽:
#   /image_rect  (NITROS rgb8, ImageFormatConverterNode)  ← /camera/color/image_raw
#   /depth       (float32 m, ConvertMetricNode)           ← /camera/aligned_depth_to_color/image_raw
#
# camera_info 는 별도 발행하지 않고 소비자(yolov8 encoder / FoundationPose)가
# /camera/color/camera_info 를 직접 보게 한다(run_cup_pose_standalone.sh 에서 지정).
#
# ⚠️ 인코딩 주의: yolov8 encoder 는 rgb8 을 기대한다. RectifyNode 의 compatible
# 모드는 rgb8 realsense 입력을 bgr8 로 잘못 라벨링해 첫 프레임에서 SIGSEGV 를
# 냈다. ImageFormatConverterNode(encoding_desired='rgb8')로 명시적으로 맞춘다.
#
# 이후 yolov8+SAM+FoundationPose 는 run_cup_pose_standalone.sh 가 이어서 띄운다.

import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import IncludeLaunchDescription
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch_ros.actions import ComposableNodeContainer
from launch_ros.descriptions import ComposableNode

# D435i 스트림 프로파일 — 학습/CAD 정합과 무관한 라이브 인식용 기본값.
COLOR_PROFILE = '640x480x15'
DEPTH_PROFILE = '640x480x15'
IMAGE_WIDTH = 640
IMAGE_HEIGHT = 480


def generate_launch_description():
    # 1) 검증된 standalone realsense2_camera (fragment realsense 대체)
    realsense = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(os.path.join(
            get_package_share_directory('realsense2_camera'), 'launch', 'rs_launch.py')),
        launch_arguments={
            'camera_name': 'camera',
            'enable_color': 'true',
            'enable_depth': 'true',
            'align_depth.enable': 'true',
            'enable_gyro': 'false',
            'enable_accel': 'false',
            'rgb_camera.profile': COLOR_PROFILE,
            'depth_module.profile': DEPTH_PROFILE,
        }.items(),
    )

    # 2) 카메라 브리지 — raw color → 명시적 rgb8 NITROS /image_rect,
    #    aligned depth(uint16 mm) → float32 m /depth
    camera_bridge = ComposableNodeContainer(
        package='rclcpp_components',
        name='perception_camera_bridge',
        namespace='',
        executable='component_container_mt',
        composable_node_descriptions=[
            ComposableNode(
                package='isaac_ros_image_proc',
                plugin='nvidia::isaac_ros::image_proc::ImageFormatConverterNode',
                name='cup_color_to_rgb8',
                parameters=[{
                    'encoding_desired': 'rgb8',
                    'image_width': IMAGE_WIDTH,
                    'image_height': IMAGE_HEIGHT,
                }],
                remappings=[
                    ('image_raw', '/camera/color/image_raw'),
                    ('image', '/image_rect'),
                ],
            ),
            ComposableNode(
                package='isaac_ros_depth_image_proc',
                plugin='nvidia::isaac_ros::depth_image_proc::ConvertMetricNode',
                name='cup_depth_convert',
                remappings=[
                    ('image_raw', '/camera/aligned_depth_to_color/image_raw'),
                    ('image', '/depth'),
                ],
            ),
        ],
        output='screen',
    )

    return LaunchDescription([realsense, camera_bridge])
