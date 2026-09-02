ARG RUNTIME_TOOLS_IMAGE=sia-lab-runtime-tools:bookworm
FROM ${RUNTIME_TOOLS_IMAGE} AS runtime-common
ARG BUILD_TAG=local

COPY bin/BUILD_TAG /usr/local/share/sia-lab/BUILD_TAG
COPY controls/ /opt/sia-lab/controls/
COPY scenarios/ /opt/sia-lab/scenarios/
COPY scripts/configure.sh scripts/entrypoint.sh /opt/sia-lab/

RUN test "$(cat /usr/local/share/sia-lab/BUILD_TAG)" = "${BUILD_TAG}" \
    && chmod 0755 /opt/sia-lab/configure.sh /opt/sia-lab/entrypoint.sh \
       /opt/sia-lab/scenarios/*.sh \
    && chmod 0644 /opt/sia-lab/controls/*.sh \
    && mkdir -p /var/lib/sia /var/lib/sia-host-storage /run/sia-lab

ENV SIA_API_PASSWORD=lab-api-password \
    INITIAL_CHAIN_HEIGHT=200 \
    BOOTSTRAP_TIMEOUT_SECONDS=7200 \
    SCENARIO_TIMEOUT_SECONDS=2400 \
    SCENARIO_RELEASE_TIMEOUT_SECONDS=900 \
    SIA_NETWORK=zen
WORKDIR /opt/sia-lab
EXPOSE 9980/tcp 9981/tcp 9984/tcp 9984/udp 10980/tcp 10981/tcp
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/sia-lab/entrypoint.sh"]

FROM runtime-common AS renter-unmodified-runtime
ENV RENTERD_VARIANT=unmodified
COPY bin/renterd-unmodified /usr/local/bin/renterd
COPY bin/walletd /usr/local/bin/walletd

FROM runtime-common AS renter-modified-runtime
ENV RENTERD_VARIANT=modified
COPY bin/renterd-modified /usr/local/bin/renterd
COPY bin/walletd /usr/local/bin/walletd

FROM runtime-common AS host-runtime
COPY bin/hostd /usr/local/bin/hostd
COPY bin/walletd /usr/local/bin/walletd

FROM runtime-common AS wallet-runtime
COPY bin/walletd /usr/local/bin/walletd
