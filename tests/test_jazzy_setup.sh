#!/usr/bin/env bash
# Shell regression contract for the Jazzy Isaac ROS perception environment.

set -u -o pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
passes=0
failures=0
test_scope="${JAZZY_SETUP_TEST_SCOPE:-all}"

case "$test_scope" in
  all | verifier) ;;
  *)
    printf 'Unknown JAZZY_SETUP_TEST_SCOPE: %s\n' "$test_scope" >&2
    exit 2
    ;;
esac

pass() {
  printf 'PASS: %s\n' "$1"
  passes=$((passes + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_contains() {
  local file="$1"
  local expected="$2"

  if [[ ! -f "$file" ]]; then
    fail "missing file: $file"
  elif grep -Fq -- "$expected" "$file"; then
    pass "$(basename "$file") contains: $expected"
  else
    fail "$(basename "$file") is missing: $expected"
  fi
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"

  if [[ ! -f "$file" ]]; then
    fail "missing file: $file"
  elif grep -Fq -- "$unexpected" "$file"; then
    fail "$(basename "$file") must not contain: $unexpected"
  else
    pass "$(basename "$file") does not contain: $unexpected"
  fi
}

assert_jazzy_live_shell_entrypoint() {
  local file="$1"
  local forbidden

  if [[ ! -f "$file" ]]; then
    fail "missing live entrypoint: $file"
    return
  fi

  for forbidden in '/opt/ros/humble' 'ros-humble-' 'ros2_humble'; do
    if grep -Fq -- "$forbidden" "$file"; then
      fail "$(basename "$file") must target Jazzy only (found: $forbidden)"
      return
    fi
  done

  if grep -Eq \
    '^[[:space:]]*source[[:space:]]+/opt/ros/jazzy/setup\.bash[[:space:]]*$' \
    "$file"; then
    pass "$(basename "$file") sources the Jazzy setup line"
  else
    fail "$(basename "$file") must source only /opt/ros/jazzy/setup.bash"
  fi
}

assert_launch_tree_has_no_humble_paths() {
  local matches
  local status

  matches="$(grep -R -n -E \
    '/opt/ros/humble|ros-humble-|ros2_humble' \
    "$repo/launch" 2>&1)"
  status=$?
  case "$status" in
    0) fail "launch/ must not contain Humble-specific paths: $matches" ;;
    1) pass 'launch/ contains no Humble-specific paths' ;;
    *) fail "launch/ Humble-path scan failed (grep exit $status): $matches" ;;
  esac
}

assert_no_runtime_distro_conditional() {
  local file="$1"

  if grep -Eq \
    '(^|[[:space:]])(if|elif|case)[^#]*(ROS_DISTRO|ROS_VERSION)' \
    "$file"; then
    fail "$(basename "$file") must not select a ROS distro at runtime"
  else
    pass "$(basename "$file") has no runtime ROS distro conditional"
  fi
}

assert_jazzy_patch_target() {
  local file="$1"

  if grep -Eq \
    '^[[:space:]]*F[[:space:]]*=[[:space:]]*"/opt/ros/jazzy/share/isaac_ros_yolov8/launch/isaac_ros_yolov8_core\.launch\.py"[[:space:]]*$' \
    "$file"; then
    pass "$(basename "$file") targets the complete Jazzy YOLO launch path"
  else
    fail "$(basename "$file") must target the complete Jazzy YOLO launch path"
  fi
}

assert_text_before() {
  local file="$1"
  local first="$2"
  local second="$3"
  local first_line
  local second_line

  first_line="$(grep -Fnm1 -- "$first" "$file" | cut -d: -f1)"
  second_line="$(grep -Fnm1 -- "$second" "$file" | cut -d: -f1)"
  if [[ -n "$first_line" && -n "$second_line" &&
    "$first_line" -lt "$second_line" ]]; then
    pass "$(basename "$file") places '$first' before '$second'"
  else
    fail "$(basename "$file") must place '$first' before '$second'"
  fi
}

assert_occurrences() {
  local file="$1"
  local expected_count="$2"
  local text="$3"
  local actual_count

  actual_count="$(grep -Fc -- "$text" "$file")"
  if [[ "$actual_count" -eq "$expected_count" ]]; then
    pass "$(basename "$file") contains $expected_count occurrence(s): $text"
  else
    fail "$(basename "$file") expected $expected_count occurrence(s), found $actual_count: $text"
  fi
}

assert_container_entrypoint_uses_canonical_workspace() {
  local file="$1"
  local canonical='ISAAC_ROS_WS=/workspaces/isaac_ros-dev'

  if grep -Eq \
    '^[[:space:]]*ISAAC_ROS_WS=/workspaces/isaac_ros-dev[[:space:]]*$' \
    "$file"; then
    pass "$(basename "$file") forces the canonical container workspace"
  else
    fail "$(basename "$file") must set $canonical unconditionally"
  fi
}

assert_default_yolo_engine_is_built() {
  local run_script="$1"
  local builder="$2"
  local default_model
  local default_engine

  default_model="$(
    sed -n 's/^YOLO_MODEL="${YOLO_MODEL:-\([^}]*\)}"$/\1/p' "$run_script"
  )"
  default_engine="$(
    sed -n 's/^YOLO_ENGINE="${YOLO_ENGINE:-\([^}]*\)}"$/\1/p' "$run_script"
  )"

  if [[ -z "$default_model" && -z "$default_engine" ]]; then
    default_model="$(
      sed -n 's#.*model_file_path:="\$M/yolov8/\([^"]*\)".*#\1#p' \
        "$run_script" | head -n 1
    )"
    default_engine="$(
      sed -n 's#.*engine_file_path:="\$M/yolov8/\([^"]*\)".*#\1#p' \
        "$run_script" | head -n 1
    )"
  fi

  if [[ -z "$default_model" || -z "$default_engine" ]]; then
    fail "$(basename "$run_script") must declare default YOLO_MODEL and YOLO_ENGINE"
    return
  fi

  assert_contains "$builder" \
    "--onnx=\"\$M/yolov8/$default_model\""
  assert_contains "$builder" \
    "build_engine \"\$M/yolov8/$default_engine\""
}

assert_command_blocks_export_workspace() {
  local file="$1"
  local line
  local block=''
  local block_number=0
  local missing=0
  local in_bash=0
  local host_workspace_export='export ISAAC_ROS_WS="${ISAAC_ROS_WS:-$HOME/workspaces/isaac_ros-dev}"'
  local container_workspace_export='export ISAAC_ROS_WS=/workspaces/isaac_ros-dev'

  while IFS= read -r line; do
    if [[ "$line" = '```bash' ]]; then
      in_bash=1
      block=''
      block_number=$((block_number + 1))
    elif [[ "$in_bash" -eq 1 && "$line" = '```' ]]; then
      if grep -Eq \
        '(\./setup_jazzy\.sh|\./verify_jazzy_setup\.sh|isaac-ros activate)' \
        <<< "$block" &&
        ! grep -Fq -- "$host_workspace_export" <<< "$block" &&
        ! grep -Fq -- "$container_workspace_export" <<< "$block"; then
        fail "$(basename "$file") bash block $block_number uses setup/verify/activate without ISAAC_ROS_WS export"
        missing=1
      fi
      in_bash=0
    elif [[ "$in_bash" -eq 1 ]]; then
      block+="$line"$'\n'
    fi
  done < "$file"

  if [[ "$missing" -eq 0 ]]; then
    pass "$(basename "$file") exports ISAAC_ROS_WS in every setup/verify/activate bash block"
  fi
}

assert_succeeds() {
  local description="$1"
  local output
  shift

  if output="$("$@" 2>&1)"; then
    pass "$description"
  else
    fail "$description"
    printf '%s\n' "$output" >&2
  fi
}

assert_fails() {
  local description="$1"
  local output
  shift

  if output="$("$@" 2>&1)"; then
    fail "$description"
    printf '%s\n' "$output" >&2
  else
    pass "$description"
  fi
}

assert_output_equals() {
  local description="$1"
  local expected="$2"
  local output
  shift 2

  if output="$("$@" 2>&1)" && [[ "$output" = "$expected" ]]; then
    pass "$description"
  else
    fail "$description"
    printf 'expected: %s\nactual: %s\n' "$expected" "$output" >&2
  fi
}

assert_fails_with() {
  local description="$1"
  local expected="$2"
  local output
  shift 2

  if output="$("$@" 2>&1)"; then
    fail "$description"
    printf 'expected failure containing: %s\nactual success: %s\n' \
      "$expected" "$output" >&2
  elif grep -Fq -- "$expected" <<< "$output"; then
    pass "$description"
  else
    fail "$description"
    printf 'expected failure containing: %s\nactual: %s\n' \
      "$expected" "$output" >&2
  fi
}

assert_empty() {
  local file="$1"
  local description="$2"

  if [[ -f "$file" && ! -s "$file" ]]; then
    pass "$description"
  else
    fail "$description"
    [[ -f "$file" ]] && sed -n '1,40p' "$file" >&2
  fi
}

assert_executable() {
  local file="$1"

  if [[ -x "$file" ]]; then
    pass "generated entrypoint is executable: ${file#"$workspace"/}"
  else
    fail "generated entrypoint is not executable: ${file#"$workspace"/}"
  fi
}

workspace="$(mktemp -d)"
stub_bin="$workspace/stubs"
mkdir -p "$stub_bin"
trap 'rm -rf "$workspace"' EXIT

printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_bin/isaac-ros"
chmod +x "$stub_bin/isaac-ros"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ "$*" = *"--query-gpu=driver_version"* ]]; then' \
  '  printf "%s\n" "${NVIDIA_DRIVER_VERSION:-580.0}"' \
  'fi' \
  'exit "${NVIDIA_SMI_EXIT:-0}"' > "$stub_bin/nvidia-smi"
chmod +x "$stub_bin/nvidia-smi"

setup_docker_log="$workspace/setup-docker.log"
: > "$setup_docker_log"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'log="${SETUP_DOCKER_TEST_LOG:-${DOCKER_TEST_LOG:?}}"' \
  'printf "%s\n" "$*" >> "$log"' \
  'case "${1:-}" in' \
  '  info) exit "${DOCKER_INFO_EXIT:-97}" ;;' \
  '  run) exit "${DOCKER_RUN_EXIT:-98}" ;;' \
  '  *) exit 91 ;;' \
  'esac' > "$stub_bin/docker"
chmod +x "$stub_bin/docker"

if [[ "$test_scope" = all ]]; then
  dockerfile="$repo/docker/Dockerfile.perception"
  assert_contains "$dockerfile" 'ros-jazzy-isaac-ros-foundationpose'
  assert_contains "$dockerfile" 'ros-jazzy-isaac-ros-yolov8'
  assert_contains "$dockerfile" 'ros-jazzy-isaac-ros-realsense'
  assert_contains "$dockerfile" 'ros-jazzy-rmw-cyclonedds-cpp'
  assert_contains "$dockerfile" 'CYCLONEDDS_URI=file:///etc/perception/cyclonedds.xml'
  assert_not_contains "$dockerfile" 'ros-humble-'
  assert_not_contains "$dockerfile" 'ros2_humble'
  assert_not_contains "$dockerfile" 'DRAFT'
  assert_not_contains "$dockerfile" '21GB'
  assert_contains "$dockerfile" 'Isaac ROS CLI 4.5'

  active_humble_matches="$(
    grep -R -n -E \
      '/opt/ros/humble|ros-humble-|ros2_humble' \
      --include='*.md' \
      --exclude-dir='.git' \
      --exclude-dir='.superpowers' \
      --exclude-dir='superpowers' \
      "$repo" 2>&1
  )"
  active_humble_status=$?
  case "$active_humble_status" in
    0) fail "active shipped docs contain Humble-specific paths: $active_humble_matches" ;;
    1) pass 'active shipped docs contain no Humble-specific paths' ;;
    *) fail "active shipped docs scan failed (grep exit $active_humble_status): $active_humble_matches" ;;
  esac

  readme="$repo/README.md"
  assert_contains "$readme" './setup_jazzy.sh'
  assert_contains "$readme" 'isaac-ros activate --build-local'
  assert_contains "$readme" './verify_jazzy_setup.sh --host'

  for documentation in \
    "$repo/README.md" \
    "$repo/SETUP_GUIDE.md" \
    "$repo/RUN.md" \
    "$repo/docker/BUILD.md"; do
    assert_not_contains "$documentation" 'run_dev.sh'
    assert_not_contains "$documentation" 'ros-humble-'
    assert_not_contains "$documentation" 'ISAAC_ROS_VERSION=3.2'
    assert_contains "$documentation" \
      'export ISAAC_ROS_WS="${ISAAC_ROS_WS:-$HOME/workspaces/isaac_ros-dev}"'
    assert_text_before "$documentation" \
      'export ISAAC_ROS_WS="${ISAAC_ROS_WS:-$HOME/workspaces/isaac_ros-dev}"' \
      './setup_jazzy.sh'
    assert_text_before "$documentation" \
      'export ISAAC_ROS_WS="${ISAAC_ROS_WS:-$HOME/workspaces/isaac_ros-dev}"' \
      'isaac-ros activate --build-local'
    assert_command_blocks_export_workspace "$documentation"
  done

  for live_documentation in \
    "$repo/README.md" \
    "$repo/SETUP_GUIDE.md" \
    "$repo/RUN.md"; do
    assert_not_contains "$live_documentation" \
      'Jazzy 진입점 마이그레이션이 완료될 때까지 라이브 실행은 보류한다.'
    assert_contains "$live_documentation" './run_cup_pose_standalone.sh'
  done
  assert_not_contains "$repo/docker/BUILD.md" \
    'Jazzy 진입점 마이그레이션이 완료될 때까지 라이브 실행은 보류한다.'
  for platform_documentation in \
    "$repo/README.md" \
    "$repo/SETUP_GUIDE.md" \
    "$repo/docker/BUILD.md"; do
    assert_contains "$platform_documentation" 'x86_64'
    assert_contains "$platform_documentation" 'Ampere'
    assert_contains "$platform_documentation" '580'
  done

  live_entrypoint_count=0
  while IFS= read -r -d '' live_entrypoint; do
    live_entrypoint_count=$((live_entrypoint_count + 1))
    assert_jazzy_live_shell_entrypoint "$live_entrypoint"
    assert_no_runtime_distro_conditional "$live_entrypoint"
    assert_container_entrypoint_uses_canonical_workspace "$live_entrypoint"
  done < <(find "$repo/launch" -maxdepth 1 -type f -name 'run_*.sh' -print0)
  if [[ "$live_entrypoint_count" -eq 0 ]]; then
    fail 'launch/ must contain at least one run_*.sh live entrypoint'
  else
    pass "discovered $live_entrypoint_count live run_*.sh entrypoint(s)"
  fi
  assert_jazzy_patch_target "$repo/launch/patch_yolo_numclasses.py"
  assert_launch_tree_has_no_humble_paths

  engine_builder="$repo/launch/build_engines.sh"
  for default_yolo_entrypoint in "$repo"/launch/run_*.sh; do
    assert_default_yolo_engine_is_built \
      "$default_yolo_entrypoint" "$engine_builder"
  done
  assert_contains "$engine_builder" \
    'build_engine "$M/yolov8/yolov8s.plan"'
  assert_contains "$engine_builder" \
    'build_engine "$M/yolov8/best.plan"'
  assert_contains "$engine_builder" '[[ -s "$output" ]]'
  assert_contains "$engine_builder" 'mv "$temporary_engine" "$output"'

  yolo_build_case="$workspace/yolo-build-case"
  yolo_build_script="$workspace/yolo-build-section.sh"
  yolo_trt_log="$workspace/yolo-trt.log"
  yolo_trt_stub="$workspace/yolo-trtexec"
  mkdir -p "$yolo_build_case/yolov8"
  mkdir -p "$yolo_build_case/foundationpose"
  : > "$yolo_build_case/yolov8/yolov8s.onnx"
  : > "$yolo_build_case/yolov8/best.onnx"
  printf 'engine\n' > "$yolo_build_case/foundationpose/refine_trt_engine.plan"
  printf 'engine\n' > "$yolo_build_case/foundationpose/score_trt_engine.plan"
  : > "$yolo_trt_log"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >> "${YOLO_TRT_LOG:?}"' \
    'for argument in "$@"; do' \
    '  case "$argument" in' \
    '    --saveEngine=*) printf "engine\n" > "${argument#--saveEngine=}" ;;' \
    '  esac' \
    'done' > "$yolo_trt_stub"
  chmod +x "$yolo_trt_stub"
  sed \
    -e 's#^M=.*#M="${YOLO_BUILD_MODELS:?}"#' \
    -e 's#^TRT=.*#TRT="${YOLO_BUILD_TRT:?}"#' \
    "$engine_builder" > "$yolo_build_script"

  assert_succeeds 'YOLO builder creates stock and custom plans' \
    env \
      M="$yolo_build_case" \
      YOLO_BUILD_MODELS="$yolo_build_case" \
      YOLO_BUILD_TRT="$yolo_trt_stub" \
      YOLO_TRT_LOG="$yolo_trt_log" \
      bash "$yolo_build_script"
  assert_succeeds 'YOLO builder is idempotent when both plans exist' \
    env \
      YOLO_BUILD_MODELS="$yolo_build_case" \
      YOLO_BUILD_TRT="$yolo_trt_stub" \
      YOLO_TRT_LOG="$yolo_trt_log" \
      bash "$yolo_build_script"
  assert_occurrences "$yolo_trt_log" 1 \
    "--onnx=$yolo_build_case/yolov8/yolov8s.onnx"
  assert_occurrences "$yolo_trt_log" 1 \
    "--onnx=$yolo_build_case/yolov8/best.onnx"

  engine_test_models="$workspace/engine-test-models"
  engine_test_script="$workspace/build-engines-under-test.sh"
  engine_test_log="$workspace/engine-test.log"
  engine_test_stub="$workspace/engine-test-trtexec"
  mkdir -p "$engine_test_models/yolov8" "$engine_test_models/foundationpose"
  printf 'onnx\n' > "$engine_test_models/yolov8/yolov8s.onnx"
  printf 'onnx\n' > "$engine_test_models/yolov8/best.onnx"
  printf 'onnx\n' > "$engine_test_models/foundationpose/refine_model.onnx"
  printf 'onnx\n' > "$engine_test_models/foundationpose/score_model.onnx"
  printf 'engine\n' > "$engine_test_models/yolov8/yolov8s.plan"
  : > "$engine_test_models/yolov8/best.plan"
  printf 'engine\n' > "$engine_test_models/foundationpose/refine_trt_engine.plan"
  printf 'engine\n' > "$engine_test_models/foundationpose/score_trt_engine.plan"
  sed \
    -e 's#^ISAAC_ROS_WS=.*#ISAAC_ROS_WS=/workspaces/isaac_ros-dev#' \
    -e 's#^M=.*#M="${ENGINE_TEST_MODELS:?}"#' \
    -e 's#^TRT=.*#TRT="${ENGINE_TEST_TRT:?}"#' \
    "$engine_builder" > "$engine_test_script"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >> "${ENGINE_TEST_LOG:?}"' \
    'for argument in "$@"; do' \
    '  case "$argument" in' \
    '    --saveEngine=*) output="${argument#--saveEngine=}" ;;' \
    '  esac' \
    'done' \
    'printf "partial\n" > "$output"' \
    '[[ "${ENGINE_TEST_FAIL:-0}" != 1 ]]' > "$engine_test_stub"
  chmod +x "$engine_test_stub"
  : > "$engine_test_log"

  assert_succeeds 'zero-byte engine is rebuilt to a nonempty plan' \
    env \
      ENGINE_TEST_MODELS="$engine_test_models" \
      ENGINE_TEST_TRT="$engine_test_stub" \
      ENGINE_TEST_LOG="$engine_test_log" \
      bash "$engine_test_script"
  if [[ -s "$engine_test_models/yolov8/best.plan" ]]; then
    pass 'zero-byte best.plan was replaced with a nonempty engine'
  else
    fail 'zero-byte best.plan must be rebuilt'
  fi

  rm -f "$engine_test_models/yolov8/yolov8s.plan"
  : > "$engine_test_log"
  assert_fails 'failed TensorRT build does not publish a final engine' \
    env \
      ENGINE_TEST_MODELS="$engine_test_models" \
      ENGINE_TEST_TRT="$engine_test_stub" \
      ENGINE_TEST_LOG="$engine_test_log" \
      ENGINE_TEST_FAIL=1 \
      bash "$engine_test_script"
  if [[ ! -e "$engine_test_models/yolov8/yolov8s.plan" ]]; then
    pass 'failed TensorRT build leaves no final yolov8s.plan'
  else
    fail 'failed TensorRT build must not leave a final yolov8s.plan'
  fi
  engine_junk="$(
    find "$engine_test_models" -type f -name '*.tmp.*' -print -quit
  )"
  if [[ -z "$engine_junk" ]]; then
    pass 'failed TensorRT build cleans temporary engine files'
  else
    fail "failed TensorRT build left temporary junk: $engine_junk"
  fi

  verify_timeout_stub="$workspace/timeout"
  verify_ros2_stub="$workspace/verify-ros2"
  verify_stub_bin="$workspace/verify-stubs"
  mkdir -p "$verify_stub_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${VERIFY_PROBES_VALID:-0}" = 1 ]]; then' \
    '  printf "%s\n" "average rate: 15.0" "class_id: 41" "score: 0.9" "size_x: 20" "position:" "z: 0.5"' \
    '  exit 0' \
    'fi' \
    'exit 1' > "$verify_timeout_stub"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$verify_ros2_stub"
  chmod +x "$verify_timeout_stub" "$verify_ros2_stub"
  ln -s "$verify_timeout_stub" "$verify_stub_bin/timeout"
  ln -s "$verify_ros2_stub" "$verify_stub_bin/ros2"

  for verify_entrypoint in \
    "$repo/launch/run_cup_pose_standalone.sh" \
    "$repo/launch/run_cup_pose_tracking.sh"; do
    verify_block="$workspace/$(basename "$verify_entrypoint").verify"
    {
      printf 'set -o pipefail\n'
      awk '
        /^if \[ "\$\{1:-\}" = "verify" \]; then$/ {
          capture = 1
          depth = 1
          print
          next
        }
        capture {
          if ($0 ~ /^[[:space:]]*if([[:space:]]|\[)/) {
            depth++
          }
          print
          if ($0 ~ /^[[:space:]]*fi[[:space:]]*$/) {
            depth--
            if (depth == 0) {
              exit
            }
          }
        }
      ' "$verify_entrypoint"
    } > "$verify_block"
    assert_fails "$(basename "$verify_entrypoint") verify fails when all probes fail" \
      env PATH="$verify_stub_bin:$PATH" bash "$verify_block" verify
    assert_succeeds "$(basename "$verify_entrypoint") verify succeeds for valid probes" \
      env \
        PATH="$verify_stub_bin:$PATH" \
        VERIFY_PROBES_VALID=1 \
        bash "$verify_block" verify
  done
  assert_not_contains "$repo/launch/run_cup_pose.sh" \
    'if [ "${1:-}" = "verify" ]; then'

  setup_guide="$repo/SETUP_GUIDE.md"
  assert_text_before "$setup_guide" './bootstrap.sh' '로그아웃한 뒤 다시'
  assert_text_before "$setup_guide" '로그아웃한 뒤 다시' 'docker info'
  assert_text_before "$setup_guide" 'docker info' 'sudo isaac-ros init docker'
  assert_text_before "$setup_guide" 'sudo isaac-ros init docker' './setup_jazzy.sh'
  assert_text_before "$setup_guide" './setup_jazzy.sh' './verify_jazzy_setup.sh --host'
  assert_text_before "$setup_guide" \
    './verify_jazzy_setup.sh --host' 'isaac-ros activate --build-local'
  assert_text_before "$setup_guide" \
    'isaac-ros activate --build-local' './verify_jazzy_setup.sh --container'
  assert_text_before "$setup_guide" \
    './verify_jazzy_setup.sh --container' './launch/build_engines.sh'
  assert_text_before "$setup_guide" \
    './launch/build_engines.sh' '## 6. 선택 사항: D435i'
  for retained_warning in '.plan' '8 GB' 'num_classes' '5.16.0.1'; do
    assert_contains "$setup_guide" "$retained_warning"
  done

  bootstrap="$repo/bootstrap.sh"
  assert_contains "$bootstrap" \
    'https://isaac.download.nvidia.com/isaac-ros/release-4.5 noble main'
  assert_contains "$bootstrap" 'sudo apt-get install -y isaac-ros-cli'
  assert_contains "$bootstrap" 'sudo isaac-ros init docker'
  assert_contains "$bootstrap" './setup_jazzy.sh'
  assert_contains "$bootstrap" 'isaac-ros activate --build-local'
  assert_not_contains "$bootstrap" 'ISAAC_ROS_VERSION=3.2'
  assert_text_before "$bootstrap" \
    'sudo apt-get install -y locales curl gnupg software-properties-common' \
    'curl -fsSL https://get.docker.com'
  assert_contains "$bootstrap" \
    'export ISAAC_ROS_WS="${ISAAC_ROS_WS:-$HOME/workspaces/isaac_ros-dev}"'
  assert_contains "$bootstrap" '# >>> perception ISAAC_ROS_WS >>>'
  assert_contains "$bootstrap" '# <<< perception ISAAC_ROS_WS <<<'

  bashrc_home="$workspace/bashrc-home"
  bashrc_setup="$workspace/bashrc-setup.sh"
  mkdir -p "$bashrc_home"
  printf '%s\n' \
    '# unrelated user setting' \
    'export KEEP_ME=yes' \
    'export ISAAC_ROS_WS="$HOME/workspaces/isaac_ros-dev"' \
    > "$bashrc_home/.bashrc"
  sed -n \
    '/^# Keep the CLI workspace available/,/^# Official repository prerequisites/{/^# Official repository prerequisites/!p}' \
    "$bootstrap" > "$bashrc_setup"

  assert_succeeds 'bootstrap bashrc setup migrates an old export' \
    env HOME="$bashrc_home" USER=tester bash "$bashrc_setup"
  assert_succeeds 'bootstrap bashrc setup is idempotent' \
    env HOME="$bashrc_home" USER=tester bash "$bashrc_setup"
  assert_not_contains "$bashrc_home/.bashrc" \
    'export ISAAC_ROS_WS="$HOME/workspaces/isaac_ros-dev"'
  assert_contains "$bashrc_home/.bashrc" '# unrelated user setting'
  assert_contains "$bashrc_home/.bashrc" 'export KEEP_ME=yes'
  assert_occurrences "$bashrc_home/.bashrc" 1 \
    '# >>> perception ISAAC_ROS_WS >>>'
  assert_occurrences "$bashrc_home/.bashrc" 1 \
    '# <<< perception ISAAC_ROS_WS <<<'

  symlink_home="$workspace/symlink-bashrc-home"
  symlink_target_dir="$workspace/symlink-bashrc-target"
  symlink_target="$symlink_target_dir/bashrc"
  mkdir -p "$symlink_home" "$symlink_target_dir"
  printf '%s\n' \
    '# symlink target setting' \
    'export KEEP_SYMLINK_TARGET=yes' \
    'export ISAAC_ROS_WS="$HOME/workspaces/isaac_ros-dev"' \
    > "$symlink_target"
  chmod 0640 "$symlink_target"
  ln -s "../symlink-bashrc-target/bashrc" "$symlink_home/.bashrc"

  assert_succeeds 'bootstrap bashrc setup updates a symlink target' \
    env HOME="$symlink_home" USER=tester bash "$bashrc_setup"
  if [[ -L "$symlink_home/.bashrc" ]]; then
    pass 'bootstrap bashrc setup preserves a symlinked .bashrc'
  else
    fail 'bootstrap bashrc setup must not replace a symlinked .bashrc'
  fi
  assert_contains "$symlink_target" '# symlink target setting'
  assert_contains "$symlink_target" 'export KEEP_SYMLINK_TARGET=yes'
  assert_not_contains "$symlink_target" \
    'export ISAAC_ROS_WS="$HOME/workspaces/isaac_ros-dev"'
  assert_occurrences "$symlink_target" 1 \
    '# >>> perception ISAAC_ROS_WS >>>'
  assert_occurrences "$symlink_target" 1 \
    '# <<< perception ISAAC_ROS_WS <<<'
  assert_output_equals 'bootstrap bashrc setup preserves symlink target mode' \
    '640' stat -c '%a' "$symlink_target"

  assert_malformed_bashrc_is_preserved() {
    local case_name="$1"
    local first_line="$2"
    local second_line="${3:-}"
    local malformed_home="$workspace/malformed-$case_name"
    local before="$workspace/malformed-$case_name.before"

    mkdir -p "$malformed_home"
    printf '%s\n' \
      '# content before malformed markers' \
      "$first_line" \
      "$second_line" \
      'export MUST_SURVIVE=yes' > "$malformed_home/.bashrc"
    cp "$malformed_home/.bashrc" "$before"

    assert_fails "bootstrap rejects malformed bashrc markers: $case_name" \
      env HOME="$malformed_home" USER=tester bash "$bashrc_setup"
    if cmp -s "$before" "$malformed_home/.bashrc"; then
      pass "bootstrap preserves malformed bashrc byte-for-byte: $case_name"
    else
      fail "bootstrap changed malformed bashrc content: $case_name"
    fi
  }

  assert_malformed_bashrc_is_preserved \
    unmatched-begin '# >>> perception ISAAC_ROS_WS >>>'
  assert_malformed_bashrc_is_preserved \
    unmatched-end '# <<< perception ISAAC_ROS_WS <<<'
  assert_malformed_bashrc_is_preserved \
    reversed-order \
    '# <<< perception ISAAC_ROS_WS <<<' \
    '# >>> perception ISAAC_ROS_WS >>>'
  assert_malformed_bashrc_is_preserved \
    duplicate-blocks \
    $'# >>> perception ISAAC_ROS_WS >>>\n# <<< perception ISAAC_ROS_WS <<<' \
    $'# >>> perception ISAAC_ROS_WS >>>\n# <<< perception ISAAC_ROS_WS <<<'

  bashrc_under_test="$workspace/bashrc-under-test"
  container_marker="$workspace/container-marker"
  sed "s#/.dockerenv#$container_marker#g" \
    "$bashrc_home/.bashrc" > "$bashrc_under_test"

  assert_output_equals 'generated bashrc defaults to the host workspace outside Docker' \
    "$bashrc_home/workspaces/isaac_ros-dev" \
    env -u ISAAC_ROS_WS HOME="$bashrc_home" \
    BASH_ENV= bash --noprofile --norc -c \
    'source "$1"; printf "%s\n" "$ISAAC_ROS_WS"' _ "$bashrc_under_test"
  assert_output_equals 'generated bashrc preserves a custom host workspace outside Docker' \
    "$workspace/custom-host-workspace" \
    env HOME="$bashrc_home" \
    ISAAC_ROS_WS="$workspace/custom-host-workspace" \
    BASH_ENV= bash --noprofile --norc -c \
    'source "$1"; printf "%s\n" "$ISAAC_ROS_WS"' _ "$bashrc_under_test"
  : > "$container_marker"
  assert_output_equals 'generated bashrc overrides a poisoned value inside Docker' \
    '/workspaces/isaac_ros-dev' \
    env HOME=/home/admin \
    ISAAC_ROS_WS=/home/admin/workspaces/isaac_ros-dev \
    BASH_ENV= bash --noprofile --norc -c \
    'source "$1"; printf "%s\n" "$ISAAC_ROS_WS"' _ "$bashrc_under_test"

  assert_occurrences "$bootstrap" 1 \
    'sudo nvidia-ctk runtime configure --runtime=docker'
  toolkit_install_block="$(
    sed -n '/^if need nvidia-ctk; then$/,/^fi$/p' "$bootstrap"
  )"
  if grep -Fq 'runtime configure --runtime=docker' <<< "$toolkit_install_block"; then
    fail 'nvidia runtime configuration must run after the toolkit install branch'
  else
    pass 'nvidia runtime configuration runs after the toolkit install branch'
  fi
  assert_contains "$bootstrap" \
    'if [[ "$docker_runtime_before" != "$docker_runtime_after" ]]; then'
  assert_contains "$bootstrap" 'docker info >/dev/null'
  assert_contains "$bootstrap" \
    "docker run --rm --gpus all ubuntu:24.04 bash -lc 'nvidia-smi >/dev/null'"
  assert_text_before "$bootstrap" 'id -nG' 'docker info >/dev/null'
  assert_contains "$bootstrap" \
    'sudo apt-get install -y locales curl gnupg software-properties-common'
  assert_contains "$bootstrap" 'sudo locale-gen en_US en_US.UTF-8'
  assert_contains "$bootstrap" 'locale charmap'
  assert_contains "$bootstrap" 'UTF-8 locale를 구성할 수 없습니다'

  setup_script="$repo/setup_jazzy.sh"
  cli_docker_dir="$workspace/initialized-cli/docker"
  cli_environment_file="$workspace/initialized-cli/environment.conf"
  mkdir -p "$cli_docker_dir"
  printf 'ISAAC_ROS_ENVIRONMENT=docker\n' > "$cli_environment_file"
  run_setup() {
    local test_workspace="$1"
    shift

    env \
      -u JAZZY_SETUP_TEST_MODE \
      -u JAZZY_TEST_BRANCH \
      -u JAZZY_TEST_OS_RELEASE \
      -u JAZZY_TEST_MODELS_DIR \
      -u JAZZY_TEST_ARCH \
      -u JAZZY_TEST_DRIVER_VERSION \
      -u JAZZY_TEST_CLI_DOCKER_DIR \
      -u JAZZY_TEST_CLI_ENVIRONMENT_FILE \
      PATH="$stub_bin:$PATH" \
      SETUP_DOCKER_TEST_LOG="$setup_docker_log" \
      ISAAC_ROS_WS="$test_workspace" \
      JAZZY_TEST_ARCH=x86_64 \
      JAZZY_TEST_DRIVER_VERSION=580.0 \
      JAZZY_TEST_CLI_DOCKER_DIR="$cli_docker_dir" \
      JAZZY_TEST_CLI_ENVIRONMENT_FILE="$cli_environment_file" \
      "$@" \
      "$setup_script"
  }

  if [[ -f "$setup_script" ]]; then
    assert_succeeds 'setup_jazzy.sh completes in test mode' \
      run_setup "$workspace" \
      JAZZY_SETUP_TEST_MODE=1 \
      JAZZY_TEST_OS_RELEASE=24.04 \
      JAZZY_TEST_BRANCH=jazzy \
      JAZZY_TEST_ARCH=x86_64 \
      JAZZY_TEST_DRIVER_VERSION=580.0 \
      JAZZY_TEST_CLI_DOCKER_DIR="$cli_docker_dir"
    assert_succeeds 'setup_jazzy.sh is idempotent in test mode' \
      run_setup "$workspace" \
      JAZZY_SETUP_TEST_MODE=1 \
      JAZZY_TEST_OS_RELEASE=24.04 \
      JAZZY_TEST_BRANCH=jazzy \
      JAZZY_TEST_ARCH=x86_64 \
      JAZZY_TEST_DRIVER_VERSION=580.0 \
      JAZZY_TEST_CLI_DOCKER_DIR="$cli_docker_dir"
  else
    fail 'missing setup_jazzy.sh'
  fi

  assert_contains "$workspace/scripts/.isaac_ros_common-config" \
    "CONFIG_DOCKER_SEARCH_DIRS=($repo/docker /etc/isaac-ros-cli/docker)"
  assert_contains "$workspace/.isaac-ros-cli/config.yaml" '      - realsense'
  assert_contains "$workspace/.isaac-ros-cli/config.yaml" '      - perception'

  if [[ -f "$workspace/.isaac-ros-cli/config.yaml" ]]; then
    realsense_line="$(grep -Fn -- '      - realsense' "$workspace/.isaac-ros-cli/config.yaml" | head -n 1 | cut -d: -f1)"
    perception_line="$(grep -Fn -- '      - perception' "$workspace/.isaac-ros-cli/config.yaml" | head -n 1 | cut -d: -f1)"
    if [[ -n "$realsense_line" && -n "$perception_line" && "$realsense_line" -lt "$perception_line" ]]; then
      pass 'realsense precedes perception in additional image keys'
    else
      fail 'realsense must precede perception in additional image keys'
    fi
  else
    fail 'cannot compare image-key order without config.yaml'
  fi

  for required_asset in \
    "$workspace/isaac_ros_assets/models/yolov8/best.onnx" \
    "$workspace/isaac_ros_assets/launch/build_engines.sh" \
    "$workspace/isaac_ros_assets/verify_jazzy_setup.sh"; do
    if [[ -f "$required_asset" ]]; then
      pass "generated asset exists: ${required_asset#"$workspace"/}"
    else
      fail "missing generated asset: ${required_asset#"$workspace"/}"
    fi
  done

  for source_entrypoint in "$repo"/launch/*.sh "$repo/verify_jazzy_setup.sh"; do
    if [[ "$source_entrypoint" = "$repo/verify_jazzy_setup.sh" ]]; then
      copied_entrypoint="$workspace/isaac_ros_assets/verify_jazzy_setup.sh"
    else
      copied_entrypoint="$workspace/isaac_ros_assets/launch/$(basename "$source_entrypoint")"
    fi
    assert_executable "$copied_entrypoint"
  done

  assert_fails_with 'setup rejects an injected non-Jazzy branch' \
    'jazzy 브랜치 전용입니다 (현재: main)' \
    run_setup "$workspace/rejected-branch" \
    JAZZY_SETUP_TEST_MODE=1 \
    JAZZY_TEST_OS_RELEASE=24.04 \
    JAZZY_TEST_BRANCH=main
  assert_fails_with 'setup rejects an injected non-Noble OS' \
    'Ubuntu 24.04가 필요합니다 (현재: 22.04)' \
    run_setup "$workspace/rejected-os" \
    JAZZY_SETUP_TEST_MODE=1 \
    JAZZY_TEST_OS_RELEASE=22.04 \
    JAZZY_TEST_BRANCH=jazzy
  assert_fails_with 'setup rejects a non-x86_64 host before workspace mutation' \
    'x86_64 아키텍처가 필요합니다' \
    run_setup "$workspace/rejected-arch" \
    JAZZY_SETUP_TEST_MODE=1 \
    JAZZY_TEST_OS_RELEASE=24.04 \
    JAZZY_TEST_BRANCH=jazzy \
    JAZZY_TEST_ARCH=aarch64 \
    JAZZY_TEST_DRIVER_VERSION=580.0 \
    JAZZY_TEST_CLI_DOCKER_DIR="$cli_docker_dir"
  assert_fails_with 'setup rejects NVIDIA drivers older than 580' \
    'NVIDIA 드라이버 580 이상이 필요합니다' \
    run_setup "$workspace/rejected-driver" \
    JAZZY_SETUP_TEST_MODE=1 \
    JAZZY_TEST_OS_RELEASE=24.04 \
    JAZZY_TEST_BRANCH=jazzy \
    JAZZY_TEST_ARCH=x86_64 \
    JAZZY_TEST_DRIVER_VERSION=579.99 \
    JAZZY_TEST_CLI_DOCKER_DIR="$cli_docker_dir"
  missing_cli_workspace="$workspace/rejected-uninitialized-cli"
  assert_fails_with 'setup rejects a missing Isaac ROS CLI system layer' \
    'sudo isaac-ros init docker' \
    run_setup "$missing_cli_workspace" \
    JAZZY_SETUP_TEST_MODE=1 \
    JAZZY_TEST_OS_RELEASE=24.04 \
    JAZZY_TEST_BRANCH=jazzy \
    JAZZY_TEST_ARCH=x86_64 \
    JAZZY_TEST_DRIVER_VERSION=580.0 \
    JAZZY_TEST_CLI_DOCKER_DIR="$workspace/missing-cli-docker" \
    JAZZY_TEST_CLI_ENVIRONMENT_FILE="$cli_environment_file"
  if [[ ! -e "$missing_cli_workspace" ]]; then
    pass 'missing CLI system-layer rejection occurs before workspace mutation'
  else
    fail 'setup mutated the workspace before rejecting missing CLI system layer'
  fi

  missing_mode_workspace="$workspace/rejected-missing-cli-mode"
  assert_fails_with 'setup rejects a missing Isaac ROS CLI mode file' \
    'sudo isaac-ros init docker' \
    run_setup "$missing_mode_workspace" \
    JAZZY_SETUP_TEST_MODE=1 \
    JAZZY_TEST_OS_RELEASE=24.04 \
    JAZZY_TEST_BRANCH=jazzy \
    JAZZY_TEST_CLI_DOCKER_DIR="$cli_docker_dir" \
    JAZZY_TEST_CLI_ENVIRONMENT_FILE="$workspace/missing-environment.conf"
  if [[ ! -e "$missing_mode_workspace" ]]; then
    pass 'missing CLI mode-file rejection occurs before workspace mutation'
  else
    fail 'setup mutated the workspace before rejecting missing CLI mode file'
  fi

  uninitialized_environment_file="$workspace/uninitialized-environment.conf"
  printf 'SOME_OTHER_SETTING=docker\n' > "$uninitialized_environment_file"
  assert_fails_with 'setup rejects a CLI mode file without the exact assignment' \
    'sudo isaac-ros init docker' \
    run_setup "$workspace/rejected-uninitialized-mode" \
    JAZZY_SETUP_TEST_MODE=1 \
    JAZZY_TEST_OS_RELEASE=24.04 \
    JAZZY_TEST_BRANCH=jazzy \
    JAZZY_TEST_CLI_DOCKER_DIR="$cli_docker_dir" \
    JAZZY_TEST_CLI_ENVIRONMENT_FILE="$uninitialized_environment_file"

  non_docker_environment_file="$workspace/non-docker-environment.conf"
  printf 'ISAAC_ROS_ENVIRONMENT=virtualenv\n' > "$non_docker_environment_file"
  assert_fails_with 'setup rejects a non-Docker Isaac ROS CLI mode' \
    'sudo isaac-ros init docker' \
    run_setup "$workspace/rejected-non-docker-mode" \
    JAZZY_SETUP_TEST_MODE=1 \
    JAZZY_TEST_OS_RELEASE=24.04 \
    JAZZY_TEST_BRANCH=jazzy \
    JAZZY_TEST_CLI_DOCKER_DIR="$cli_docker_dir" \
    JAZZY_TEST_CLI_ENVIRONMENT_FILE="$non_docker_environment_file"

  setup_model_cases="$workspace/setup-model-cases"
  empty_models="$setup_model_cases/empty"
  truncated_models="$setup_model_cases/truncated"
  lfs_models="$setup_model_cases/lfs"
  mkdir -p "$empty_models" "$truncated_models" "$lfs_models"
  head -c 999 /dev/zero > "$truncated_models/truncated.onnx"
  {
    printf 'version https://git-lfs.github.com/spec/v1\n'
    head -c 1000 /dev/zero
  } > "$lfs_models/pointer.onnx"

  assert_fails_with 'setup rejects a missing source ONNX model' \
    'ONNX 모델을 찾을 수 없습니다' \
    run_setup "$workspace/rejected-missing-model" \
    JAZZY_SETUP_TEST_MODE=1 \
    JAZZY_TEST_OS_RELEASE=24.04 \
    JAZZY_TEST_BRANCH=jazzy \
    JAZZY_TEST_MODELS_DIR="$empty_models"
  assert_fails_with 'setup rejects a truncated source ONNX model' \
    'ONNX 모델이 너무 작습니다' \
    run_setup "$workspace/rejected-truncated-model" \
    JAZZY_SETUP_TEST_MODE=1 \
    JAZZY_TEST_OS_RELEASE=24.04 \
    JAZZY_TEST_BRANCH=jazzy \
    JAZZY_TEST_MODELS_DIR="$truncated_models"
  assert_fails_with 'setup rejects a Git LFS source ONNX pointer' \
    'ONNX 모델이 Git LFS 포인터입니다' \
    run_setup "$workspace/rejected-lfs-model" \
    JAZZY_SETUP_TEST_MODE=1 \
    JAZZY_TEST_OS_RELEASE=24.04 \
    JAZZY_TEST_BRANCH=jazzy \
    JAZZY_TEST_MODELS_DIR="$lfs_models"

  assert_empty "$setup_docker_log" \
    'test mode never invokes the Docker stub'

  : > "$setup_docker_log"
  assert_succeeds \
    'production mode ignores test model override and runs Docker/GPU probes' \
    run_setup "$workspace/production-success" \
    JAZZY_TEST_MODELS_DIR="$empty_models" \
    DOCKER_INFO_EXIT=0 \
    DOCKER_RUN_EXIT=0
  assert_contains "$setup_docker_log" 'info'
  assert_contains "$setup_docker_log" \
    'run --rm --gpus all ubuntu:24.04 bash -lc nvidia-smi >/dev/null'

  : > "$setup_docker_log"
  assert_fails_with 'production mode reports Docker access failure guidance' \
    'docker 그룹에 사용자를 추가한 뒤 다시 로그인하세요' \
    run_setup "$workspace/production-docker-failure" \
    DOCKER_INFO_EXIT=1 \
    DOCKER_RUN_EXIT=0
  assert_contains "$setup_docker_log" 'info'
  assert_not_contains "$setup_docker_log" \
    'run --rm --gpus all ubuntu:24.04 bash -lc nvidia-smi >/dev/null'

  : > "$setup_docker_log"
  assert_fails_with 'production mode rejects failed GPU passthrough' \
    'Docker 컨테이너에서 NVIDIA GPU를 사용할 수 없습니다' \
    run_setup "$workspace/production-gpu-failure" \
    DOCKER_INFO_EXIT=0 \
    DOCKER_RUN_EXIT=1
  assert_contains "$setup_docker_log" \
    'run --rm --gpus all ubuntu:24.04 bash -lc nvidia-smi >/dev/null'
fi

verifier="$repo/verify_jazzy_setup.sh"
for forbidden_probe in \
  'lsusb' \
  'rs-enumerate-devices' \
  '/dev/video' \
  '/dev/bus/usb' \
  'v4l2-ctl' \
  'realsense-viewer'; do
  assert_not_contains "$verifier" "$forbidden_probe"
done
assert_contains "$verifier" '[[ -f /.dockerenv ]]'
assert_contains "$verifier" 'ISAAC_ROS_WS=/workspaces/isaac_ros-dev'

for container_entrypoint in \
  "$repo/launch/build_engines.sh" \
  "$repo"/launch/run_*.sh; do
  assert_container_entrypoint_uses_canonical_workspace "$container_entrypoint"
done

verify_workspace="$workspace/verify-workspace"
verify_assets="$verify_workspace/isaac_ros_assets"
verify_cli_docker_dir="$workspace/verify-initialized-cli/docker"
verify_cli_environment_file="$workspace/verify-initialized-cli/environment.conf"
mkdir -p \
  "$verify_cli_docker_dir" \
  "$verify_workspace/scripts" \
  "$verify_workspace/.isaac-ros-cli" \
  "$verify_assets/models" \
  "$verify_assets/isaac_ros_foundationpose/Cup"
printf 'ISAAC_ROS_ENVIRONMENT=docker\n' > "$verify_cli_environment_file"
printf 'CONFIG_DOCKER_SEARCH_DIRS=(%s/docker /etc/isaac-ros-cli/docker)\n' \
  "$repo" > "$verify_workspace/scripts/.isaac_ros_common-config"
printf '%s\n' \
  'docker:' \
  '  image:' \
  '    additional_image_keys:' \
  '      - realsense' \
  '      - perception' > "$verify_workspace/.isaac-ros-cli/config.yaml"

while IFS= read -r -d '' source_model; do
  copied_model="$verify_assets/${source_model#"$repo"/}"
  mkdir -p "$(dirname "$copied_model")"
  cp "$source_model" "$copied_model"
done < <(find "$repo/models" -type f -name '*.onnx' -print0)
cp "$repo/assets/Cup/cup.obj" \
  "$verify_assets/isaac_ros_foundationpose/Cup/Cup.obj"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'exit "${NVIDIA_SMI_EXIT:-0}"' > "$stub_bin/nvidia-smi"
chmod +x "$stub_bin/nvidia-smi"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" >> "${ROS2_TEST_LOG:?}"' \
  'if [[ "${3:-}" = "${ROS2_FAIL_PACKAGE:-}" ]]; then exit 1; fi' \
  'exit 0' > "$stub_bin/ros2"
chmod +x "$stub_bin/ros2"
docker_log="$workspace/docker.log"
ros2_log="$workspace/ros2.log"
: > "$docker_log"
: > "$ros2_log"

run_host_verifier() {
  local test_workspace="$1"
  shift

  env \
    PATH="$stub_bin:$PATH" \
    DOCKER_TEST_LOG="$docker_log" \
    DOCKER_INFO_EXIT=0 \
    DOCKER_RUN_EXIT=0 \
    JAZZY_VERIFY_TEST_MODE=1 \
    JAZZY_VERIFY_TEST_ARCH=x86_64 \
    JAZZY_VERIFY_TEST_DRIVER_VERSION=580.0 \
    JAZZY_VERIFY_TEST_CLI_DOCKER_DIR="$verify_cli_docker_dir" \
    JAZZY_VERIFY_TEST_CLI_ENVIRONMENT_FILE="$verify_cli_environment_file" \
    ISAAC_ROS_WS="$test_workspace" \
    "$@" \
    bash "$verifier" --host
}

run_container_verifier() {
  local test_workspace="$1"
  shift

  env \
    PATH="$stub_bin:$PATH" \
    NVIDIA_SMI_EXIT=0 \
    ROS2_TEST_LOG="$ros2_log" \
    ROS_DISTRO=jazzy \
    JAZZY_VERIFY_TEST_MODE=1 \
    JAZZY_VERIFY_TEST_WORKSPACE="$test_workspace" \
    ISAAC_ROS_WS="$workspace/poisoned-host-workspace" \
    "$@" \
    bash "$verifier" --container
}

make_verify_case() {
  local name="$1"

  case_workspace="$workspace/case-$name"
  cp -al "$verify_workspace" "$case_workspace"
}

assert_output_equals 'host mode prints one concise OK summary' \
  'OK: Jazzy host environment verified (5 models)' \
  run_host_verifier "$verify_workspace"
assert_contains "$docker_log" 'info'
assert_contains "$docker_log" \
  'run --rm --gpus all ubuntu:24.04 bash -lc nvidia-smi >/dev/null'

assert_output_equals 'container mode prints one concise OK summary' \
  'OK: Jazzy container environment verified (5 packages)' \
  run_container_verifier "$verify_workspace"

assert_fails_with \
  'container mode ignores a poisoned inherited host workspace' \
  'workspace does not exist: /workspaces/isaac_ros-dev' \
  env \
    PATH="$stub_bin:$PATH" \
    NVIDIA_SMI_EXIT=0 \
    ROS2_TEST_LOG="$ros2_log" \
    ROS_DISTRO=jazzy \
    ISAAC_ROS_WS="$workspace/poisoned-host-workspace" \
    bash "$verifier" --container

# No camera-related commands are stubbed: both success paths above prove that
# verification completes using only Docker, GPU, and ROS package probes.

assert_fails 'verifier rejects an unknown mode' \
  bash "$verifier" --camera
assert_fails 'verifier rejects multiple modes' \
  bash "$verifier" --host --container

for package in \
  rmw_cyclonedds_cpp \
  isaac_ros_foundationpose \
  isaac_ros_yolov8 \
  isaac_ros_realsense \
  isaac_ros_image_proc \
  isaac_ros_tensor_rt; do
  assert_contains "$ros2_log" "pkg prefix $package"
done
assert_text_before "$ros2_log" \
  'pkg prefix rmw_cyclonedds_cpp' \
  'pkg prefix isaac_ros_foundationpose'

assert_fails 'host mode rejects a missing workspace' \
  run_host_verifier "$workspace/does-not-exist"
assert_fails_with 'host mode rejects a non-x86_64 host' \
  'x86_64 architecture is required' \
  run_host_verifier "$verify_workspace" \
  JAZZY_VERIFY_TEST_ARCH=aarch64
assert_fails_with 'host mode rejects NVIDIA drivers older than 580' \
  'NVIDIA driver 580 or newer is required' \
  run_host_verifier "$verify_workspace" \
  JAZZY_VERIFY_TEST_DRIVER_VERSION=579.99
assert_fails_with 'host mode rejects an uninitialized Docker CLI' \
  'sudo isaac-ros init docker' \
  run_host_verifier "$verify_workspace" \
  JAZZY_VERIFY_TEST_CLI_DOCKER_DIR="$workspace/missing-verify-cli"
assert_fails_with 'host mode rejects a missing CLI environment file' \
  'sudo isaac-ros init docker' \
  run_host_verifier "$verify_workspace" \
  JAZZY_VERIFY_TEST_CLI_ENVIRONMENT_FILE="$workspace/missing-verify-environment.conf"
assert_fails_with 'host mode rejects a non-Docker CLI environment' \
  'sudo isaac-ros init docker' \
  run_host_verifier "$verify_workspace" \
  JAZZY_VERIFY_TEST_CLI_ENVIRONMENT_FILE="$non_docker_environment_file"

make_verify_case missing-common-config
rm -f "$case_workspace/scripts/.isaac_ros_common-config"
assert_fails 'host mode rejects a missing common config' \
  run_host_verifier "$case_workspace"

make_verify_case missing-cli-config
rm -f "$case_workspace/.isaac-ros-cli/config.yaml"
assert_fails 'host mode rejects a missing CLI config' \
  run_host_verifier "$case_workspace"

make_verify_case missing-cli-key
rm -f "$case_workspace/.isaac-ros-cli/config.yaml"
printf '%s\n' \
  'docker:' \
  '  image:' \
  '    additional_image_keys:' \
  '      - realsense' > "$case_workspace/.isaac-ros-cli/config.yaml"
assert_fails 'host mode rejects a missing CLI key' \
  run_host_verifier "$case_workspace"

assert_fails 'host mode rejects failed Docker access' \
  run_host_verifier "$verify_workspace" DOCKER_INFO_EXIT=1
assert_fails 'host mode rejects failed GPU passthrough' \
  run_host_verifier "$verify_workspace" DOCKER_RUN_EXIT=1

copied_yolo_model='isaac_ros_assets/models/yolov8/best.onnx'

make_verify_case missing-copied-model
rm -f "$case_workspace/$copied_yolo_model"
assert_fails 'host mode rejects a missing copied ONNX model' \
  run_host_verifier "$case_workspace"

make_verify_case truncated-copied-model
rm -f "$case_workspace/$copied_yolo_model"
printf 'truncated\n' > "$case_workspace/$copied_yolo_model"
assert_fails 'host mode rejects a truncated copied ONNX model' \
  run_host_verifier "$case_workspace"

make_verify_case lfs-copied-model
rm -f "$case_workspace/$copied_yolo_model"
{
  printf 'version https://git-lfs.github.com/spec/v1\n'
  printf '%01024d\n' 0
} > "$case_workspace/$copied_yolo_model"
assert_fails 'host mode rejects a Git LFS copied ONNX model' \
  run_host_verifier "$case_workspace"

assert_fails 'container mode rejects the wrong ROS distribution' \
  run_container_verifier "$verify_workspace" ROS_DISTRO=humble
assert_fails 'container mode rejects failed GPU visibility' \
  run_container_verifier "$verify_workspace" NVIDIA_SMI_EXIT=1
assert_fails_with 'container mode reports a missing CycloneDDS RMW clearly' \
  'required CycloneDDS RMW package is unavailable: rmw_cyclonedds_cpp' \
  run_container_verifier "$verify_workspace" \
  ROS2_FAIL_PACKAGE=rmw_cyclonedds_cpp
assert_fails 'container mode rejects a missing ROS package prefix' \
  run_container_verifier "$verify_workspace" \
  ROS2_FAIL_PACKAGE=isaac_ros_yolov8

make_verify_case missing-models-directory
rm -rf "$case_workspace/isaac_ros_assets/models"
assert_fails 'container mode rejects a missing models directory' \
  run_container_verifier "$case_workspace"

make_verify_case missing-cup-mesh
rm -f "$case_workspace/isaac_ros_assets/isaac_ros_foundationpose/Cup/Cup.obj"
assert_fails 'container mode rejects a missing cup mesh' \
  run_container_verifier "$case_workspace"

make_verify_case empty-cup-mesh
rm -f "$case_workspace/isaac_ros_assets/isaac_ros_foundationpose/Cup/Cup.obj"
: > "$case_workspace/isaac_ros_assets/isaac_ros_foundationpose/Cup/Cup.obj"
assert_fails 'container mode rejects an empty cup mesh' \
  run_container_verifier "$case_workspace"

if [[ -f /.dockerenv ]]; then
  assert_output_equals 'default mode follows present /.dockerenv' \
    'OK: Jazzy container environment verified (5 packages)' \
    env \
      PATH="$stub_bin:$PATH" \
      NVIDIA_SMI_EXIT=0 \
      ROS2_TEST_LOG="$ros2_log" \
      ROS_DISTRO=jazzy \
      JAZZY_VERIFY_TEST_MODE=1 \
      JAZZY_VERIFY_TEST_WORKSPACE="$verify_workspace" \
      ISAAC_ROS_WS="$workspace/poisoned-host-workspace" \
      bash "$verifier"
else
  assert_output_equals 'default mode follows absent /.dockerenv' \
    'OK: Jazzy host environment verified (5 models)' \
    env \
      PATH="$stub_bin:$PATH" \
      DOCKER_TEST_LOG="$docker_log" \
      DOCKER_INFO_EXIT=0 \
      DOCKER_RUN_EXIT=0 \
      JAZZY_VERIFY_TEST_MODE=1 \
      JAZZY_VERIFY_TEST_ARCH=x86_64 \
      JAZZY_VERIFY_TEST_DRIVER_VERSION=580.0 \
      JAZZY_VERIFY_TEST_CLI_DOCKER_DIR="$verify_cli_docker_dir" \
      JAZZY_VERIFY_TEST_CLI_ENVIRONMENT_FILE="$verify_cli_environment_file" \
      ISAAC_ROS_WS="$verify_workspace" \
      bash "$verifier"
fi

printf '\n%d passed, %d failed\n' "$passes" "$failures"
(( failures == 0 ))
