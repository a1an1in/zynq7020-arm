#!/usr/bin/env bash
# WSL2  disks/资源体检 —— 定位 petalinux-build 期间“磁盘利用率 100%”。
#
# 关键区分:
#   * 空间满  -> 看 df -h / df -i 里 / 或 /mnt/c 的 Use% / IUse%
#   * I/O 饱和-> df 一切正常,但 Windows 任务管理器“磁盘”长期 100%,
#                根因通常是 WSL 内存太小 + bitbake 并发太高(见 .wslconfig)
#
# 用法: ./utils/wsl-disk.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo '===== 1. 空间与 inode ====='
df -h | grep -vE '^(none|rootfs|tmpfs)[[:space:]]'
echo
df -i / /home 2>/dev/null
echo
echo '提示: /dev/loop0 ... 100% ... /mnt/wsl/docker-desktop/cli-tools 是 Docker Desktop'
echo '      的只读 CLI 镜像(iso9660),固定 100%,属正常现象,与构建无关。'
echo

echo '===== 2. Windows 侧剩余空间(在 WSL 内看 C:)====='
df -h /mnt/c 2>/dev/null || echo '(未挂载 /mnt/c)'
echo

echo '===== 3. WSL 虚拟盘(.vhdx 只涨不缩)====='
find /mnt/c/Users/*/AppData/Local -maxdepth 5 -name '*.vhdx' \
  -printf '%s\t%p\n' 2>/dev/null | sort -rn \
  | awk '{printf "%8.1f GB  %s\n", $1/1073741824, $2}'
echo

echo '===== 4. 构建产物体积(大目录,可能较慢)====='
du -sh "${HERE}/sdk/petalinux" "${HERE}/sdk/downloads" "${HERE}/sdk/sstate" \
       "${HERE}/src/zynq7020/build/tmp" "${HERE}/src/zynq7020/build/downloads" 2>/dev/null
echo

echo '===== 5. Docker 占用(可 prune 回收)====='
docker system df 2>/dev/null || echo '(docker 不可用)'
echo

echo '===== 6. WSL 资源配置(内存/swap/CPU)====='
cat /mnt/c/Users/*/.wslconfig 2>/dev/null || echo '(无 .wslconfig:默认内存=宿主50%, swap=25%)'
echo
echo "容器内可见 CPU 数: $(nproc)"
free -h
echo
echo '建议: 16 核 / 28GB 宿主 -> memory=12GB, processors=12, swap=8GB'
echo '      改完 .wslconfig 后需在 Windows 执行 wsl --shutdown 生效。'
