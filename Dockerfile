ARG KICAD_BUILD_DEBUG=false
ARG KICAD_BUILD_MAJVERSION=9
ARG KICAD_BUILD_RELEASE=nightly
ARG KICAD_CMAKE_OPTIONS="-DKICAD_SCRIPTING_WXPYTHON=ON \
                         -DKICAD_BUILD_I18N=ON \
                         -DCMAKE_INSTALL_PREFIX=/usr \
                         -DKICAD_USE_CMAKE_FINDPROTOBUF=ON \
                         -DOCC_LIBRARY_DIR=/usr/lib/x86_64"

FROM debian:bookworm AS build-dependencies

# install build dependencies and clean apt cache
RUN <<-EOF
    apt-get update
    apt-get install -y build-essential \
        bison cmake autoconf automake flex \
        libbz2-dev libcairo2-dev libglu1-mesa-dev \
        libgl1-mesa-dev libglew-dev libx11-dev \
        mesa-common-dev pkg-config python3-dev \
        libboost-all-dev libglm-dev libcurl4-gnutls-dev \
        libtbb-dev \
        libgtk-3-dev \
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
        libzstd-dev \
        python-is-python3 \
        libfreeimage-dev \
        libfreetype-dev \
        libtbb-dev \
        libxext-dev \
        libxi-dev \
        libxmu-dev \
        rapidjson-dev \
        tcl-dev \
        tk-dev
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

FROM build-dependencies AS build-ngspice
COPY --from=ngspice-src . /tmp/ngspice
WORKDIR /tmp/ngspice
RUN <<-EOF
    ./autogen.sh
    ./configure --prefix=/usr --with-ngshared --enable-xspice --enable-cider \
    --disable-debug --disable-openmp
EOF
RUN make install -j $(nproc) DESTDIR=/tmp/rootfs
FROM scratch AS ngspice
COPY --from=build-ngspice /tmp/rootfs /

FROM build-dependencies AS build-occt
COPY --from=occt-src . /tmp/occt
WORKDIR /tmp/occt
RUN <<-EOF
    mkdir build
    cd build
    cmake -G Ninja -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release \
    -DFREETYPE_INCLUDE_DIR=/usr/include/freetype2 \
    -DINSTALL_CMAKE_DATA_DIR:PATH=lib/x86_64/opencascade \
	-DINSTALL_DIR_LIB:PATH=lib/x86_64 \
	-DINSTALL_DIR_CMAKE:PATH=lib/x86_64/cmake/opencascade \
	-DUSE_RAPIDJSON:BOOL=ON \
	-DUSE_TBB:BOOL=ON \
    -D3RDPARTY_TBB_LIBRARY_DIR:PATH=/usr/lib/x86_64-linux-gnu \
    -D3RDPARTY_TBBMALLOC_LIBRARY_DIR:PATH=/usr/lib/x86_64-linux-gnu \
	-DUSE_VTK:BOOL=OFF \
    -DUSE_TK:BOOL=OFF \
	-DUSE_FREEIMAGE:BOOL=ON \
	-DBUILD_RELEASE_DISABLE_EXCEPTIONS:BOOL=ON \
    -DBUILD_MODULE_Draw:BOOL=OFF \
    -DBUILD_MODULE_Visualization:BOOL=OFF \
	-DCMAKE_BUILD_TYPE=Release \
    .. \
EOF
RUN ninja -C build
RUN DESTDIR=/tmp/rootfs cmake --install build
FROM scratch AS occt
COPY --from=build-occt /tmp/rootfs /

FROM build-dependencies AS build-wx
ADD https://github.com/wxWidgets/wxWidgets/releases/download/v3.2.6/wxWidgets-3.2.6.tar.bz2 /tmp/wxWidgets.tar.bz2
WORKDIR /tmp
RUN <<-EOF
    mkdir wxWidgets
    tar xjf wxWidgets.tar.bz2 -C wxWidgets --strip-components=1
    cd wxWidgets
    cmake -G Ninja -B builddir -DCMAKE_INSTALL_PREFIX=/usr \
          -DwxBUILD_TOOLKIT=gtk3 -DwxUSE_OPENGL=ON \
          -DwxUSE_GLCANVAS_EGL=OFF
EOF
WORKDIR /tmp/wxWidgets
RUN ninja -C builddir
RUN DESTDIR=/tmp/rootfs cmake --install builddir
FROM scratch AS wx
COPY --from=build-wx /tmp/rootfs /

FROM build-dependencies AS build-wxpython
COPY --from=wx / /
ADD https://github.com/wxWidgets/Phoenix/releases/download/wxPython-4.2.2/wxPython-4.2.2.tar.gz /tmp/wxPython.tar.gz
WORKDIR /tmp
RUN <<-EOF
    mkdir wxPython
    tar xzf wxPython.tar.gz -C wxPython --strip-components=1
EOF
WORKDIR /tmp/wxPython
RUN python build.py build --use_syswx --prefix=/usr
RUN python build.py install --destdir=/tmp/rootfs
FROM scratch AS wxpython
COPY --from=build-wxpython /tmp/rootfs/usr/local /usr

FROM build-dependencies AS build-symbols
COPY --from=symbols-src . /src
RUN /build-library.sh
FROM scratch AS symbols
COPY --from=build-symbols /usr/installtemp /usr/installtemp

FROM build-dependencies AS build-footprints
COPY --from=footprints-src . /src
RUN /build-library.sh
FROM scratch AS footprints
COPY --from=build-footprints /usr/installtemp /usr/installtemp

FROM build-dependencies AS build-templates
COPY --from=templates-src . src
RUN /build-library.sh
FROM scratch AS templates
COPY --from=build-templates /usr/installtemp /usr/installtemp

FROM build-dependencies AS build-packages3d
COPY --from=packages3d-src . /src
RUN /build-library.sh
FROM scratch AS packages3d
COPY --from=build-packages3d /usr/installtemp /usr/installtemp

FROM build-dependencies AS build-kicad
COPY --from=wx / /
COPY --from=wxpython / /
COPY --from=ngspice / /
COPY --from=occt / /
COPY --from=kicad-src . /src
ARG KICAD_CMAKE_OPTIONS
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
      ${KICAD_CMAKE_OPTIONS} \
      ../..
EOF

WORKDIR /src/build/linux
# build
RUN ninja
# install
RUN cmake --install . --prefix=/usr/installtemp/

FROM scratch AS kicad
COPY --from=build-kicad /usr/installtemp /usr/installtemp
COPY --from=build-kicad /usr/share/kicad /usr/share/kicad

FROM scratch AS install
COPY --from=wx / /
COPY --from=wxpython / /
COPY --from=ngspice /usr /usr
COPY --from=occt /usr /usr
COPY --from=symbols /usr/installtemp/share /usr/share
COPY --from=footprints /usr/installtemp/share /usr/share
COPY --from=templates /usr/installtemp/share /usr/share
COPY --from=packages3d /usr/installtemp/share /usr/share
COPY --from=kicad /usr/installtemp/bin /usr/bin
COPY --from=kicad /usr/installtemp/share /usr/share
COPY --from=kicad /usr/installtemp/lib /usr/lib
COPY --from=kicad /usr/share/kicad /usr/share/kicad

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
ADD --chmod=755 https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage /tmp/appimagetool-x86_64.AppImage

FROM appimage-builder AS build-appdir
COPY --from=install / /tmp/AppDir/
COPY ./kicad.sh /tmp/AppDir/usr/bin/
WORKDIR /tmp
COPY ./AppImageBuilder.yml /tmp/AppImageBuilder.yml
ARG KICAD_BUILD_DEBUG
ARG KICAD_BUILD_MAJVERSION
ARG KICAD_BUILD_RELEASE
RUN KICAD_BUILD_DEBUG=${KICAD_BUILD_DEBUG} KICAD_BUILD_MAJVERSION=${KICAD_BUILD_MAJVERSION} KICAD_BUILD_RELEASE=${KICAD_BUILD_RELEASE} appimage-builder --skip-appimage

FROM scratch AS appdir
COPY --from=build-appdir /tmp/AppDir /AppDir

FROM appimage-builder AS build-appimage
COPY --from=appdir /AppDir /tmp/AppDir
RUN /tmp/appimagetool-x86_64.AppImage --appimage-extract-and-run -l -g -v --comp zstd /tmp/AppDir /tmp/KiCad-x86_64.AppImage

FROM scratch AS appimage
ARG KICAD_BUILD_RELEASE
COPY --from=build-appimage /tmp/KiCad-x86_64.AppImage /KiCad-${KICAD_BUILD_RELEASE}-x86_64.AppImage
