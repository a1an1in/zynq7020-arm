#!/usr/bin/env bash
# 进入 PetaLinux 构建容器（交互 bash）。这是日常开发入口。
#
#   全部挂载单卷 sdk/ 到容器 /opt/xilinx，附带只读挂载安装器/离线包
#   压缩包目录（可选）。进入后先 source settings.sh：
#       source /opt/xilinx/petalinux/settings.sh
#
#   用法：
#       ./utils/devops.sh                        # 交互 shell，/work 是当前目录
#       IMG_NAME=myimg ./utils/devops.sh
#       直接带命令(自动 source settings.sh 并 cd 到工程)：
#       ./utils/devops.sh petalinux-build
#       ./utils/devops.sh petalinux-package --boot --u-boot --fpga --force
#       # 工程容器内路径可覆盖:PETALINUX_PROJ=/work/<名>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG_NAME="${IMG_NAME:-petalinux:2021.1}"
SDK_HOST_DIR="${HERE}/sdk"

# 可选的只读源：离线包压缩包所在的宿主目录（用于在容器内解压）
# 默认指向 docker/archives/，可设 OFFLINE_SRC 覆盖。目录不存在则自动回退 baidu。
if [ -d "${HERE}/docker/archives" ]; then
  OFFLINE_SRC="${OFFLINE_SRC:-${HERE}/docker/archives}"
else
  OFFLINE_SRC="${OFFLINE_SRC:-/mnt/c/Users/a1an1in/Downloads/baidu}"
fi

mkdir -p "${SDK_HOST_DIR}"/{petalinux,downloads,sstate}
# petalinux 工程放在仓库根目录 zynq7020-arm/(容器内通过 ${HERE}:/work 挂载为 /work/zynq7020-arm)
mkdir -p "${HERE}/zynq7020-arm"

# 只读挂载离线源，若存在
MOUNTS_OFFLINE=()
if [ -d "$OFFLINE_SRC" ]; then
  MOUNTS_OFFLINE=(-v "${OFFLINE_SRC}:/offline_src:ro")
fi

# 仅在有 TTY 时才附加 -t，否则非交互环境(如管道/CI)会报
# "the input device is not a TTY"。
DOCKER_TTY=()
if [ -t 0 ] && [ -t 1 ]; then
  DOCKER_TTY=(-t)
fi

# 无参数与带参数是互斥的两种用法:
#   - 无参数 → 进入交互 shell(日常开发入口)
#   - 带参数 → 容器内先 source settings.sh 并切到工程目录,再执行传入命令
#               (例如 ./utils/devops.sh petalinux-build 免交互直接可用)
if [ "$#" -eq 0 ]; then
  exec docker run --rm -i "${DOCKER_TTY[@]}" --network host \
    -e TERM=xterm \
    ${MOUNTS_OFFLINE[@]+"${MOUNTS_OFFLINE[@]}"} \
    -v "${SDK_HOST_DIR}:/opt/xilinx" \
    -v "${HERE}:/work" \
    -w /work \
    -u plsdk \
    "${IMG_NAME}"
else
  # 工程容器内路径可用 PETALINUX_PROJ 覆盖,默认 /work/zynq7020-arm。
  PROJ_DIR="${PETALINUX_PROJ:-/work/zynq7020-arm}"
  exec docker run --rm -i "${DOCKER_TTY[@]}" --network host \
    -e TERM=xterm \
    ${MOUNTS_OFFLINE[@]+"${MOUNTS_OFFLINE[@]}"} \
    -v "${SDK_HOST_DIR}:/opt/xilinx" \
    -v "${HERE}:/work" \
    -w /work \
    -u plsdk \
    "${IMG_NAME}" \
    bash -c 'source /opt/xilinx/petalinux/settings.sh /opt/xilinx/petalinux && cd "${1}" && shift && exec "$@"' plsdk "${PROJ_DIR}" "$@"
fi