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
ARG KICAD_APPIMAGE_LIGHT=false

# Copy all dependencies
COPY --from=wx / /
COPY --from=wxpython / /
COPY --from=ngspice / /
COPY --from=occt / /
COPY --from=libs / /
COPY --from=packages3d / /

# Copy KiCad source and appimage-builder
COPY --from=kicad-src . /tmp/kicad
COPY --from=appimage-builder-src . /tmp/appimage-builder

WORKDIR /tmp/kicad

# Build KiCad
RUN <<'EOS'
    mkdir build
    cd build
    cmake -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DDEFAULT_INSTALL_PATH=/usr \
        ..
    ninja -j$(nproc)
    DESTDIR=/tmp/AppDir ninja install
EOS

# AppImage build stage
FROM base AS appimage
ARG KICAD_BUILD_RELEASE
ARG KICAD_APPIMAGE_LIGHT

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
ENV KICAD_BUILD_MAJVERSION=8
ENV KICAD_BUILD_DEBUG=false
ENV KICAD_APPIMAGE_LIGHT=${KICAD_APPIMAGE_LIGHT}

# Build AppImage
RUN <<'EOS'
    # Create launcher script
    mkdir -p AppDir/usr/bin
    cat > AppDir/usr/bin/kicad.sh << 'EOF'
#!/bin/bash
export LD_LIBRARY_PATH="${APPDIR}/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH}"
exec "${APPDIR}/usr/bin/kicad" "$@"
EOF
    chmod +x AppDir/usr/bin/kicad.sh

    # Set compression based on LIGHT mode
    if [ "${KICAD_APPIMAGE_LIGHT}" = "true" ]; then
        export COMP_TYPE="gzip"
    else
        export COMP_TYPE="zstd"
    fi

    # Build AppImage
    appimage-builder --comp ${COMP_TYPE}
EOS

# Final stage - extract AppImage
FROM scratch
COPY --from=appimage /tmp/*.AppImage /