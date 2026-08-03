# alfalfa-worker-dependencies

This repo builds and publishes the base Docker image consumed by the `alfalfa_worker` service in [alfalfa](https://github.com/NatLabRockies/alfalfa) (`ghcr.io/natlabrockies/alfalfa-dependencies`). It exists to isolate the slow-to-compile, infrequently-changing native/scientific dependencies the worker needs from alfalfa's own faster-moving application code, so they're built once as a shared image instead of being recompiled on every `alfalfa_worker` build:

- **EnergyPlus** and **OpenStudio** — building energy simulation engine and SDK.
- **Assimulo** and **PyFMI** (built against SUNDIALS) — Modelica/FMU co-simulation support.
- **Legacy SUNDIALS 5.x runtime libraries** (`sundials-legacy-compat` stage) — OpenModelica's CVode-based FMU solver is bound to SUNDIALS 5.x (still true as of OM 1.27.0), so any FMU compiled with OpenModelica and CVode enabled needs `libsundials_cvode.so.5`/`libsundials_nvecserial.so.5` at runtime — a different, older ABI/SONAME than the SUNDIALS version built above for this image's own Assimulo/PyFMI use. We install both side by side.

## Relationship to alfalfa

This repo is an independent git repository from `alfalfa` (no submodule/subtree link) — the two are connected only through the image tag that `alfalfa_worker/Dockerfile`'s `FROM` line references. [`.github/workflows/build.yml`](.github/workflows/build.yml) builds and pushes a multi-arch (`linux/amd64`, `linux/arm64`) image on every push, tagged with the branch name (plus semver tags on release). During development, `alfalfa` may point at a work-in-progress branch tag from here to validate a fix before it's merged; once merged and released, `alfalfa_worker/Dockerfile` should be bumped to the corresponding release tag.

If a worker build/runtime issue looks like it belongs to EnergyPlus, OpenStudio, Assimulo/PyFMI, or SUNDIALS rather than alfalfa's own application code, it likely belongs here rather than in the `alfalfa` repo.
