#!/usr/bin/env bash
# 首次运行：用 auto-install.sh 把 PetaLinux 2021.1 SDK 安装到宿主 sdk/ 卷。
#
#   sdk/ 是唯一持久化卷，挂载到容器 /opt/xilinx。目录约定：
#     sdk/petalinux    <- SDK 本体（容器内路径 /opt/xilinx/petalinux）
#     sdk/downloads    <- 离线源码 pre-mirror（petalinux-config 里配
#                         file:///opt/xilinx/downloads）
#     sdk/sstate       <- 32 位 sstate 缓存（/opt/xilinx/sstate）
# 工程目录为仓库根 src/（不装到此卷；容器内 /work/src）
#
# 前置：已 build 镜像；已下载安装器。安装器默认从两个候选路径找，
#       也可用环境变量 PETALINUX_INSTALLER 显式指定。
#
#   ./utils/install-sdk.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG_NAME="${IMG_NAME:-petalinux:2021.1}"

SDK_HOST_DIR="${HERE}/sdk"
INSTALL_TARGET="/opt/xilinx/petalinux"

# 安装器候选路径（按序找，第一个存在即用）
declare -a CANDIDATES=(
  "${PETALINUX_INSTALLER:-}"
  "${HERE}/sdk/downloads/petalinux-v2021.1-final-installer.run"
  "${HERE}/docker/archives/petalinux-v2021.1-final-installer.run"
  "${HERE}/downloads/petalinux-v2021.1-final-installer.run"
  "/mnt/c/Users/a1an1in/Downloads/baidu/petalinux-v2021.1-final-installer.run"
)
INSTALLER_RUN=""
for c in "${CANDIDATES[@]}"; do
  if [ -n "$c" ] && [ -f "$c" ]; then INSTALLER_RUN="$c"; break; fi
done
if [ -z "$INSTALLER_RUN" ]; then
  echo "未找到安装器。请设置环境变量: PETALINUX_INSTALLER=<路径> ./utils/install-sdk.sh" >&2
  exit 1
fi
echo ">> 安装器: ${INSTALLER_RUN}"

mkdir -p "${SDK_HOST_DIR}"/{petalinux,downloads,sstate}
mkdir -p "${HERE}/src"

INSTALLER_DIR="$(dirname "$INSTALLER_RUN")"
INSTALLER_NAME="$(basename "$INSTALLER_RUN")"

# 交互模式（推荐用于看清真实安装器界面）：
#   ./utils/install-sdk.sh --interactive
# 直接以 -it 分配交互 tty 运行真实安装器，你可亲眼看到并亲手完成许可确认、
# 目录选择等。PetaLinux 许可用 less 显示，交互 tty 下你按 q 关闭、y 接受即可。
# 注意：交互模式必须在你自己的终端前台运行（不能 nohup 后台），否则无输入。
if [ "${1:-}" = "--interactive" ]; then
  echo ">> 交互模式启动 SDK 安装器 ...（请在本终端操作）"
  echo ">> 到 LICENSE AGREEMENTS 时按 q 关闭、y 接受，然后确认安装目录 /opt/xilinx/petalinux"
  exec docker run --rm --network host -it \
    -v "${INSTALLER_DIR}:/installer:ro" \
    -v "${SDK_HOST_DIR}:/opt/xilinx" \
    -u plsdk \
    --workdir /tmp \
    "${IMG_NAME}" \
    "/installer/${INSTALLER_NAME}" --dir "${INSTALL_TARGET}"
fi

echo ">> SDK 安装中（自动应答许可，实时打印进度心跳）... SDK 将写入宿主: ${SDK_HOST_DIR}/petalinux"
docker run --rm --network host \
  -t \
  -v "${INSTALLER_DIR}:/installer:ro" \
  -v "${SDK_HOST_DIR}:/opt/xilinx" \
  -v "${HERE}/docker/scripts:/scripts:ro" \
  -u plsdk \
  --workdir /tmp \
  "${IMG_NAME}" \
  expect /scripts/auto-install.sh "/installer/${INSTALLER_NAME}" "${INSTALL_TARGET}"

# 完成校验：settings.sh 是 SDK 安装成功的标志
if [ ! -s "${SDK_HOST_DIR}/petalinux/settings.sh" ]; then
  echo "!! 未发现 ${SDK_HOST_DIR}/petalinux/settings.sh，安装可能未完成。用 SAP_EXP_TTY=1 重跑可看安装器原始输出。" >&2
  exit 1
fi

echo ">> SDK 安装完成:"
echo "    已生成: ${SDK_HOST_DIR}/petalinux/settings.sh"
echo "    大小:   $(du -sh "${SDK_HOST_DIR}/petalinux" 2>/dev/null | cut -f1)"
echo ">> 下一步: utils/unpack-offline.sh 解压离线包，然后 utils/devops.sh 进入工程开发"