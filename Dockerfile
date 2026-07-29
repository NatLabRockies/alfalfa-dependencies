ARG PYTHON_VERSION=3.10.14
ARG DEBIAN_VERSION=bookworm

# Build modelica-dependencies on bullseye (this uses an older version of GLibc which allows for making manylinux wheels)
FROM python:${PYTHON_VERSION}-slim-bullseye AS modelica-dependencies
ARG SUNDIALS_VERSION=v7.1.1
ARG ASSIMULO_VERSION=3.5.2
RUN apt-get update \
  && apt-get install -y \
  cmake \
  liblapack-dev \
  libsuitesparse-dev \
  libhypre-dev \
  curl \
  git \
  build-essential \
  dpkg-dev \
  && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install \
  Cython \
  numpy \
  scipy \
  matplotlib \
  setuptools==69.1.0 \
  auditwheel \
  patchelf

RUN gnuArch="$(dpkg-architecture --query DEB_HOST_MULTIARCH)"; \
ln -s /usr/lib/$gnuArch/libblas.so /usr/lib/$gnuArch/libblas_OPENMP.so

WORKDIR /build

RUN curl -fSsL https://portal.nersc.gov/project/sparse/superlu/superlu_mt_3.1.tar.gz | tar xz \
  && cd SuperLU_MT_3.1 \
  && make CFLAGS="-O2 -fPIC -fopenmp" BLASLIB="-lblas" PLAT="_OPENMP" MPLIB="-fopenmp" lib -j1 \
  && cp -v ./lib/libsuperlu_mt_OPENMP.a /usr/lib \
  && cp -v ./SRC/*.h /usr/include

RUN git clone --depth 1 -b ${SUNDIALS_VERSION} https://github.com/LLNL/sundials.git \
  && cd sundials \
  && mkdir build && cd build \
  && cmake \
  -LAH \
  -DSUPERLUMT_BLAS_LIBRARIES=blas \
  -DSUPERLUMT_LIBRARIES=blas \
  -DSUPERLUMT_INCLUDE_DIR=/usr/include \
  -DSUPERLUMT_LIBRARY=/usr/lib/libsuperlu_mt_OPENMP.a \
  -DSUPERLUMT_THREAD_TYPE=OpenMP \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DSUPERLUMT_ENABLE=ON \
  -DSUNDIALS_INDEX_SIZE=32 \
  -DLAPACK_ENABLE=ON \
  -DEXAMPLES_ENABLE=OFF \
  -DEXAMPLES_ENABLE_C=OFF \
  .. \
  && make -j4 \
  && make install

RUN gnuArch="$(dpkg-architecture --query DEB_HOST_MULTIARCH)" \
  && git clone --depth 1 -b Assimulo-3.5.2 https://github.com/modelon-community/Assimulo.git \
  && cd Assimulo \
  && python3 setup.py bdist_wheel --sundials-home=/usr --blas-home=/usr/lib/${gnuArch} --lapack-home=/usr/lib/${gnuArch} --superlu-home=/usr \
  && auditwheel repair --plat manylinux_2_31_$(uname -m) build/dist/*.whl \
  && pip3 install wheelhouse/*.whl

RUN git clone --depth 1 -b 2.4.1 https://github.com/modelon-community/fmi-library.git \
  && cd fmi-library \
  && sed -i "/CMAKE_INSTALL_PREFIX/d" CMakeLists.txt \
  && mkdir fmi_build && cd fmi_build \
  && mkdir fmi_library \
  && cmake -DCMAKE_INSTALL_PREFIX=/build/fmi-libary/fmi_library .. \
  && make -j4 \
  && make install

RUN git clone --depth 1 -b PyFMI-2.13.1 https://github.com/modelon-community/PyFMI.git \
  && cd PyFMI \
  && python3 setup.py bdist_wheel --fmil-home=/build/fmi-libary/fmi_library --with-openmp\
  && auditwheel repair --plat manylinux_2_31_$(uname -m) dist/*.whl

WORKDIR /artifacts

RUN cp /build/Assimulo/wheelhouse/* . \
  && cp /build/PyFMI/wheelhouse/* .

RUN gnuArch="$(dpkg-architecture --query DEB_HOST_ARCH_CPU)"\
  && curl -SfL http://ftp.us.debian.org/debian/pool/main/g/gcc-7/libgfortran4_7.4.0-6_${gnuArch}.deb -o libgfortran4.deb \
  && curl -SfL http://ftp.us.debian.org/debian/pool/main/g/gcc-7/gcc-7-base_7.4.0-6_${gnuArch}.deb -o gcc-7.deb \
  && curl -SfL https://archive.debian.org/debian/pool/main/g/gcc-6/gcc-6-base_6.3.0-18+deb9u1_${gnuArch}.deb -o gcc-6.deb \
  && curl -SfL https://archive.debian.org/debian/pool/main/g/gcc-6/libgfortran3_6.3.0-18+deb9u1_${gnuArch}.deb -o libgfortran3.deb

# Many Modelica-exported FMUs (e.g. from Dymola) with a built-in CVode-based
# solver dynamically link against SUNDIALS 5.x at runtime, which is a much
# older ABI/SONAME (.so.5) than the SUNDIALS ${SUNDIALS_VERSION} we build above
# for Assimulo/PyFMI's own use. Debian bookworm/bullseye only package SUNDIALS
# 4.x/6.x, so we build the legacy 5.x runtime libraries from source and ship
# them alongside, without touching the newer SUNDIALS install used elsewhere.
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
ARG OPENSTUDIO_VERSION=3.8.0
ARG OPENSTUDIO_VERSION_SHA=f953b6fcaf
ARG ENERGYPLUS_VERSION=24.1.0
ARG ENERGYPLUS_VERSION_SHA=9d7789a3ac

RUN apt-get update \
  && apt-get install -y \
  curl \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /artifacts

RUN export gnuArch=x86_64; if [ "$(uname -m)" = "aarch64" ]; then gnuArch=arm64; fi; export gnuArch \
  && echo https://github.com/NREL/EnergyPlus/releases/download/v${ENERGYPLUS_VERSION}/EnergyPlus-${ENERGYPLUS_VERSION}-${ENERGYPLUS_VERSION_SHA}-Linux-Ubuntu22.04-${gnuArch}.tar.gz \
  && curl -SfL https://github.com/NREL/EnergyPlus/releases/download/v${ENERGYPLUS_VERSION}/EnergyPlus-${ENERGYPLUS_VERSION}-${ENERGYPLUS_VERSION_SHA}-Linux-Ubuntu22.04-${gnuArch}.tar.gz -o energyplus.tar.gz \
  && curl -SfL https://github.com/NREL/OpenStudio/releases/download/v${OPENSTUDIO_VERSION}/OpenStudio-${OPENSTUDIO_VERSION}+${OPENSTUDIO_VERSION_SHA}-Ubuntu-22.04-${gnuArch}.deb -o openstudio.deb \
  && curl -SfL https://openstudio-resources.s3.amazonaws.com/bcvtb-linux.tar.gz -o bcvtb.tar.gz

FROM python:${PYTHON_VERSION}-slim-${DEBIAN_VERSION} AS dual-python

  ENV PYTHON_VERSION=3.8.19
  ENV GPG_KEY=E3FF2839C048B25C084DEBE9B26995E310250568

  RUN set -eux; \
      \
      savedAptMark="$(apt-mark showmanual)"; \
      apt-get update; \
      apt-get install -y --no-install-recommends \
          dpkg-dev \
          gcc \
          gnupg \
          libbluetooth-dev \
          libbz2-dev \
          libc6-dev \
          libdb-dev \
          libexpat1-dev \
          libffi-dev \
          libgdbm-dev \
          liblzma-dev \
          libncursesw5-dev \
          libreadline-dev \
          libsqlite3-dev \
          libssl-dev \
          make \
          tk-dev \
          uuid-dev \
          wget \
          xz-utils \
          zlib1g-dev \
      ; \
      \
      wget -O python.tar.xz "https://www.python.org/ftp/python/${PYTHON_VERSION%%[a-z]*}/Python-$PYTHON_VERSION.tar.xz"; \
      wget -O python.tar.xz.asc "https://www.python.org/ftp/python/${PYTHON_VERSION%%[a-z]*}/Python-$PYTHON_VERSION.tar.xz.asc"; \
      GNUPGHOME="$(mktemp -d)"; export GNUPGHOME; \
      gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "$GPG_KEY"; \
      gpg --batch --verify python.tar.xz.asc python.tar.xz; \
      gpgconf --kill all; \
      rm -rf "$GNUPGHOME" python.tar.xz.asc; \
      mkdir -p /usr/src/python; \
      tar --extract --directory /usr/src/python --strip-components=1 --file python.tar.xz; \
      rm python.tar.xz; \
      \
      cd /usr/src/python; \
      gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
      ./configure \
          --build="$gnuArch" \
          --enable-loadable-sqlite-extensions \
          --enable-optimizations \
          --enable-option-checking=fatal \
          --enable-shared \
          --with-system-expat \
          --without-ensurepip \
      ; \
      nproc="$(nproc)"; \
      EXTRA_CFLAGS="$(dpkg-buildflags --get CFLAGS)"; \
      LDFLAGS="$(dpkg-buildflags --get LDFLAGS)"; \
      LDFLAGS="${LDFLAGS:--Wl},--strip-all"; \
      make -j "$nproc" \
          "EXTRA_CFLAGS=${EXTRA_CFLAGS:-}" \
          "LDFLAGS=${LDFLAGS:-}" \
          "PROFILE_TASK=${PROFILE_TASK:-}" \
      ; \
  # https://github.com/docker-library/python/issues/784
  # prevent accidental usage of a system installed libpython of the same version
      rm python; \
      make -j "$nproc" \
          "EXTRA_CFLAGS=${EXTRA_CFLAGS:-}" \
          "LDFLAGS=${LDFLAGS:--Wl},-rpath='\$\$ORIGIN/../lib'" \
          "PROFILE_TASK=${PROFILE_TASK:-}" \
          python \
      ; \
      make altinstall; \
      \
      cd /; \
      rm -rf /usr/src/python; \
      \
      find /usr/local -depth \
          \( \
              \( -type d -a \( -name test -o -name tests -o -name idle_test \) \) \
              -o \( -type f -a \( -name '*.pyc' -o -name '*.pyo' -o -name 'libpython*.a' \) \) \
              -o \( -type f -a -name 'wininst-*.exe' \) \
          \) -exec rm -rf '{}' + \
      ; \
      \
      ldconfig; \
      \
      apt-mark auto '.*' > /dev/null; \
      apt-mark manual $savedAptMark; \
      find /usr/local -type f -executable -not \( -name '*tkinter*' \) -exec ldd '{}' ';' \
          | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); printf "*%s\n", so }' \
          | sort -u \
          | xargs -r dpkg-query --search \
          | cut -d: -f1 \
          | sort -u \
          | xargs -r apt-mark manual \
      ; \
      apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
      rm -rf /var/lib/apt/lists/*; \
      \
      python3.8 --version

  RUN python3.8 -m ensurepip --altinstall


FROM dual-python AS alfalfa-dependencies

ENV ENERGYPLUS_DIR=/usr/local/EnergyPlus
ENV HOME=/alfalfa

WORKDIR /artifacts

# Install EnergyPlus
RUN --mount=type=bind,from=energyplus-dependencies,source=/artifacts,target=/artifacts set -eux; \
  mkdir ${ENERGYPLUS_DIR}; \
  tar -C $ENERGYPLUS_DIR/ --strip-components=1 -xzf energyplus.tar.gz; \
  cd ${ENERGYPLUS_DIR}; \
  rm -rf \
    ExampleFiles \
    DataSets \
    Documentation \
    MacroDataSets \
    python_standard_lib \
    WeatherData \
    libpython3.8.so.1.0 \
  ; \
  ln -s $ENERGYPLUS_DIR/energyplus /usr/local/bin/; \
  ln -s $ENERGYPLUS_DIR/ExpandObjects /usr/local/bin/; \
  ln -s $ENERGYPLUS_DIR/runenergyplus /usr/local/bin/; \
  ln -s /usr/local/lib/python3.8 ${ENERGYPLUS_DIR}/python_standard_lib; \
  ln -s /usr/local/lib/libpython3.8.so.1.0 ${ENERGYPLUS_DIR}/libpython3.8.so.1.0

# Install OpenStudio
RUN --mount=type=bind,from=energyplus-dependencies,source=/artifacts,target=/artifacts set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    gdebi-core \
    openjdk-17-jre-headless \
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
  python3.10 -m pip install 'numpy>=1.19.5' 'scipy>=1.10.1' 'matplotlib>3'; \
  python3.10 -m pip install --no-deps Assimulo*.whl PyFMI*.whl; \
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

# Install legacy SUNDIALS 5.x runtime libraries (see sundials-legacy-compat
# above) needed by FMUs that dynamically link against them for their
# built-in CVode-based solver, independent of the SUNDIALS ${SUNDIALS_VERSION}
# built for Assimulo/PyFMI.
ARG TARGETARCH
RUN --mount=type=bind,from=sundials-legacy-compat,source=/artifacts,target=/sundials-legacy set -eux; \
  case "${TARGETARCH}" in \
    amd64) gnuArch=x86_64-linux-gnu ;; \
    arm64) gnuArch=aarch64-linux-gnu ;; \
    *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
  esac; \
  cp -P /sundials-legacy/lib/${gnuArch}/libsundials_cvode.so.5* /usr/lib/${gnuArch}/; \
  cp -P /sundials-legacy/lib/${gnuArch}/libsundials_nvecserial.so.5* /usr/lib/${gnuArch}/; \
  ldconfig

WORKDIR $HOME

# Only the xml lib component of bcvtb is actaully required for communication, so we just extract that to save space
RUN --mount=type=bind,from=energyplus-dependencies,source=/artifacts,target=/artifacts tar -xzf /artifacts/bcvtb.tar.gz bcvtb/lib/xml
