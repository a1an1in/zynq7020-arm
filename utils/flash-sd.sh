#!/usr/bin/env bash
# SD 卡烧写工具(子命令化)。
#
# 子命令:
#   list | detect   识别当前 SD 卡(WSL 可移动盘 + Windows usbipd 读卡器状态)
#   release         归还 SD 卡给 Windows(usbipd detach;会弹 UAC,请点允许)
#   part            只做分区 + 格式化
#   mkfs|format     仅重新格式化已有分区(sdg1/sdg2),不重写分区表(自动卸载残留挂载)
#   flash  [源]     刷包;若 SD 卡尚未分区则先自动分区再刷包(不传源时默认官方出厂设置包)
#   deploy <选项> <源目录> <root@板IP> <设备>
#                    SSH 登板(用户/密码 root/root),把本地源同步到板上的 SD 分区。
#                    <选项>二选一:
#                      -b|--boot  只同步 boot(FAT)启动模块(BOOT.BIN/image.ub/boot.scr 等)
#                                    用 scp 拷贝、只增不删(板上 dropbear/busybox 常无 rsync)
#                      -f|--fs    增量+镜像删除地同步文件系统(源=目录或 .tar.gz/.tgz,归档自动解压且同步后删;输出文件级变更明细)
#                    <设备>为板上目标 SD 块设备(mmcblk0 或 /dev/mmcblk0);
#                    必须显式指定 源目录/板IP/设备,均无默认;会先校验设备为 SD 卡(removable=1 或 device/type=SD)后才操作。
#
# 源(SOURCE): 一律为目录路径;省略时默认官方出厂设置包
#   /mnt/c/Users/a1an1in/workspace/xlinx/F6_7020/V2022/01_user_start/02_start_linux/03_restore_factory/rst_to_factory_img/rst_to_factory_img/sdcard_image
# 刷本工程产物传: <工程>/src/images/linux 目录
# deploy 无默认源,必须显式给 <源目录>
#
# 用法例:
#   utils/flash-sd.sh help
#   utils/flash-sd.sh list
#   utils/flash-sd.sh part
#   utils/flash-sd.sh flash ./src/images/linux
#   utils/flash-sd.sh deploy -b ./src/images/linux root@192.168.1.100 mmcblk0   # 只换启动模块
#   utils/flash-sd.sh deploy -f ./nfs/rootfs root@192.168.1.100 /dev/mmcblk0    # 增量同步文件系统
#   utils/flash-sd.sh release
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO=sudo

FACTORY_SRC="/mnt/c/Users/a1an1in/workspace/xlinx/F6_7020/V2022/01_user_start/02_start_linux/03_restore_factory/rst_to_factory_img/rst_to_factory_img/sdcard_image"      # 官方出厂设置包
SELF_SRC="${HERE}/src/images/linux"                  # 本工程 PetaLinux 产物
PSWIN='/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'

usage() {
  awk 'NR>1 && /^#/ {print; next} NR>1 && !/^#/ {exit}' \
    "${BASH_SOURCE[0]}" | sed -E 's/^#[ ]*/  /'
  exit 0
}

# ---- 工具补装(需 sudo,一次) ----------------------------------------------
ensure_tools() {
  local MISS="" t
  for t in parted mkfs.vfat rsync tar mount; do command -v "$t" >/dev/null 2>&1 || MISS="${MISS} $t"; done
  if [ -n "$MISS" ]; then
    echo ">> 缺工具:$MISS,安装 parted dosfstools rsync tar ..."
    ${SUDO} apt-get update -qq && ${SUDO} apt-get install -y parted dosfstools rsync tar
  fi
  # deploy 走 ssh,需 sshpass(密码认证)
  if ! command -v sshpass >/dev/null 2>&1; then
    echo ">> 缺 sshpass(deploy 用),安装 ..."
    ${SUDO} apt-get install -y sshpass
  fi
}

# ---- 选择 SD 卡设备(交互确认) ---------------------------------------------
pick_dev() {
  echo "WSL 当前可见可移动盘(应见 ~29G 的那块):" >&2
  lsblk -dno NAME,SIZE,RM,TYPE,MODEL | awk 'NR==1 || $3==1' >&2
  local dev
  read -r -p "输入要操作的 SD 卡设备(如 /dev/sdg)并回车: " dev >&2
  [ -n "$dev" ] && [ -b "$dev" ] || { echo "[错误] ${dev:-空} 不是块设备(提示/列表输出走 stderr,stdout 只返回设备路径)" >&2; return 1; }
  printf '%s' "$dev"
}

# ---- 解析源目录 -----------------------------------------------------------
resolve_src() {
  local s="${1:-}"
  [ -n "$s" ] || s="$FACTORY_SRC"     # 省略时默认出厂包目录
  [ -d "$s" ] && { echo "$s"; } || { echo "!目录不存在: $s" >&2; return 1; }
}

# ---- 只分区 + 格式化 --------------------------------------------------------
do_part() {
  local dev="$1"
  echo "!!!! 即将把 ${dev} ($(lsblk -dno SIZE "${dev}")) 整卡抹掉重分区 !!!!"
  local yy; read -r -p "确认请输入大写 YES 继续: " yy
  [ "$yy" = "YES" ] || { echo "已取消"; return 0; }
  ${SUDO} -v || { echo "[错误] sudo 认证失败"; return 1; }
  sync
  local m p
  for m in $(lsblk "$dev" -o mountpoint --noheadings | grep -v '^$'); do ${SUDO} umount "$m" 2>/dev/null || true; done
  for p in $(lsblk -l "$dev" | awk '/part/{print $1}'); do ${SUDO} swapoff "/dev/$p" 2>/dev/null || true; done
  echo "[分区] fat32(BOOT,1-100MiB,可引导) + ext4(rootfs,到盘尾)..."
  ${SUDO} parted -s "$dev" mklabel msdos
  ${SUDO} parted -s "$dev" mkpart primary fat32 1MiB 100MiB
  ${SUDO} parted -s "$dev" set 1 boot on
  ${SUDO} parted -s "$dev" mkpart primary ext4 100MiB 100%
  ${SUDO} partprobe "$dev" || ${SUDO} partx -u "$dev" || true
  sleep 2
  ${SUDO} mkfs.vfat -F 32 -n BOOT "${dev}1"
  echo y | ${SUDO} mkfs.ext4 -L rootfs "${dev}2"
  echo ">> 分区完成:"; lsblk -o NAME,SIZE,FSTYPE,LABEL "$dev"
}

# ---- 仅重新格式化(保留分区表,自动卸载残留挂载) -------------------------------
do_mkfs() {
  local dev="$1" yy m
  echo "即将重新格式化 ${dev}1(BOOT/vfat) 与 ${dev}2(rootfs/ext4),保留分区表不重写。"
  echo "当前布局:"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$dev" | grep -v '^$'
  read -r -p "确认请输入大写 YES 继续: " yy
  [ "$yy" = "YES" ] || { echo "已取消"; return 0; }
  ${SUDO} -v || { echo "[错误] sudo 认证失败"; return 1; }
  for m in $(lsblk "$dev" -o mountpoint --noheadings | grep -v '^$'); do ${SUDO} umount "$m" 2>/dev/null || true; done
  ${SUDO} mkfs.vfat -F 32 -n BOOT "${dev}1"
  echo y | ${SUDO} mkfs.ext4 -L rootfs "${dev}2"
  echo ">> 格式化完成:"
  lsblk -o NAME,SIZE,FSTYPE,LABEL "$dev"
}

# ---- 刷包(boot + rootfs) ----------------------------------------------------
do_flash() {
  local dev="$1" src="$2" bootdir rootfs_tgz=""
  if   [ -d "$src/boot" ]; then bootdir="$src/boot"        # 出厂包风格
  elif [ -f "$src/BOOT.BIN" ] || [ -f "$src/BOOT.bin" ]; then bootdir="$src"   # 工程 images 风格(任一大小写存在即可)
  else echo "! 源里找不到启动文件($src/boot 或 BOOT.bin)" >&2; return 1; fi
  rootfs_tgz=""
  if   [ -f "$src/rootfs/rootfs.tar.gz" ]; then rootfs_tgz="$src/rootfs/rootfs.tar.gz"   # 出厂布局
  elif [ -f "$src/rootfs.tar.gz" ]; then rootfs_tgz="$src/rootfs.tar.gz"; fi             # 工程布局(根下)
  ${SUDO} -v || { echo "[错误] sudo 认证失败"; return 1; }
  local m1 m2
  echo ">> 刷 boot(${bootdir}) 到 ${dev}1 ..."
  m1="$(mktemp -d)"; ${SUDO} mount -t vfat "${dev}1" "$m1"
  if [ "$bootdir" = "$src" ]; then
    # 工程 images 风格:只拷启动相关文件,排除 rootfs/pxelinux/vmlinux 等,避免塞爆 FAT
    echo ">> 工程源,已排除非启动文件(rootfs*, pxelinux*, vmlinux*, *.cpio, *.ext4, *.jffs2, *.manifest, config, *.elf):"
    ${SUDO} rsync -rv --exclude='rootfs*' --exclude='pxelinux*' --exclude='vmlinux*' \
                      --exclude='*.cpio*' --exclude='*.jffs2' --exclude='*.ext4' \
                      --exclude='*.manifest' --exclude='config' --exclude='*.elf' \
                      "${bootdir}/" "$m1"/
  else
    ${SUDO} rsync -rv "${bootdir}/" "$m1"/
  fi
  sync; ${SUDO} umount "$m1"; rmdir "$m1"
  if [ -n "$rootfs_tgz" ]; then
    echo ">> 解压 rootfs.tar.gz($(du -h "$rootfs_tgz" | cut -f1),从 C 盘读取较慢)到 ${dev}2 ..."
    m2="$(mktemp -d)"; ${SUDO} mount -t ext4 "${dev}2" "$m2"
    if command -v pv >/dev/null 2>&1; then
      echo "   (带进度条,pv 显示;走 /mnt/c 可能慢,请等到 100% 后出现 '刷包完成')"
      ${SUDO} sh -c "pv -f '$rootfs_tgz' | tar zx -C '$m2'"
    else
      echo "   (无 pv,无进度条;正在解压 420M 级文件,请不要中断,完成后打印字节总数)"
      ${SUDO} tar --totals -zxf "$rootfs_tgz" -C "$m2" \
        || { echo "[!] rootfs 解压失败" >&2; ${SUDO} umount "$m2" 2>/dev/null || true; rmdir "$m2" 2>/dev/null || true; return 1; }
    fi
    sync; ${SUDO} umount "$m2"; rmdir "$m2"
  else
    echo ">> 无 rootfs.tar.gz,ext4 分区留空(工程若用 image.ub 内 ramdisk 则正常)。"
  fi
  sync
  echo ">> 刷包完成。"
}

# ---- 识别: WSL 盘 + Windows usbipd ----------------------------------------
detect() {
  echo "== WSL 可见可移动盘 =="; lsblk -dno NAME,SIZE,RM,TYPE,MODEL | awk 'NR==1 || $3==1'
  echo
  if [ -x "$PSWIN" ]; then
    echo "== Windows usbipd 读卡器状态(SD/读卡器相关行) =="
    "$PSWIN" -NoProfile -Command "usbipd list" 2>&1 | grep -iE 'BUS|14cd|SD|USB' | head -10 \
      || echo "(无法读取 usbipd,可在管理员 PowerShell 手动运行 usbipd list)"
  fi
}

# ---- 归还给 Windows --------------------------------------------------------
release() {
  if [ ! -x "$PSWIN" ]; then echo "未找到 Windows interop,powershell 不可用"; return 1; fi
  local busids
  busids=$("$PSWIN" -NoProfile -Command "usbipd list" 2>/dev/null | awk '/Attached/{print $1}')
  if [ -z "$busids" ]; then echo ">> 当前没有处于 Attached 的 usbip 设备,无需归还。"; return 0; fi
  local id
  for id in $busids; do
    echo ">> 归还 $id (会弹 UAC 提升窗口,请点‘允许’)..."
    "$PSWIN" -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -Command \"usbipd detach --busid $id\"'" >/dev/null 2>&1 \
      && echo ">> 已发起 detach(UAC 窗口中点允许即可)。" \
      || echo "! 无法自动提升。请在管理员 PowerShell 手动执行: usbipd detach --busid ${id}"
    echo "   或: usbipd detach --busid ${id}"
  done
}

# ---- 生成并打印 -f 的"文件级变更明细" ---------------------------------------
# $1 = rsync -i 的原样输出日志文件; $2 = 本地源目录(用于求"未变化 = 源全集 - 已更新")
# 解析 rsync itemize 行(status + 路径)与 deleting 行,给出 新增/更新、镜像删除、未变化 三类 + 完整清单。
fs_change_report() {
  local out="$1" srcdir="$2"
  local upd="$out.upd" del="$out.del" src="$out.src" unch="$out.unch"
  : > "$upd"; : > "$del"; : > "$src"; : > "$unch"

  # 已更新(新增/覆盖):字段1是状态字(如 >f+++++++++),字段2是相对路径;
  # 排除 汇总行(sending/receiving) 与 删除行(deleting)。
  awk 'NF>1 && $1!="sending" && $1!="receiving" && $1!~"deleting" && $1!~"Warning" && $1!~"Permanently" { p=$2; sub(/^\//,"",p); print p }' "$out" \
    | sort -u > "$upd"
  # 镜像删除:形如 "deleting path" 或 "*deleting path"
  sed -nE 's/^[*]?deleting[[:space:]]+//p' "$out" | sort -u > "$del"
  # 源全集(仅普通文件/软链,相对根)
  ( cd "$srcdir" 2>/dev/null && find . \( -type f -o -type l \) | sed 's#^\./##' ) | sort -u > "$src"
  # 未变化 = 源全集 - 已更新(目标已与源一致)
  comm -23 "$src" "$upd" > "$unch" || true

  local nupd ndel nunch
  nupd=$(wc -l < "$upd"); ndel=$(wc -l < "$del"); nunch=$(wc -l < "$unch")
  echo ">> --- 文件级变更明细 ---"
  echo "  ♻ 新增/更新: $nupd 个"
  awk '{ print "      +  " $0 }' "$upd"
  echo "  ✖ 镜像删除(源已无,板上已删): $ndel 个"
  awk '{ print "      -  " $0 }' "$del"
  echo "  ○ 未变化(目标已与源一致): $nunch 个"
  awk '{ print "      .  " $0 }' "$unch"

  rm -f "$upd" "$del" "$src" "$unch"
}

# ---- deploy: SSH 登板,同步模块到板上指定 SD 设备 --------------------------------
# ---- deploy: SSH 登板,同步模块到板上指定 SD 设备 --------------------------------
# 用法: deploy <-b|--boot | -f|--fs> <源目录> <root@板IP> <设备>
#   -b/--boot  只同步 boot(FAT)启动模块(BOOT.bin/image.ub/boot.scr 等,排除 rootfs)
#   -f/--fs    增量+镜像删除同步文件系统(源=目录或 rootfs 归档 .tar.gz/.tgz——归档自动解压,同步后删临时;
#              输出文件级变更明细:新增/更新、镜像删除、未变化)
#   <源目录>   本地待同步目录(无默认)
#   <root@板IP> SSH 目标(用户/密码均为 root)
#   <设备>     板上目标 SD 块设备,可写设备名或路径(如 mmcblk0 / /dev/mmcblk0)
# 必须显式指定:源目录、板 IP、目标设备,三者皆无默认。
# 会上板校验 <设备> 是否存在且为可移动介质(removable=1,确为 SD 卡)后才操作。
do_deploy() {
  local mode="" src="" dst="" dev="" ip=""
  # 解析选项(放在最前)
  while [ $# -gt 0 ]; do
    case "$1" in
      -b|--boot) mode=boot; shift ;;
      -f|--fs)   mode=fs;   shift ;;
      *) break ;;
    esac
  done
  src="${1:-}"; dst="${2:-}"; dev="${3:-}"
  # ---- 校验(均显式,无默认) ----
  if [ -z "$mode" ]; then
    echo "[错误] 必须用 -b/--boot 或 -f/--fs 二选一指定同步内容(boot 模块 / 文件系统)" >&2; return 1
  fi
  { [ -n "$src" ] && [ -n "$dst" ] && [ -n "$dev" ]; } || \
    { echo "[错误] 用法: flash-sd.sh deploy -b|-f <源目录> <root@板IP> <设备>" >&2; return 1; }
  if [ "$mode" = fs ]; then
    [ -d "$src" ] || [ -f "$src" ] || { echo "[错误] 文件系统源不存在(应为目录或 .tar.gz/.tgz 归档): $src" >&2; return 1; }
  else
    [ -d "$src" ] || { echo "[错误] 源目录不存在: $src" >&2; return 1; }
  fi
  # 提取 IP(允许 root@1.2.3.4 或 1.2.3.4)
  case "$dst" in
    root@*|user@*) ip="${dst#*@}" ;;
    *)             ip="$dst" ;;
  esac
  # 设备名规整:mmcblk0 → /dev/mmcblk0
  case "$dev" in
    /dev/*) remote_dev="$dev" ;;
    *)      remote_dev="/dev/$dev" ;;
  esac
  ensure_tools   # 确保 sshpass/rsync 就绪

  local SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8"
  echo ">> 连接 root@${ip} (密码 root) ..."
  if ! sshpass -p root ssh $SSHOPTS "root@$ip" 'echo ok' >/dev/null 2>&1; then
    echo "[错误] 无法 SSH 到 ${ip}(确认板已联网、sshd 已启动、密码为 root)" >&2; return 1
  fi

  # ---- 校验目标设备:确实存在 & 是 SD 卡而非内嵌存储 ----
  # WSL/USB 读卡器/可插拔卡一般设 removable=1;但板载 SDIO 槽(本 Zynq 即如此)的
  # MMC/SD 控制器驱动不设置 removable(恒 0),故退化为用 device/type 区分 SD 卡 vs 内嵌 eMMC。
  local bname dtype rem
  bname="$(basename "$remote_dev")"
  rem=$(sshpass -p root ssh $SSHOPTS "root@$ip" \
    "[ -e '$remote_dev' ] && cat /sys/block/$bname/removable 2>/dev/null" 2>/dev/null | head -1 || true)
  if [ -z "$rem" ]; then
    echo "[错误] 板上不存在目标设备 $remote_dev,或读取 removable 失败" >&2; return 1
  fi
  if [ "$rem" = "1" ]; then
    echo ">> 目标设备 $remote_dev 已确认为可移动 SD 介质 ✅"
  else
    dtype=$(sshpass -p root ssh $SSHOPTS "root@$ip" \
      "cat /sys/block/$bname/device/type 2>/dev/null" 2>/dev/null | head -1 || true)
    case "$dtype" in
      "" ) echo "[错误] 无法读取 $remote_dev 的类型(removable=$rem 且 device/type 为空)" >&2; return 1 ;;
      SD*|SDIO )
        echo ">> 板上未提供 removable 标记(板载 SD 槽常见,=0),按 device/type=$dtype 判定 $remote_dev 为 SD 卡 ✅" ;;
      * )
        echo "[错误] $remote_dev 不是 SD 介质(device/type=$dtype,疑似内嵌 eMMC/本地盘),拒绝操作。板上 mmc 设备:"
        sshpass -p root ssh $SSHOPTS "root@$ip" \
          "for d in /sys/block/mmcblk*/device/type; do b=\$(basename \$(dirname \$(dirname \"\$d\"))); t=\$(cat \"\$d\" 2>/dev/null); echo \"  /dev/\$b  type=\$t\"; done" 2>/dev/null || true
        return 1 ;;
    esac
  fi

  # 目标是 boot(FAT) 还是 rootfs(ext4)
  local tgt_fstype
  [ "$mode" = boot ] && tgt_fstype=vfat || tgt_fstype=ext4

  # 该设备下找目标 fstype 分区。本板缺 lsblk/blkid/findmnt,但 /proc/mounts 可用
  # (其列为: 设备 挂载点 fstype 选项 0 0),且系统已把 SD 分区自动挂载;据此解析。
  local dev mountpoint=""
  read -r dev mountpoint < <(sshpass -p root ssh $SSHOPTS "root@$ip" \
    "awk -v d='$remote_dev' -v t='$tgt_fstype' '\$1 ~ (\"^\" d \"p\") && \$3==t {print \$1, \$2; exit}' /proc/mounts" 2>/dev/null) || true
  if [ -z "$dev" ] || [ -z "$mountpoint" ]; then
    # 目标分区未挂载:尝试自动挂载(本板约定 boot=p1、fs=p2)到 /mnt/deploy-<mode>,再校验。
    local pnum=1; [ "$mode" = fs ] && pnum=2
    local rdev="${remote_dev#/dev/}"
    dev="/dev/${rdev}p${pnum}"
    mountpoint="/mnt/deploy-${mode}-${rdev}p${pnum}"
    echo ">> 分区未挂载,尝试自动挂载 ${dev} → ${mountpoint} ..."
    if ! sshpass -p root ssh $SSHOPTS "root@$ip" \
        "mkdir -p '$mountpoint' && mount '$dev' '$mountpoint' >/dev/null 2>&1 && grep -q '$dev $mountpoint ' /proc/mounts" 2>/dev/null; then
      echo "[错误] 自动挂载 ${dev} 失败(确认分区已建;或先手动 mount 再重试)" >&2; return 1
    fi
    echo ">> 已自动挂载,后续同步结束会 umount"
  fi
  echo ">> 目标分区: $dev  挂载点: $mountpoint  ($tgt_fstype)"

  echo ">> 同步 $src → 板上 ${mountpoint}/ ..."
  local rc=0
  if [ "$mode" = boot ]; then
    # boot(FAT):用 scp(板上为 dropbear,原生支持 scp、两端都无需 rsync);按名过滤非启动项;
    # 只增不删,避免误删 boot.scr。scp -p 保留时间戳。
    local f bn
    for f in "$src"/*; do
      [ -e "$f" ] || continue
      bn="$(basename "$f")"
      case "$bn" in
        rootfs*|pxelinux*|vmlinux*|*.cpio*|*.jffs2|*.ext4|*.manifest|config|*.elf)
          echo "  (跳过 $bn)"; continue ;;
      esac
      sshpass -p root scp $SSHOPTS -p "$f" "root@$ip:${mountpoint}/" >/dev/null || { echo "[!] 拷贝失败: $f" >&2; rc=1; }
    done
  else
    # fs(ext4):增量+镜像删除需板上 rsync(工程交叉静态版,板上自举;--numeric-ids 免静态 rsync
    # 在无 NSS 库的板上做 uid→名解析致段错误)。源可为目录,也为 rootfs 归档(.tar.gz/.tgz/...):
    # 若是归档则自动解压到临时目录,同步完成后删除。
    local srcdir="$src" tarsrc=""
    case "$src" in
      *.tar.gz|*.tgz|*.tar)
        tarsrc="$(mktemp -d /tmp/deploy-fs.XXXXXX)"
        if ! tar -xzf "$src" -C "$tarsrc" >/dev/null 2>&1; then
          echo "[错误] 解压源失败: $src" >&2; rm -rf "$tarsrc"; return 1
        fi
        echo ">> 源 $(basename "$src") 是归档,已解压到临时目录 $tarsrc(同步后自动清理)"
        srcdir="$tarsrc"
        if ( cd "$tarsrc" && [ $(ls -A | wc -l) -eq 1 ] ); then
          local only; only="$(cd "$tarsrc" && echo ./*)"; [ -d "$only" ] && srcdir="$only"
        fi
        ;;
    esac
    if sshpass -p root ssh $SSHOPTS "root@$ip" \
        'if ! command -v rsync >/dev/null 2>&1; then for m in $(grep " vfat " /proc/mounts | cut -d" " -f2); do if [ -x "$m/tools/rsync" ]; then cp "$m/tools/rsync" /usr/bin/rsync; chmod 755 /usr/bin/rsync; echo ">> 已从 $m/tools/rsync 拉起板上 rsync"; break; fi; done; fi; command -v rsync' \
        >/dev/null; then
      local rlog; rlog="$(mktemp /tmp/deploy-rsync.XXXXXX)"
      echo ">> 同步 ${srcdir}/ → 板上 ${mountpoint}/ ..."
      if sshpass -p root rsync -i -a --delete --delete-during --numeric-ids \
          -e "sshpass -p root ssh $SSHOPTS" \
          "${srcdir}/" "root@$ip:${mountpoint}/" >"$rlog" 2>&1; then
        fs_change_report "$rlog" "$srcdir"
      else
        echo "[!] rsync 同步出错,最近输出:" >&2
        tail -30 "$rlog" >&2
        rc=1
      fi
      rm -f "$rlog"
    else
      echo "[错误] 板上无 rsync 且自举失败(boot 分区未挂载,或其 tools/rsync 副本缺失)。" >&2
      echo "        mount -t vfat /dev/${remote_dev}p1 /mnt 后重试;或经 utils 把静态 rsync 放 boot 的 tools/。" >&2
      rc=1
    fi
    { [ -n "$tarsrc" ] && rm -rf "$tarsrc"; } || true
  fi
  sshpass -p root ssh $SSHOPTS "root@$ip" "sync; umount '$mountpoint' 2>/dev/null || true" >/dev/null 2>&1
  if [ $rc -eq 0 ]; then echo ">> deploy($mode) 完成。拔电/reboot 后生效。"; else echo "[!] 同步出错(退出码 $rc)"; return $rc; fi
}
# ---- 主入口 ----------------------------------------------------------------
CMD="${1:-}"
if [ -z "$CMD" ]; then usage; fi            # 无子命令 → 打印帮助
shift || true                                # 去掉 CMD,剩余参数交给子命令
case "$CMD" in
  list|detect) detect ;;
  release)     release ;;
  part)        DEV="$(pick_dev)" || exit 1; ensure_tools; do_part "$DEV" ;;
  mkfs|format) DEV="$(pick_dev)" || exit 1; ensure_tools; do_mkfs "$DEV" ;;
  flash)       SRCARG="${1:-}"; DEV="$(pick_dev)" || exit 1; S="$(resolve_src "$SRCARG")" || exit 1; ensure_tools
               if [ ! -b "${DEV}1" ]; then echo ">> ${DEV} 尚未分区,先分区..."; do_part "$DEV"; fi
               do_flash "$DEV" "$S" ;;
  deploy)      do_deploy "$@" ;;           # deploy -b|-f <源> <root@IP>,参数原样透传
  -h|--help|help) usage ;;
  *) echo "未知子命令: $CMD"; usage ;;
esac
