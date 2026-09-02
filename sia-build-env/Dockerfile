ARG GO_BUILDER_IMAGE=golang:1.26-bookworm
FROM ${GO_BUILDER_IMAGE} AS source-build

ARG CORE_REPO
ARG COREUTILS_REPO
ARG HOSTD_REPO
ARG RENTERD_UNMODIFIED_REPO
ARG RENTERD_MODIFIED_REPO
ARG WALLETD_REPO
ARG BUILD_JOBS=1
ARG RUN_GO_GENERATE=1
ARG APPLY_LAB_NETWORK_PATCH=1
ARG SIA_BUILD_STATIC=1
ARG BUILD_TAG=local

ENV CORE_REPO="${CORE_REPO}" \
    COREUTILS_REPO="${COREUTILS_REPO}" \
    HOSTD_REPO="${HOSTD_REPO}" \
    RENTERD_UNMODIFIED_REPO="${RENTERD_UNMODIFIED_REPO}" \
    RENTERD_MODIFIED_REPO="${RENTERD_MODIFIED_REPO}" \
    WALLETD_REPO="${WALLETD_REPO}" \
    BUILD_JOBS="${BUILD_JOBS}" \
    RUN_GO_GENERATE="${RUN_GO_GENERATE}" \
    APPLY_LAB_NETWORK_PATCH="${APPLY_LAB_NETWORK_PATCH}" \
    SIA_BUILD_STATIC="${SIA_BUILD_STATIC}" \
    BUILD_TAG="${BUILD_TAG}" \
    GOPROXY=off \
    GOSUMDB=off \
    GOTOOLCHAIN=local

WORKDIR /workspace
COPY src/ /workspace/src/
COPY scripts/prepare-dependencies.sh scripts/patch-lab-network.sh scripts/build-binaries.sh /workspace/scripts/
RUN chmod 0755 /workspace/scripts/*.sh \
    && /workspace/scripts/prepare-dependencies.sh sources \
    && /workspace/scripts/build-binaries.sh

FROM scratch AS binary-export
COPY --from=source-build /out/ /out/
