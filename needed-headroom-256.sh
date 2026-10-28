#!/bin/bash
# needed-headroom-256.sh: cost of raising veth needed_headroom to 256 (Jesper Dangaard Brouer's veth RFC 4/4) on two machines.
# This node (host) runs net-next; the sender sends to the host's mlx5 NIC, which runs an XDP_PASS program. The host forwards into
# vethB0 (host netns) / vethB1 (netns hrB, XDP_PASS). Variants: stock and headroom256, veth.ko built the same way from the same tree.
# Run on the host as root, in tmux:
#   ./needed-headroom-256.sh build                      # net-next main, kernel + both veth.ko; then reboot into it
#   ./needed-headroom-256.sh run 2>&1 | tee run.log     # count runs with bpftrace, then ROUNDS interleaved rounds
# Env: SND=10.0.1.2 HOST_IP=10.0.1.1 ROUNDS=9 DUR=15 RRDUR=20 CS=2 CR=4 T=<kernel tree> O=<results dir>
export LC_ALL=C
D=$(cd "$(dirname "$0")" && pwd) U=${SUDO_USER:-$USER}; H=$(getent passwd $U | cut -d: -f6)
T=${T:-$H/net-next} M=$D/mods O=${O:-$D/results/needed-headroom-256-$(hostname -s)-$(date +%m%d)}
SND=${SND:-10.0.1.2} HOST_IP=${HOST_IP:-10.0.1.1} ROUNDS=${ROUNDS:-9} DUR=${DUR:-15} RRDUR=${RRDUR:-20}
CS=${CS:-2} CR=${CR:-4}   # host: NIC IRQ + iperf3/netperf client CPU, server CPU in hrB; sender: pktgen and iperf3 client CPU
VARIANTS="stock headroom256" TESTS="forward_tcp forward_udp64 local_tcp local_tcp_rev tcp_rr"
NETNEXT=https://git.kernel.org/pub/scm/linux/kernel/git/netdev/net-next.git

log() { echo "$(date +%T) $*"; }
die() { log "FATAL: $*"; exit 2; }
[ $EUID -eq 0 ] || die "run as root"

build() {
  apt-get update -q && apt-get install -yq git build-essential bc bison flex libssl-dev libelf-dev libdw-dev dwarves zstd \
    clang libbpf-dev iperf3 netperf bpftrace sysstat jq ethtool || die "apt"
  [ -d $T ] || runuser -u $U -- git clone --depth 1 -b main $NETNEXT $T || die "clone"
  cd $T; mkdir -p $O; git log -1 --format='net-next %H %s' | tee $O/kernel.txt
  # keep veth, pktgen and the NIC drivers as modules
  modprobe veth; modprobe pktgen; cp /boot/config-$(uname -r) .config; make olddefconfig
  yes '' | make localmodconfig > /dev/null; scripts/config --set-str SYSTEM_TRUSTED_KEYS '' --set-str SYSTEM_REVOCATION_KEYS ''
  make olddefconfig; grep -qx CONFIG_VETH=m .config || die "CONFIG_VETH is not m"
  make -j$(nproc) > $O/kernel-build.log 2>&1 || die "make, see $O/kernel-build.log"
  make modules_install install > /dev/null || die "install"
  # headroom256 = stock + RFC 4/4 via git am; both veth.ko are built out of tree against this tree
  git -c user.name=bench -c user.email=bench@localhost am $D/jesper-veth-rfc-4of4.mbox 2>&1 | tee -a $O/kernel.txt
  [ ${PIPESTATUS[0]} = 0 ] || die "git am of RFC 4/4 failed"
  git diff HEAD~ --stat | tee -a $O/kernel.txt
  for v in $VARIANTS; do mkdir -p $M/$v; echo 'obj-m := veth.o' > $M/$v/Makefile; done
  git show HEAD~:drivers/net/veth.c > $M/stock/veth.c; cp drivers/net/veth.c $M/headroom256/veth.c
  for v in $VARIANTS; do make -C $T M=$M/$v modules > /dev/null || die "veth.ko $v"
    [ -f certs/signing_key.pem ] && scripts/sign-file sha512 certs/signing_key.pem certs/signing_key.x509 $M/$v/veth.ko; done
  clang -O2 -g -target bpf -I/usr/include/$(uname -m)-linux-gnu -c tools/testing/selftests/bpf/progs/xdp_dummy.c -o $D/xdp_dummy.bpf.o
  log "built $(make -s kernelrelease); reboot into it, then run"; }

[ "$1" = build ] && { build; exit; }
[ "$1" = run ] || die "usage: $0 build|run"

S() { ssh -i $H/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR $U@$SND "$@"; }
R=$O/results.tsv L=$O/logs
res() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> $R; log "RESULT $*"; }   # test variant round metric value extra
state() { # $1 = test NIC; node state for the record
  local b=$(ethtool -i $1 | awk '/bus-info/{print $2}') i
  echo "== $(hostname) $(date -Is)"; uname -r; cat /proc/cmdline
  lscpu | grep -E '^(Model name|CPU\(s\)|Thread|Socket|NUMA node)'
  echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo none) driver: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null) no_turbo: $(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)"
  echo "smt: $(cat /sys/devices/system/cpu/smt/active) irqbalance: $(systemctl is-active irqbalance) nic numa: $(cat /sys/class/net/$1/device/numa_node)"
  ethtool -i $1; ethtool $1 | grep -E 'Speed|Link detected'; ip -d link show $1 | head -4
  ethtool -l $1; ethtool -g $1; ethtool -c $1; ethtool -a $1
  ethtool -k $1 | grep -E '^(rx-gro|generic-receive|large-receive|tcp-segm|generic-segm|rx-checksumming|tx-checksumming|ntuple|rx-gro-hw|rx-udp-gro-forwarding)'
  ethtool --show-priv-flags $1; ethtool -n $1 | head -3; echo "rps_cpus rx-0: $(cat /sys/class/net/$1/queues/rx-0/rps_cpus)"
  for i in $(grep "mlx5_comp[0-9]*@pci:$b" /proc/interrupts | cut -d: -f1); do echo "irq $i $(grep "^ *$i:" /proc/interrupts | awk '{print $NF}') -> cpu $(cat /proc/irq/$i/smp_affinity_list)"; done
  sysctl net.core.default_qdisc net.core.netdev_budget net.core.netdev_max_backlog net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem \
    net.ipv4.tcp_wmem net.ipv4.tcp_congestion_control net.ipv4.ip_forward net.core.bpf_jit_enable net.core.busy_poll net.core.rps_sock_flow_entries
  ip -br addr; ip route; }

# preflight, before the trap: an abort here changes nothing
NIC=$(ip -o -4 addr show | awk -v a=$HOST_IP/ 'index($4, a) == 1 {print $2}'); [ -n "$NIC" ] || die "no NIC with $HOST_IP"
ethtool -i $NIC | grep -q 'driver: mlx5_core' || die "$NIC is not mlx5"
SIF=$(S "ip -o -4 addr show" < /dev/null | awk -v a=$SND/ 'index($4, a) == 1 {print $2}'); [ -n "$SIF" ] || die "sender $SND"
HMAC=$(cat /sys/class/net/$NIC/address) BUS=$(ethtool -i $NIC | awk '/bus-info/{print $2}')
for t in iperf3 netperf netserver mpstat jq bpftrace taskset; do command -v $t > /dev/null || die "missing $t"; done
for v in $VARIANTS; do [ -f $M/$v/veth.ko ] || die "no $M/$v/veth.ko, run build"; done
[ -f $D/xdp_dummy.bpf.o ] || die "no xdp_dummy.bpf.o"
[ -z "$(ip netns list)" ] || die "netns exist: $(ip netns list | tr '\n' ' ')"
[ -z "$(ip -br link show type veth)" ] || die "veth devices exist"
[ -d $T/samples/pktgen ] || die "no $T/samples/pktgen"
mkdir -p $L; [ -s $O/kernel.txt ] || git -C $T log -2 --format='%H %s' > $O/kernel.txt

CH0=$(ethtool -l $NIC | awk '/^Current/{c=1} c && /^Combined/{print $2; exit}')
restore() { log "restore"; down; rmmod veth 2>/dev/null; modprobe veth; ip link set dev $NIC xdpdrv off
  ethtool -L $NIC combined $CH0; S "sudo sh -c 'echo stop > /proc/net/pktgen/pgctrl'" < /dev/null 2>/dev/null
  dmesg | tail -n +$((DM0 + 1)) > $L/dmesg-new.txt; log EXIT; }
DM0=$(dmesg | wc -l); trap restore EXIT; trap 'exit 130' INT TERM HUP; trap '' PIPE

# both: performance governor; host: one channel, its IRQ on CPU $CS, XDP_PASS on the NIC; sender: tools, pktgen samples, route to hrB
GOV='for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $g; done'
bash -c "$GOV"; S "sudo bash -c '$GOV'" < /dev/null
systemctl stop irqbalance 2>/dev/null; sysctl -qw net.ipv4.ip_forward=1
ethtool -L $NIC combined 1 || die "ethtool -L"
ip link set dev $NIC xdpdrv obj $D/xdp_dummy.bpf.o sec xdp program xdp_dummy_prog || die "xdp on $NIC"
IRQ=$(grep "mlx5_comp0@pci:$BUS" /proc/interrupts | cut -d: -f1 | tr -d ' '); echo $CS > /proc/irq/$IRQ/smp_affinity_list || die "irq $IRQ"
S "command -v mpstat > /dev/null || sudo apt-get install -yq iperf3 sysstat; sudo modprobe pktgen; sudo ip route replace 10.77.2.0/24 via $HOST_IP" < /dev/null > /dev/null || die "sender setup"
tar -C $T/samples -c pktgen | S "rm -rf pktgen; tar -x" || die "copy pktgen samples"
sleep 3; state $NIC > $O/env-host.txt 2>&1; { declare -f state; echo "state $SIF"; } | S "sudo bash -s" > $O/env-sender.txt 2>&1
[ -s $R ] || printf 'test\tvariant\tround\tmetric\tvalue\textra\n' > $R
echo "# $(date -Is) ROUNDS=$ROUNDS DUR=$DUR RRDUR=$RRDUR CS=$CS CR=$CR NIC=$NIC SIF=$SIF" >> $R
log "start: NIC $NIC (irq $IRQ on cpu $CS), sender $SND $SIF, results $R"

down() { ip netns pids hrB 2>/dev/null | xargs -r kill 2>/dev/null; sleep 0.3; ip netns pids hrB 2>/dev/null | xargs -r kill -9 2>/dev/null; ip netns del hrB 2>/dev/null; }
# vethB0 (host) / vethB1 (hrB, XDP_PASS); no IPv6 on either end, so no timer sends packets from another CPU
up() { down; ip netns add hrB; ip netns exec hrB sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
  ip -n hrB link set lo up; ip link add vethB0 type veth peer name vethB1 netns hrB; sysctl -qw net.ipv6.conf.vethB0.disable_ipv6=1
  ip addr add 10.77.2.1/24 dev vethB0; ip -n hrB addr add 10.77.2.2/24 dev vethB1; ip link set vethB0 up; ip -n hrB link set vethB1 up
  ip -n hrB route add default via 10.77.2.1
  ip -n hrB link set dev vethB1 xdpdrv obj $D/xdp_dummy.bpf.o sec xdp program xdp_dummy_prog || die "xdp on vethB1"
  ping -c1 -W1 10.77.2.2 > /dev/null || die "topology"
  [ -n "$BTF" ] && { bpftrace -q $D/count.bt $NIC > $BTF 2>&1 & BT=$!; sleep 8; }; }
swap() { down; local i; for i in $(seq 30); do lsmod | grep -q '^veth ' || break; rmmod veth 2>/dev/null && break; sleep 1; done
  lsmod | grep -q '^veth ' && die "rmmod veth"; insmod $M/$1/veth.ko || die "insmod $1"
  [ "$(cat /sys/module/veth/srcversion)" = "$(modinfo -F srcversion $M/$1/veth.ko)" ] || die "srcversion $1"; log "veth = $1"; }
wport() { local i; for i in $(seq 50); do ip netns exec hrB ss -Hltn "sport = :$1" | grep -q . && return 0; sleep 0.1; done; return 1; }
# counters "t NIC(rx rxdrop rxmissed tx txdrop) vethB0(...) vethB1(...)": NIC fields 2-6, vethB0 7-11, vethB1 12-16
st() { ip "$@" | jq -r '.[0].stats64|"\(.rx.packets) \(.rx.dropped) \(.rx.missed_errors // 0) \(.tx.packets) \(.tx.dropped)"'; }
snap() { echo "$(date +%s.%N) $(st -j -s link show dev $NIC) $(st -j -s link show dev vethB0) $(st -n hrB -j -s link show dev vethB1)"; }
delta() { awk -v a="$1" -v b="$2" 'BEGIN{split(a,x," "); split(b,y," "); split("nic vethB0 vethB1",n," "); split("rx rxdrop rxmissed tx txdrop",f," "); printf "dt=%.2f", y[1]-x[1]
  for (i = 1; i <= 3; i++) for (j = 1; j <= 5; j++) { o = 5*i - 4 + j; printf " %s_%s=%d", n[i], f[j], y[o]-x[o] } }'; }
rate() { awk -v a="$1" -v b="$2" -v k=$3 'BEGIN{split(a,x," "); split(b,y," "); printf "%.0f", (y[k]-x[k])/(y[1]-x[1])}'; }
mp() { mpstat -P ALL $1 1 > $2 2>&1 & }
# called in $(...), which cannot wait for our children: poll for the Average lines (10 s at most)
avg() { local i; for i in $(seq 50); do grep -q '^Average' $1 && return; sleep 0.2; done; }
# sender CPU $CS busy over the same window
smp() { S "mpstat -P $CS $1 1" < /dev/null > $2 2>&1 & }
smpget() { avg $1; awk '$1=="Average:" && $2~/^[0-9]+$/ {printf " sender_cpu%s_busy=%.1f", $2, 100-$NF}' $1; }
# busy and softirq share of the two pinned CPUs, then every other CPU with more than 5% softirq
mpget() { avg $1; awk -v a=$CS -v b=$CR '$1=="Average:" && ($2==a || $2==b) {printf " cpu%s_busy=%.1f cpu%s_soft=%.1f", $2, 100-$NF, $2, $8}
  $1=="Average:" && $2~/^[0-9]+$/ && $2!=a && $2!=b && $8>5 {printf " cpu%s_soft=%.1f", $2, $8}' $1; }
nicstat() { ethtool -S $NIC | grep -E '^ +(rx_out_of_buffer|rx_discards_phy|rx_packets_phy|rx_xdp_drop|rx_buff_alloc_err):' | tr -s ' \n' ' '; }

# iperf3 server in hrB on CPU $CR; client $2 (local: this netns, sender: over ssh) on CPU $CS; counters and CPU over $DUR after 2 s
iperf_run() { local lg=$1 where=$2 s c; shift 2
  ip netns exec hrB timeout $((DUR + 30)) taskset -c $CR iperf3 -s -1 -J > $lg.srv.json 2>&1 & s=$!
  wport 5201 || { kill $s; return 1; }
  if [ $where = sender ]; then S "timeout $((DUR + 30)) taskset -c $CS iperf3 -c 10.77.2.2 -t $((DUR + 1)) -O 2 -J $*" < /dev/null > $lg.cli.json 2>&1 & c=$!
  else timeout $((DUR + 30)) taskset -c $CS iperf3 -c 10.77.2.2 -t $((DUR + 1)) -O 2 -J "$@" > $lg.cli.json 2>&1 & c=$!; fi
  sleep 2; IA=$(snap); mp $DUR $lg.mpstat; [ $where = sender ] && smp $DUR $lg.sender-mpstat; sleep $DUR; IB=$(snap); CPU=$(mpget $lg.mpstat)
  [ $where = sender ] && CPU+=$(smpget $lg.sender-mpstat); wait $c; wait $s; }
tcp() { # $1 test, $2 log prefix, $3 client side, rest: iperf3 client options
  local t=$1 lg=$2 w=$3; shift 3
  if iperf_run $lg $w "$@"; then
    res $t $v $r gbps "$(jq -r '(.end.sum_received.bits_per_second / 1e6 | round) / 1000' $lg.cli.json)" \
      "retrans=$(jq -r '.end.sum_sent.retransmits' $lg.cli.json)$CPU $(delta "$IA" "$IB")"
  else res $t $v $r gbps NA "iperf3 failed"; fi; }
forward_tcp() { up; tcp forward-tcp $1 sender; }       # sender -> NIC (XDP) -> ip_forward -> vethB0 -> vethB1 (XDP) -> hrB
local_tcp() { up; tcp local-tcp $1 local; }            # host -> vethB0 -> vethB1 (XDP) -> hrB
local_tcp_rev() { up; tcp local-tcp-rev $1 local -R; } # hrB -> vethB1 -> vethB0 -> host
forward_udp64() { # pktgen on the sender: 60-byte frames (64 on the wire), one UDP flow to 10.77.2.2, burst 32 (sample default)
  local lg=$1 p a b c n0; up; n0=$(nicstat)
  S "sudo timeout -s INT $((DUR + 30)) ./pktgen/pktgen_sample03_burst_single_flow.sh -i $SIF -d 10.77.2.2 -m $HMAC -s 60 -t 1 -f $CS -n ${PGN:-0}" < /dev/null > $lg.pktgen 2>&1 & p=$!
  if [ -n "$PGN" ]; then wait $p; return; fi
  sleep 2; a=$(snap); mp $DUR $lg.mpstat; smp $DUR $lg.sender-mpstat; sleep $DUR; b=$(snap); c=$(mpget $lg.mpstat)$(smpget $lg.sender-mpstat)
  S "sudo sh -c 'echo stop > /proc/net/pktgen/pgctrl'" < /dev/null; wait $p
  echo "before: $n0" > $lg.nicstat; echo "after: $(nicstat)" >> $lg.nicstat
  res forward-udp64 $v $r vethB1_rx_pps $(rate "$a" "$b" 12) "nic_rx_pps=$(rate "$a" "$b" 2) pktgen=$(grep -oE '[0-9]+pps' $lg.pktgen | head -1)$c $(delta "$a" "$b")"; }
tcp_rr() { # netperf TCP_RR 1-byte request and response: host CPU $CS -> netserver in hrB on CPU $CR
  local lg=$1 ns out c; up
  ip netns exec hrB taskset -c $CR netserver -D -4 > $lg.netserver 2>&1 & ns=$!
  if wport 12865; then
    mp $RRDUR $lg.mpstat
    timeout $((RRDUR + 30)) taskset -c $CS netperf -4 -H 10.77.2.2 -t TCP_RR -l $RRDUR -P 0 -- -r 1,1 \
      -o THROUGHPUT,MEAN_LATENCY,P50_LATENCY,P99_LATENCY > $lg.netperf 2>&1
    c=$(mpget $lg.mpstat); out=$(tail -1 $lg.netperf)
    res tcp-rr $v $r tps "${out%%,*}" "mean,p50,p99_us=${out#*,}$c"
  else res tcp-rr $v $r tps NA "netserver did not listen"; fi
  kill $ns 2>/dev/null; wait $ns 2>/dev/null; }

# count runs: bpftrace on, short traffic, no throughput result
for v in $VARIANTS; do swap $v
  for t in $TESTS; do log "count $v $t"; BTF=$L/count-$t-$v.bt
    if [ $t = forward_udp64 ]; then PGN=200000 $t $L/count-$t-$v; else DUR=5 RRDUR=5 R=$L/count-results.tsv $t $L/count-$t-$v; fi
    kill -INT $BT; wait $BT; BTF=
  done
done
# rounds: both variants per round, order swapped every round; fresh topology per test
for r in $(seq $ROUNDS); do
  [ $((r % 2)) = 1 ] && order="stock headroom256" || order="headroom256 stock"
  for v in $order; do swap $v
    for t in $TESTS; do log "round $r $v $t"; $t $L/$t-$v-r$r; done
  done
done
log "DONE: $(grep -vc -e '^#' -e '^test' $R) result lines in $R"
