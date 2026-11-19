# veth headroom benchmarks

> [!TIP]
> This branch has the benchmarks of the tx_extra_headroom v2 series. The benchmarks of v1 are on the
> [`v1` branch](https://github.com/tgao-cf/tx-extra-headroom-bench/tree/v1).

Two tables for the cover letter of the tx_extra_headroom v2 series (`tx-extra-headroom-v2.mbox`). The series adds a
per-device headroom that only locally generated skbs get. The alternative is to raise `needed_headroom`, as
[patch 4/4 of Jesper Dangaard Brouer's veth RFC](https://lore.kernel.org/all/169272716651.1975370.10514711233878278884.stgit@firesoul/)
does for a veth with XDP.

| Measurement | Question | Results |
|---|---|---|
| Regression | What does `needed_headroom` 256 on veth cost forwarded and local traffic? | `results/2026-11-19-reg/` |
| Gain | How much faster is local UDP into or out of a netns when no packet is copied or reallocated? | `results/2026-11-19-gain/` |

`results/table.txt` holds both tables of the run on 2026-11-19, and `results/tx-extra-headroom-v2.png` the chart.

The host runs net-next d6816d9a93b6, with or without the series. The sender runs 6.18.55.

Both nodes are tuned on every boot: performance governor, turbo off, energy-performance bias 0, idle states deeper
than C1 off, and uncore frequency fixed at its maximum. The host also has `workqueue.power_efficient=0` on the kernel
command line. The sender in this run does not, and it still sends 1.13 Mpps, about twice the forwarded rate. The
BIOS owns ASPM, so it is not changed. C1 stays on: with only POLL, the idle SMT sibling of the test CPU spins and takes
cycles from it.

## Regression: needed_headroom 256

### Setup

```
sender ens1f1np1 --25G-- ens1f1np1 (mlx5, XDP_PASS)  host  vethB0 --veth-- vethB1 (XDP_PASS)  netns hrB
```

- Two variants, same kernel. Only `veth.ko` changes, both built out of tree from the same source:
  - `stock`: `drivers/net/veth.c` of net-next d6816d9a93b6.
  - `headroom256`: the same file after `git am` of Jesper's RFC 4/4, rebased (`jesper-veth-rfc-4of4.mbox`).
- The XDP program on the host NIC and on vethB1 is `xdp_dummy` from the bpf selftests. It returns `XDP_PASS`.
- The host NIC has one channel, with its IRQ on CPU 2. Clients run on CPU 2. Servers run in hrB on CPU 4.
- IPv6 is off on vethB0 and in hrB, so no timer sends packets from another CPU.

| Test | Path | Tool |
|---|---|---|
| forwarded UDP | sender -> NIC -> `ip_forward()` -> vethB0 -> vethB1 -> hrB, one UDP flow of 1400-byte payloads, no socket in hrB | `pktgen_sample03_burst_single_flow.sh`, burst 32 |
| local TCP, netns to host | hrB socket -> vethB1 -> vethB0 -> host | iperf3 `-R`, one stream, 128 KB writes, MSS 1448, GSO on veth |

The script first runs each test once per variant with `bench.bt` attached. Then come 9 measured rounds without
bpftrace, 15 s per test. Each round runs every test on both variants, and the variant order swaps every round. Both
variants run in the same boot. **Head expanded** is the share of skbs that got `pskb_expand_head()`. For forwarded
traffic, it is out of the skbs that `ip_forward()` got from the NIC. For local traffic, it is out of the skbs sent on
vethB0 or vethB1, ACKs included.

## Gain: tx_extra_headroom

### Setup

The topology is the same. One kernel, `series`: net-next d6816d9a93b6 plus the 11 patches of
`tx-extra-headroom-v2.mbox` and `xdp-tx-extra-headroom-switch.patch`. Each test runs with tx_extra_headroom `off` and
`on` in the same boot:

| Test | Path | `on` | `off` |
|---|---|---|---|
| plain | host socket -> vethB0 -> vethB1 -> hrB | nothing attached | the same: the control |
| generic XDP_PASS | the same | `xdp_dummy` on vethB1 in generic mode | the same, with `xdp_tx_extra_headroom` 0: generic XDP copies the skb |
| generic XDP_DROP | host socket -> vethB0 -> vethB1 | `xdp_native.bpf.c` from the net selftests, drop mode for the test port, on vethB1 in generic mode | the same, with `xdp_tx_extra_headroom` 0: generic XDP copies the skb |
| push | host socket -> vethB0 -> vethB1 | `push.bpf.c` at tcx egress of vethB0 | `push.bpf.c` without the decl tag: the push reallocates the skb |
| uplink push | hrB socket -> vethB1 -> vethB0 -> `ip_forward()` -> NIC -> sender | `push.bpf.c` at tcx egress of the host NIC, veth pair created with `VETH_INFO_TX_EXTRA_HEADROOM` 20 | the veth pair without the attribute: the push reallocates the skb |

- Every test sends UDP from a socket with netperf `UDP_STREAM`, on CPU 2, with 1400-byte datagrams. The rate is the rx
  counter of vethB1 over 15 s. The XDP_DROP test uses the tx counter of vethB0, and the uplink test the tx counter of
  the host NIC.
- `push.bpf.c` pushes 20 bytes after the MAC header of each UDP packet to port 9999, as `push_tagged` in the series'
  selftest does, and declares them with the decl tag `tx_extra_headroom:20`. `-DNO_DECL_TAG` builds it without the tag.
- `xdp-tx-extra-headroom-switch.patch` is for this benchmark only, not part of the series. It adds
  `/sys/module/kernel/parameters/xdp_tx_extra_headroom`. With 0, XDP on a veth peer sets no tx_extra_headroom. The
  value is read when XDP is attached, so the data path is the same code in both variants.
- Both variants run the same kernel binary in the same boot. A comparison of two kernels is not used: on this machine
  the code layout alone moved the rate of the same base kernel by up to 13% between boots (KASLR on, 298 kpps; KASLR off,
  258 to 264 kpps), as much as the gain.
- Rounds as in the regression. **Copied or reallocated** is the share of datagrams that generic XDP copied or the push
  reallocated, from the `bench.bt` run.

## Run

On the host, as root, in tmux. The sender must accept ssh from the host user with `~/.ssh/id_ed25519`. Requirements:
two x86 machines on one link, an mlx5 NIC on the host, Ubuntu 24.04 (the build uses its kernel config and packages).
The defaults (host 10.0.1.1, sender 10.0.1.2, CPUs 2 and 4, rounds) are variables listed at the top of `bench.sh`.

```
./bench.sh build    # clones net-next, builds both kernels, both veth.ko, bpftool and the BPF objects
reboot              # into 7.4.0-rc2+, the base kernel
O=$PWD/results/<date>-reg ./bench.sh run 2>&1 | tee run-reg.log
```

Then the gain table, after a reboot into 7.4.0-rc2-txhr+, the series kernel:

```
O=$PWD/results/<date>-gain ./bench.sh run 2>&1 | tee run-gain.log
uv run --with matplotlib python3 table.py results/<date>-reg results/<date>-gain > results/table.txt
```

`bench.sh run` restores the NIC channel count, removes the XDP program and loads the in-tree veth when it exits. The
tuning lasts until the next reboot. `workqueue.power_efficient=0` must be added to `GRUB_CMDLINE_LINUX_DEFAULT` by hand
on both nodes.

## Files

| File | Content |
|---|---|
| `bench.sh` | `build`: both kernels, both `veth.ko`, bpftool, BPF objects. `run`: tuning, count runs, then the measured rounds |
| `table.py` | Both tables and the chart from the two results directories |
| `bench.bt` | bpftrace counters (x86 only: it reads the caller from the stack pointer) |
| `push.bpf.c` | The tcx egress push with the decl tag, or without it (`-DNO_DECL_TAG`) |
| `xdp-tx-extra-headroom-switch.patch` | Benchmark only: the switch for the XDP part of tx_extra_headroom |
| `jesper-veth-rfc-4of4.mbox` | Jesper's RFC 4/4, rebased onto net-next |
| `tx-extra-headroom-v2.mbox` | The series |
| `results/<date>-*/` | `bench-results.tsv`, `logs/`, `env-*.txt`, `kernel.txt` |

## Settings

From `env-host-*.txt` and `env-sender.txt` in the results directories:

| Item | Host | Sender |
|---|---|---|
| Kernel | 7.4.0-rc2+ (net-next d6816d9a93b6), 7.4.0-rc2-txhr+ (the same plus the series and the switch) | 6.18.55 |
| Kernel config | Ubuntu 24.04 config, localmodconfig | Ubuntu mainline build |
| Cmdline | `mitigations=off workqueue.power_efficient=0` | `mitigations=off` |
| CPU | performance, turbo off, EPB 0, C1E/C3/C6 off, uncore 2.7 GHz | the same |
| SMT, irqbalance | on, not running | on, not running |
| NIC firmware | 14.18.2030 | the same |
| NIC channels | 1, IRQ on CPU 2 | 20 (default) |
| Rings, coalescing | 1024, adaptive rx/tx (driver default) | the same |
| Pause frames | rx on, tx on (default) | the same |
| Offloads | GRO on, LRO off, HW GRO off, rx-udp-gro-forwarding off, striding RQ off | the same |
| RPS, ntuple | off, no rules | the same |
| XDP | `xdp_dummy` on the NIC | none |
| Sysctls | defaults (fq_codel, `netdev_max_backlog` 1000, cubic), `ip_forward` 1 | defaults |
| MTU | 1500 | 1500 |
