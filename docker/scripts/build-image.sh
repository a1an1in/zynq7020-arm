#!/usr/bin/env bash
# 构建 PetaLinux 2021.1 的 Docker 镜像（不含 SDK，镜像只含 OS+依赖）。
#
#   ./utils/build-image.sh            # 以当前用户 UID/GID 构建
#   UID_ARG=1000 GID_ARG=1000 ./utils/build-image.sh   # 显式指定
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG_NAME="${IMG_NAME:-petalinux:2021.1}"
UID_ARG="${HOST_UID:-$(id -u)}"
GID_ARG="${HOST_GID:-$(id -g)}"

echo ">> 构建镜像: ${IMG_NAME}  (UID=${UID_ARG}, GID=${GID_ARG})"
docker build \
  --network host \
  --build-arg HOST_USER_UID="${UID_ARG}" \
  --build-arg HOST_USER_GID="${GID_ARG}" \
  -t "${IMG_NAME}" \
  "${HERE}/docker"

echo ">> 完成: ${IMG_NAME}"