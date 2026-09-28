#!/bin/bash
# SPDX-License-Identifier: LicenseRef-CSSL-1.0

# -------------------------------------------------------------------------------
# Build one NF in its Docker builder stage, on top of oai-cn-base.
#   usage: build_nf.sh [--deps-only] <nf>
#   --deps-only  only install the NF-only libraries (install_<nf>_extra_deps),
#                so they get their own cached image layer
# ENABLE_LTTNG (true/false) and BUILD_ARGS (extra build_<nf> flags) come from
# the environment, as set by the Dockerfile ARGs.
# -------------------------------------------------------------------------------

deps_only=0
if [ "$1" = "--deps-only" ]; then deps_only=1; shift; fi
NF=${1:?usage: build_nf.sh [--deps-only] <nf>}

# this script lives in <root>/build/common-build/docker
ROOT=$(realpath "$(dirname "$0")/../../..")
source "$ROOT/build/scripts/build_helper.$NF" || exit 1
set_openair_env

# drop package caches so they do not end up in the image layer
clean_package_cache() {
  if [[ "$INSTALLER" == "dnf" ]]; then dnf clean all; else rm -rf /var/lib/apt/lists/*; fi
  rm -rf /tmp/*
}

# NF-specific libraries not shipped in the base image, if the NF defines any;
# the marker skips them when an earlier --deps-only layer installed them
DEPS_MARKER=/usr/local/share/oai/$NF-extra-deps.done
if type -t install_${NF}_extra_deps > /dev/null && [ ! -f "$DEPS_MARKER" ]; then
  update_package_db || exit $?
  install_${NF}_extra_deps 1 0 || exit $?
  ldconfig
  clean_package_cache
  mkdir -p "$(dirname "$DEPS_MARKER")" && touch "$DEPS_MARKER"
fi
# the CI build report looks for this marker, as printed by build_<nf> --install-deps
echo_success "$NF deps installation successful"
[ $deps_only -eq 1 ] && exit 0

# lttng tracing, when the image is built with ENABLE_LTTNG=true
if [ "$ENABLE_LTTNG" = "true" ]; then
  update_package_db || exit $?
  if [[ "$INSTALLER" == "dnf" ]]; then
    $INSTALLER install -y lttng-ust-devel lttng-tools || exit $?
  else
    $INSTALLER install -y liblttng-ust-dev lttng-tools || exit $?
  fi
  clean_package_cache
  BUILD_ARGS="$BUILD_ARGS --lttng"
fi

# build the NF
BIN_DIR=$OPENAIRCN_DIR/build/$NF/build
ldconfig
cd "$OPENAIRCN_DIR/build/scripts" || exit 1
./build_$NF --clean --Verbose --build-type Release --jobs $BUILD_ARGS || exit $?
mv "$BIN_DIR/$NF" "$BIN_DIR/oai_$NF" || exit 1

# ldd exits 0 even when a library is missing, so check its output
if ldd "$BIN_DIR/oai_$NF" | grep "not found"; then
  echo_error "oai_$NF is missing libraries"
  exit 1
fi

# collect the /usr/local libraries the binary needs, for the target stage to copy
# (CMake-built libraries install into lib64 on EL, meson and autotools into lib)
mkdir -p "$OPENAIRCN_DIR/runtime-libs"
ldd "$BIN_DIR/oai_$NF" | awk '$3 ~ /^\/usr\/local\/lib(64)?\// {print $3}' | sort -u | \
  xargs -r cp -L -t "$OPENAIRCN_DIR/runtime-libs/" || exit 1
ls -l "$OPENAIRCN_DIR/runtime-libs/"
