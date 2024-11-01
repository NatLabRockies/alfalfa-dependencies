ARG PYTHON_VERSION=3.12.2
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
  && make CFLAGS="-O2 -fPIC -fopenmp" BLASLIB="-lblas" PLAT="_OPENMP" MPLIB="-fopenmp" lib -j$(nproc) \
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
  && make -j$(nproc) \
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
  && make -j$(nproc) \
  && make install

RUN git clone --depth 1 -b PyFMI-2.14.0 https://github.com/modelon-community/PyFMI.git \
  && cd PyFMI \
  && python3 setup.py build --fmil-home=/build/fmi-libary/fmi_library --with-openmp -j $(nproc)\
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

FROM python:${PYTHON_VERSION}-slim-${DEBIAN_VERSION} AS energyplus-dependencies
ARG OPENSTUDIO_VERSION=3.9.0-rc1
ARG OPENSTUDIO_VERSION_SHA=fb69e5479c
ARG ENERGYPLUS_VERSION=24.2.0
ARG ENERGYPLUS_VERSION_SHA=94a887817b

RUN apt-get update \
  && apt-get install -y \
  curl \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /artifacts

RUN export gnuArch=x86_64; if [ "$(uname -m)" = "aarch64" ]; then gnuArch=arm64; fi; export gnuArch \
  && curl -SfL https://github.com/NREL/EnergyPlus/releases/download/v${ENERGYPLUS_VERSION}a/EnergyPlus-${ENERGYPLUS_VERSION}-${ENERGYPLUS_VERSION_SHA}-Linux-Ubuntu22.04-${gnuArch}.tar.gz -o energyplus.tar.gz \
  && curl -SfL https://github.com/NREL/OpenStudio/releases/download/v${OPENSTUDIO_VERSION}/OpenStudio-${OPENSTUDIO_VERSION}+${OPENSTUDIO_VERSION_SHA}-Ubuntu-22.04-${gnuArch}.deb -o openstudio.deb \
  && curl -SfL https://openstudio-resources.s3.amazonaws.com/bcvtb-linux.tar.gz -o bcvtb.tar.gz

FROM python:${PYTHON_VERSION}-slim-${DEBIAN_VERSION} AS alfalfa-dependencies

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
    libpython3.12.so.1.0 \
  ; \
  ln -s $ENERGYPLUS_DIR/energyplus /usr/local/bin/; \
  ln -s $ENERGYPLUS_DIR/ExpandObjects /usr/local/bin/; \
  ln -s $ENERGYPLUS_DIR/runenergyplus /usr/local/bin/; \
  ln -s /usr/local/lib/python3.12 ${ENERGYPLUS_DIR}/python_standard_lib; \
  ln -s /usr/local/lib/libpython3.12.so.1.0 ${ENERGYPLUS_DIR}/libpython3.12.so.1.0

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

WORKDIR $HOME

# Only the xml lib component of bcvtb is actaully required for communication, so we just extract that to save space
RUN --mount=type=bind,from=energyplus-dependencies,source=/artifacts,target=/artifacts tar -xzf /artifacts/bcvtb.tar.gz bcvtb/lib/xml
