#!/usr/bin/env bash
# 进入 PetaLinux 构建容器（交互 bash）。这是日常开发入口。
#
#   全部挂载单卷 sdk/ 到容器 /opt/xilinx，附带只读挂载安装器/离线包
#   压缩包目录（可选）。进入后先 source settings.sh：
#       source /opt/xilinx/petalinux/settings.sh
#
#   用法：
#       ./utils/run.sh                        # 交互 shell，/work 是当前目录
#       IMG_NAME=myimg ./utils/run.sh
#       也可直接带命令：./utils/run.sh petalinux-build
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
# petalinux 工程放在仓库根目录 src/(容器内通过 ${HERE}:/work 挂载为 /work/src)
mkdir -p "${HERE}/src"

# 只读挂载离线源，若存在
MOUNTS_OFFLINE=()
if [ -d "$OFFLINE_SRC" ]; then
  MOUNTS_OFFLINE=(-v "${OFFLINE_SRC}:/offline_src:ro")
fi

exec docker run --rm -it --network host \
  -e TERM=xterm \
  ${MOUNTS_OFFLINE[@]+"${MOUNTS_OFFLINE[@]}"} \
  -v "${SDK_HOST_DIR}:/opt/xilinx" \
  -v "${HERE}:/work" \
  -w /work \
  -u plsdk \
  "${IMG_NAME}" \
  "$@"