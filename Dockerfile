ARG PYTHON_VERSION=3.12.2
ARG DEBIAN_VERSION=bookworm

# Build modelica-dependencies on bullseye (this uses an older version of GLibc which allows for making manylinux wheels)
FROM python:${PYTHON_VERSION}-slim-bullseye AS modelica-dependencies
ARG SUNDIALS_VERSION=v7.1.1
ARG ASSIMULO_VERSION=3.5.2

# Bandaid to deal with segfaults when installing libc-bin
RUN rm /var/lib/dpkg/info/libc-bin.* \
  && apt-get clean

RUN apt-get update \
  && apt-get install -y \
  cmake \
  curl \
  git \
  build-essential \
  dpkg-dev \
  && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install \
  'Cython<3.1' \
  numpy \
  scipy \
  matplotlib \
  setuptools==69.1.0 \
  auditwheel \
  patchelf

WORKDIR /build

RUN gnuArch="$(dpkg-architecture --query DEB_HOST_MULTIARCH)" \
  && git clone --depth 1 -b Assimulo-3.5.2 https://github.com/modelon-community/Assimulo.git \
  && cd Assimulo \
  && python3 setup.py bdist_wheel \
  && auditwheel repair --plat manylinux_2_31_$(uname -m) build/dist/*.whl \
  && pip3 install wheelhouse/*.whl

RUN git clone --depth 1 -b 2.4.1 https://github.com/modelon-community/fmi-library.git \
  && cd fmi-library \
  && sed -i "/CMAKE_INSTALL_PREFIX/d" CMakeLists.txt \
  && mkdir fmi_build && cd fmi_build \
  && mkdir fmi_library \
  && cmake -DCMAKE_INSTALL_PREFIX=/build/fmi-libary/fmi_library .. \
  && make -j$(nproc) \
  && make install

RUN git clone --depth 1 -b PyFMI-2.14.0 https://github.com/modelon-community/PyFMI.git \
  && cd PyFMI \
  # Build is done in 2 steps to allow for a multi-threaded build. bdist_wheel does not support -j
  && python3 setup.py build --fmil-home=/build/fmi-libary/fmi_library -j $(nproc)\
  && python3 setup.py bdist_wheel --fmil-home=/build/fmi-libary/fmi_library\
  && auditwheel repair --plat manylinux_2_31_$(uname -m) dist/*.whl

WORKDIR /artifacts

RUN cp /build/Assimulo/wheelhouse/* . \
  && cp /build/PyFMI/wheelhouse/* .

RUN gnuArch="$(dpkg-architecture --query DEB_HOST_ARCH_CPU)"\
  && curl -SfL http://ftp.us.debian.org/debian/pool/main/g/gcc-7/libgfortran4_7.4.0-6_${gnuArch}.deb -o libgfortran4.deb \
  && curl -SfL http://ftp.us.debian.org/debian/pool/main/g/gcc-7/gcc-7-base_7.4.0-6_${gnuArch}.deb -o gcc-7.deb \
  && curl -SfL https://archive.debian.org/debian/pool/main/g/gcc-6/gcc-6-base_6.3.0-18+deb9u1_${gnuArch}.deb -o gcc-6.deb \
  && curl -SfL https://archive.debian.org/debian/pool/main/g/gcc-6/libgfortran3_6.3.0-18+deb9u1_${gnuArch}.deb -o libgfortran3.deb

# Many Modelica-exported FMUs (e.g. from Dymola/OpenModelica) with a
# built-in CVode-based solver dynamically link against SUNDIALS 5.x at
# runtime (libsundials_cvode.so.5, libsundials_nvecserial.so.5). This is a
# much older ABI/SONAME than the SUNDIALS ${SUNDIALS_VERSION} this image
# builds above for its own Assimulo/PyFMI use, and Debian bookworm/bullseye
# only package SUNDIALS 4.x/6.x, so those FMUs fail to load with a
# misleading "cannot open shared object file" error even though the .so is
# present in the FMU. Compile just the SUNDIALS v5.8.0 runtime libraries
# here (built on bullseye for broad glibc compatibility) so they can be
# installed into the final image below, without touching the newer
# SUNDIALS build used by Assimulo/PyFMI.
FROM python:${PYTHON_VERSION}-slim-bullseye AS sundials-legacy-compat
ARG SUNDIALS_LEGACY_VERSION=v5.8.0
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
  cmake \
  build-essential \
  git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN gnuArch="$(dpkg-architecture --query DEB_HOST_MULTIARCH)" \
  && git clone --depth 1 -b ${SUNDIALS_LEGACY_VERSION} https://github.com/LLNL/sundials.git \
  && cd sundials \
  && mkdir build && cd build \
  && cmake -DCMAKE_INSTALL_PREFIX=/artifacts -DCMAKE_INSTALL_LIBDIR=lib/${gnuArch} -DEXAMPLES_ENABLE_C=OFF .. \
  && make -j4 \
  && make install

FROM python:${PYTHON_VERSION}-slim-${DEBIAN_VERSION} AS energyplus-dependencies
ARG OPENSTUDIO_VERSION=3.9.0
ARG OPENSTUDIO_VERSION_SHA=c77fbb9569
ARG ENERGYPLUS_VERSION=24.2.0
ARG ENERGYPLUS_VERSION_SHA=94a887817b

RUN apt-get update \
  && apt-get install -y \
  curl \
  binutils \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /artifacts

RUN set -eux; \
  export gnuArch=x86_64; if [ "$(uname -m)" = "aarch64" ]; then gnuArch=arm64; fi; export gnuArch; \
  curl -SfL https://github.com/NREL/EnergyPlus/releases/download/v${ENERGYPLUS_VERSION}a/EnergyPlus-${ENERGYPLUS_VERSION}-${ENERGYPLUS_VERSION_SHA}-Linux-Ubuntu22.04-${gnuArch}.tar.gz -o energyplus.tar.gz; \
  curl -SfL https://github.com/NREL/OpenStudio/releases/download/v${OPENSTUDIO_VERSION}/OpenStudio-${OPENSTUDIO_VERSION}+${OPENSTUDIO_VERSION_SHA}-Ubuntu-22.04-${gnuArch}.deb -o openstudio.deb

FROM python:${PYTHON_VERSION}-slim-${DEBIAN_VERSION} AS alfalfa-dependencies

ENV ENERGYPLUS_DIR=/usr/local/EnergyPlus
ENV HOME=/alfalfa

WORKDIR /artifacts

# Install EnergyPlus
RUN --mount=type=bind,from=energyplus-dependencies,source=/artifacts,target=/artifacts set -eux; \
  mkdir -p ${ENERGYPLUS_DIR}; \
  tar -C $ENERGYPLUS_DIR/ --strip-components=1 -xzf energyplus.tar.gz; \
  cd ${ENERGYPLUS_DIR}; \
  cp -n -r ${ENERGYPLUS_DIR}/python_lib/* /usr/local/lib/python3.12; \
  rm -rf \
    ExampleFiles \
    DataSets \
    Documentation \
    MacroDataSets \
    python_lib \
    WeatherData \
    libpython3.12.so.1.0 \
  ; \
  ln -s $ENERGYPLUS_DIR/energyplus /usr/local/bin/; \
  ln -s $ENERGYPLUS_DIR/ExpandObjects /usr/local/bin/; \
  ln -s $ENERGYPLUS_DIR/runenergyplus /usr/local/bin/; \
  ln -s /usr/local/lib/python3.12 ${ENERGYPLUS_DIR}/python_lib; \
  ln -s /usr/local/lib/libpython3.12.so.1.0 ${ENERGYPLUS_DIR}/libpython3.12.so.1.0

# Install OpenStudio
RUN --mount=type=bind,from=energyplus-dependencies,source=/artifacts,target=/artifacts set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    gdebi-core \
  ; \
  gdebi -o "APT::Install-Recommends=0" -n openstudio.deb; \
  cd /usr/local/openstudio*; \
  rm -rf \
    EnergyPlus \
    Examples \
    *Release_Notes*.pdf \
  ; \
  ln -s ${ENERGYPLUS_DIR} EnergyPlus; \
  apt-get purge -y \
    gdebi-core \
  ; \
  apt-get autoremove -y; \
  rm -rf /var/lib/apt/lists/*


# Install Assimulo, PyFMI and Old Fortran Libraries
RUN --mount=type=bind,from=modelica-dependencies,source=/artifacts,target=/artifacts set -eux; \
  python3.12 -m pip install 'numpy>=1.19.5' 'scipy>=1.10.1' 'matplotlib>3'; \
  python3.12 -m pip install --no-deps Assimulo*.whl PyFMI*.whl; \
  pip3 cache purge; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    gdebi-core \
    libgfortran5 \
  ; \
  gdebi -n gcc-6.deb; \
  gdebi -n libgfortran3.deb; \
  gdebi -n gcc-7.deb; \
  gdebi -n libgfortran4.deb; \
  apt-get purge -y \
    gdebi-core \
  ; \
  apt-get autoremove -y; \
  rm -rf /var/lib/apt/lists/*

# Install the legacy SUNDIALS 5.x runtime libraries built above (see the
# sundials-legacy-compat stage comment for why these are needed).
ARG TARGETARCH
RUN --mount=type=bind,from=sundials-legacy-compat,source=/artifacts,target=/sundials-legacy set -eux; \
  case "${TARGETARCH:-amd64}" in \
    amd64) gnuArch=x86_64-linux-gnu ;; \
    arm64) gnuArch=aarch64-linux-gnu ;; \
    *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
  esac; \
  cp -P /sundials-legacy/lib/${gnuArch}/libsundials_cvode.so.5* /usr/lib/${gnuArch}/; \
  cp -P /sundials-legacy/lib/${gnuArch}/libsundials_nvecserial.so.5* /usr/lib/${gnuArch}/; \
  ldconfig

ENV PYTHONPATH="${ENERGYPLUS_DIR}:/usr/local/openstudio-3.9.0/Python"
WORKDIR $HOME
