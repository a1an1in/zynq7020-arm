# PetaLinux 2021.1 构建环境镜像
#
# 关键设计：
#   - 基镜像用 Ubuntu 18.04（PetaLinux 2021.1 官方支持，libncurses5/libtinfo5
#     原生齐全，比 20.04 少踩依赖坑）。
#   - PetaLinux SDK 本身【不打进镜像】，作为宿主卷在运行期挂载到
#     /opt/xilinx/petalinux。本镜像只装 OS + 依赖（体积小、换机可复用同一份 SDK）。
#   - PetaLinux 安装器拒绝以 root 运行，因此在镜像内创建普通用户 plsdk，
#     与宿主 UID/GID 对齐；安装动作由 plsdk 用户完成。
#   - 环境使用：进入容器后执行 `source $PLSDK_INSTALL_PATH/settings.sh`，
#     不另做包装/透传层（保持最简单、与官方用法一致）。

FROM ubuntu:18.04

ENV DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    TERM=xterm

# 1) 基础依赖 + PetaLinux 2021.1 运行时依赖（x86_64 宿主、arm 目标）
#    PetaLinux 2021.1 官方建议的 Ubuntu 环境依赖，见 ug1144。
RUN dpkg --add-architecture i386 && \
    apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        gcc-multilib \
        g++ \
        gawk \
        gperf \
        git \
        gnupg \
        flex \
        bison \
        texinfo \
        bzip2 \
        cpio \
        rsync \
        autoconf \
        automake \
        libtool \
        diffstat \
        chrpath \
        socat \
        net-tools \
        iproute2 \
        tofrodos \
        xterm \
        xvfb \
        screen \
        openssh-server \
        procps \
        wget \
        curl \
        unzip \
        locales \
        x11-utils \
        x11-apps \
        libxft2 \
        libxrender1 \
        libxrandr2 \
        libxext6 \
        libxtst6 \
        libxi6 \
        libfontconfig1 \
        libglib2.0-0 \
        libdbus-1-3 \
        libgtk2.0-0 \
        libsdl1.2-dev \
        libx11-dev \
        libxmu-dev \
        libxt-dev \
        libncurses5-dev \
        libncursesw5-dev \
        libtinfo5 \
        libtinfo-dev \
        libssl-dev \
        zlib1g-dev \
        zlib1g:i386 \
        libc6-dev-i386 \
        lib32z1 \
        lib32stdc++6 \
        python3 \
        python3-pip \
        python3-setuptools \
        python3-venv \
        python3-pexpect \
        python3-dev \
        cmake \
        pkg-config \
        expect \
        vim \
        lsb-release \
        mtd-utils \
        swig \
        # 安装器环境检查所需的"系统工具"（曾缺失导致安装被拒）
        bc \
        less \
        # 其它 ug1144 官方清单常用项，一次补齐避免二次反复
        device-tree-compiler \
        lzop \
        u-boot-tools \
        libxml2-dev \
        libbz2-dev \
        lib32ncurses5 \
        python \
        python-pexpect \
    # 2) 让 /bin/sh 为 bash（PetaLinux 依赖 bash 作为默认 shell）
    && echo "dash dash/sh boolean false" | debconf-set-selections \
    && DEBIAN_FRONTEND=noninteractive dpkg-reconfigure dash \
    # 3) 生成必需 locale（PetaLinux 环境要求 en_US.UTF-8）
    && locale-gen --no-archive en_US.UTF-8 \
    # 4) 清理 apt 缓存
    && rm -rf /var/lib/apt/lists/* /tmp/*

# 5) 创建普通用户 plsdk（与宿主 UID/GID 对齐），SDK/工程以该用户读写
#    安装器会写入 /opt/xilinx，挂载卷也因此归属 plsdk。
ARG HOST_USER_UID=1000
ARG HOST_USER_GID=1000
RUN groupadd -g ${HOST_USER_GID} plsdk \
    && useradd -m -s /bin/bash -u ${HOST_USER_UID} -g plsdk plsdk \
    && mkdir -p /opt/xilinx \
    && chown -R plsdk:plsdk /opt/xilinx

# 6) 工作目录：宿主工程目录将挂载到这里
WORKDIR /work

USER plsdk
CMD ["/bin/bash"]