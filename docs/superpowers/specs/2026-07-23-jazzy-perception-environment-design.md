# Isaac ROS 4.5 Jazzy Perception Environment Design

## Goal

Make this repository reproducibly install the cup-pose perception environment
on an x86_64 Ubuntu 24.04 host with an NVIDIA Ampere-or-newer GPU. A new machine
must be able to clone the repository, initialize Isaac ROS CLI in Docker mode,
run one repository setup command, and build the same Jazzy-based development
image without manually modifying a running container.

Camera hardware is not required to build or validate the development image.
The D435i is required only for the final live-pipeline verification.

## Branch Strategy

The repository deliberately maintains separate environments by Git branch:

- `main` is the Ubuntu 22.04, ROS 2 Humble, Isaac ROS 3.2 branch.
- `jazzy` is the Ubuntu 24.04, ROS 2 Jazzy, Isaac ROS 4.5 branch.

This implementation modifies only the checked-out `jazzy` branch. It does not
add Jazzy conditionals to the Humble setup and does not modify `main`.
Branch-specific files such as `bootstrap.sh`, `Dockerfile.perception`, README,
and setup guides describe only their branch's environment. Models, CAD assets,
and portable Python nodes remain structurally aligned between branches where
their runtime APIs are compatible.

## Supported Platform

- Host OS: Ubuntu 24.04 Noble
- ROS distribution: ROS 2 Jazzy
- Isaac ROS: release 4.5
- Environment manager: Isaac ROS CLI in Docker mode
- GPU: NVIDIA Ampere or newer, with at least 8 GB VRAM
- NVIDIA driver: 580 or newer
- Workspace: `${ISAAC_ROS_WS}`, defaulting to
  `${HOME}/workspaces/isaac_ros-dev`

Within the `jazzy` branch, the old Isaac ROS 3.2/Humble runbook is historical
reference only. The Jazzy setup must not use `isaac_ros_common/run_dev.sh` or
any `ros-humble-*` binary package.

## Architecture

The official Isaac ROS CLI `isaac_ros` image is the base. The CLI adds its
official `realsense` layer and then the repository's `perception` layer. The
layer order is therefore:

```text
isaac_ros -> realsense -> perception
```

The repository owns only the final `Dockerfile.perception` layer. Isaac ROS CLI
owns the base and RealSense layers. This keeps CUDA, TensorRT, ROS, and
librealsense versions aligned with Isaac ROS 4.5 while preserving the
project-specific package set and CycloneDDS configuration.

## Repository Components

### `docker/Dockerfile.perception`

The Dockerfile consumes `ARG BASE_IMAGE`, installs the required
`ros-jazzy-isaac-ros-*` binary packages, copies `docker/cyclonedds.xml`, and
sets container-wide ROS environment variables.

It must install at least:

- Isaac ROS examples
- FoundationPose
- YOLOv8
- RealSense
- image processing and DNN image encoding
- TensorRT, tensor processing, Triton
- depth image processing and NITROS topic tools

Segment Anything and RT-DETR remain included because the repository retains
their models and launch assets, even though the default 8 GB live path uses the
bbox-depth mask instead of SAM.

### `setup_jazzy.sh`

This is the host-side entrypoint after `sudo isaac-ros init docker`. It:

1. Validates Ubuntu 24.04, `isaac-ros`, Docker access, and GPU passthrough.
2. Uses an existing `ISAAC_ROS_WS`, or defaults it to
   `${HOME}/workspaces/isaac_ros-dev`.
3. Creates the workspace directories.
4. Writes the Isaac ROS CLI Docker search configuration, including both this
   repository's `docker` directory and `/etc/isaac-ros-cli/docker`.
5. Writes workspace-scoped CLI YAML with additional image keys in this order:
   `realsense`, then `perception`.
6. Calls `setup_workspace.sh` with the resolved workspace to copy models, CAD,
   nodes, configuration, tools, and launch scripts.
7. Prints the exact build command without hiding the potentially long-running
   image build: `isaac-ros activate --build-local`.

The script is idempotent. Re-running it overwrites only generated CLI
configuration owned by this repository and refreshes derived workspace assets.

### `verify_jazzy_setup.sh`

The verification script has two modes:

- Host mode validates CLI configuration, Docker access, GPU passthrough,
  source model files, and copied workspace assets.
- Container mode validates `ROS_DISTRO=jazzy`, GPU visibility, and all required
  ROS package prefixes.

Neither mode requires a RealSense camera.

## Data and Asset Flow

The repository is the source of truth:

```text
perception/models, assets, nodes, config, launch, tools
                              |
                              v
          ${ISAAC_ROS_WS}/isaac_ros_assets
                              |
                              v
              TensorRT engine generation
```

ONNX and CAD assets are copied into the mounted workspace. TensorRT `.plan`
files are generated inside the built container because they depend on the GPU
and TensorRT version. They are never committed.

## Error Handling

The setup command stops with a clear message when:

- the host is not Ubuntu 24.04;
- `isaac-ros` is missing or not initialized in Docker mode;
- the current shell lacks Docker group access;
- Docker cannot expose the NVIDIA GPU;
- a Git LFS model is missing or still a pointer;
- the system Isaac ROS Dockerfile directory is absent.

Camera absence is never treated as an installation failure.

## Testing

Shell-level regression tests run in a temporary fake home/workspace and stub
external commands. They verify:

- default and explicit workspace resolution;
- generated Docker search configuration contains both required directories;
- generated YAML preserves image-key order;
- setup delegates asset copying with the resolved workspace;
- missing Docker access and missing model assets fail before mutation;
- the Dockerfile contains Jazzy packages and contains no Humble package names.

Static checks use `bash -n` for all shell scripts. Container validation is a
separate integration gate because it requires Docker, network access, and an
NVIDIA GPU.

## Installation and Verification Sequence

On a new machine:

```bash
git clone <repository-url>
cd perception
./bootstrap.sh
sudo isaac-ros init docker
./setup_jazzy.sh
isaac-ros activate --build-local
```

Inside the built environment:

```bash
verify_jazzy_setup.sh --container
launch/build_engines.sh
```

Only after these checks pass is the D435i connected for the live launch and
topic verification.
