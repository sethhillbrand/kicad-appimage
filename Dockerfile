# Main Dockerfile for building KiCad AppImage
ARG REGISTRY

# Import all dependency images
FROM ${REGISTRY}/base:latest AS base
FROM ${REGISTRY}/wx:latest AS wx
FROM ${REGISTRY}/wxpython:latest AS wxpython
FROM ${REGISTRY}/ngspice:latest AS ngspice
FROM ${REGISTRY}/occt:latest AS occt
FROM ${REGISTRY}/libs:latest AS libs
FROM ${REGISTRY}/packages3d:latest AS packages3d

# Main build stage
FROM base AS kicad-build

ARG KICAD_BUILD_RELEASE=nightly
ARG KICAD_BUILD_TYPE=RelWithDebInfo

# Copy all dependencies
COPY --from=wx / /
COPY --from=wxpython / /
COPY --from=ngspice / /
COPY --from=occt / /
COPY --from=libs / /

# Copy KiCad source and appimage-builder
COPY --from=kicad-src . /tmp/kicad
COPY --from=appimage-builder-src . /tmp/appimage-builder

WORKDIR /tmp/kicad

# Build KiCad
RUN <<'EOS'
    mkdir build
    cd build
    cmake -G Ninja \
        -DCMAKE_BUILD_TYPE=${KICAD_BUILD_TYPE} \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DDEFAULT_INSTALL_PATH=/usr \
        ..
    ninja -j$(nproc)
    DESTDIR=/tmp/AppDir ninja install
EOS

# AppImage base stage
FROM base AS appimage-base
ARG KICAD_BUILD_RELEASE
ARG KICAD_BUILD_MAJVERSION
ARG KICAD_BUILD_TYPE

# Install appimage-builder
COPY --from=appimage-builder-src . /tmp/appimage-builder
WORKDIR /tmp/appimage-builder
RUN python3 -m pip install --break-system-packages .

# Copy built KiCad
COPY --from=kicad-build /tmp/AppDir /tmp/AppDir

# Copy AppImage configuration
COPY AppImageBuilder.yml /tmp/

WORKDIR /tmp

# Set environment variables for AppImage build
ENV KICAD_BUILD_RELEASE=${KICAD_BUILD_RELEASE}
ENV KICAD_BUILD_MAJVERSION=${KICAD_BUILD_MAJVERSION}
ENV KICAD_BUILD_TYPE=${KICAD_BUILD_TYPE}

# Build standard AppImage (zstd)
FROM appimage-base AS appimage
COPY --from=packages3d / /

# Set KICAD_BUILD_DEBUG based on KICAD_BUILD_TYPE
ARG KICAD_BUILD_TYPE
RUN <<'EOS'
if [ "$KICAD_BUILD_TYPE" = "Debug" ]; then export KICAD_BUILD_DEBUG=1; else export KICAD_BUILD_DEBUG=0; fi && \
    mkdir -p AppDir/usr/bin && \
    cat > AppDir/usr/bin/kicad.sh << 'EOF'
#!/bin/bash
export LD_LIBRARY_PATH="${APPDIR}/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH}"
exec "${APPDIR}/usr/bin/kicad" "$@"
EOF
    chmod +x AppDir/usr/bin/kicad.sh
    export COMP_TYPE=zstd
    appimage-builder
EOS

FROM scratch AS build-kicad
COPY --from=appimage /tmp/*.AppImage /

# Build light AppImage (gzip)
FROM appimage-base AS appimage-light
ARG KICAD_BUILD_TYPE
RUN <<'EOS'
if [ "$KICAD_BUILD_TYPE" = "Debug" ]; then export KICAD_BUILD_DEBUG=1; else export KICAD_BUILD_DEBUG=0; fi && \
    mkdir -p AppDir/usr/bin && \
    cat > AppDir/usr/bin/kicad.sh << 'EOF'
#!/bin/bash
export LD_LIBRARY_PATH="${APPDIR}/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH}"
exec "${APPDIR}/usr/bin/kicad" "$@"
EOF
    chmod +x AppDir/usr/bin/kicad.sh
    export COMP_TYPE=gzip
    appimage-builder
EOS

FROM scratch AS build-kicad-light
COPY --from=appimage-light /tmp/*.AppImage /
