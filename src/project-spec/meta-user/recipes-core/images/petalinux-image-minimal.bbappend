# ===== PS_LED8 (PS_MIO51 / gpio957) 开机自动熄灭 =====
# 构建 rootfs 时在 /etc/rc5.d/ 生成 S99psled-off:进入运行级5时 sysvinit 必然遍历
# rc5.d/S*(板子 SSH 靠 S10dropbear 起来即为证),把 MIO51 配成输出并拉低,否则 FSBL
# 上电把 LED8 拉高会常亮。不做 inittab(实测 psled:5:wait 开机不触发)。仅改这里。
# 注意:postprocess 的 shell 函数必须定义在 image 的 .bbappend(Base .conf 不解析函数,
# 直接写会如 petalinuxbsp.conf 那样报 ParseError: unparsed line),故放本文件。
ROOTFS_POSTPROCESS_COMMAND += "ps_led_off_cfg ;"

ps_led_off_cfg() {
	if [ -d "${IMAGE_ROOTFS}/etc/rc5.d" ]; then
		{
			echo '#!/bin/sh'
			echo '# PS_LED8 = PS_MIO51 = gpio957: 开机熄灭(runlevel5, gpio 已就绪)'
			echo '[ -d /sys/class/gpio ] || exit 0'
			echo 'echo 957 > /sys/class/gpio/export 2>/dev/null'
			echo 'echo out > /sys/class/gpio/gpio957/direction 2>/dev/null'
			echo 'echo 0   > /sys/class/gpio/gpio957/value   2>/dev/null'
			echo 'exit 0'
		} > "${IMAGE_ROOTFS}/etc/rc5.d/S99psled-off"
		chmod 0755 "${IMAGE_ROOTFS}/etc/rc5.d/S99psled-off"
	fi
}