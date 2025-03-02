FROM debian:bookworm AS build-dependencies

# install build dependencies and clean apt cache
RUN <<-EOF
    apt-get update
    apt-get install -y build-essential cmake libbz2-dev libcairo2-dev libglu1-mesa-dev \
        libgl1-mesa-dev libglew-dev libx11-dev libwxgtk3.2-dev \
        mesa-common-dev pkg-config python3-dev python3-wxgtk4.0 \
        libboost-all-dev libglm-dev libcurl4-openssl-dev \
        libgtk-3-dev \
        libngspice0-dev \
        ngspice-dev \
        libocct-modeling-algorithms-dev \
        libocct-modeling-data-dev \
        libocct-data-exchange-dev \
        libocct-visualization-dev \
        libocct-foundation-dev \
        libocct-ocaf-dev \
        unixodbc-dev \
        zlib1g-dev \
        shared-mime-info \
        git \
        gettext \
        ninja-build \
        libgit2-dev \
        libsecret-1-dev \
        libnng-dev \
        libprotobuf-dev \
        protobuf-compiler \
        swig4.0 \
        python3-pip \
        python3-venv \
        protobuf-compiler \
        libzstd-dev
    apt-get clean autoclean
    apt-get autoremove -y
    rm -rf /var/lib/apt/lists/*
EOF

COPY --chmod=755 <<-'EOF' /build-library.sh
    #!/bin/bash
    set -ex
    mkdir -p /tmp/build/linux
    cd /tmp/build/linux
    cmake \
      -G Ninja \
      -DCMAKE_RULE_MESSAGES=OFF \
      -DCMAKE_VERBOSE_MAKEFILE=OFF \
      -DCMAKE_INSTALL_PREFIX=/usr \
      /src
    ninja
    cmake --install . --prefix=/usr/installtemp/
EOF

FROM build-dependencies AS build-symbols
RUN --mount=from=symbols-src,target=/src /build-library.sh
FROM scratch AS symbols
COPY --from=build-symbols /usr/installtemp /usr/installtemp

FROM build-dependencies AS build-footprints
RUN --mount=from=footprints-src,target=/src /build-library.sh
FROM scratch AS footprints
COPY --from=build-footprints /usr/installtemp /usr/installtemp

FROM build-dependencies AS build-templates
RUN --mount=from=templates-src,target=/src /build-library.sh
FROM scratch AS templates
COPY --from=build-templates /usr/installtemp /usr/installtemp

FROM build-dependencies AS build-packages3d
RUN --mount=from=packages3d-src,target=/src /build-library.sh
FROM scratch AS packages3d
COPY --from=build-packages3d /usr/installtemp /usr/installtemp

FROM build-dependencies AS build-kicad
COPY --from=kicad-src . /src
# We want the built install prefix in /usr to match normal system installed software
# However to aid in docker copying only our files, we redirect the prefix in the cmake install
# config
RUN <<-EOF
    set -ex
    mkdir -p /src/build/linux
    cd /src/build/linux
    cmake \
      -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DKICAD_SCRIPTING_WXPYTHON=ON \
      -DKICAD_USE_OCC=ON \
      -DKICAD_SPICE=ON \
      -DKICAD_BUILD_I18N=ON \
      -DCMAKE_INSTALL_PREFIX=/usr \
      -DKICAD_USE_CMAKE_FINDPROTOBUF=ON \
      ../..
EOF

WORKDIR /src/build/linux
# build
RUN ninja
# install
RUN cmake --install . --prefix=/usr/installtemp/

# Now test the build, shipping a broken image doesn't help us
# Maybe we should only run the cli tests but all of them is fine for now
WORKDIR /src
RUN <<-EOF
    set -ex
    pip3 install -r ./qa/tests/requirements.txt --break-system-packages
    cd build/linux
    ctest --output-on-failure
EOF

FROM scratch AS kicad
COPY --from=build-kicad /usr/installtemp /usr/installtemp
COPY --from=build-kicad /usr/share/kicad /usr/share/kicad

# Everything except 3D models
FROM scratch AS install
COPY --from=symbols /usr/installtemp/share /usr/share
COPY --from=footprints /usr/installtemp/share /usr/share
COPY --from=templates /usr/installtemp/share /usr/share
COPY --from=kicad /usr/installtemp/bin /usr/bin
COPY --from=kicad /usr/installtemp/share /usr/share
COPY --from=kicad /usr/installtemp/lib /usr/lib
COPY --from=kicad /usr/share/kicad /usr/share/kicad

FROM debian:bookworm-slim AS runtime
ARG USER_NAME=kicad
ARG USER_UID=1000
ARG USER_GID=$USER_UID

LABEL org.opencontainers.image.authors='https://groups.google.com/a/kicad.org/g/devlist' \
      org.opencontainers.image.url='https://kicad.org' \
      org.opencontainers.image.documentation='https://docs.kicad.org/' \
      org.opencontainers.image.source='https://gitlab.com/kicad/kicad-ci/kicad-cli-docker' \
      org.opencontainers.image.vendor='KiCad' \
      org.opencontainers.image.licenses='GPL-3.0-or-later' \
      org.opencontainers.image.description='Image containing KiCad EDA, python and the stock symbol and footprint libraries for use in automation workflows'

# install runtime dependencies 
RUN <<-EOF
    apt-get update
    apt-get install -y libbz2-1.0 \
        libcairo2 \
        libglu1-mesa \
        libglew2.2 \
        libx11-6 \
        libwxgtk3.2* \
        libpython3.11 \
        python3 \
        python3-wxgtk4.0 \
        python3-yaml \
        python3-typing-extensions \
        libcurl4 \
        libngspice0 \
        ngspice \
        libocct-modeling-algorithms-7.6 \
        libocct-modeling-data-7.6 \
        libocct-data-exchange-7.6 \
        libocct-visualization-7.6 \
        libocct-foundation-7.6 \
        libocct-ocaf-7.6 \
        unixodbc \
        zlib1g \
        shared-mime-info \
        git \
        libgit2-1.5 \
        libsecret-1-0 \
        libprotobuf32 \
        libzstd1 \
        libnng1 \
        sudo
    apt-get clean autoclean
    apt-get autoremove -y
    rm -rf /var/lib/apt/lists/*
EOF

# Setup user
RUN groupadd --gid $USER_GID $USER_NAME \
    && useradd --uid $USER_UID --gid $USER_GID -m $USER_NAME \
    && usermod -aG sudo $USER_NAME \
    && echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

COPY --from=install / /

# fix the linkage to libkicad_3dsg
RUN ldconfig -l /usr/bin/_pcbnew.kiface

# Copy over the lib tables to the user config directory
RUN mkdir -p /home/$USER_NAME/.config/kicad/$(kicad-cli -v | cut -d . -f 1,2)

RUN cp /usr/share/kicad/template/*-lib-table /home/$USER_NAME/.config/kicad/$(kicad-cli -v | cut -d . -f 1,2)

RUN chown -R $USER_NAME:$USER_NAME /home/$USER_NAME/.config
RUN chown -R $USER_NAME:$USER_NAME /tmp/org.kicad.kicad || true

USER $USER_NAME

FROM runtime AS runtime-full
COPY --from=packages3d /usr/installtemp/share /usr/share

FROM python:3.12-bookworm AS appimage-builder
RUN <<-EOF
    apt-get update
    apt-get install -y breeze-icon-theme \
        desktop-file-utils \
        elfutils \
        fakeroot \
        file \
        git \
        gnupg2 \
        gtk-update-icon-cache \
        libgdk-pixbuf2.0-dev \
        libglib2.0-bin \
        librsvg2-dev \
        libyaml-dev \
        strace \
        wget \
        squashfs-tools \
        zsync \
        patchelf
    apt-get clean autoclean
    apt-get autoremove -y
    rm -rf /var/lib/apt/lists/*
EOF
COPY --from=appimage-builder-src . /tmp/appimage-builder
RUN <<-EOF
    python3 -m pip install --break-system-packages /tmp/appimage-builder
    rm -rf /tmp/appimage-builder
EOF

# Debug target: do not pack and compress, onle prepare AppImage contents
FROM appimage-builder AS build-appdir
COPY --from=install / /tmp/AppDir/
WORKDIR /tmp
COPY ./AppImageBuilder.yml /tmp/AppImageBuilder.yml
RUN appimage-builder --skip-appimage

FROM scratch AS appdir
COPY --from=build-appdir /tmp/AppDir /

FROM appimage-builder AS build-appimage
COPY --from=install / /tmp/AppDir/
WORKDIR /tmp
COPY ./AppImageBuilder.yml /tmp/AppImageBuilder.yml
RUN appimage-builder

FROM scratch AS appimage
COPY --from=build-appimage /tmp/KiCad-nightly-x86_64.AppImage /KiCad-nightly-x86_64.AppImage

FROM appimage-builder AS build-appimage-full
COPY --from=install / /tmp/AppDir/
COPY --from=packages3d /usr/installtemp/share /tmp/AppDir/usr/share
WORKDIR /tmp
COPY ./AppImageBuilder.yml /tmp/AppImageBuilder.yml
RUN appimage-builder

FROM scratch AS appimage-full
COPY --from=build-appimage-full /tmp/KiCad-nightly-x86_64.AppImage /KiCad-full-nightly-x86_64.AppImage
