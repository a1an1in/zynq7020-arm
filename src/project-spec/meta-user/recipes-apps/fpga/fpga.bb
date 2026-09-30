#
# This is the fpga application recipe (register read/write tool.
#   read : fpga read  ADDR [WIDTH]
#   write: fpga write ADDR VALUE [WIDTH]
#   addresses may be absolute (-a) or offsets relative to -b base (default 0x50000000).
#
SUMMARY = "fpga register read/write tool (absolute & offset addressing)"
SECTION = "PETALINUX/apps"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
SRC_URI = "file://fpga.c \
           file://Makefile \
          "
S = "${WORKDIR}"
INHIBIT_PACKAGE_STRIP = "1"

do_compile() {
        oe_runmake
}
do_install() {
        install -d ${D}${bindir}
        install -m 0755 ${S}/fpga ${D}${bindir}
}