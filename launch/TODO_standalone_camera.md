# [해결됨] 단독 카메라 우회 — 완료

이 문서가 계획하던 "fragment realsense 우회"는 **구현·검증 완료**되었다.

- 산출물: `cup_pose_standalone_cam.launch.py` (단독 realsense2_camera +
  ImageFormatConverter(rgb8)→/image_rect + ConvertMetric→/depth) +
  `run_cup_pose_standalone.sh`.
- 추가로 발견/해결한 진짜 블로커: **YoloV8DecoderNode 의 num_classes 미배선**으로
  인한 SIGSEGV(-11) → `patch_yolo_numclasses.py` 로 자동 수정.

자세한 배경·트러블슈팅은 **[../SETUP_GUIDE.md](../SETUP_GUIDE.md)** (§7.1 num_classes,
§7.2 fragment realsense 우회) 참조.
