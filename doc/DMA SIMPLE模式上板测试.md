# Zynq-7020 AXI DMA — SIMPLE 模式上板测试文档

- **目标 IP**：Xilinx AXI DMA（`axi_dma_0`），**SIMPLE 模式**（`c_include_sg=0`，非 SG）
- **数据通路**：PL 假数据源 `aurora_dma_src`（AXI4-Stream 帧发生器）→ `S_AXIS_S2MM`
  → `axi_dma_0` → `hp0_axi_periph` → PS `S_AXI_HP0`(DDR 0x0–0x40000000)
- **控制通路**：PS `M_AXI_GP0` 直连 BD 内部 M01 → `axi_dma_0`（寄存器 0x50000000）
  + 假源经 `M00_AXI` + 单 AXI4-Lite 窗 `0x40000000`（`DMA` 块偏址 0x30）

本版已把 BD 源 `projects/aurora/bd/system.tcl` 固化为 `CONFIG.c_include_sg {0}`，
DT 中 dma 节点不应再含 `xlnx,include-sg`，`compatible` 应为 `xlnx,axi-dma-7.1`
（SG 时为 `xlnx,axi-vdma`）。

---

## 1. 环境

| 项 | 值 |
|----|----|
| 板卡 / FPGA | Zynq-7020，本次跑 `build/aurora.bit`（simple）|
| ARM 侧 | PetaLinux 5.10（xilinx-v2021.1）+ 对应 `system.xsa`（simple）重生成 device-tree |
| 板 IP / 账号 | `10.10.10.110` / `root:root`（dropbear）|
| 部署工具 | `zynq7020-arm/utils/flash-sd.sh`（`deploy` / `probe`）|
| 校验工具 | 板上 `busybox devmem`（读写 AXI 寄存器 / DDR）|
| 中断 | S2MM 完成中断 → GIC-61（`xilinx-dma-controller`）|

### 1.1 查看 FPGA 固件版本（先确认板上跑的是哪版）

查看当前运行 PL 的固件版本 = 读假源窗的 **VERSION** 寄存器 `0x40000000 + 0x04`（只读）：

```bash
# 板上 root 执行
busybox devmem 0x40000004 32   # 例: 读到 0x01000100 => 版本 1.0.1
```

版本编码 `[31:24]主 [23:16]次 [15:8]修订 [7:0]保留(=0)`：

| 读值        | 版本   |
|-------------|--------|
| `0x01000100` | 1.0.1 |
| `0x01000700` | 1.0.7 |

> ⚠ 注意：该**读值来自 `AURORA_VERSION` 常量**（`projects/aurora/src/aurora_addr_def.vh:8`），
> 它由 `tools/gen_regs.py` 从 `aurora_regs.json` 的 `version` 字段**自动生成**（唯一真源），
> `aurora_system_regs.v` 的版本寄存器读此宏。改版本号 = 改 json → 跑 `gen_regs.py` → **重编 bit** 才生效，
> .vh / .v / .h 已不再手工双写、不会脱钩。
> 因此判断板上固件版本，一律以板上 `devmem` 读到的**实际值**为准，
> 不要用 json 里 `version` 去猜（json 只是真源；板上要等重编后才是新值）。

---

## 2. 前置条件与部署

1. **FPGA**：确保 `bd/system.tcl` 为 `c_include_sg {0}`，构建产出 simple 位流 + XSA：
   ```bash
   python scripts/fpga.py build --top aurora        # 产出 build/aurora.xsa(含 bit)
   ```
2. **ARM**：用 simple 的 XSA 重生成 device-tree 并构建镜像（`--get-hw-description=<.../build/aurora.xsa>`），
   使 DT 不含 SG 属性。
3. **上板**（SD 卡现状复杂时用远程部署，二选一）：
   ```bash
   utils/flash-sd.sh deploy -b ./src/images/linux root@10.10.10.110 mmcblk0   # 仅换启动模块
   # 或整 SD 直接刷：utils/flash-sd.sh flash ./src/images/linux
   ```
4. 板入网后确认可达：`bash -lc "bash utils/flash-sd.sh probe root@10.10.10.110"`

---

## 3. 判据（通过标准）

| 编号 | 判据 |
|------|------|
| C1 | dma 节点 `xlnx,include-sg` **不存在**，`compatible = xlnx,axi-dma-7.1 ...` |
| C2 | `xilinx-vdma 50000000.dma: ... Probed!!`（SIMPLE/非 SG 路径正常 probe）|
| C3 | 触发一次搬运后 DDR 目标区出现期望数据（连续 `0x5AA5xxxx` 序列）|
| C4 | 使能 IOC 后，S2MM 完成中断触发：GIC-61 计数 **+1**，且 `DMASR` 置完成位 |

全部通过 ⇒ SIMPLE 模式链路（配置 / 搬运 / 中断）验收合格。

## 4. 寄存器验证（busybox devmem 手工读写 AXI 寄存器）

> §4 仅用 `busybox devmem` **手工读写 AXI 寄存器**做最底层验证，不依赖任何内核驱动：
> 读假源 VERSION → 直接写 DMA 的 `DMACR / DSTADDR / BTT` → 触发假源 `CTRL/RUN`，
> 以 DDR 数据 + `DMASR` + GIC-61 判定寄存器级链路（配置 → 搬运 → 完成中断）。
> 驱动/应用级（dmaengine + `/dev/xlnx-s2mm`）验证见 **§5 s2mm-user**。
> （远程 bash 的 `PATH` 常为空，`devmem`/`busybox` 不在 PATH，需用绝对路径
> `/bin/busybox devmem`。）

### 前置：先离线判 DTB 是否 SIMPLE（构建用料对不对）

跑下面的测试前，先离线确认 DTB 是 SIMPLE （`xlnx,include-sg` 缺失、`compatible=xlnx,axi-dma-7.1`），避免把 SG 的 BIT/DTB 拿来测。

**① 板上运行时（已封装 `utils/flash-sd.sh probe`）**
```bash
cat  /proc/device-tree/amba_pl/dma@50000000/compatible                    # 应含 xlnx,axi-dma-7.1
ls   /proc/device-tree/amba_pl/dma@50000000/xlnx,include-sg               # SIMPLE: No such file
dmesg | grep -i xilinx-vdma                                              # "...Probed!!"
```

**② 离线查 DTB（免上板 · 直接对构建产物）**
```bash
DTB=src/build/tmp/deploy/images/zynq-generic/zynq-generic-system.dtb
dtc -I dtb -O dts -o /tmp/dma.dts "$DTB" 2>/dev/null
echo "include-sg 次数(期望 0): $(grep -c 'xlnx,include-sg' /tmp/dma.dts)"
grep 'axi-vdma'   /tmp/dma.dts     # 空 = 非 SG
grep 'axi-dma-7.1' /tmp/dma.dts    # 有 = SIMPLE
```
快速版（不落盘）：`strings "$DTB" | grep -E 'include-sg|axi-vdma'`（SIMPLE 应无输出）；
`fdtdump "$DTB" | grep -E 'include-sg|axi-dma'`。


**③ DTS 源（petalinux 工程）**
```bash
grep -nE 'dma@50000000|include-sg|axi-dma-7.1|axi-vdma' \
  src/components/plnx_workspace/device-tree/device-tree/pl.dtsi
```

| 证据 | SIMPLE ✅ | SG ❌ |
|------|-----------|-------|
| 节点属性 `xlnx,include-sg` | 无 | 有 |
| `compatible` | `xlnx,axi-dma-7.1`… | `xlnx,axi-vdma-7.1`… |
| 驱动 probe | `xilinx-vdma … Probed` | （vdma）|


### 寄存器验证：硬写寄存器发起一次 S2MM 搬运 + 完成中断

> **⚠ 写序铁律（2026-10-06 实证定案）：`RS` 先、`BTT` 最后写。**
> datamover 由**最后一次写 `BTT`** 触发开始消费（拉 `tready`）。若**先写 `BTT` 再写 `RS`**，
> datamover 在 `RS` 时刻读到的 `BTT` 是 0（还没写）→ 认为“空” → **`tready` 恒为 0**，
> 于是假源握手卡死（`tvalid` 吐不出）、`BTT` 不减、永不产生 IOC / 完成中断。
> 本次（同配置）先 BTT 后 RS 数据不动；**改成 `RS(0x1001) → BTT` 立即一次跑通**：
> `DMASR=0x2`(完成) + `FRAMES[15:8]=1`(假源发完一帧) + DDR 出现 `0x5AA50000/0x1/0x2` +
> `grep -w 61` 计数 `0→1` —— 搬运(C3)与完成中断(C4)双通过。

> SIMPLE 无描述符环：**手动**写 S2MM `DMACR/ADDR/BTT` 即发起搬运。
> 直接在 `DMACR` **同时置 IOC_IrqEn(bit12)**：一帧搬完，既校验 DDR 数据(C3)，
> 又验证完成中断(C4)，一步跑通。

```bash
busybox devmem 0x40000004 32 

for i in $(seq 0 4 1020); do
    busybox devmem $((0x30000000 + i)) 32 0
done

# 板上执行（busybox devmem 基址数据宽 32bit）
echo before:; grep -w 61 /proc/interrupts
# DMA 目标地址（建议换一块干净内存，避免旧数据干扰）
busybox devmem 0x50000048 32 0x30000000   # S2MM_DSTADDR
# 启动 DMA：IOC_IrqEn(bit12) | RS(bit0) —— RS 先启动，等待最后写 BTT
busybox devmem 0x50000030 32 0x1001       # S2MM_DMACR = RS|IOC
# BTT = 1024 字节（256 字 × 4 字节，32-bit 源，每拍 4B）
# ⚠ 铁律：BTT 必须最后写（在 RS 之后）！写它才触发 datamover 消费。
#   先 BTT 后 RS ⇒ datamover 于 RS 时读到 BTT=0 ⇒ tready 恒 0 ⇒ 假源卡死。
busybox devmem 0x50000058 32 0x400        # S2MM_BTT = 1024B（最后写，触发搬运）
# 假源 LEN = 256 字/帧
busybox devmem 0x40000034 32 256          # 假源 LEN
# 启动假源
busybox devmem 0x40000030 32 1            # RUN
sleep 0.6
# 校验：读 DDR 开头和结尾
busybox devmem 0x30000000 32    # 第 1 个字，期望 5AA50000（{16'h5AA5, idx=0}）
busybox devmem 0x30000004 32    # 第 2 个字，期望 5AA50001
# 最后一个字地址 = 0x30000000 + (256-1)*4 = 0x300003FC
busybox devmem 0x300003FC 32              # 期望 5AA500FF（末字，idx=0xFF）
# 关 RS
busybox devmem 0x50000030 32 0
echo DMASR:; busybox devmem 0x50000034 32
echo after:; grep -w 61 /proc/interrupts

for i in $(seq 0 4 1020); do
    addr=$((0x30000000 + i))
    val=$(busybox devmem $addr 32)
    idx=$((val & 0xFFFF))
    printf "0x%08X  0x%08X  idx=%d\n" "$addr" "$val" "$idx"
done
```

通过：
- **C3**：`0x20000000` 起读到 `0x5AA50000 / 0x5AA50001 / ...`（`{16'h5AA5, word_index}`）
- **C4**：`after` 比 `before` 中断计数 **+1**，且 `DMASR` bit0(完成)=1

> 想单独隔离某项时，可先把 `DMACR` 写 `0x1`(仅 RS) 只验数据、再改 `0x1001` 验中断；
> 合并写法已置 IOC，搬运完成即产生中断。

> **⚠ BTT 必须 = 源整帧字节数（根因示意）**：假源为 **32-bit**（每拍 4 字节），整帧 = **`LEN×4`**
> （`LEN` = 假源每帧字数）。若写的 BTT **小于整帧**，DMA 永远收不满字节数、永不置完成位
> → 无 IOC → 误报「中断消失」。凡怀疑「搬运完成 / 完成中断」，先核对 **BTT 与假源 LEN 是否匹配**（`BTT=LEN×4`）。
> 注：早期 64-bit 源实测曾用「整帧=`0x2000`(8192B)/`LEN×8`」作例，改 32-bit 源后统一 `LEN×4`。

> **⚠ 稳定复测（2026-10-05，旧 bit）→ RTL 加固已根治**：旧 bit 的假源 `aurora_dma_src`
> 无超时/中止保护，连续触发或中途写 `RS=0`，会因 S2MM 不即时吞吐 `tready` 而 **busy 残留、一帧永不完成 → 无中断**。
> 该隐患已由 RTL 加固根治（见 `src/aurora_dma_src.v`）：① 新 RUN **无条件覆盖**旧 busy（重发必生效）；
> ② `busy` 无握手达 `STALL_TIMEOUT`（默认 100ms @100MHz）自动放弃本帧回 idle（不再永久死锁）。
> **重新综合上板后的新 bit 无需再 reboot 恢复。** 稳测习惯仍推荐：
> 1. 每次只 **一次性 re-arm**：`DSTADDR → DMACR=0x1001(RS|IOC) → BTT(最后写)`。
>    **BTT 必须最后写（在 RS 之后）**——由它触发 datamover；先 BTT 后 RS 会让 datamover 于 RS 时
>    读到 BTT=0 → `tready` 恒 0 → 假源卡死、无完成（2026-10-06 实证：RS→BTT 才一次跑通）。
>    **不要再额外写一次 RS=0**。
> 2. 判据看**三者齐备**：`DMASR` 完成位 + `DDR@0x20000000` 出现新帧(`0x5AA5…`) + `grep -w 61` 自增；单看 irq 不可靠。

---

## 5. s2mm-user 应用验证（dmaengine 驱动链路 + /dev/xlnx-s2mm）

> 与 §4 的 devmem 直写不同，本节省去手工编排 `DMACR/DSTADDR/BTT`，改走**内核 dmaengine**
> 链路：`xlnx_s2mm_test.ko` 绑定 DT 节点 `xlnx,s2mm-test`，`dma_request_chan("s2mm_channel")`
> 申请 AXI-DMA **S2MM** 通道，用 `dmaengine_prep_slave_single(DEV_TO_MEM)` 提交一次搬运，
> 并**在驱动内部自动 `RUN` 假源**（假源是 self-clearing 单帧，不 RUN 不吐数据）；搬运完成后经
> **IOC 完成中断**回调 `complete()`——与 §4 手动置 `IOC_IrqEn` 走的是同一条 GIC-61 中断——
> 再经 `read()` 把捕获缓冲区交回用户态校验。**一次 `s2mm-user` 调用即完成**
> 驱动→DMA 配置→假源→搬运→完成中断→读回数据的全链路验证。

- 目标 IP：`axi_dma_0`（SIMPLE，同 §1）
- 控制面：PS `M_AXI_GP0` → `axi_dma_0`（0x50000000）
- 内核模块：`xlnx_s2mm_test.ko`（`recipes-modules/xlnx-s2mm-test/`）
- 用户工具：`s2mm-user`（`recipes-apps/s2mm-user/`，打开 `/dev/xlnx-s2mm`）
- 数据面：假源 `aurora_dma_src` → `S_AXIS_S2MM` → dmaengine S2MM → 内核 coherent 缓冲 → `read()` 回读

### 5.1 前置条件（跑前先确认）

1. **模块已装入并自动加载**（`xlnx-s2mm-test.bb` 设了 `KERNEL_MODULE_AUTOLOAD += "xlnx_s2mm_test"`）：
   ```bash
   ls -l /dev/xlnx-s2mm                 # 存在? 无 => 模块未加载 / DT 节点缺失
   dmesg | grep -i xlnx-s2mm             # "Xilinx S2MM test driver: buf ... chan=dma1chan1" 即已 probe
   ```
   若缺：先 `modprobe xlnx_s2mm_test`；仍缺说明 DT 的 `xlnx,s2mm-test` 节点或 S2MM
   `interrupts` 补丁（`system-user.dtsi`）未生效，需重编镜像。

2. **PL 跑 simple 位流**（假源窗可读）：
   ```bash
   /bin/busybox devmem 0x40000004 32    # 可读到 VERSION（如 0x01000100）即假源/窗有效
   ```

3. **`s2mm-user` 在 PATH**：`which s2mm-user`。不指定长度时默认抓 `default_len` 字节
   （假源单帧 `LEN×4`，见模块参数 `default_len`）。

### 5.2 运行与验收

```bash
# ① 触发一次 S2MM 搬运并回读校验（默认 256 字节 = 假源 LEN=64 帧 × 4B）
grep -w 61 /proc/interrupts
s2mm-user 1024

# ② 显式指定长度（须 = 假源整帧字节数，32-bit 源为 LEN*4），并用 xxd 查看前段字节
s2mm-user 1024 | xxd | head              # 若假源 LEN=256 字/帧

# ③ 核对完成中断 GIC-61 计数逐次 +1（IOC 完成中断，等同 §4 的 C4）
s2mm-user 256 >/dev/null
grep -w 61 /proc/interrupts              # 每触发一次，计数 +1
```

通过标准（对应 §3 的 C3/C4）：

| 判据 | s2mm-user 证据 |
|------|----------------|
| C3 数据 | 打印 `captured N bytes`，首 32 字节出现 `5a a5 xx xx …`（`{16'h5AA5, idx}` 的字节序），且非全 0 |
| C4 中断 | `dmesg` 出现 `S2MM: received N bytes (dev addr ...)`；`read()` 能返回数据即 IOC 完成回调已触发；`/proc/interrupts` GIC-61 计数 +1 |

> s2mm-user 内部已代发假源 `RUN`（驱动 `do_s2mm_transfer` 在 `dma_async_issue_pending` 后
> `iowrite32(1, FAKE_CTRL)`），**无需手动触发假源**；长度须为 4 的倍数且等于假源整帧字节
> （`len = LEN*4`），否则 DMA 永远收不满、无完成中断（同 §6 寄存器表核对）。

### 5.3 常见问题

| 现象 | 处理 |
|------|------|
| `open /dev/xlnx-s2mm ...` 失败 | 模块未加载或 DT `xlnx,s2mm-test` 节点缺失，见 5.1 前置① |
| `ioctl TRIGGER: ... (PL must be feeding S_AXIS_S2MM)` | 返回 errno，常见为假源/中断路径异常；先确认 5.1 前置②的 VERSION 可读 |
| `ioctl TRIGGER: Cannot allocate memory` | `len > buf_size`（默认 4 MiB）；缩小长度或同步加大假源帧 |
| `S2MM timeout: never delivered N bytes ... channel marked bad` | **数据落 DDR 但 completion 未触发** → 多半是电平中断粘滞被 GIC 掩蔽（§7.3）；通道已 `chan_bad`，需重插模块或 reboot；先用 §4 确认 DMASR 置完成位 + DDR 新帧 + irq 自增"三者齐备" |
| `WARNING: captured data is all 0x00` | DMA 完成但捕获区全 0（PL 数据源异常 / 假源未真正发数据），查 PL 侧 |

---

## 6. 寄存器参考（SIMPLE / S2MM，axi_dma_0 base = 0x50000000）

| 名称 | 偏移 | 位域 | 说明 |
|------|------|------|------|
| S2MM_DMACR | +0x30 | bit0=RS；bit12=IOC_IrqEn；bit13=Dly_IrqEn；bit14=Err_IrqEn | 启动 bit0 写 1；开中断 |=0x1000 |
| S2MM_DMASR | +0x34 | bit0=完成(halt)；bit12=IOC_Irq；bit13=Dly_Irq；bit14=Err_Irq | 完成/中断状态 |
| S2MM_DSTADDR | +0x48 | 32 | DDR 目标地址 |
| S2MM_BTT | +0x58 | 26 | 搬运字节数（须 = LEN×4）|

假源（base `0x40000000`，`DMA` 块，见 README 寄存器表）：

| 寄存器 | 地址 | 说明 |
|--------|------|------|
| DMA_CTRL | 0x40000030 | bit0=RUN 发一帧（写 1 自动清）|
| DMA_LEN  | 0x40000034 | 每帧字数（默认 1024）|
| DMA_STATUS| 0x40000038 | [0]busy [1]帧完成 [15:8]已发帧数 |

> BTT 与 LEN 必须匹配：`BTT(字节) = LEN(字) × 4`。不匹配会致 DMA 搬运字节与源帧不等不同步。

---

## 7. 实测记录（2026-10-04 首测；2026-10-05 复核，simple bit）

**A. probe**：`include-sg? = NO (SIMPLE)`；`compatible = xlnx,axi-dma-7.1`；
`xilinx-vdma ... Probed!!`；`s2mm-test ... chan=dma1chan1` → **C1/C2 ✅**

**B. 搬运**：
```
DDR@0x20000000: 0x5AA50004 / 0x5AA50005 / 0x5AA50006 / 0x5AA50007   → **C3 ✅**
```

**C. 中断**（B 步只 RS 时 `irq61=0`；开 IOC 后）：
```
before:  55: 0  0  GIC-0 61 Level  xilinx-dma-controller
DMASR:   0x00000001   (完成位置位)
after:   55: 1  0  GIC-0 61 Level  xilinx-dma-controller           → **C4 ✅**
```

**结论：SIMPLE 模式端到端（配置 C1/C2、搬运 C3、中断 C4）全部通过。**

### 7.2 复核（2026-10-05，同一 SIMPLE bit + 现网 DTB 直接上板重验）

针对 "SIMPLE 完成中断疑似消失" 的排查，用 §4 同款触发流程在板上重跑，实测**中断正常**：

```
BEFORE:  55:  0  0  GIC-0  61 Level  xilinx-dma-controller, xilinx-dma-controller   # 未触发，计数 0
DMACR:   0x00011003       # 读回：bit0 RS=1、bit12 IOC_IrqEn=1(中断使能已生效)、bit14 Err_IrqEn、bit16 Cic_IrqEn
DMASR:   0x00000002       # bit1 Idle：传输完成、数据已落 DDR
DDR:     0x5AA50000 / 0x5AA50001                                                   # C3 ✅
AFTER:   55:  1  0  GIC-0  61 Level  xilinx-dma-controller, xilinx-dma-controller   # GIC-61 +1 → C4 ✅
```

- `/proc/interrupts` 中 GIC-61 行恒存在（驱动已注册中断）；触发后计数 0→1。
- 板上 `dma-channel@50000030/interrupts = <0 29 4>`（0x1d=29 → IRQ_F2P[0]=SPI 61，LEVEL_HIGH），DT 中断（补在 user 设备树 `system-user.dtsi`）已生效。
- 结论：**C1/C2（probe）、C3（数据）、C4（中断）全部通过**，arm / fpga 侧均无需改动。

**两个经验点（避免再误报 "中断消失"）：**
1. 中断只有**触发后才计数**：未触发时 61 恒为 0，属正常，不是中断缺失。
2. `utils/flash-sd.sh probe` 里 `grep -w " 61 "` 会漏抓 `/proc/interrupts` 那行（误显示 "IRQ 61 为空"），是**工具写法问题**，不是没中断；核实请用 `grep -w 61 /proc/interrupts`。

### 7.3 电平中断粘滞复测（2026-10-05，devmem 直写，待 2026-10-06 续查）

> 背景：`BTT=0x2000`+`源LEN=2048` 修好后，用 devmem 直写复测中断，发现**第三次计数不涨**。
> 现象已复现并定位为**电平中断 + 粘滞 IOC_Irq 未撤除**，属"断点待续"。

**复现先决**：板上远程 bash 的 `PATH` 为空，`busybox`/`devmem` 不在 PATH → 必须用绝对路径 `/bin/busybox devmem`。

**三次触发实测（同 `BTT=0x2000` 配置，仅源 LEN 不同）**：

| 次 | 源 LEN | DMASR | DDR@0x20000000 | irq61 | 说明 |
|----|--------|-------|----------------|-------|------|
| 1 | 1024(4096B) | `0x00000000` | `0x5AA50000`(旧) | 0 | 源帧<BTT，DMA 永不收满 → 无完成/无中断 |
| 2 | 2048(8192B) | `0x00000011` | `0x5AA50000`/`0xA5A50000` | **0→1** | BTT=源帧对齐，一次收满 → 中断触发 ✅ |
| 3 | 2048(8192B) | `0x00000011` | 已刷新 | **1（不涨）** | DMA 完成、IOC 已置，但计数不 +1 |

**关键证据（第 3 次后寄存器 dump）**：
```
0x30 DMACR  = 0x00010002   # bit1 / bit16 置位，RS(bit0)=0
0x34 DMASR  = 0x00000011   # bit0=halt + bit4(0x10) IOC_Irq —— 注意持位在 bit4，不是 bit12
0x48 DSTADDR= 0x20000000
0x58 BTT    = 0x00002000
0x5c DMAIRQ = 0x00000000   # 写 0x1e 清零已生效（W1C 读回 0）
```
- 即便 `DMACR=0` 关 RS + 写 `DMAIRQ=0x10` 清粘滞，`DMASR` 的 IOC_Irq(bit4) **始终不撤除** → 中断输出电平保持高。
- GIC 为 LEVEL 触发：线持续为高且未撤除前，内核掩蔽该 level 中断 → 后续完成不再计数（第 3 次卡在 1）。

**待明天确认的开放点**：
1. IOC_Irq 粘滞位为何经 `DMAIRQ(0x5c)` 写 0x10 仍不清？可能是该 dma 的 IRQ 归内核 `xilinx-dma-controller` 驱动管理，devmem 直写与驱动抢占/驱动自行清位冲突；需查驱动是否在 ISR 里写同一位、或该 IP 的清除寄存器/清除值是否与标准 AXI DMA 不同。
2. 用驱动路径 `board_s2mm_run2.sh`（`s2mm-user` ioctl）复测：每次触发后 ISR 清位 → 计数应逐次累加，用来区分"原始 devmem 清不掉" vs "真实链路只出一次"。
3. 若确认是电平+粘滞导致永久掩蔽，可尝试：S2MM 复位/整 DMA reset、或改用边沿感知替代，观察 `irq61` 能否多次自增。
4. 校验 §6 寄存器表：观察到的 IOC 完成在 `DMASR` **bit4(0x10)**，表内写的 bit12 疑似是 DMACR 的使能位，需勘误。
5. **（2026-10-06 追加·勘误后修正）驱动路径 `s2mm-user` 超时/挂死排查——BTT 映射以 RTL 为准**：
   - **假源是 32-bit**（`aurora_dma_src.v:DATA_WIDTH=32`，`m_tkeep=4'hF`，`m_tdata={16'h5AA5, idx[15:0]}`），每拍 **4 字节**，`BTT 必须 = 源LEN × 4`。这与 **`aurora_addr_def.vh:41`（"32bit 字 / BTT=len*4"）及 §7.2 表一致**。※此前一版曾先误判为 64-bit/×8（当时把 `*4` 当 bug 写成 `*8`），已据 RTL+仿真（`tdata=5aa5xxxx`、`tkeep=f`、`beats=LEN`）改回 32-bit/×4。
   - `board_s2mm_run.sh` / `board_s2mm_run2.sh` / `board_s2mm_run3.sh` 一律 `BYTES=$((LEN*4))`（对应当前 32-bit 源，每拍 4 字节）。
   - **真正的问题在完成/中断路径**：`LEN=64 → BTT=256`（32-bit 源，正确匹配）仍打印 "S2MM timeout: never delivered 256 bytes" ⇒ DMA 数据已落、但 **dmaengine completion 未触发**（§7.3 电平中断粘滞→GIC 掩蔽→无回调→模块 5s 超时→`terminate_all` 打向已掩蔽/卡死通道→系统死锁）。若 `direct` 自检 DDR 有 `5AA5xxxx`（32-bit 头）且 DMASR 完成位已置，即坐实"数据到位、中断没到"。
   - **结论**：BTT 不算 bug；重点查 **IRQ/completion**（电平粘滞/掩蔽 + 旧模块无 `chan_bad` 兜底）。**测试一律用 `board_s2mm_run3.sh`（`BTT=LEN*4`，含 reserved-region `direct` 自检）**；模块缓冲为 `dma_alloc_coherent`（cache-coherent），**无需手动刷 cache**。下次连跑前先 build/deploy 带 `chan_bad` 的新模块，避免一次超时把系统捅死。
---

## 8. 故障排查

| 现象 | 可能原因 / 处理 |
|------|-----------------|
| `include-sg` 仍存在 / compatible 为 vdma | 用了旧 SG 位流或旧 XSA；重建 simple bit+XSA 并重生成 device-tree |
| 搬运后 DDR 无数据 | 假源未 RUN（看 `DMA_STATUS[0]busy`）；`DSTADDR` 超出 HP0 范围；`BTT≠源LEN×4`（32-bit 源，每拍 4 字节） |
| GIC-61 计数为 0 | 仅写了 `DMACR=0x1`（RS）未置 IOC_IrqEn(bit12)；需 `0x1001` 才触发完成中断 |
| `DMASR` 读 0 | 相比只 RS 时未开 IOC，或读时序过早；sleep 后重读；完成时 bit0 应=1 |
| DMA 无握手、源 busy 死等 | 先配 DMA(RS=1) 进入等 `tvalid` 再触发假源，避免源先握手无消费方 |
| probe 显示 "IRQ 61 为空" 但实测中断正常 | `flash-sd.sh probe` 内用 `grep -w " 61 "` 漏抓 /proc/interrupts 行（工具写法问题）；核实改用 `grep -w 61 /proc/interrupts` |
| 断开后连跑/中途复位，搬运不再完成、无中断、SRC 一直 busy | **旧 bit** 因假源无超时，`busy` 残留(丢 tvalid 同步)而永久卡死 → 需 reboot。**新 bit（假源已加看门狗 + RUN 强覆盖）已自愈**：`busy` 无握手达 `STALL_TIMEOUT` 自动回 idle、下次 RUN 必生效，无需 reboot（须**重新综合上板**才生效）。可靠判据 = DMASR 完成位 + DDR 新帧 + irq 自增**三者齐备**，勿只看 irq |