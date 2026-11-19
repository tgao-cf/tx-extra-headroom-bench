#!/usr/bin/env python3
# table.py <regression dir> <gain dir>: the two cover letter tables from the raw files, and a bar
# chart of both, tx-extra-headroom-v2.png in the parent directory of the gain dir.
# Regression: stock vs headroom256 veth.ko on the base kernel. Gain: tx_extra_headroom off vs on in the series kernel.
# Each value is the median of all rounds of one boot. Head expansions and copies come from logs/count-*.bt.
# Run: uv run --with matplotlib python3 table.py <regression dir> <gain dir>
import collections, os, re, statistics, sys

def load(d):
    v = collections.defaultdict(list)  # (test, variant) -> rates of all rounds
    for l in open(os.path.join(d, "bench-results.tsv")):
        r = l.rstrip("\n").split("\t")
        if l[0] != "#" and r[0] != "test" and r[4] != "NA":
            v[r[0], r[1]].append(float(r[4]))
    return v

def bt(d, test, variant):
    m = collections.Counter()
    for l in open(os.path.join(d, "logs", f"count-{test}-{variant}.bt")):
        if x := re.match(r"^@(\w+)(?:\[(.*)\])?: (\d+)$", l.strip()):
            m[(x[1],) + tuple(s.strip() for s in (x[2] or "").split(","))] += int(x[3])
    return m

def expanded(d, test, variant):
    # share of the skbs that pskb_expand_head() reallocated. forward: by ip_forward() / skbs ip_forward() got from the NIC.
    # local TCP: on vethB0 or vethB1 / all skbs sent on them (ACKs included). gain tests: by generic XDP, the push or
    # ip_forward() / the datagrams the socket sent on vethB0 or vethB1.
    m = bt(d, test, variant)
    if test == "forward_udp":
        nic = next(k[1] for k in m if k[0] == "fwd" and k[1] != "vethB0")
        e, a = m["expand", nic, "ip_forward"], m["fwd", nic]
    elif test == "local_tcp_rev":
        e = sum(v for k, v in m.items() if k[0] == "expand" and k[1] in ("vethB0", "vethB1"))
        a = m["out", "vethB0"] + m["out", "vethB1"]
    else:
        e = sum(v for k, v in m.items() if k[0] == "expand" and k[2] in ("do_xdp_generic", "bpf_skb_adjust_room", "ip_forward"))
        a = max(m["out", "vethB0"], m["out", "vethB1"])
    return f"{100 * e / a:.0f}%" if a else "NA"

bars = []
def row(d, b, t, c, name, unit, scale, x, y, color):
    if not b[t, x] or not b[t, y]:
        return
    mx, my = statistics.median(b[t, x]), statistics.median(b[t, y])
    bars.append((name, 100 * (my / mx - 1), color))
    print(f"  {name:44} {mx / scale:7.3f} ({min(b[t, x]) / scale:.3f}-{max(b[t, x]) / scale:.3f})  "
          f"{my / scale:7.3f} ({min(b[t, y]) / scale:.3f}-{max(b[t, y]) / scale:.3f}) {unit}  {bars[-1][1]:+.1f}%  "
          f"expanded {expanded(d, c, x)} -> {expanded(d, c, y)}  rounds {len(b[t, x])}/{len(b[t, y])}")

reg, gain = sys.argv[1:3]
print("needed_headroom 256: stock -> headroom256 veth.ko, base kernel, median of all rounds (range)")
b = load(reg)
for t, c, name, unit, scale in [("local-tcp-rev", "local_tcp_rev", "netns sends TCP to host", "Gbit/s", 1),
                                ("forward-udp", "forward_udp", "host forwards 1400B UDP into netns", "Mpps", 1e6)]:
    row(reg, b, t, c, name, unit, scale, "stock", "headroom256", "#C44E52")
print("\ntx_extra_headroom: off -> on, series kernel, 1400-byte UDP payload, median of all rounds (range)")
b = load(gain)
for t, c, name in [("plain-udp", "plain_udp", "host to netns, nothing attached"),
                   ("xdp-udp", "xdp_udp", "host to netns, generic XDP_PASS in netns"),
                   ("xdpdrop-udp", "xdpdrop_udp", "host to netns, generic XDP_DROP in netns"),
                   ("push-udp", "push_udp", "host to netns, 20-byte push at TC egress"),
                   ("uplink-udp", "uplink_udp", "netns to uplink, 20-byte push on the uplink")]:
    row(gain, b, t, c, name, "Mpps", 1e6, "off", "on", "#4C72B0")

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
fig, ax = plt.subplots(figsize=(8, 4))
y = range(len(bars))
ax.barh(y, [v for _, v, _ in bars], color=[c for _, _, c in bars])
ax.set_yticks(list(y), [n for n, _, _ in bars], fontsize=7); ax.invert_yaxis(); ax.axvline(0, color="black", lw=0.8)
ax.set_xlabel("change of the median (%): red needed_headroom 256 vs stock, blue tx_extra_headroom on vs off")
fig.tight_layout(); fig.savefig(os.path.join(os.path.dirname(os.path.abspath(gain)), "tx-extra-headroom-v2.png"), dpi=300)
