# Final Jazzy Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the final Jazzy integration review findings with tested failure semantics, durable CLI preconditions, accurate documentation, and atomic engine generation.

**Architecture:** Extend the existing shell regression contract before changing production files. Keep runtime entrypoints structurally unchanged outside their `verify` branches, validate host prerequisites before workspace writes, and centralize TensorRT atomic output behavior in the existing builder.

**Tech Stack:** Bash, Dockerfile, Markdown, stubbed shell integration tests.

## Global Constraints

- Ubuntu 24.04 x86_64, NVIDIA Ampere-or-newer GPU, driver 580 or newer.
- Isaac ROS CLI 4.5 initialized in Docker mode.
- ROS 2 Jazzy only; shipped active documentation must contain no Humble workflow.
- Do not commit; preserve unrelated working-tree changes.

---

### Task 1: Add the failing regression contract

**Files:**
- Modify: `tests/test_jazzy_setup.sh`

**Interfaces:**
- Consumes: current setup, verifier, live verify branches, builder, and documentation.
- Produces: RED coverage for every final-review finding.

- [ ] Add active-documentation scans that exclude only historical Superpowers plans/specs.
- [ ] Add isolated verify-branch tests proving all-fail is nonzero and valid output is zero.
- [ ] Add setup/host-verifier tests for `/etc/isaac-ros-cli/docker`, x86_64, and driver 580.
- [ ] Add builder tests for zero-byte rebuild and failed-build cleanup.
- [ ] Run `bash tests/test_jazzy_setup.sh` and record the expected failures.

### Task 2: Implement Jazzy docs and prerequisite validation

**Files:**
- Modify: `docs/EXTRINSICS_CALIBRATION.md`
- Modify: `docker/BUILD.md`
- Modify: `docker/Dockerfile.perception`
- Modify: `README.md`
- Modify: `SETUP_GUIDE.md`
- Modify: `setup_jazzy.sh`
- Modify: `verify_jazzy_setup.sh`

**Interfaces:**
- Consumes: CLI Docker directory, `uname -m`, and `nvidia-smi` driver output.
- Produces: pre-mutation setup rejection and durable host-verifier diagnostics.

- [ ] Port calibration commands to the CLI/Jazzy workflow and remove the obsolete live gate.
- [ ] Refresh Dockerfile comments and document exact platform requirements.
- [ ] Validate architecture, initialized Docker directory, and driver floor before workspace mutation.
- [ ] Run the focused setup/verifier tests until green.

### Task 3: Implement verify status and atomic engines

**Files:**
- Modify: `launch/run_cup_pose_standalone.sh`
- Modify: `launch/run_cup_pose_tracking.sh`
- Modify: `launch/build_engines.sh`

**Interfaces:**
- Consumes: topic probe pipelines and TensorRT `--saveEngine`.
- Produces: aggregate verify exit status and nonempty atomically published plan files.

- [ ] Aggregate verify failures without changing startup or stop paths.
- [ ] Build every missing/empty engine to a temporary sibling, require nonempty output, then rename atomically.
- [ ] Clean temporary engine files on success, failure, and signal.
- [ ] Run the full regression suite.

### Task 4: Verify and report

**Files:**
- Create: `.superpowers/sdd/final-fix-report.md`

**Interfaces:**
- Consumes: RED/GREEN logs and final validation output.
- Produces: exact handoff evidence and remaining machine-level concerns.

- [ ] Run all shell syntax checks.
- [ ] Byte-compile all Python files with cache redirected to `/tmp`.
- [ ] Run `git diff --check`.
- [ ] Record exact results and no-commit status.
