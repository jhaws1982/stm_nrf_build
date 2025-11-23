ARG ATLASSIAN_VERSION=5
FROM atlassian/default-image:${ATLASSIAN_VERSION}

# Install necessary build packages and other tools for basic builds
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive && \
    echo "Acquire::Retries \"3\";" > /etc/apt/apt.conf.d/90retry && \
    apt remove -y build-essential && \
    apt autoremove -y && \
    apt install -y --no-install-recommends git p7zip-full clang-format curl jq cmake make
RUN npm install -g release-it @release-it/conventional-changelog @j-ulrich/release-it-regex-bumper --save-dev

# Install STM32CubeCLT
# Latest download at https://www.st.com/en/development-tools/stm32cubeclt.html
# Extract *.zip to get the *.sh file and update the filename here
ENV CLT_SCRIPT="st-stm32cubeclt_1.19.0_25876_20250729_1159_amd64.sh"
COPY ${CLT_SCRIPT} /tmp/CLT.sh
RUN cd /tmp && chmod a+x CLT.sh && \
    echo /opt/st/stm32cubeclt_ | LICENSE_ALREADY_ACCEPTED=1 ./CLT.sh --nox11 && \
    rm CLT.sh

# Install dependencies for NRF Connect SDK
# See https://developer.nordicsemi.com/nRF_Connect_SDK/doc/latest/nrf/installation/install_ncs.html
RUN wget developer.nordicsemi.com/.pc-tools/nrfutil/x64-linux/nrfutil && \
    chmod a+x nrfutil && \
    mv nrfutil /usr/local/bin/.
RUN cd /tmp && wget http://ftp.us.debian.org/debian/pool/main/libu/libunistring/libunistring2_1.0-2_amd64.deb && \
    apt install -y /tmp/libunistring2_1.0-2_amd64.deb && rm /tmp/libunistring2_1.0-2_amd64.deb 

ENV NCS_VERSION="v2.5.1"
RUN wget https://nsscprodmedia.blob.core.windows.net/prod/software-and-other-downloads/desktop-software/nrf-command-line-tools/sw/versions-10-x-x/10-24-2/nrf-command-line-tools_10.24.2_amd64.deb && \
    apt install -y ./nrf-command-line-tools_10.24.2_amd64.deb && \
    rm ./nrf-command-line-tools_10.24.2_amd64.deb && \
    nrfutil install toolchain-manager && \
    nrfutil toolchain-manager install --ncs-version ${NCS_VERSION} && \
    cd /root/ncs && \
    nrfutil toolchain-manager launch -- west init -m https://github.com/nrfconnect/sdk-nrf --mr ${NCS_VERSION} && \
    nrfutil toolchain-manager launch -- west update && \
    nrfutil toolchain-manager launch -- west zephyr-export

RUN rm -rf toolchains/7795df4459/var/cache toolchains/7795df4459/var/lib/apt && \
    rm -rf downloads/* && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /opt/atlassian/bitbucketci/agent/build
ENTRYPOINT ["/bin/bash"]
