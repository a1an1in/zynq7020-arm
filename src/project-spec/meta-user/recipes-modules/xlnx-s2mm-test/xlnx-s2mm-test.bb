#
# Xilinx AXI DMA S2MM dmaengine test driver (kernel module).
#
SUMMARY = "Xilinx AXI DMA S2MM dmaengine test driver"
DESCRIPTION = "Platform driver that requests the AXI-DMA S2MM channel and \
exposes /dev/xlnx-s2mm (ioctl trigger + read-back) for S2MM capture tests."
SECTION = "PETALINUX/modules"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://Makefile \
           file://xlnx_s2mm_test.c \
          "
S = "${WORKDIR}"

inherit module

# Point `module` bbclass at the staged (configured) kernel it was built against.
EXTRA_OEMAKE += "KERNEL_SRC=${STAGING_KERNEL_DIR}"

# Kernel module install name (used by the module class and for IMAGE_INSTALL).
RDEPENDS_${PN} += "kernel-module-xlnx-s2mm-test"
RPROVIDES_${PN} += "kernel-module-xlnx-s2mm-test"

# Auto-load at boot once the device-tree node (xlnx,s2mm-test) is present.
KERNEL_MODULE_AUTOLOAD += "xlnx_s2mm_test"