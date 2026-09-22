#!/usr/bin/expect -f
# 自动应答 PetaLinux 2021.1 安装器交互（无头、无人值守）。
# 用法：auto-install.sh <installer.run> <install_dir>
# 必须用普通用户（非 root）运行 —— PetaLinux 安装器拒绝 root。
#
# PetaLinux 2021.1 交互序列（UI 为 ncurses 对话框，文本可预期）：
#   1. "Press Enter to display the license agreements"    -> 回车
#   2. 许可正文，按 q 退出，随后若干 "Do you accept ...? (y/N)" -> 逐个 y
#   3. "Enter the Installation Directory"                  -> 输入路径（或默认）
#   4. 确认并开始安装
# 不同小版本措辞略有差异，故用宽松匹配 + 循环兜底，避免偶发卡死。

set timeout 1200
set installer [lindex $argv 0]
set install_dir [lindex $argv 1]

# 诊断：设置 SAP_EXP_LOG=/路径 时记录 expect 与安装器的完整字节交互
if {[info exists env(SAP_EXP_LOG)] && $env(SAP_EXP_LOG) ne ""} {
    exp_internal -f $env(SAP_EXP_LOG) 1
    log_user 1
}

proc bail {msg} {
    puts "AUTO_INSTALL_ERR: $msg"
    exit 1
}

# 让安装器用 cat 而非交互式 less 显示许可协议：
# less 是交互分页器，会停下等按键、且不一次输出全文，导致 expect 收不到触发词而卡死。
# 设 PAGER=cat 后许可全文直接输出，安装器立即继续，expect 可继续匹配后续提示。
set env(PAGER) cat
set env(LESS) ""

# 进度心跳：安装(解压)阶段周期性打印目标目录已写入体积，
# 让无人值守运行也能实时看到进度，而不是在 wait 里静默 30~60 分钟。
# PetaLinux 安装本质就是解压一堆文件到目标目录，du 体积即真实进度信号。
proc heartbeat {dir last_qty_var} {
    upvar 1 $last_qty_var last
    set stamp [clock format [clock seconds] -format "%H:%M:%S"]
    if {[catch {exec du -sk "$dir"} out]} {
        puts "  \[$stamp\] 目标目录尚未就绪"
        return
    }
    if {[regexp {^(\d+)\s+} $out -> kb]} {
        set grow ""
        if {$last > 0} {
            set d [expr {round(($kb - $last) / 1024.0)}]
            if {$d > 0} { set grow " (+${d} MB)" }
        }
        puts "  \[$stamp\] 已写入 ${kb} KB${grow}"
        set last $kb
    }
}

spawn $installer --dir $install_dir

# 阶段1：等待并进入许可正文（送一次回车即可，勿在循环里重复匹配）
expect {
    "Press Enter to display the license" { send "\r" }
    timeout { bail "无法定位许可提示（start）" }
}

# 阶段2：循环驱动安装器交互 + 安装进度心跳。
#  - 许可/目录等提示 -> 自动应答（宽松匹配）
#  - 进入安装后：每 timeout 秒打印一次目标目录体积（真实进度），不再静默等待
#  - 默认干净输出（只留本脚本关键行 + 进度心跳）；设 SAP_EXP_TTY=1 可看安装器原始流
if {[info exists env(SAP_EXP_TTY)] && $env(SAP_EXP_TTY) eq "1"} {
    log_user 1
} else {
    log_user 0
}
set done 0
set in_install 0
set last_kb 0
set timeout 60
while {!$done} {
    expect {
        -re {press\s*['\"]?q['\"]?\s*to\s*close} { puts "  \[accept\] 关闭许可阅读器"; send "q"; exp_continue }
        "(press RETURN)" { send "\r"; exp_continue }
-re {--More--|--\([0-9]+%\)--} { send " "; exp_continue }
        -re {\(END\)} { send "q"; exp_continue }
        -re {(Do you (accept|agree)).*(y/N)} { puts "  \[accept\] 接受许可"; send "y\r"; exp_continue }
        -re {Installation Directory|install directory|Enter the target directory} {
            puts "  \[config\] 安装目录 -> $install_dir"; send "$install_dir\r"; exp_continue
        }
        -re {directory exists.*[(](Y|y).*[/]n[)]|directory exists.*?[Yy]/n} { puts "  \[config\] 目录已存在,确认覆盖"; send "y\r"; exp_continue }
        -re {directory\s*\(.*\)\s*(already|exists).*y} { puts "  \[config\] 目录存在,确认"; send "y\r"; exp_continue }
        -re {Extracting|Installing} {
            if {!$in_install} { puts "  \[install\] 开始安装(解压) —— 以下为进度心跳" }
            set in_install 1; exp_continue
        }
        eof { set done 1 }
        timeout {
            if {$in_install} {
                heartbeat $install_dir last_kb
            } else {
                puts "  \[wait\] 等待安装器响应……"
            }
            exp_continue
        }
    }
}

catch wait result
set rc [lindex $result 3]
if {$rc != 0} {
    bail "安装器返回码 $rc"
}
if {$last_kb > 0} {
    puts "  \[install\] 完成: 目标目录 ${last_kb} KB"
}
puts "AUTO_INSTALL_OK"
exit 0