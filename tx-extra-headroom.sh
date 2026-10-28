#!/bin/bash
# tx-extra-headroom.sh: pskb_expand_head() calls per 500000 UDP datagrams from a socket on a veth with a 20-byte push at
# tc egress, for tx_extra_headroom 0, 64, 128, 256, and 256 with no tc program (idle).
# The kernel is a tree with the tx_extra_headroom series (T); ip comes from iproute2 with the iplink patch (I).
# Run as root, in tmux, on a machine that runs the kernel from "needed-headroom-256.sh build" (its config is reused):
#   ./tx-extra-headroom.sh build                      # kernel with LOCALVERSION -txhr, ip, bpftool, the tc program; then reboot
#   ./tx-extra-headroom.sh run 2>&1 | tee run.log
# Env: T=<kernel tree> I=<iproute2 tree> N=500000 LEN=64 ROUNDS=5 CS=2 CR=4 O=<results dir>
export LC_ALL=C
D=$(cd "$(dirname "$0")" && pwd) U=${SUDO_USER:-$USER}; H=$(getent passwd $U | cut -d: -f6)
T=${T:-$H/net-next-txhr} I=${I:-$H/iproute2-txhr} N=${N:-500000} LEN=${LEN:-64} ROUNDS=${ROUNDS:-5} CS=${CS:-2} CR=${CR:-4}
O=${O:-$D/results/tx-extra-headroom-$(hostname -s)-$(date +%m%d)} IP=$I/ip/ip BPFTOOL=$T/tools/bpf/bpftool/bpftool
ROWS="0:tc 64:tc 128:tc 256:tc 256:idle" PUSH=20 PORT=9999   # PORT: TEST_PORT in tx_extra_headroom.bpf.c

log() { echo "$(date +%T) $*"; }
die() { log "FATAL: $*"; exit 2; }
[ $EUID -eq 0 ] || die "run as root"

build() {
  apt-get install -yq libmnl-dev libcap-dev pkg-config netperf bpftrace clang llvm libbpf-dev > /dev/null || die "apt"
  mkdir -p $O; git -C $T log -1 --format='%H %s' > $O/kernel.txt; git -C $T log --oneline -9 >> $O/kernel.txt
  git -C $I log --oneline -3 > $O/iproute2.txt 2>/dev/null || echo "iproute2 tree without git" > $O/iproute2.txt
  # needed-headroom-256.sh's config (localmodconfig) plus clsact and cls_bpf for the tc program
  cd $T; cp /boot/config-$(uname -r) .config; scripts/config --set-str LOCALVERSION -txhr --module NET_SCH_INGRESS --module NET_CLS_BPF
  make olddefconfig; grep -qx CONFIG_NET_CLS_BPF=m .config || die "CONFIG_NET_CLS_BPF"
  make -j$(nproc) > $O/kernel-build.log 2>&1 || die "make, see $O/kernel-build.log"
  make modules_install install > /dev/null || die "install"
  make -C tools/bpf/bpftool -j$(nproc) > /dev/null 2>&1 || die "bpftool"
  clang -O2 -g -target bpf -I/usr/include/$(uname -m)-linux-gnu -c tools/testing/selftests/net/tx_extra_headroom.bpf.c \
    -o $D/tx_extra_headroom.bpf.o || die "bpf object"
  cd $I; ./configure > /dev/null && make -j$(nproc) SUBDIRS="lib ip" > /dev/null || die "iproute2"
  log "built $(make -s -C $T kernelrelease); reboot into it, then run"; }

[ "$1" = build ] && { build; exit; }
[ "$1" = run ] || die "usage: $0 build|run"
for t in $IP $BPFTOOL $D/tx_extra_headroom.bpf.o; do [ -e $t ] || die "missing $t, run build"; done
for t in netperf netserver bpftrace jq taskset; do command -v $t > /dev/null || die "missing $t"; done
[ -z "$(ip netns list)" ] || die "netns exist: $(ip netns list | tr '\n' ' ')"
$IP link help 2>&1 | grep -q tx_extra_headroom || die "$IP has no tx_extra_headroom"
mkdir -p $O/logs; R=$O/results.tsv
# host state in the same format as the needed-headroom-256.sh run, for the diff against it
source <(sed -n '/^state() {/,/ip route; }$/p' $D/needed-headroom-256.sh)
state $(ip -o -4 addr show | awk 'index($4, "10.0.1.1/") == 1 {print $2}') > $O/env-host.txt 2>&1
down() { for n in hrA hrB; do ip netns pids $n 2>/dev/null | xargs -r kill 2>/dev/null; done; sleep 0.3
  for n in hrA hrB; do ip netns del $n 2>/dev/null; done; }
trap 'down; log EXIT' EXIT; trap 'exit 130' INT TERM HUP

# vethB0 in hrA, its peer vethB1 in hrB; no IPv6 and a permanent neighbour, so nothing but the test sends on vethB0
up() { down; local n m; for n in hrA hrB; do ip netns add $n; ip netns exec $n sysctl -qw net.ipv6.conf.all.disable_ipv6=1 \
    net.ipv6.conf.default.disable_ipv6=1; ip -n $n link set lo up; done
  ip link add vethB0 netns hrA type veth peer name vethB1 netns hrB
  ip -n hrA addr add 10.0.0.1/24 dev vethB0; ip -n hrB addr add 10.0.0.2/24 dev vethB1
  ip -n hrA link set vethB0 up; ip -n hrB link set vethB1 up
  m=$(ip -n hrB -j link show dev vethB1 | jq -r '.[0].address'); ip -n hrA neigh replace 10.0.0.2 lladdr $m dev vethB0 nud permanent
  $IP -n hrA link set dev vethB0 tx_extra_headroom $1 || die "tx_extra_headroom $1"
  ip netns exec hrB taskset -c $CR netserver -4 -L 10.0.0.2 > /dev/null 2>&1 || die "netserver"; }
# tx_extra_headroom.bpf.o at tc egress of vethB0, rec.push = $PUSH; prints the map id
tcprog() { local p m s
  ip netns exec hrA tc qdisc add dev vethB0 clsact
  ip netns exec hrA tc filter add dev vethB0 egress bpf da obj $D/tx_extra_headroom.bpf.o sec tc || die "tc filter"
  p=$(ip netns exec hrA tc -j filter show dev vethB0 egress | jq -r '.[] | select(.options) | .options.prog.id')
  m=$($BPFTOOL prog show id $p -j | jq -r '.map_ids[]' | while read i; do $BPFTOOL map show id $i -j | jq -r 'select(.name == "rec") | .id'; done)
  s=$($BPFTOOL map show id $m -j | jq -r .bytes_value)
  $BPFTOOL map update id $m key hex 00 00 00 00 value hex $(printf '%02x %02x %02x %02x' $PUSH 0 0 0) $(yes 00 | head -$((s - 4)) | tr '\n' ' ') \
    || die "map update"; echo $m; }

[ -s $R ] || printf 'knob\ttc\tround\tdatagrams\ttc_seen\ttc_realloc_last\tout_vethB0\texpand_vethB0\texpand_by_caller\n' > $R
echo "# $(date -Is) $(uname -r) N=$N LEN=$LEN PUSH=$PUSH ROUNDS=$ROUNDS" >> $R
log "start: $(uname -r), $N datagrams of $LEN bytes per row, results $R"
set -- $ROWS; NR=$#
for r in $(seq $ROUNDS); do
  # rotate the row order every round
  for i in $(seq 0 $((NR - 1))); do row=$(echo $ROWS | cut -d' ' -f$(( (i + r - 1) % NR + 1 ))); k=${row%:*} mode=${row#*:}
    lg=$O/logs/knob$k-$mode-r$r; up $k; m=; [ $mode = tc ] && { m=$(tcprog); [ -n "$m" ] || die "tc program"; }
    bpftrace -q $D/count.bt none > $lg.bt 2>&1 & bt=$!; sleep 8
    # netperf sends N datagrams and 3 end-of-test datagrams, all to PORT; the push makes them unreadable, so netserver never
    # answers and netperf would wait 120 s: stop it once the datagrams are out. tc_seen counts what was sent.
    ip netns exec hrA timeout $((10 + N / 50000)) taskset -c $CS netperf -4 -H 10.0.0.2 -t UDP_STREAM -l -$((N * LEN)) -P 0 -- \
      -m $LEN -P ,$PORT > $lg.netperf 2>&1
    sleep 1; kill -INT $bt; wait $bt
    rec='{}'; [ -n "$m" ] && rec=$($BPFTOOL map dump id $m -j | jq -c '.[0].formatted.value // .[0].value'); echo "$rec" > $lg.rec
    out=$(awk -F': ' '/^@out\[vethB0\]/{print $2}' $lg.bt) ex=$(awk -F': ' '/^@expand\[vethB0,/{s += $2} END{print s + 0}' $lg.bt)
    by=$(grep '^@expand\[vethB0,' $lg.bt | sed -E 's/^@expand\[vethB0, ([^]]*)\]: /\1=/' | tr '\n' ' ')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' $k $mode $r $N \
      "$(jq -r '.count // "NA"' <<< "$rec")" "$(jq -r '.realloc // "NA"' <<< "$rec")" "${out:-0}" $ex "${by:-none}" >> $R
    log "round $r knob $k $mode: out_vethB0=${out:-0} expand_vethB0=$ex rec=$rec"
  done
done
# median and range of pskb_expand_head() calls on vethB0 per row, and of the datagrams the tc program saw
summary() { echo "tx_extra_headroom, tc: pskb_expand_head on vethB0, median (range); datagrams seen by tc, median (range)"
  awk -F'\t' '!/^#/ && NR > 1 {k = $1 " " $2; e[k] = e[k] " " $8; t[k] = t[k] " " $5}
  function mr(l,  a, n, i, j, x) { n = split(l, a, " ")
    for (i = 2; i <= n; i++) { x = a[i]; for (j = i - 1; j >= 1 && a[j] + 0 > x + 0; j--) a[j + 1] = a[j]; a[j + 1] = x }
    return (n % 2 ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2) " (" a[1] "-" a[n] ", " n " rounds)" }
  END { for (k in e) printf "%-9s %-36s %s\n", k, mr(e[k]), mr(t[k]) }' $R | sort -n -k1,1 -k2,2r; }
summary | tee $O/summary.txt
log "DONE"
