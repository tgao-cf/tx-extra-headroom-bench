# veth headroom benchmarks

Two measurements for
[David Keogh's tx_extra_headroom series](https://lore.kernel.org/all/20261015235335.4162993-1-dkeogh@amazon.com/).
The series adds a per-device headroom that only new skbs get. The alternative is to raise `needed_headroom`, as
[patch 4/4 of Jesper Dangaard Brouer's veth RFC](https://lore.kernel.org/all/169272716651.1975370.10514711233878278884.stgit@firesoul/)
does for a veth with XDP.

| Measurement | Question | Script | Results |
|---|---|---|---|
| needed_headroom 256 | What does `needed_headroom` 256 on veth cost forwarded and local traffic? | `needed-headroom-256.sh` | `results/needed-headroom-256-xl170-1027/` |
| tx_extra_headroom | How many head expansions does a 20-byte push at tc egress cause, per knob value? | `tx-extra-headroom.sh` | `results/tx-extra-headroom-xl170-1027/` |

Summary:

- With `needed_headroom` 256, every forwarded packet and every local TCP skb gets its head expanded. Forwarded 64-byte
  UDP loses 20.8%. TCP loses 2.8% to 5.8%.
- With tx_extra_headroom 64 or more, the push causes no expansion. With 0, every datagram is expanded.

Both ran on two CloudLab xl170 nodes: Intel Xeon E5-2640 v4 (10 cores, SMT on) and ConnectX-4 Lx 25G (mlx5). The host
runs net-next 734bef548a96. The sender runs 6.18.55.

## needed_headroom 256

### Setup

```
sender ens1f1np1 --25G-- ens1f1np1 (mlx5, XDP_PASS)  host  vethB0 --veth-- vethB1 (XDP_PASS)  netns hrB
```

- Two variants, same kernel. Only `veth.ko` changes, both built out of tree from the same source:
  - `stock`: `drivers/net/veth.c` of net-next 734bef548a96.
  - `headroom256`: the same file after `git am` of Jesper's RFC 4/4 (`jesper-veth-rfc-4of4.mbox`, applies cleanly).
- The XDP program on the host NIC and on vethB1 is `xdp_dummy` from the bpf selftests. It returns `XDP_PASS`.
- The host NIC has one channel, with its IRQ on CPU 2. Clients run on CPU 2. Servers run in hrB on CPU 4.
- IPv6 is off on vethB0 and in hrB, so no timer sends packets from another CPU.

| Test | Path | Tool |
|---|---|---|
| forwarded TCP | sender -> NIC -> `ip_forward()` -> vethB0 -> vethB1 -> hrB | iperf3, one flow |
| forwarded 64B UDP | the same path, one UDP flow of 64-byte frames, no socket in hrB | `pktgen_sample03_burst_single_flow.sh`, burst 32 |
| local TCP, host to netns | host socket -> vethB0 -> vethB1 -> hrB | iperf3 |
| local TCP, netns to host | hrB socket -> vethB1 -> vethB0 -> host | iperf3 `-R` |
| TCP_RR, 1 byte | host netperf <-> netserver in hrB | netperf `TCP_RR -r 1,1` |

The script first runs each test once per variant with `count.bt` attached. Then come 9 measured rounds without
bpftrace, 15 s per test (TCP_RR 20 s). Each round runs every test on both variants, and the variant order swaps
every round.

- **Head expanded**: the share of skbs that got `pskb_expand_head()`. For forwarded traffic, out of the skbs that
  `ip_forward()` got from the NIC (GRO skbs for TCP). For local traffic, out of the skbs that `ip_finish_output2()`
  sent on vethB0 or vethB1, ACKs included.
- **Copied on vethB1**: the share of skbs on the vethB1 XDP path that `skb_pp_cow_data()` copied.

### Results

Median of 9 rounds, range in brackets:

| Test | Head expanded | Copied on vethB1 | stock | headroom256 | Change |
|---|---|---|---|---|---|
| forwarded TCP | 0% -> 100% | 100% -> 100% | 7.04 Gbit/s (6.79-7.13) | 6.76 (6.65-6.82) | -4.0% |
| forwarded 64B UDP | 0% -> 100% | 0% -> 100% | 873822 pps (870247-875886) | 692155 (689793-693811) | -20.8% |
| local TCP, host to netns | 0% -> 100% | 100% -> 100% | 5.75 Gbit/s (5.71-5.78) | 5.59 (5.32-5.67) | -2.8% |
| local TCP, netns to host | 0% -> 100% | 100% -> 100% | 39.14 Gbit/s (37.78-39.48) | 37.70 (36.33-38.28) | -3.7% |
| TCP_RR, 1 byte | 0% -> 100% | 100% -> 100% | 91582/s (89620-93620) | 86296/s (84228-87327) | -5.8% |

- **Forwarded packets**: they have 270 bytes in front of the IP header at `ip_forward()`. With `needed_headroom` 256,
  `LL_RESERVED_SPACE()` of vethB0 is 272, so `ip_forward()` expands every packet.
- **Forwarded UDP is copied too**: `pskb_expand_head()` sets `head_frag` to 0. The expanded packet then fails
  `skb_head_is_locked()` in `veth_convert_skb_to_xdp_buff()`, so vethB1 copies it. Stock: 1 of 97825 copied.
  headroom256: 71425 of 71425.
- **Forwarded TCP loses less**: the host GRO-merges the segments. vethB0 has no GSO while its peer has XDP, so the GSO
  skb is segmented, and vethB1 copies every segment in both variants. The expansion in `ip_forward()` comes once per
  GRO skb. headroom256 also expands in `skb_segment()` (0 -> 163453 calls) and expands every ACK from hrB.
- **Local TCP**: it reserves 204 bytes in front of the IP header. With 256, every TCP skb in both directions is
  expanded, ACKs included.
- **CPU**: host CPU 2 is at 97-100% in the forwarded and host-to-netns tests. In netns-to-host, CPU 4 (the sender in
  hrB) is at 100%. No other host CPU did more than 5% softirq work in any round. In the UDP test the sender sends
  1.35-1.47 Mpps, and the host NIC drops the rest (`rx_out_of_buffer`).
- **Noise**: the forwarded TCP ranges touch, and the netns-to-host ranges overlap. The other ranges do not overlap.

`table.txt` and `needed-headroom-256.png` in the results directory come from `needed-headroom-256-table.py`.

## tx_extra_headroom

### Setup

This repeats the measurement in David's cover letter: UDP datagrams from a socket on a veth, a 20-byte push at tc
egress, only tx_extra_headroom varied.

- Kernel: net-next 734bef548a96 plus the tx_extra_headroom v1 series (8 patches, tip 7974bf026dd7).
- `ip`: iproute2-next 204a72103355 plus the iplink patch. The knob is set with `ip link set dev vethB0 tx_extra_headroom N`.
- Topology: vethB0 in netns hrA, its peer vethB1 in netns hrB. IPv6 is off in both, and 10.0.0.2 is a permanent
  neighbour, so only the test sends on vethB0.
- Push: `tx_extra_headroom.bpf.c` from the series' selftests, at tc egress of vethB0. It calls
  `bpf_skb_adjust_room(20, BPF_ADJ_ROOM_MAC)` on every UDP packet to port 9999. It also records the headroom in front
  of the Ethernet header before the push.
- Sender: `netperf -t UDP_STREAM -l -<500000 * 64> -- -m 64 -P ,9999` in hrA. This sends 500000 datagrams of 64
  bytes, then 3 end-of-test datagrams to the same port.
  - The push makes all of them unreadable, so netserver never answers. The script stops netperf when the datagrams
    are out.
  - iperf3 does not work here: its UDP test starts with a datagram to the server port and waits for the reply.
- Count: `count.bt` counts `pskb_expand_head()` on vethB0 by caller.
- 5 rounds. The row order rotates every round.

### Results

| tx_extra_headroom | tc push | Headroom before the push | pskb_expand_head() on vethB0, median (range) | Datagrams seen by tc |
|---|---|---|---|---|
| 0 | yes | 2 | 500003 (500003-500003) | 500003 |
| 64 | yes | 66 | 0 (0-0) | 500003 |
| 128 | yes | 130 | 0 (0-0) | 500003 |
| 256 | yes | 258 | 0 (0-0) | 500003 |
| 256 | no | - | 0 (0-0) | - |

- **0**: every datagram is expanded, all by `bpf_skb_adjust_room()`. 500003 is 500000 datagrams plus netperf's 3
  end-of-test datagrams.
- **Headroom**: `LL_ALLOC_SPACE()` = ((14 + tx_extra_headroom) & ~15) + 16, minus the 14-byte Ethernet header. The
  push needs 20, so any value from 18 up is enough.
- **David's numbers**: his cover letter reports 4 with 64 and 2 with 128, from ARP and ND. The permanent neighbour and
  IPv6 off remove them here.

`summary.txt` in the results directory comes from the `summary` function of `tx-extra-headroom.sh`.

## Run

On the host, as root, in tmux. The sender must accept ssh from the host user with `~/.ssh/id_ed25519`. Requirements:
two x86 machines on one link, an mlx5 NIC on the host, Ubuntu 24.04 (the build uses its kernel config and packages).
The defaults (host 10.0.1.1, sender 10.0.1.2, CPUs 2 and 4, rounds) are variables listed at the top of each script.

```
./needed-headroom-256.sh build    # clones net-next main, builds the kernel and both veth.ko
reboot
./needed-headroom-256.sh run 2>&1 | tee run.log
uv run --with matplotlib python3 needed-headroom-256-table.py results/needed-headroom-256-<host>-<date>

./tx-extra-headroom.sh build      # T=<kernel tree with the series> I=<iproute2 tree with the iplink patch>
reboot                            # into 7.3.0-txhr+
./tx-extra-headroom.sh run 2>&1 | tee run.log
```

`needed-headroom-256.sh run` restores the NIC channel count, removes the XDP program and loads the stock veth when it
exits. `tx-extra-headroom.sh build` reuses the config of the running kernel from `needed-headroom-256.sh build` and
adds `NET_SCH_INGRESS` and `NET_CLS_BPF` as modules.

## Files

| File | Content |
|---|---|
| `needed-headroom-256.sh` | `build`: kernel and both `veth.ko`. `run`: count runs, then the measured rounds |
| `needed-headroom-256-table.py` | Results table and chart from one results directory |
| `jesper-veth-rfc-4of4.mbox` | Jesper's RFC 4/4 as posted |
| `tx-extra-headroom.sh` | `build`: kernel with the series, `ip`, bpftool, the tc program. `run`: the expansion count per knob value |
| `count.bt` | bpftrace counters for both scripts (x86 only: it reads the caller from the stack pointer) |
| `results/<measurement>-xl170-1027/` | `results.tsv`, `logs/`, `env-*.txt`, `kernel.txt`, `run.log` |

## Settings

From `env-host.txt` and `env-sender.txt` in the results directories:

| Item | Host, needed_headroom 256 | Host, tx_extra_headroom | Sender |
|---|---|---|---|
| Kernel | 7.3.0+ (net-next 734bef548a96) | 7.3.0-txhr+ (734bef548a96 + v1 series) | 6.18.55 |
| Kernel config | Ubuntu 24.04 config, localmodconfig | the same plus `NET_SCH_INGRESS=m`, `NET_CLS_BPF=m` | Ubuntu mainline build |
| Cmdline | `mitigations=off` | `mitigations=off` | `mitigations=off` |
| Governor, turbo | performance, turbo on | schedutil (counts only, no throughput), turbo on | performance, turbo on |
| SMT, irqbalance | on, not running | on, not running | on, not running |
| NIC firmware | 14.32.1904 | 14.32.1904 | 14.18.2030 |
| NIC channels | 1, IRQ on CPU 2 | 20 (default, NIC not used) | 20 (default) |
| Rings, coalescing | 1024, adaptive rx/tx (driver default) | the same | the same |
| Pause frames | rx on, tx on (default) | the same | the same |
| Offloads | GRO on, LRO off, HW GRO off, rx-udp-gro-forwarding off, striding RQ off | the same | the same |
| RPS, ntuple | off, no rules | the same | the same |
| XDP | `xdp_dummy` on the NIC and on vethB1 | none | none |
| Sysctls | defaults (fq_codel, `netdev_max_backlog` 1000, cubic), `ip_forward` 1 | defaults | defaults |
| MTU | 1500 | 1500 | 1500 |
