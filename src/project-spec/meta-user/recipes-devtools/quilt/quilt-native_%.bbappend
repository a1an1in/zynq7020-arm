# Workaround: quilt-native 首次构建的 autotools 时间戳竞态
# ---------------------------------------------------------------------------
# 现象: do_compile 报 "Please run ./configure" / "Makefile:284: Makefile Error 1"
#       并 fail 于 quilt 自身的自毁规则:
#           Makefile : Makefile.in configure
#                   @echo "Please run ./configure"
#                   @false
# 原因: do_configure 由 config.status 生成 Makefile 后, autotools 又把
#       Makefile.in 的时间戳刷新得比 Makefile 还新, 于是 do_compile 的
#       make 判定 "Makefile 过期", 触发上面那条假失败规则。
# 修复: 在 do_compile 前 touch 生成的 Makefile, 使其时间戳最新, 让 make
#       认为无需重新生成配置。对功能无任何影响, 仅规避该竞态。
do_compile_prepend() {
    touch ${B}/Makefile ${B}/config.status 2>/dev/null || true
}