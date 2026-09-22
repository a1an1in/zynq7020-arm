#!/usr/bin/env bash
# 把离线包解压进 sdk/ 卷，供 PetaLinux 离线编译使用。
#
# 前置机制（重要，改动会破坏离线编译）：
#   - 米联客手册把 downloads/sstate 解压到 /home/uisrc，然后在
#     petalinux-config -> Yocto Settings 配 pre-mirror url:
#         file:///home/uisrc/downloads_2021.1_update1
#     local sstate: /home/uisrc/sstate_arm_2021.1 /arm
#   - 本工程把 SDK 卷挂到 /opt/xilinx，故对应容器内路径为：
#         downloads pre-mirror: /opt/xilinx/downloads
#         sstate:               /opt/xilinx/sstate
#   源码在 Linux 里配置时会用这些容器内路径。
#
#   ./utils/unpack-offline.sh
#
# 离线包来源：离线包压缩包（.tar.gz）默认从 docker/archives/ 找
# （安装器与离线包统一放在 docker/archives/，属 Docker 所需文件），
#   也可用环境变量 DOWNLOADS_TGZ / SSTATEGZ 显式指定。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_HOST_DIR="${HERE}/sdk"
IMG_NAME="${IMG_NAME:-petalinux:2021.1}"

# 原始离线包取源候选（按序，命中首现存目录即用）：
#   1) 用户统一归档 C:/Users/a1an1in/softs/xlinx（下载/安装包集中地，推荐）
#   2) docker/archives/（含安装器）
#   3) baidu 下载目录（旧，已迁移）
# 也可用环境变量 DOWNLOADS_TGZ / SSTATEGZ 显式指定。
for _a in \
    "/mnt/c/Users/a1an1in/softs/xlinx" \
    "${HERE}/docker/archives" \
    "/mnt/c/Users/a1an1in/Downloads/baidu"; do
  [ -d "$_a" ] && ARCHIVES="$_a" && break
done
: "${ARCHIVES:=/mnt/c/Users/a1an1in/softs/xlinx}"
DOWNLOADS_TGZ="${DOWNLOADS_TGZ:-${ARCHIVES}/downloads_2021.1_update1.tar.gz}"
SSTATE_TGZ="${SSTATEGZ:-${ARCHIVES}/sstate_arm_2021.1.tar.gz}"

# ---------- 目标（解压后省略顶层目录，直接落到 sdk/<sub> 下 ----------
DOWNLOADS_DST="${SDK_HOST_DIR}/downloads"   # 期望内部结构 downloads_2021.1_update1/... -> sdk/downloads/...
SSTATE_DST="${SDK_HOST_DIR}/sstate"         # 期望 sstate_arm_2021.1/arm -> sdk/sstate/arm

echo "==> 解压 downloads ..."
echo "    源: ${DOWNLOADS_TGZ}"
[ -f "$DOWNLOADS_TGZ" ] || { echo "缺少 downloads 包: $DOWNLOADS_TGZ" >&2; exit 1; }
mkdir -p "${DOWNLOADS_DST}"
# --strip-components=1 去掉顶层 downloads_2021.1_update1/
tar -xzf "$DOWNLOADS_TGZ" -C "${DOWNLOADS_DST}" --strip-components=1

echo "==> 解压 sstate ..."
echo "    源: ${SSTATE_TGZ}"
[ -f "$SSTATE_TGZ" ] || { echo "缺少 sstate 包: $SSTATE_TGZ" >&2; exit 1; }
mkdir -p "${SSTATE_DST}"
# 结构为 sstate_arm_2021.1/arm；保留再一层 /arm
tar -xzf "$SSTATE_TGZ" -C "${SDK_HOST_DIR}"  # 会重建 sstate_arm_2021.1/arm
# 把 arm 目录就位
if [ -d "${SDK_HOST_DIR}/sstate_arm_2021.1/arm" ]; then
  mv "${SDK_HOST_DIR}/sstate_arm_2021.1/arm" "${SSTATE_DST}/arm"
  rmdir "${SDK_HOST_DIR}/sstate_arm_2021.1" || true
else
  echo "警告: 未在预期位置找到 sstate/arm, 请检查包结构。" >&2
fi

echo "==> 离线包就位:"
echo "    downloads: ${DOWNLOADS_DST}"
echo "    sstate   : ${SSTATE_DST}"
echo "==> 在 petalinux-config 的 Yocto Settings 中设置:"
echo "    pre-mirror url      = file:///opt/xilinx/downloads"
echo "    local sstate feeds  = /opt/xilinx/sstate  /arm"
echo "    并取消勾选 Enable Network sstate feeds"