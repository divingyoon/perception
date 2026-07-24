# Isaac ROS 4.5 Jazzy Perception Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `jazzy` branch reproducibly build and validate the perception environment with Isaac ROS 4.5, ROS 2 Jazzy, and Isaac ROS CLI Docker mode.

**Architecture:** Isaac ROS CLI supplies the official `isaac_ros` base and `realsense` image layer; this repository supplies a final `perception` layer. A host setup script writes workspace-scoped CLI configuration, copies repository assets into `${ISAAC_ROS_WS}`, and leaves the long image build as an explicit command.

**Tech Stack:** Bash, Docker, Isaac ROS CLI release 4.5, ROS 2 Jazzy, NVIDIA CUDA/TensorRT, shell regression tests

## Global Constraints

- Modify only the checked-out `jazzy` branch; `main` remains Ubuntu 22.04, ROS 2 Humble, Isaac ROS 3.2.
- Host OS is Ubuntu 24.04 Noble.
- ROS distribution is ROS 2 Jazzy.
- Isaac ROS version is release 4.5.
- Environment manager is Isaac ROS CLI in Docker mode.
- The default workspace is `${HOME}/workspaces/isaac_ros-dev`.
- Camera hardware is not required for image build or environment verification.
- No `ros-humble-*` package or `isaac_ros_common/run_dev.sh` workflow may remain in active Jazzy setup instructions.
- TensorRT `.plan` files are generated per GPU and are never committed.

---

## File Structure

- `docker/Dockerfile.perception`: repository-owned Jazzy package and environment layer.
- `setup_jazzy.sh`: idempotent host entrypoint that validates prerequisites, writes CLI configuration, and copies assets.
- `verify_jazzy_setup.sh`: host/container verification entrypoint that does not require a camera.
- `tests/test_jazzy_setup.sh`: regression tests for branch-specific Docker and setup configuration.
- `setup_workspace.sh`: copies all runtime assets, including verification and launch scripts, into the mounted workspace.
- `bootstrap.sh`: performs host setup and points only to the supported Jazzy CLI workflow on this branch.
- `README.md`, `SETUP_GUIDE.md`, `RUN.md`, `docker/BUILD.md`: Jazzy-specific installation and run instructions.

### Task 1: Add Failing Jazzy Configuration Regression Tests

**Files:**
- Create: `tests/test_jazzy_setup.sh`
- Test: `tests/test_jazzy_setup.sh`

**Interfaces:**
- Consumes: repository files from the current checkout.
- Produces: executable shell test suite invoked as `bash tests/test_jazzy_setup.sh`.

- [ ] **Step 1: Write the failing static Dockerfile tests**

Create a temporary assertion harness with `pass`, `fail`, `assert_contains`, and
`assert_not_contains` helpers. Assert that `docker/Dockerfile.perception`:

```bash
assert_contains docker/Dockerfile.perception 'ros-jazzy-isaac-ros-foundationpose'
assert_contains docker/Dockerfile.perception 'ros-jazzy-isaac-ros-yolov8'
assert_contains docker/Dockerfile.perception 'ros-jazzy-isaac-ros-realsense'
assert_contains docker/Dockerfile.perception 'CYCLONEDDS_URI=file:///etc/perception/cyclonedds.xml'
assert_not_contains docker/Dockerfile.perception 'ros-humble-'
assert_not_contains docker/Dockerfile.perception 'ros2_humble'
```

- [ ] **Step 2: Write the failing setup-generation tests**

Run `setup_jazzy.sh` in a temporary workspace with `JAZZY_SETUP_TEST_MODE=1`,
stubbed `docker`, `nvidia-smi`, and `isaac-ros` commands, then assert:

```bash
assert_contains "$workspace/scripts/.isaac_ros_common-config" \
  "CONFIG_DOCKER_SEARCH_DIRS=($repo/docker /etc/isaac-ros-cli/docker)"
assert_contains "$workspace/.isaac-ros-cli/config.yaml" \
  '      - realsense'
assert_contains "$workspace/.isaac-ros-cli/config.yaml" \
  '      - perception'
test -f "$workspace/isaac_ros_assets/models/yolov8/best.onnx"
test -f "$workspace/isaac_ros_assets/launch/build_engines.sh"
test -f "$workspace/isaac_ros_assets/verify_jazzy_setup.sh"
```

Also compare line numbers so `realsense` precedes `perception`.

- [ ] **Step 3: Run the tests to verify RED**

Run:

```bash
bash tests/test_jazzy_setup.sh
```

Expected: FAIL because `setup_jazzy.sh` and `verify_jazzy_setup.sh` do not exist
and the Dockerfile still contains `ros-humble-*`.

- [ ] **Step 4: Commit the test**

```bash
git add tests/test_jazzy_setup.sh
git commit -m "test: define Jazzy perception environment contract"
```

### Task 2: Port the Perception Docker Layer to Jazzy

**Files:**
- Modify: `docker/Dockerfile.perception`
- Test: `tests/test_jazzy_setup.sh`

**Interfaces:**
- Consumes: Isaac ROS CLI-provided `ARG BASE_IMAGE` and build context containing `cyclonedds.xml`.
- Produces: Docker image key `perception` with required ROS packages and container-wide DDS settings.

- [ ] **Step 1: Replace Humble metadata and packages**

Use `ARG BASE_IMAGE`/`FROM ${BASE_IMAGE}` and install:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
      ros-jazzy-isaac-ros-examples \
      ros-jazzy-isaac-ros-foundationpose \
      ros-jazzy-isaac-ros-segment-anything \
      ros-jazzy-isaac-ros-yolov8 \
      ros-jazzy-isaac-ros-rtdetr \
      ros-jazzy-isaac-ros-realsense \
      ros-jazzy-isaac-ros-image-proc \
      ros-jazzy-isaac-ros-dnn-image-encoder \
      ros-jazzy-isaac-ros-tensor-rt \
      ros-jazzy-isaac-ros-tensor-proc \
      ros-jazzy-isaac-ros-triton \
      ros-jazzy-isaac-ros-depth-image-proc \
      ros-jazzy-isaac-ros-nitros-topic-tools \
    && rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 2: Make DDS configuration independent of the runtime home**

Copy the configuration and set image-wide values:

```dockerfile
COPY cyclonedds.xml /etc/perception/cyclonedds.xml

ENV RMW_IMPLEMENTATION=rmw_cyclonedds_cpp \
    CYCLONEDDS_URI=file:///etc/perception/cyclonedds.xml \
    ROS_DOMAIN_ID=126 \
    ISAAC_ROS_WS=/workspaces/isaac_ros-dev
```

Do not mutate `/home/admin/.bashrc`, because Isaac ROS CLI controls runtime
users and mounted homes.

- [ ] **Step 3: Run the focused static tests**

Run:

```bash
bash tests/test_jazzy_setup.sh
```

Expected: Dockerfile assertions PASS; setup-script assertions still FAIL.

- [ ] **Step 4: Commit**

```bash
git add docker/Dockerfile.perception
git commit -m "feat: port perception image layer to Jazzy"
```

### Task 3: Implement Idempotent Jazzy Workspace Setup

**Files:**
- Create: `setup_jazzy.sh`
- Modify: `setup_workspace.sh`
- Test: `tests/test_jazzy_setup.sh`

**Interfaces:**
- Consumes: optional `ISAAC_ROS_WS`; `JAZZY_SETUP_TEST_MODE=1` disables real Docker/GPU probes in tests.
- Produces: workspace CLI config, copied assets, and a printed `isaac-ros activate --build-local` command.

- [ ] **Step 1: Implement branch and platform guards**

`setup_jazzy.sh` must use `set -euo pipefail`, resolve its repository directory,
and reject non-Jazzy checkouts and non-Noble hosts:

```bash
CURRENT_BRANCH="$(git -C "$REPO_DIR" branch --show-current)"
[ "$CURRENT_BRANCH" = jazzy ] ||
  die "이 스크립트는 jazzy 브랜치 전용입니다 (현재: ${CURRENT_BRANCH:-detached})"

. /etc/os-release
[ "${VERSION_ID:-}" = 24.04 ] ||
  die "Ubuntu 24.04가 필요합니다 (현재: ${VERSION_ID:-unknown})"
```

In `JAZZY_SETUP_TEST_MODE=1`, accept `JAZZY_TEST_OS_RELEASE` and
`JAZZY_TEST_BRANCH` so tests do not modify or depend on the host.

- [ ] **Step 2: Implement prerequisite and model validation**

Require `isaac-ros`, `docker`, and Git LFS materialized ONNX files. Treat a file
smaller than 1,000 bytes or beginning with the Git LFS pointer header as an
error. Outside test mode run:

```bash
docker info >/dev/null
docker run --rm --gpus all ubuntu:24.04 \
  bash -lc 'nvidia-smi >/dev/null'
```

The Docker failure message must tell the user to re-login after joining the
`docker` group. Camera state must not be inspected.

- [ ] **Step 3: Generate CLI configuration**

Resolve:

```bash
ISAAC_ROS_WS="${ISAAC_ROS_WS:-$HOME/workspaces/isaac_ros-dev}"
```

Create `${ISAAC_ROS_WS}/scripts/.isaac_ros_common-config` containing:

```bash
CONFIG_DOCKER_SEARCH_DIRS=(/absolute/path/to/perception/docker /etc/isaac-ros-cli/docker)
```

Create `${ISAAC_ROS_WS}/.isaac-ros-cli/config.yaml` containing:

```yaml
docker:
  image:
    additional_image_keys:
      - realsense
      - perception
```

- [ ] **Step 4: Copy workspace assets**

Invoke:

```bash
ISAAC_ROS_WS="$ISAAC_ROS_WS" "$REPO_DIR/setup_workspace.sh"
```

Extend `setup_workspace.sh` to copy `launch/*.sh`, `launch/*.py`, and
`verify_jazzy_setup.sh`, preserving executable modes for shell entrypoints.

- [ ] **Step 5: Run tests to verify GREEN**

Run:

```bash
bash tests/test_jazzy_setup.sh
bash -n setup_jazzy.sh setup_workspace.sh
```

Expected: all setup-generation tests PASS and both scripts parse successfully.

- [ ] **Step 6: Commit**

```bash
git add setup_jazzy.sh setup_workspace.sh
git commit -m "feat: add reproducible Jazzy workspace setup"
```

### Task 4: Add Camera-Independent Environment Verification

**Files:**
- Create: `verify_jazzy_setup.sh`
- Modify: `tests/test_jazzy_setup.sh`
- Test: `tests/test_jazzy_setup.sh`

**Interfaces:**
- Consumes: `--host` or `--container`; defaults based on presence of `/.dockerenv`.
- Produces: nonzero exit on an unmet requirement and a concise success summary.

- [ ] **Step 1: Add failing verifier contract tests**

Assert the verifier accepts only `--host` and `--container`, and that its source
contains no `lsusb`, RealSense device enumeration, or camera requirement:

```bash
assert_not_contains verify_jazzy_setup.sh 'lsusb'
assert_not_contains verify_jazzy_setup.sh 'rs-enumerate-devices'
```

Run:

```bash
bash tests/test_jazzy_setup.sh
```

Expected: FAIL because the verifier does not yet exist.

- [ ] **Step 2: Implement host verification**

Host mode checks:

- `ISAAC_ROS_WS` resolves to an existing workspace;
- both generated CLI files exist and contain required keys;
- Docker works without sudo;
- a disposable Ubuntu container sees the GPU;
- all repository ONNX files and copied assets are materialized.

- [ ] **Step 3: Implement container verification**

Container mode checks:

```bash
[ "${ROS_DISTRO:-}" = jazzy ]
nvidia-smi >/dev/null
ros2 pkg prefix isaac_ros_foundationpose
ros2 pkg prefix isaac_ros_yolov8
ros2 pkg prefix isaac_ros_realsense
ros2 pkg prefix isaac_ros_image_proc
ros2 pkg prefix isaac_ros_tensor_rt
```

Also require `${ISAAC_ROS_WS}/isaac_ros_assets/models` and the cup mesh.

- [ ] **Step 4: Run regression and syntax tests**

Run:

```bash
bash tests/test_jazzy_setup.sh
bash -n verify_jazzy_setup.sh
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add verify_jazzy_setup.sh tests/test_jazzy_setup.sh
git commit -m "feat: verify Jazzy perception environment"
```

### Task 5: Replace Active Humble Installation Documentation on Jazzy

**Files:**
- Modify: `bootstrap.sh`
- Modify: `README.md`
- Modify: `SETUP_GUIDE.md`
- Modify: `RUN.md`
- Modify: `docker/BUILD.md`
- Test: `tests/test_jazzy_setup.sh`

**Interfaces:**
- Consumes: the implemented setup and verification commands.
- Produces: branch-specific Jazzy instructions with no active Humble workflow.

- [ ] **Step 1: Add failing documentation assertions**

Require the active quick start to contain:

```text
./setup_jazzy.sh
isaac-ros activate --build-local
./verify_jazzy_setup.sh --host
```

Reject active references to `run_dev.sh`, `ros-humble-*`, and
`ISAAC_ROS_VERSION=3.2` from `README.md`, `SETUP_GUIDE.md`, `RUN.md`, and
`docker/BUILD.md`.

- [ ] **Step 2: Simplify `bootstrap.sh` for the Jazzy branch**

Keep Docker, NVIDIA Container Toolkit, Git LFS, and host settings installation.
Require Ubuntu 24.04 instead of selecting 3.2/4.5. Configure the official
release-4.5 Noble APT source idempotently, install `isaac-ros-cli`, and print:

```bash
sudo isaac-ros init docker
./setup_jazzy.sh
isaac-ros activate --build-local
```

- [ ] **Step 3: Rewrite the branch installation path**

Document these phases without camera dependency:

1. `./bootstrap.sh`
2. re-login for Docker group membership
3. `sudo isaac-ros init docker`
4. `./setup_jazzy.sh`
5. `./verify_jazzy_setup.sh --host`
6. `isaac-ros activate --build-local`
7. container verification
8. TensorRT engine generation
9. optional D435i connection and live run

Retain operational warnings that still apply: GPU-specific engines, 8 GB
tracking OOM, YOLO class-count patch, and camera firmware constraints.

- [ ] **Step 4: Run documentation and shell tests**

Run:

```bash
bash tests/test_jazzy_setup.sh
bash -n bootstrap.sh host_setup.sh setup_jazzy.sh setup_workspace.sh \
  verify_jazzy_setup.sh launch/*.sh
git diff --check
```

Expected: all tests and syntax checks PASS, with no whitespace errors.

- [ ] **Step 5: Commit**

```bash
git add bootstrap.sh README.md SETUP_GUIDE.md RUN.md docker/BUILD.md \
  tests/test_jazzy_setup.sh
git commit -m "docs: make Jazzy branch installation self-contained"
```

### Task 5b: Port Live Entrypoints to Jazzy

**Files:**
- Modify: `launch/run_cup_pose.sh`
- Modify: `launch/run_cup_pose_standalone.sh`
- Modify: `launch/run_cup_pose_tracking.sh`
- Modify: `launch/patch_yolo_numclasses.py`
- Modify: `tests/test_jazzy_setup.sh`
- Modify: `README.md`
- Modify: `SETUP_GUIDE.md`
- Modify: `RUN.md`

**Interfaces:**
- Consumes: the ROS 2 Jazzy installation under `/opt/ros/jazzy`.
- Produces: live entrypoints and YOLO patching that target only Jazzy on this branch.

- [ ] **Step 1: Add failing launch migration assertions**

Assert every active launch shell script sources `/opt/ros/jazzy/setup.bash`,
the patch targets `/opt/ros/jazzy/share/isaac_ros_yolov8`, and no file under
`launch/` contains `/opt/ros/humble`, `ros-humble-`, or `ros2_humble`.

- [ ] **Step 2: Observe RED**

Run:

```bash
bash tests/test_jazzy_setup.sh
```

Expected: FAIL only for the four remaining Humble paths.

- [ ] **Step 3: Port the entrypoints**

Replace the branch-specific ROS setup and patch paths with their Jazzy
equivalents. Do not add runtime Humble/Jazzy conditionals: `main` owns Humble,
and this branch owns Jazzy.

- [ ] **Step 4: Remove the temporary live-run documentation gate**

Replace the “migration pending” notices with the actual Jazzy live commands,
while keeping camera connection in the optional final phase.

- [ ] **Step 5: Verify GREEN**

Run:

```bash
bash tests/test_jazzy_setup.sh
bash -n launch/*.sh
python3 -m py_compile launch/*.py
git diff --check
```

Expected: all tests and static checks PASS.

- [ ] **Step 6: Commit**

```bash
git add launch tests/test_jazzy_setup.sh README.md SETUP_GUIDE.md RUN.md
git commit -m "feat: port perception launch entrypoints to Jazzy"
```

### Task 6: Run Real Host and Container Integration Gates

**Files:**
- Modify only if a test exposes a defect in the files above.
- Test: `verify_jazzy_setup.sh`

**Interfaces:**
- Consumes: Ubuntu 24.04 host with working Docker GPU runtime and initialized Isaac ROS CLI.
- Produces: a locally built reusable Jazzy perception image and validated mounted assets.

- [ ] **Step 1: Run host setup and verification**

Run on the host:

```bash
cd ~/rl_ws/perception
./setup_jazzy.sh
./verify_jazzy_setup.sh --host
```

Expected: configuration and asset checks PASS without a connected camera.

- [ ] **Step 2: Build and activate the image**

Run:

```bash
isaac-ros activate --build-local
```

Expected: image layers build in order `isaac_ros`, `realsense`, `perception`,
then an admin shell opens in `/workspaces/isaac_ros-dev`.

- [ ] **Step 3: Verify inside the container**

Run:

```bash
/workspaces/isaac_ros-dev/isaac_ros_assets/verify_jazzy_setup.sh --container
```

Expected: Jazzy, GPU, required ROS package, model, and mesh checks all PASS.

- [ ] **Step 4: Generate GPU-specific TensorRT engines**

Run:

```bash
/workspaces/isaac_ros-dev/isaac_ros_assets/launch/build_engines.sh
```

Expected: YOLO and FoundationPose `.plan` files are created under
`/workspaces/isaac_ros-dev/isaac_ros_assets/models`.

- [ ] **Step 5: Run the complete local verification suite**

Exit the container and run:

```bash
bash tests/test_jazzy_setup.sh
bash -n bootstrap.sh host_setup.sh setup_jazzy.sh setup_workspace.sh \
  verify_jazzy_setup.sh launch/*.sh
git diff --check
git status --short
```

Expected: tests and syntax checks PASS; status contains only intentional Jazzy
branch changes.
