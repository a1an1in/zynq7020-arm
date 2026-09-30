FILESEXTRAPATHS_prepend := "${THISDIR}/u-boot-zynq-scr:"
# This recipe has no source dir (SRC_URI is all file:// dumped into WORKDIR),
# so quilt must apply the patch in WORKDIR. Otherwise do_patch fails with
# "can't find file to patch" for boot.cmd.generic.
S = "${WORKDIR}"

# Fix U-Boot distro boot.scr: quote $uenvcmd.
#
# Root cause: the upstream boot.cmd.generic template tests the uEnv.txt
# `uenvcmd` variable UNQUOTED (`if test -n $uenvcmd; then`). Because uenvcmd
# is a compound command containing spaces/`;`, hush re-splits it, `test -n`
# gets extra args and reports a usage error, so `run uenvcmd` (which loads and
# fpga-configures system.bit) is silently skipped and the boot falls through to
# the FIT image. The quote fix is harmless: only the empty-check for uenvcmd
# changes.
SRC_URI += "file://0001-fix-unquoted-uenvcmd.patch"