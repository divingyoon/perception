#!/usr/bin/env bash
# perception 호스트(비전 PC) 1회 세팅 — 컨테이너 밖에서 실행.
# 이번 s2r 구축에서 겪은 호스트 레벨 함정(usbfs / udev / DDS 소켓버퍼 / DISPLAY)을
# 한 번에 처리한다. sudo 필요. 자세한 배경은 SETUP_GUIDE.md 참조.
set -euo pipefail

echo "=== perception 호스트 세팅 ==="

# 1) usbfs 버퍼 (RealSense 다중 스트림 EAGAIN/stream start failure 방지) ---------
#    기본 16MB → RealSense color+depth 동시 스트림서 control_transfer EAGAIN.
echo "[1/4] usbfs_memory_mb=1000 (런타임)"
sudo sh -c 'echo 1000 > /sys/module/usbcore/parameters/usbfs_memory_mb'
cat /sys/module/usbcore/parameters/usbfs_memory_mb
echo "  ⚠️ 영구화: /etc/default/grub 의 GRUB_CMDLINE_LINUX_DEFAULT 에"
echo "     usbcore.usbfs_memory_mb=1000 추가 후 'sudo update-grub && 재부팅'"

# 2) DDS 소켓 버퍼 (cyclonedds 10MB 요구 → rmw handle invalid 방지) --------------
echo "[2/4] net.core.rmem_max 확대 (cyclonedds)"
sudo sysctl -w net.core.rmem_max=2147483647
if ! grep -q "net.core.rmem_max" /etc/sysctl.d/60-perception.conf 2>/dev/null; then
  echo "net.core.rmem_max=2147483647" | sudo tee /etc/sysctl.d/60-perception.conf >/dev/null
  echo "  → /etc/sysctl.d/60-perception.conf 로 영구화"
fi

# 3) RealSense udev (컨테이너 비-root USB 접근) ----------------------------------
echo "[3/4] RealSense udev rules"
RULES=/etc/udev/rules.d/99-realsense-libusb.rules
if [ ! -f "$RULES" ]; then
  echo "  ⚠️ $RULES 없음 — librealsense 공식 rules 설치 필요:"
  echo "     wget -O /tmp/99-realsense-libusb.rules https://raw.githubusercontent.com/IntelRealSense/librealsense/master/config/99-realsense-libusb.rules"
  echo "     sudo cp /tmp/99-realsense-libusb.rules $RULES"
  echo "     sudo udevadm control --reload-rules && sudo udevadm trigger"
  echo "     그리고 카메라 재연결"
else
  echo "  → 이미 설치됨: $RULES"
fi

# 4) DISPLAY (rqt/rviz 를 이 PC 모니터에 띄우려면) ------------------------------
echo "[4/4] DISPLAY (GUI 확인용)"
echo "  arm3070 로컬 모니터 세션에서:  xhost +local:"
echo "  ssh 세션에서 컨테이너 진입 전:  export DISPLAY=:0"

echo
echo "=== 호스트 세팅 완료. usbfs 영구화(GRUB)는 재부팅 필요할 수 있음. ==="
echo "다음: SETUP_GUIDE.md §4 (컨테이너 이미지 로드/실행) 진행"
