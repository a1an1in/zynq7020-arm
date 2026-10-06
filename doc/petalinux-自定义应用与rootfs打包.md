# PetaLinux 自定义应用(App)与打包进文件系统

> 适用：PetaLinux 2021.1 / Zynq-7020（32 位）。本文以本工程 **fpga**（寄存器读写工具）为完整示例，
> 并附带 s2mm 相关的 app + 内核模块对照。文中路径默认工程根为 `/work/src`（即仓库的 `src/`），
> 交互命令假设已在容器内并 `source /opt/xilinx/petalinux/settings.sh`（见《环境与编译.md》）。

---

## 一、总体概念

PetaLinux 自定义的应用/驱动分两种形态，都放在 **`meta-user`** 自定义层里：

| 形态 | 位置 | 产物示例 |
|---|---|---|
| 用户态应用 app | `meta-user/recipes-apps/<名>/` | `/usr/bin/<名>` 可执行文件 |
| 内核模块 kernel-module | `meta-user/recipes-modules/<名>/` | `/lib/modules/<内核>/extra/<名>.ko` |

一个 `.bb` recipe 描述「源码从哪来、怎么编译、装到哪」，PetaLinux/Yocto 据此把产物
作为 Linux 包（ipk/rpm）打进 rootfs。

**重点结论（先记住）**：把 app “装进文件系统”的标准做法是 **rootfs 标准注入**，
只改两个配置文件、再跑一次配置同步 + 重建即可，**不需要写任何 bbappend**。

---

## 二、创建 App：目录结构与 recipe

### 1. 目录结构

```
meta-user/recipes-apps/<app名>/
├── <app名>.bb          # recipe：构建与安装规则
└── files/
    ├── <源码>.c
    └── Makefile
```

`files/` 里的文件会被 `SRC_URI = "file://..."` 拉进工作目录即可用。

### 2. recipe 全字段注释（以 fpga 为例）

文件：`meta-user/recipes-apps/fpga/fpga.bb`

```bitbake
# 一段描述（会显示在 rootfs 菜单 help 里）
SUMMARY = "fpga register read/write tool (absolute & offset addressing)"

# SECTION 控制它在 rootfs 菜单里的分组(PETALINUX/apps -> "apps" 菜单)
SECTION = "PETALINUX/apps"

# 开源许可与它的检验和(MIT 直接引用 meta-common 里的模板)
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# 源码/构建产物清单：files/ 下的文件
SRC_URI = "file://fpga.c \
           file://Makefile \
          "

# 工作目录=解包的源目录
S = "${WORKDIR}"
INHIBIT_PACKAGE_STRIP = "1"

do_compile() {
    oe_runmake
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${S}/fpga ${D}${bindir}
}
```

`files/Makefile`（交叉编译变量 `CC/CFLAGS/LDFLAGS` 由 Yocto 自动传入）：

```make
TARGET = fpga
OBJS   = fpga.o

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $(OBJS) $(LDLIBS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	-rm -f $(TARGET) *.o *.elf *.gdb
```

要点：

- **不要自己写死交叉工具链路径**，永远用 `$(CC)` / `oe_runmake`，让 Yocto 注入。
- `do_install` 决定最终装进 rootfs 的位置；`.bb` 的软件包名 = `<名>`（`fpga`），
  最终可执行在 `/usr/bin/fpga`。
- 若缺 `LIC_FILES_CHKSUM`，bitbake 会直接报错拒绝打包。

### 3.（可选）内核模块：recipes-modules

驱动类放 `meta-user/recipes-modules/<名>/`，同样 `files/` 放源码，`do_install` 里把
`.ko` 装到 `lib/modules/.../extra/`，并（可选）加一个 `/etc/modules-load.d/<名>.conf`
实现开机加载。本工程的 **xlnx-s2mm-test**（AXI-DMA S2MM 测试驱动）就是这种形态，
安装后 rootfs 里出现：

- `/lib/modules/<内核>/extra/xlnx_s2mm_test.ko`
- `/etc/modules-load.d/xlnx_s2mm_test.conf`

---

## 三、把 App 打包进文件系统：标准三步

前提：app 的 recipe 已存在于 `meta-user`。以 fpga 为例。

### 第 1 步：注册到 rootfs 菜单清单

文件：`meta-user/conf/user-rootfsconfig`（每行一个 `CONFIG_<包名>`，不要带 `=y`）：

```text
CONFIG_gpio-demo
CONFIG_peekpoke
CONFIG_s2mm-user
CONFIG_xlnx-s2mm-test
CONFIG_fpga          # 新增一行
```

这决定它出现在 `rootfs` 菜单的哪个入口。

### 第 2 步：启用（=y）+ 触发同步

在**工程根**执行（首次可用 `petalinux-config -c rootfs` 交互勾选；非交互可直接 silentconfig）：

```bash
./utils/devops.sh petalinux-config -c rootfs --silentconfig
```

silentconfig 会做两件事：

1. 把 `CONFIG_<包名>=y` 写进 `project-spec/configs/rootfs_config`（菜单状态持久化）；
2. **关键**：把这些 `=y` 的包重新生成到 `build/conf/plnxtool.conf` 的
   `IMAGE_INSTALL_pn-petalinux-image-minimal = "..."` 清单里（真正决定镜像装什么）。

本工程 fpga 同步后，`build/conf/plnxtool.conf` 里会新增一行：

```text
IMAGE_INSTALL_pn-petalinux-image-minimal = "\
    ...
    s2mm-user \
    fpga \                       # ← 出现即说明已纳入镜像
    "
```

### 第 3 步：重建镜像

```bash
./utils/devops.sh petalinux-build -c petalinux-image-minimal
```

产物在 `images/linux/`：`rootfs.tar.gz`、`rootfs.manifest` 等。

---

## 四、⚠️ 最容易踩的坑：手改 rootfs_config 不会生效

**不要**只手动往 `rootfs_config` 写 `CONFIG_fpga=y` 就完事——那不会让 app 进镜像。

原因：`rootfs_config` 只是**菜单配置**；bitbake 真正读的是

```
build/conf/plnxtool.conf   （被 build/conf/local.conf 的 include 引入）
```

`IMAGE_INSTALL_pn-petalinux-image-minimal = "..."` 那一整段，是由
`petalinux-config -c rootfs`（内部执行 `python3 build/misc/rootfs_config/rootfs_config.py
--update_cfg ...`）从 `rootfs_config` **重新生成**的。

验证你是否走对：跑 silentconfig 后 grep `plnxtool.conf`，模块包/应用包的名字
出现在 `IMAGE_INSTALL_pn-...` 段里，才算真正生效：

```bash
grep -nE 's2mm|fpga' src/build/conf/plnxtool.conf
```

> 判断依据（本次实测）：加完 `rootfs_config` 里 `CONFIG_fpga=y` 后先 `bitbake -e petalinux-image-minimal
> | grep IMAGE_INSTALL`，发现完全没有新包；跑完 silentconfig 后 `IMAGE_INSTALL`/
> `PACKAGE_INSTALL` 展开里立刻出现 `s2mm-user`、`fpga`。

---

## 五、验证打包结果

### 1. 看 manifest（记录了每个装进去的包）

```bash
grep -iE '^fpga ' src/images/linux/rootfs.manifest        # fpga 相关包行
# 期望:
#   fpga     cortexa9t2hf_neon 1.0
#   fpga-lic cortexa9t2hf_neon 1.0
```

### 2. 直接看 rootfs 里的文件

```bash
tar -tzf src/images/linux/rootfs.tar.gz | grep -E '/usr/bin/fpga$'
# 期望: ./usr/bin/fpga
```

> 系统自带的 `fpgautil`、`fpga-manager-script` 是 Xilinx FPGA-manager 工具，并非我们的
> `fpga` app，注意区分。

---

## 六、本工程已有示例对照

| app | recipe | 形态 | 产物 |
|---|---|---|---|
| fpga | `recipes-apps/fpga/fpga.bb` | 用户 app | `/usr/bin/fpga` |
| s2mm-user | `recipes-apps/s2mm-user/s2mm-user.bb` | 用户 app | `/usr/bin/s2mm-user` |
| xlnx-s2mm-test | `recipes-modules/xlnx-s2mm-test/xlnx-s2mm-test.bb` | 内核模块 | `.ko` + `/etc/modules-load.d/xlnx_s2mm_test.conf` |
| gpio-demo / peekpoke | `recipes-apps/` 下同名 | 用户 app | 未注册，未打包 |

三者都已通过**同一套标准注入**（`user-rootfsconfig` 注册 + silentconfig 同步 + build）打进 rootfs。

---

## 七、FAQ

**Q：新建 app 后要重跑 silentconfig 吗？**
A：每次新增/变更 `user-rootfsconfig` 里的包，或想改 rootfs 勾选项，都要重跑一次
`petalinux-config -c rootfs --silentconfig` 让 `plnxtool.conf` 同步，再 build。

**Q：只想临时往镜像塞东西，不想走这套流程行吗？**
A：可以，但属于“绕过机制”：在 `meta-user` 写 `recipes-core/images/xxx.bbappend` 里
`IMAGE_INSTALL += "<包>"`。缺点是绕过了 rootfs 菜单、不便于配置化复用，本工程已弃用该方式,
统一走标准注入。

**Q：包重新编译不过，如何只重建这个包？**
A：`./utils/devops.sh petalinux-build -c <包名>`；若改了 recipe 想强制重编：
`./utils/devops.sh petalinux-build -x cleanall -c <包名>` 后再 build。

**Q：打包后的可执行文件在板子哪个位置？**
A：按 `do_install` 决定；本工程示例都装到 `${bindir}`（`/usr/bin/<名>`）。