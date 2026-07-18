ARG ATLASSIAN_VERSION=5

# ---- builder stage: unpack PE Micro Cyclone, discard the installer afterward ----
FROM atlassian/default-image:${ATLASSIAN_VERSION} AS pemicro-builder

# Install PE Micro Cyclone. Downloaded manually from
# https://www.pemicro.com/downloads/download_file.cfm?download_id=577
# (portal download, not fetchable by URL), or override at build time with
# --build-arg PEMICRO_DEB=<filename>.
# The package's preinst script prompts to accept a license agreement, so we
# pipe `yes` into it. `dpkg --unpack` (not `-i`/`--configure`) is used since
# the postinst step doesn't complete cleanly in a headless build environment;
# --unpack still runs preinst (where the prompt lives) and extracts all files,
# it just skips the maintainer-script configure step afterward.
ARG PEMICRO_DEB="pemicrocyclone_1160_x64.deb"
COPY ${PEMICRO_DEB} /tmp/pemicro.deb
RUN export TERM=xterm && \
    yes | dpkg --unpack /tmp/pemicro.deb ; \
    rm -rf /tmp/pemicro.deb && \
    test -d /usr/local/pemicrocyclone

# ---- builder stage: install STM32CubeCLT, discard the installer/tmp afterward ----
FROM atlassian/default-image:${ATLASSIAN_VERSION} AS stm32cubeclt-builder

# Install STM32CubeCLT
# Latest download at https://www.st.com/en/development-tools/stm32cubeclt.html
# Extract *.zip to get the *.sh file and update the filename here, or override
# at build time with --build-arg CLT_SCRIPT=<filename>
ARG CLT_SCRIPT="stm32cubeclt_1.22.0_29188_20260626_1359-Lin-x86_64.sh"
COPY ${CLT_SCRIPT} /tmp/CLT.sh
RUN cd /tmp && chmod a+x CLT.sh && \
    echo /opt/st/stm32cubeclt_ | LICENSE_ALREADY_ACCEPTED=1 ./CLT.sh --nox11 && \
    rm -rf CLT.sh /tmp/*

# Prune everything except the GNU ARM toolchain — this is a build-only image.
# Verified against actual `du -sh` output from a built image:
#   - STMicroelectronics_CMSIS_SVD (1.1G): register-map XML for debugger/IDE
#     peripheral views only; never touched by the compiler or linker.
#   - st-arm-clang (648M): ST's Clang toolchain; unused since the build
#     actually invokes arm-none-eabi-gcc from GNU-tools-for-STM32.
#   - CMake (144M): unused since apt's cmake is what's on PATH (see below).
RUN cd /opt/st/stm32cubeclt_* && \
    rm -rf ./STM32CubeProgrammer ./STLink-gdb-server \
           ./STMicroelectronics_CMSIS_SVD ./st-arm-clang ./CMake && \
    find . -maxdepth 1 -iname "*jre*" -exec rm -rf {} + ; \
    find . -maxdepth 1 -iname "*node*" -exec rm -rf {} + ; \
    find . -maxdepth 1 -iname "*pack-manager*" -exec rm -rf {} + ; \
    find . -maxdepth 1 -iname "*cmsis-scanner*" -exec rm -rf {} + ; \
    find . -maxdepth 1 -iname "*clangd*" -exec rm -rf {} + ; \
    find . -maxdepth 1 -iname "*code-doc*" -exec rm -rf {} + ; \
    find . -type d -iname "doc*" -exec rm -rf {} + ; \
    find . -type f \( -iname "*.pdf" -o -iname "*.chm" \) -delete ; \
    true

# ---- final stage ----
FROM atlassian/default-image:${ATLASSIAN_VERSION}

# Install necessary build packages and other tools for basic builds
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive && \
    echo "Acquire::Retries \"3\";" > /etc/apt/apt.conf.d/90retry && \
    apt remove -y build-essential && \
    apt autoremove -y && \
    apt install -y --no-install-recommends git p7zip-full clang-format curl jq cmake make python3-yaml && \
    rm -rf /var/lib/apt/lists/*
RUN npm install -g release-it @release-it/conventional-changelog @j-ulrich/release-it-regex-bumper --save-dev && \
    npm cache clean --force

# Pull in only PE Micro Cyclone's installed output, not the .deb that produced
# it (and none of the builder stage's dpkg "half-configured" bookkeeping,
# since we only copy the installed directory itself, not the filesystem).
COPY --from=pemicro-builder /usr/local/pemicrocyclone /usr/local/pemicrocyclone

# Pull in only the installed STM32CubeCLT output, not the 889MB installer that produced it
COPY --from=stm32cubeclt-builder /opt/st /opt/st

# Put the STM32 toolchain on PATH. The installed directory (and the GCC
# toolchain subfolder under GNU-tools-for-STM32) is version-named, so we
# discover the real bin directories at build time rather than hardcoding a
# path that would break on the next ST version bump. A stable symlink is
# also created at /opt/st/stm32cubeclt for anything that wants a fixed path.
RUN STM32CUBECLT_DIR=$(find /opt/st -maxdepth 1 -type d -name "stm32cubeclt_*" | head -1) && \
    ln -sfn "${STM32CUBECLT_DIR}" /opt/st/stm32cubeclt && \
    GCC_BINDIR=$(find "${STM32CUBECLT_DIR}" -type f -name "arm-none-eabi-gcc" -exec dirname {} \; | head -1) && \
    for f in "${GCC_BINDIR}"/*; do \
        [ -f "$f" ] && ln -sf "$f" /usr/local/bin/"$(basename "$f")"; \
    done && \
    arm-none-eabi-gcc --version

# Install dependencies for NRF Connect SDK
# See https://developer.nordicsemi.com/nRF_Connect_SDK/doc/latest/nrf/installation/install_ncs.html
# Note: nrf-command-line-tools (nrfjprog/mergehex) is intentionally NOT installed here —
# it's only needed for flashing/programming physical devices, not for `west build`.
RUN wget developer.nordicsemi.com/.pc-tools/nrfutil/x64-linux/nrfutil && \
    chmod a+x nrfutil && \
    mv nrfutil /usr/local/bin/.

# libunistring2 is required by the git-core bundled inside the NCS toolchain
# (used for HTTPS clones during `west update`), not by nrf-command-line-tools.
RUN cd /tmp && wget http://ftp.us.debian.org/debian/pool/main/libu/libunistring/libunistring2_1.0-2_amd64.deb && \
    apt-get update && \
    apt install -y /tmp/libunistring2_1.0-2_amd64.deb && \
    rm /tmp/libunistring2_1.0-2_amd64.deb && \
    rm -rf /var/lib/apt/lists/*

ENV NCS_VERSION="v2.5.1"
RUN nrfutil install toolchain-manager && \
    nrfutil toolchain-manager install --ncs-version ${NCS_VERSION} && \
    cd /root/ncs && \
    nrfutil toolchain-manager launch -- west init -m https://github.com/nrfconnect/sdk-nrf --mr ${NCS_VERSION} && \
    python3 -c "\
import yaml; \
path = '/root/ncs/nrf/west.yml'; \
data = yaml.safe_load(open(path)); \
exclude = {'matter', 'openthread', 'hostap', 'trusted-firmware-m', 'qcbor', 'psa-arch-tests', 'tf-m-tests', 'wfa-qt-control-app', 'lvgl', 'hal_st', 'cirrus', 'azure-sdk-for-c', 'chre', 'memfault-firmware-sdk', 'loramac-node'}; \
data['manifest']['projects'] = [p for p in data['manifest']['projects'] if p.get('name') not in exclude]; \
yaml.safe_dump(data, open(path, 'w'), sort_keys=False)" && \
    nrfutil toolchain-manager launch -- west config manifest.group-filter -- -optional,-testing && \
    nrfutil toolchain-manager launch -- west update --narrow && \
    nrfutil toolchain-manager launch -- west zephyr-export && \
    rm -rf toolchains/7795df4459/var/cache toolchains/7795df4459/var/lib/apt && \
    rm -rf toolchains/7795df4459/opt/zephyr-sdk/x86_64-zephyr-elf toolchains/7795df4459/opt/zephyr-sdk/aarch64-zephyr-elf && \
    rm -rf toolchains/7795df4459/usr/local/doc toolchains/7795df4459/usr/local/man && \
    rm -rf downloads/* && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /opt/atlassian/bitbucketci/agent/build
ENTRYPOINT ["/bin/bash"]
