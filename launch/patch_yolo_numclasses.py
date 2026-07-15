#!/usr/bin/env python3
# isaac_ros_yolov8_core.launch.py 패치: YoloV8DecoderNode 에 num_classes 전달.
# 원래 launch 는 num_classes 를 디코더에 안 넘겨 기본값 80 사용 → 1-class 커스텀
# 모델([1,5,8400])에서 디코더가 [1,84,8400] 가정하고 out-of-bounds → SIGSEGV.
import sys

F = "/opt/ros/humble/share/isaac_ros_yolov8/launch/isaac_ros_yolov8_core.launch.py"
s = open(F).read()

if "'num_classes': num_classes," in s:
    print("ALREADY PATCHED")
    sys.exit(0)

# A) num_classes LaunchConfiguration 추가
a_old = "        nms_threshold = LaunchConfiguration('nms_threshold')\n"
a_new = a_old + "        num_classes = LaunchConfiguration('num_classes')\n"
assert a_old in s, "A anchor missing"
s = s.replace(a_old, a_new, 1)

# B) 디코더 노드에 num_classes 파라미터 전달
b_old = "                    'nms_threshold': nms_threshold,\n                }]"
b_new = ("                    'nms_threshold': nms_threshold,\n"
         "                    'num_classes': num_classes,\n"
         "                }]")
assert b_old in s, "B anchor missing"
s = s.replace(b_old, b_new, 1)

# C) num_classes DeclareLaunchArgument 추가 (기본 80 = 원래 동작 보존)
c_old = "            'confidence_threshold': DeclareLaunchArgument("
c_new = ("            'num_classes': DeclareLaunchArgument(\n"
         "                'num_classes',\n"
         "                default_value='80',\n"
         "                description='Number of classes the YOLO model detects'\n"
         "            ),\n"
         "            'confidence_threshold': DeclareLaunchArgument(")
assert c_old in s, "C anchor missing"
s = s.replace(c_old, c_new, 1)

open(F, "w").write(s)
print("PATCHED OK")
