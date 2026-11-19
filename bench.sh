#!/bin/bash
# bench.sh: the two performance tables of the tx_extra_headroom v2 cover letter, on two machines.
# This node (host) runs net-next $BASE; the sender sends to the host's mlx5 NIC, which runs an XDP_PASS program. The host
# forwards between the NIC and vethB0 (host netns) / vethB1 (netns hrB).
#   Regression table, base kernel: needed_headroom 256 (Jesper Dangaard Brouer's veth RFC 4/4, rebased) vs stock veth.ko.
#   Gain table, series kernel (base + the tx_extra_headroom v2 series + xdp-tx-extra-headroom-switch.patch, release
#   -txhr): UDP from a socket, $MSG-byte datagrams, tx_extra_headroom on vs off in the same kernel and boot. off: XDP
#   with the switch at 0, the push without its decl tag, the veth pair without VETH_INFO_TX_EXTRA_HEADROOM.
# Run on the host as root, in tmux:
#   ./bench.sh build                                 # both kernels, both veth.ko, bpftool, BPF objects; then reboot
#   ./bench.sh run 2>&1 | tee run.log                # once per boot; picks the variants from the running kernel
# Env: SND=10.0.1.2 HOST_IP=10.0.1.1 ROUNDS=9 DUR=15 CS=2 CR=4 MSG=1400 T=<kernel tree> O=<results dir> VARIANTS= TESTS=
export LC_ALL=C
D=$(cd "$(dirname "$0")" && pwd) U=${SUDO_USER:-$USER}; H=$(getent passwd $U | cut -d: -f6)
BASE=d6816d9a93b66a12bf01e10037e377f3333ad6cc NETNEXT=https://git.kernel.org/pub/scm/linux/kernel/git/netdev/net-next.git
T=${T:-$H/net-next} TX=${TX:-$H/net-next-txhr} M=$D/mods O=${O:-$D/results/$(hostname -s)-$(date +%m%d)}
SND=${SND:-10.0.1.2} HOST_IP=${HOST_IP:-10.0.1.1} ROUNDS=${ROUNDS:-9} DUR=${DUR:-15}
CS=${CS:-2} CR=${CR:-4}   # host: NIC IRQ + client CPU, server CPU in hrB; sender: pktgen CPU
REGRESSION="forward_udp local_tcp_rev" GAIN="plain_udp xdp_udp xdpdrop_udp push_udp uplink_udp"
BPFTOOL=$TX/tools/bpf/bpftool/bpftool YNL="$TX/tools/net/ynl/pyynl/cli.py --spec $TX/Documentation/netlink/specs/rt-link.yaml"
SW=/sys/module/kernel/parameters/xdp_tx_extra_headroom   # xdp-tx-extra-headroom-switch.patch
PORT=9999 MSG=${MSG:-1400}   # PORT: UDP_TEST_PORT in push.bpf.c; MSG: UDP payload bytes

log() { echo "$(date +%T) $*"; }
die() { log "FATAL: $*"; exit 2; }
[ $EUID -eq 0 ] || die "run as root"

build() {
  apt-get update -q && apt-get install -yq git build-essential bc bison flex libssl-dev libelf-dev libdw-dev dwarves zstd \
    clang llvm libbpf-dev libcap-dev iperf3 netperf bpftrace sysstat jq ethtool python3-yaml || die "apt"
  if [ ! -d $T ]; then runuser -u $U -- git init -q $T && runuser -u $U -- git -C $T fetch -q --depth 1 $NETNEXT $BASE &&
    runuser -u $U -- git -C $T checkout -q --detach FETCH_HEAD || die "fetch $BASE"; fi
  cd $T; [ "$(git rev-parse HEAD)" = $BASE ] || die "$T is at $(git rev-parse HEAD), not $BASE"
  mkdir -p $O; git log -1 --format='net-next %H %s' | tee $O/kernel.txt
  # base kernel: the distro config cut to the loaded modules; veth and pktgen stay modules
  modprobe veth; modprobe pktgen; cp /boot/config-$(uname -r) .config; make olddefconfig
  yes '' | make localmodconfig > /dev/null; scripts/config --set-str SYSTEM_TRUSTED_KEYS '' --set-str SYSTEM_REVOCATION_KEYS ''
  make olddefconfig; for c in VETH=m NET_XGRESS=y DEBUG_INFO_BTF=y; do grep -qx CONFIG_$c .config || die "CONFIG_$c"; done
  make -j$(nproc) > $O/kernel-build.log 2>&1 || die "make, see $O/kernel-build.log"
  make modules_install install > /dev/null || die "install"
  # series kernel: the same config on base + the series, LOCALVERSION -txhr
  [ -d $TX ] || runuser -u $U -- git worktree add -q --detach $TX $BASE || die "worktree"
  cd $TX; [ "$(git rev-parse HEAD)" = $BASE ] && { runuser -u $U -- git -c user.name=bench -c user.email=bench@localhost \
    am $D/tx-extra-headroom-v2.mbox $D/xdp-tx-extra-headroom-switch.patch || die "git am of the series"; }
  git log --oneline $BASE..HEAD | tee -a $O/kernel.txt
  cp $T/.config .config; scripts/config --set-str LOCALVERSION -txhr; make olddefconfig
  make -j$(nproc) > $O/kernel-build-txhr.log 2>&1 || die "make, see $O/kernel-build-txhr.log"
  make modules_install install > /dev/null || die "install -txhr"
  make -C tools/bpf/bpftool -j$(nproc) > /dev/null 2>&1 || die "bpftool"
  # headroom256 = stock + RFC 4/4 via git am; both veth.ko are built out of tree against the base tree
  cd $T; git -c user.name=bench -c user.email=bench@localhost am $D/jesper-veth-rfc-4of4.mbox 2>&1 | tee -a $O/kernel.txt
  [ ${PIPESTATUS[0]} = 0 ] || die "git am of RFC 4/4 failed"
  git diff HEAD~ --stat | tee -a $O/kernel.txt
  for v in stock headroom256; do mkdir -p $M/$v; echo 'obj-m := veth.o' > $M/$v/Makefile; done
  git show HEAD~:drivers/net/veth.c > $M/stock/veth.c; cp drivers/net/veth.c $M/headroom256/veth.c
  for v in stock headroom256; do make -C $T M=$M/$v modules > /dev/null || die "veth.ko $v"
    [ -f certs/signing_key.pem ] && scripts/sign-file sha512 certs/signing_key.pem certs/signing_key.x509 $M/$v/veth.ko; done
  for f in tools/testing/selftests/bpf/progs/xdp_dummy.c tools/testing/selftests/net/lib/xdp_native.bpf.c $D/push.bpf.c; do
    clang -O2 -g -target bpf -I/usr/include/$(uname -m)-linux-gnu -c $f -o $D/$(basename $f .c).bpf.o || die "clang $f"; done
  mv $D/push.bpf.bpf.o $D/push.bpf.o; mv $D/xdp_native.bpf.bpf.o $D/xdp_native.bpf.o
  clang -O2 -g -target bpf -DNO_DECL_TAG -I/usr/include/$(uname -m)-linux-gnu -c $D/push.bpf.c -o $D/push-notag.bpf.o || die "clang push-notag"
  log "built $(make -s kernelrelease) and $(make -s -C $TX kernelrelease); reboot into one of them, then run"; }

[ "$1" = build ] && { build; exit; }
[ "$1" = run ] || die "usage: $0 build|run"

# the running kernel picks the variants: the base kernel runs the regression table, the -txhr kernel the gain table
case $(uname -r) in
  *-txhr*) VARIANTS=${VARIANTS:-"on off"} TESTS=${TESTS:-$GAIN} KT=$TX ;;
  *) VARIANTS=${VARIANTS:-"stock headroom256"} TESTS=${TESTS:-$REGRESSION} KT=$T ;;
esac
tests_of() { case $1 in on|off) echo " $TESTS " | tr ' ' '\n' | grep -xF -f <(echo $GAIN | tr ' ' '\n') ;;
  *) echo " $TESTS " | tr ' ' '\n' | grep -xF -f <(echo $REGRESSION | tr ' ' '\n') ;; esac; }

S() { ssh -i $H/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR $U@$SND "$@"; }
R=$O/bench-results.tsv L=$O/logs
res() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$(uname -r)" "$6" >> $R; log "RESULT $*"; }
state() { # $1 = test NIC; node state for the record
  local b=$(ethtool -i $1 | awk '/bus-info/{print $2}') i
  echo "== $(hostname) $(date -Is)"; uname -r; cat /proc/cmdline
  lscpu | grep -E '^(Model name|CPU\(s\)|Thread|Socket|NUMA node)'
  echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo none) driver: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null) no_turbo: $(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)"
  echo "energy_perf_bias: $(cat /sys/devices/system/cpu/cpu0/power/energy_perf_bias) idle states disabled: $(cat /sys/devices/system/cpu/cpu0/cpuidle/state*/disable | tr -d '\n') MHz: $(grep -m1 MHz /proc/cpuinfo | cut -d: -f2)"
  echo "aspm: $(cat /sys/module/pcie_aspm/parameters/policy) uncore kHz: $(cat /sys/devices/system/cpu/intel_uncore_frequency/package_*/{min,max}_freq_khz | tr '\n' ' ')wq power_efficient: $(cat /sys/module/workqueue/parameters/power_efficient)"
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
for t in iperf3 netperf netserver mpstat jq bpftrace taskset $BPFTOOL; do command -v $t > /dev/null || die "missing $t"; done
for v in stock headroom256; do [ -f $M/$v/veth.ko ] || die "no $M/$v/veth.ko, run build"; done
for f in xdp_dummy xdp_native push; do [ -f $D/$f.bpf.o ] || die "no $f.bpf.o"; done
grep -q 'name: tx-extra-headroom' $TX/Documentation/netlink/specs/rt-link.yaml || die "rt-link.yaml in $TX has no veth attribute"
[ -z "$(ip netns list)" ] || die "netns exist: $(ip netns list | tr '\n' ' ')"
[ -z "$(ip -br link show type veth)" ] || die "veth devices exist"
[ -d $T/samples/pktgen ] || die "no $T/samples/pktgen"
mkdir -p $L; [ -s $O/kernel.txt ] || git -C $KT log --format='%H %s' HEAD ^$BASE^@ > $O/kernel.txt

down() { ip netns pids hrB 2>/dev/null | xargs -r kill 2>/dev/null; sleep 0.3; ip netns pids hrB 2>/dev/null | xargs -r kill -9 2>/dev/null
  ip netns del hrB 2>/dev/null; $BPFTOOL net detach tcx_egress dev $NIC 2>/dev/null; rm -rf /sys/fs/bpf/txhr-bench; }
CH0=$(ethtool -l $NIC | awk '/^Current/{c=1} c && /^Combined/{print $2; exit}')
restore() { log "restore"; down; rmmod veth 2>/dev/null; modprobe veth; [ -w $SW ] && echo 1 > $SW; ip link set dev $NIC xdpdrv off
  ethtool -L $NIC combined $CH0; S "sudo sh -c 'echo stop > /proc/net/pktgen/pgctrl'; pkill -x netserver" < /dev/null 2>/dev/null
  dmesg | tail -n +$((DM0 + 1)) > $L/dmesg-$(uname -r)-$(date +%H%M).txt; log EXIT; }
DM0=$(dmesg | wc -l); trap restore EXIT; trap 'exit 130' INT TERM HUP; trap '' PIPE

# both: performance governor and energy bias, turbo off, idle states deeper than C1 off, uncore at its maximum
# (until reboot; workqueue.power_efficient=0 is on the kernel command line; the BIOS owns ASPM); host: one
# channel, its IRQ on CPU $CS, XDP_PASS on the NIC; sender: tools, pktgen samples, route to hrB, netserver for the uplink test
TUNE='echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo; for c in /sys/devices/system/cpu/cpu[0-9]*; do echo performance > $c/cpufreq/scaling_governor; echo 0 > $c/power/energy_perf_bias; for i in $c/cpuidle/state[2-9]*; do echo 1 > $i/disable; done; done; for u in /sys/devices/system/cpu/intel_uncore_frequency/package_*; do cat $u/initial_max_freq_khz > $u/min_freq_khz; done'
bash -c "$TUNE"; S "sudo bash -c '$TUNE'" < /dev/null
systemctl stop irqbalance 2>/dev/null; sysctl -qw net.ipv4.ip_forward=1
ethtool -L $NIC combined 1 || die "ethtool -L"
ip link set dev $NIC xdpdrv obj $D/xdp_dummy.bpf.o sec xdp program xdp_dummy_prog || die "xdp on $NIC"
IRQ=$(grep "mlx5_comp0@pci:$BUS" /proc/interrupts | cut -d: -f1 | tr -d ' '); echo $CS > /proc/irq/$IRQ/smp_affinity_list || die "irq $IRQ"
S "command -v netserver > /dev/null || { sudo apt-get update -q && sudo apt-get install -yq iperf3 sysstat netperf; }; sudo modprobe pktgen; sudo ip route replace 10.77.2.0/24 via $HOST_IP; pgrep -x netserver > /dev/null || netserver -4" < /dev/null > /dev/null || die "sender setup"
tar -C $T/samples -c pktgen | S "rm -rf pktgen; tar -x" || die "copy pktgen samples"
sleep 3; state $NIC > $O/env-host-$(uname -r).txt 2>&1; { declare -f state; echo "state $SIF"; } | S "sudo bash -s" > $O/env-sender.txt 2>&1
[ -s $R ] || printf 'test\tvariant\tround\tmetric\tvalue\tkernel\textra\n' > $R
echo "# $(date -Is) $(uname -r) VARIANTS=$VARIANTS ROUNDS=$ROUNDS DUR=$DUR CS=$CS CR=$CR NIC=$NIC SIF=$SIF" >> $R
log "start: $(uname -r), variants $VARIANTS, NIC $NIC (irq $IRQ on cpu $CS), sender $SND $SIF, results $R"

# up <XDP mode on vethB1: xdpdrv, xdpgeneric or none> [VETH_INFO_TX_EXTRA_HEADROOM]
# vethB0 (host) / vethB1 (hrB); no IPv6 on either end, so no timer sends packets from another CPU
up() { local p; down; ip netns add hrB; ip netns exec hrB sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
  ip -n hrB link set lo up
  if [ -n "$2" ]; then $YNL --do newlink --create --excl --json "{\"ifname\": \"vethB0\", \"linkinfo\": {\"kind\": \"veth\",
      \"data\": {\"tx-extra-headroom\": $2}}}" > /dev/null || die "YNL newlink"
    p=$(ip -j link show | jq -r --argjson i $(cat /sys/class/net/vethB0/iflink) '.[] | select(.ifindex == $i) | .ifname')
    ip link set $p name vethB1 netns hrB || die "move $p"
  else ip link add vethB0 type veth peer name vethB1 netns hrB; fi
  sysctl -qw net.ipv6.conf.vethB0.disable_ipv6=1
  ip addr add 10.77.2.1/24 dev vethB0; ip -n hrB addr add 10.77.2.2/24 dev vethB1; ip link set vethB0 up; ip -n hrB link set vethB1 up
  ip -n hrB route add default via 10.77.2.1
  [ $1 = none ] || ip -n hrB link set dev vethB1 $1 obj $D/xdp_dummy.bpf.o sec xdp program xdp_dummy_prog || die "xdp on vethB1"
  ping -c1 -W1 10.77.2.2 > /dev/null || die "topology"
  [ -n "$BTF" ] && { bpftrace -q $D/bench.bt $NIC > $BTF 2>&1 & BT=$!; sleep 8; }; }
swap() { down; local i; for i in $(seq 30); do lsmod | grep -q '^veth ' || break; rmmod veth 2>/dev/null && break; sleep 1; done
  lsmod | grep -q '^veth ' && die "rmmod veth"
  case $1 in on|off) modprobe veth || die "modprobe veth"; [ -z "$(modinfo -F filename veth | grep -v "/$(uname -r)/")" ] || die "veth"
      echo $([ $1 = on ] && echo 1 || echo 0) > $SW || die "$SW";;
    *) insmod $M/$1/veth.ko || die "insmod $1"
      [ "$(cat /sys/module/veth/srcversion)" = "$(modinfo -F srcversion $M/$1/veth.ko)" ] || die "srcversion $1";; esac
  log "veth = $1, xdp_tx_extra_headroom $(cat $SW 2>/dev/null)"; }
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
local_tcp_rev() { up xdpdrv; tcp local-tcp-rev $1 local -R; } # hrB -> vethB1 -> vethB0 -> host
forward_udp() { # pktgen on the sender: frames with $MSG bytes of UDP payload, one UDP flow to
  # 10.77.2.2, burst 32 (sample default)
  local lg=$1 p a b c n0; up xdpdrv; n0=$(nicstat)
  S "sudo timeout -s INT $((DUR + 30)) ./pktgen/pktgen_sample03_burst_single_flow.sh -i $SIF -d 10.77.2.2 -m $HMAC -s $((MSG + 42)) -t 1 -f $CS -n ${PGN:-0}" < /dev/null > $lg.pktgen 2>&1 & p=$!
  if [ -n "$PGN" ]; then wait $p; return; fi
  sleep 2; a=$(snap); mp $DUR $lg.mpstat; smp $DUR $lg.sender-mpstat; sleep $DUR; b=$(snap); c=$(mpget $lg.mpstat)$(smpget $lg.sender-mpstat)
  S "sudo sh -c 'echo stop > /proc/net/pktgen/pgctrl'" < /dev/null; wait $p
  echo "before: $n0" > $lg.nicstat; echo "after: $(nicstat)" >> $lg.nicstat
  res forward-udp $v $r vethB1_rx_pps $(rate "$a" "$b" 12) "nic_rx_pps=$(rate "$a" "$b" 2) pktgen=$(grep -oE '[0-9]+pps' $lg.pktgen | head -1)$c $(delta "$a" "$b")"; }

# udp <test> <log> <netns of the sender: host or hrB> <destination> <counter field>: netperf UDP_STREAM of $MSG-byte
# datagrams to port $PORT on CPU $CS, the rate of the counter over $DUR after 2 s. A push makes the datagrams unreadable,
# so netserver gets nothing and netperf may wait for its report: stop it after the window, the counters are the result.
# -R 1: netperf sets SO_DONTROUTE on the data socket by default, which fails for the routed uplink destination.
udp() { local t=$1 lg=$2 where=$3 dst=$4 k=$5 n=() p a b c
  [ $where = hrB ] && n=(ip netns exec hrB)
  "${n[@]}" timeout -s INT $((DUR + 10)) taskset -c $CS netperf -4 -H $dst -t UDP_STREAM -l $((DUR + 4)) -P 0 -- \
    -m $MSG -P ,$PORT -R 1 > $lg.netperf 2>&1 & p=$!
  if [ -n "$CNT" ]; then wait $p; return; fi
  sleep 2; a=$(snap); mp $DUR $lg.mpstat; sleep $DUR; b=$(snap); c=$(mpget $lg.mpstat); wait $p
  [ -f /sys/fs/bpf/txhr-bench/push ] && c+=" bpf=$($BPFTOOL map dump name push.bss -j | jq -c '.[0].formatted')"
  res $t $v $r pps $(rate "$a" "$b" $k) "$c $(delta "$a" "$b")"; }
# push.bpf.o at tcx egress of $1
tcpush() { local o=push; [ $v = off ] && o=push-notag; mkdir -p /sys/fs/bpf/txhr-bench
  $BPFTOOL prog load $D/$o.bpf.o /sys/fs/bpf/txhr-bench/push || die "push load"
  $BPFTOOL net attach tcx_egress pinned /sys/fs/bpf/txhr-bench/push dev $1 || die "tcx attach $1"; }
netserver_hrB() { ip netns exec hrB taskset -c $CR netserver -4 > /dev/null 2>&1 || die "netserver"; }
plain_udp() { # host socket -> vethB0 -> vethB1 -> hrB, nothing attached: tx_extra_headroom is 0 on both kernels
  up none; netserver_hrB; udp plain-udp $1 host 10.77.2.2 12; }
xdp_udp() { # host socket -> vethB0 -> vethB1 (generic XDP) -> hrB
  up xdpgeneric; netserver_hrB; udp xdp-udp $1 host 10.77.2.2 12; }
xdpdrop_udp() { # host socket -> vethB0 -> vethB1 (generic XDP, xdp_native.bpf.c in drop mode for port $PORT)
  up none; ip -n hrB link set dev vethB1 xdpgeneric obj $D/xdp_native.bpf.o sec xdp program xdp_prog || die "xdp_native on vethB1"
  $BPFTOOL map update name map_xdp_setup key 0 0 0 0 value 1 0 0 0 && \
    $BPFTOOL map update name map_xdp_setup key 1 0 0 0 value $((PORT & 255)) $((PORT >> 8)) 0 0 || die "xdp_native setup"
  netserver_hrB; udp xdpdrop-udp $1 host 10.77.2.2 10; }
push_udp() { # host socket -> vethB0 (tcx egress push) -> vethB1 -> hrB
  up none; netserver_hrB; tcpush vethB0; udp push-udp $1 host 10.77.2.2 12; }
uplink_udp() { # hrB socket -> vethB1 -> vethB0 -> ip_forward -> NIC (tcx egress push) -> sender; on sets the
  # 20 bytes on the veth pair with VETH_INFO_TX_EXTRA_HEADROOM
  if [ $v = on ]; then up none 20; else up none; fi; tcpush $NIC; udp uplink-udp $1 hrB $SND 5; }

# count runs: bpftrace on, short traffic, no throughput result
for v in $VARIANTS; do swap $v
  for t in $(tests_of $v); do log "count $v $t"; BTF=$L/count-$t-$v.bt
    case $t in forward_udp) PGN=200000 $t $L/count-$t-$v;; *_udp) CNT=1 DUR=3 $t $L/count-$t-$v;;
      *) DUR=5 R=$L/count-results.tsv $t $L/count-$t-$v;; esac
    kill -INT $BT; wait $BT; BTF=
  done
done
# rounds: every variant per round, order rotated every round; fresh topology per test
set -- $VARIANTS; NV=$#
for r in $(seq $ROUNDS); do
  order=$(for i in $(seq 0 $((NV - 1))); do echo $VARIANTS | cut -d' ' -f$(( (i + r - 1) % NV + 1 )); done)
  for v in $order; do swap $v
    for t in $(tests_of $v); do log "round $r $v $t"; $t $L/$t-$v-$(uname -r)-r$r; done
  done
done
log "DONE: $(grep -vc -e '^#' -e '^test' $R) result lines in $R"
