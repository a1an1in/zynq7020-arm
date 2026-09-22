# petalinux-zynq7020

基于 **Docker** 的 PetaLinux **2021.1** 构建环境,面向 **Zynq-7020**(XC7Z020, 32 位 ARM Cortex-A9)。

## 为什么用 Docker

- 编译环境可移植、可切换 —— 换机/换环境只需一个镜像 + 一份 SDK 卷。
- 目标板固定为 Zynq-7020(32 位),离线包用 `sstate_arm_2021.1.tar.gz`(不是 aarch64)。

## 目录结构

```
petalinux-zynq7020/
├── docker/
│   ├── Dockerfile            # OS(Ubuntu 18.04)+PetaLinux 依赖,不含 SDK
│   └── scripts/
│       └── auto-install.sh   # expect 自动应答安装器许可(无人值守)
├── sdk/                      # 唯一持久化卷(挂到容器 /opt/xilinx)
│   ├── petalinux/            #   ← SDK 本体(安装器写入 /opt/xilinx/petalinux)
│   ├── downloads/            #   ← 离线源码 pre-mirror
│   └── sstate/arm/           #   ← 32 位 sstate 缓存
├── zynq7020-arm/              # petalinux 工程(arm,容器内 /work/zynq7020-arm)
└── utils/
    ├── build-image.sh        # 构建 docker 镜像
    ├── install-sdk.sh        # 用 auto-install.sh 装 SDK 到 sdk/卷
    ├── unpack-offline.sh     # 解压 downloads/sstate 离线包
    └── devops.sh                # 进入容器做工程开发(日常入口)
```

`docker/patches/` 预留放需要的补丁(当前版本未用)。

## 文档

本 README 是总纲,模块化、细节化文档放在 `doc/` 下:

- [`doc/环境与编译.md`](doc/环境与编译.md) —— 环境搭建(Docker 镜像 / SDK / 离线包 / 进容器)+ 工程编译与打包
- 业务模块说明(如 `gpio-demo`、`peekpoke`)规划中,后续随模块文档补进 `doc/`

## 使用流程

完整的环境搭建与编译步骤都在 [`doc/环境与编译.md`](doc/环境与编译.md),这里只给速览:

```bash
./utils/build-image.sh      # 1. 构建 Docker 镜像(一次性,只装 OS+依赖)
./utils/install-sdk.sh      # 2. 安装 PetaLinux SDK 到 sdk/(前置:已下载安装器与离线包)
./utils/unpack-offline.sh   # 3. 解压 downloads/sstate 离线包(可选但推荐,离线编译用)
./utils/devops.sh              # 4. 进容器 → source settings.sh → cd zynq7020-arm → petalinux-build
```

> 前置下载 - `petalinux-v2021.1-final-installer.run`、`downloads_2021.1_update1.tar.gz`、
> `sstate_arm_2021.1.tar.gz`(32 位,Zynq-7000 用这个)。详细参数与坑见
> [`doc/环境与编译.md`](doc/环境与编译.md)。

## 体积与换机

- SDK 卷 `sdk/` 是唯一需要持久保留的东西;换机时把它整体拷走 + 重建镜像即可。
- petalinux 工程放在仓库根目录 `zynq7020-arm/`(容器内 `/work/zynq7020-arm`),不进 sdk 卷,方便随代码一起管理。
- 离线包比较大,已解压后原 `.tar.gz` 可删除以省空间(见米联客手册第 5.2 节)。

## 说明与坑

- 基镜像用 Ubuntu 18.04(PetaLinux 2021.1 官方支持),20.04 缺 `libncurses5/libtinfo5`,易踩坑。
- Zynq-7000 是 32 位:模板用 `--template zynq`,sstate 用 `arm`,不是 zynqMP/aarch64。
- PetaLinux 安装器**拒绝 root 运行**,镜像内以 `plsdk` 用户(与宿主 UID/GID 对齐)执行。
- 更完整的坑提示见 [`doc/环境与编译.md`](doc/环境与编译.md)。