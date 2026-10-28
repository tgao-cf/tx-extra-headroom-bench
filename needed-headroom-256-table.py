#!/usr/bin/env python3
# needed-headroom-256-table.py <results dir>: the cover letter table from the raw files (medians of results.tsv,
# head expansion and vethB1 copy shares from logs/count-*.bt) and a bar chart of the change, <results dir>/needed-headroom-256.png.
# Run: uv run --with matplotlib python3 needed-headroom-256-table.py <results dir>
import collections, csv, glob, os, re, statistics, sys

d = sys.argv[1]
rows = collections.defaultdict(list)
with open(os.path.join(d, "results.tsv")) as f:
    for r in csv.DictReader((l for l in f if not l.startswith("#")), delimiter="\t"):
        if r["value"] != "NA":
            rows[r["test"], r["variant"]].append(float(r["value"]))

def bt(test, variant):
    m = collections.Counter()
    for l in open(os.path.join(d, "logs", f"count-{test}-{variant}.bt")):
        if x := re.match(r"^@(\w+)(?:\[(.*)\])?: (\d+)$", l.strip()):
            m[(x[1],) + tuple(s.strip() for s in (x[2] or "").split(","))] += int(x[3])
    return m

def share(m, test):
    # forwarded: skbs that ip_forward() expanded / skbs ip_forward() got from the NIC; local: veth output skbs expanded / all
    if test.startswith("forward"):
        nic = next(k[1] for k in m if k[0] == "fwd" and k[1] != "vethB0")
        return m["expand", nic, "ip_forward"], m["fwd", nic]
    return sum(v for k, v in m.items() if k[0] == "expand" and k[1] in ("vethB0", "vethB1")), m["out", "vethB0"] + m["out", "vethB1"]

TESTS = [("forward-tcp", "forward_tcp", "forwarded TCP", "Gbit/s"), ("forward-udp64", "forward_udp64", "forwarded 64B UDP", "pps"),
         ("local-tcp", "local_tcp", "local TCP, host to netns", "Gbit/s"), ("local-tcp-rev", "local_tcp_rev", "local TCP, netns to host", "Gbit/s"),
         ("tcp-rr", "tcp_rr", "TCP_RR, 1 byte", "/s")]
fmt = lambda v, u: f"{v:.2f}" if u == "Gbit/s" else f"{v:.0f}"
n = min(len(v) for v in rows.values())
print(f"median of {n} rounds; range in brackets\n")
print(f"{'traffic':26} {'head expanded':16} {'vethB1 copied':16} {'stock':28} 256")
chg = []
for t, c, name, unit in TESTS:
    s, h = rows[t, "stock"], rows[t, "headroom256"]
    if not s or not h:
        continue
    pct, cp = [], []
    for v in ("stock", "headroom256"):
        m = bt(c, v); e, a = share(m, t)
        pct.append(f"{100 * e / a:.0f}%" if a else "NA")
        # skb_pp_cow_data() on vethB1 / skbs its XDP path got
        cp.append(f"{100 * m['vethB1_copy',''] / m['vethB1_xdp_rcv','']:.0f}%")
    ms, mh = statistics.median(s), statistics.median(h)
    chg.append((name, 100 * (mh / ms - 1), 100 * (min(h) / ms - 1), 100 * (max(h) / ms - 1)))
    print(f"{name:26} {pct[0] + ' -> ' + pct[1]:16} {cp[0] + ' -> ' + cp[1]:16} {fmt(ms, unit) + ' ' + unit:>12} ({fmt(min(s), unit)}-{fmt(max(s), unit)})"
          f"  {fmt(mh, unit)} ({chg[-1][1]:+.1f}%) ({fmt(min(h), unit)}-{fmt(max(h), unit)})")

print("\nhead expansions by device and caller, stock / headroom256:")
for t, c, name, unit in TESTS:
    ms = [bt(c, v) for v in ("stock", "headroom256")]
    keys = sorted({k for m in ms for k in m if k[0] in ("expand", "fwd", "out", "vethB1_copy", "vethB1_xdp_rcv")})
    print(f"  {name}: " + "; ".join(f"{'/'.join(k)} {ms[0][k]}/{ms[1][k]}" for k in keys))

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
fig, ax = plt.subplots(figsize=(7, 3.2))
y = range(len(chg))
ax.barh(y, [x[1] for x in chg], xerr=[[x[1] - x[2] for x in chg], [x[3] - x[1] for x in chg]], color="#4C72B0", capsize=3)
ax.set_yticks(list(y), [x[0] for x in chg]); ax.invert_yaxis(); ax.axvline(0, color="black", lw=0.8)
ax.set_xlabel(f"256 vs stock (%), median of {n} rounds, bars: range of the 256 rounds")
fig.tight_layout(); fig.savefig(os.path.join(d, "needed-headroom-256.png"), dpi=300)
