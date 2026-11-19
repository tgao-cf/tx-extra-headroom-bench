// SPDX-License-Identifier: GPL-2.0
/* tcx egress: push 20 bytes after the MAC header of each UDP packet to port 9999, as push_tagged in
 * tools/testing/selftests/net/tx_extra_headroom.bpf.c does. The decl tag declares the 20 bytes; kernels
 * without the tx_extra_headroom series ignore it. -DNO_DECL_TAG builds it without the tag. Counts the pushes and the pushes that reallocated skb->head.
 */
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/in.h>
#include <linux/ip.h>
#include <linux/udp.h>
#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>

#define UDP_TEST_PORT 9999
#define PUSH_LEN 20

struct sk_buff {
	unsigned char *head;
} __attribute__((preserve_access_index));

void *bpf_cast_to_kern_ctx(void *obj) __ksym;

__u64 pushes;
__u64 reallocated;

SEC("tcx/egress")
#ifndef NO_DECL_TAG
__attribute__((btf_decl_tag("tx_extra_headroom:20")))
#endif
int push(struct __sk_buff *skb)
{
	struct sk_buff *kskb;
	struct udphdr udph;
	struct iphdr iph;
	unsigned char *head;

	if (skb->protocol != bpf_htons(ETH_P_IP) ||
	    bpf_skb_load_bytes(skb, ETH_HLEN, &iph, sizeof(iph)) ||
	    iph.protocol != IPPROTO_UDP ||
	    bpf_skb_load_bytes(skb, ETH_HLEN + iph.ihl * 4, &udph, sizeof(udph)) ||
	    udph.dest != bpf_htons(UDP_TEST_PORT))
		return TCX_NEXT;

	kskb = bpf_cast_to_kern_ctx(skb);
	head = kskb->head;
	if (!bpf_skb_adjust_room(skb, PUSH_LEN, BPF_ADJ_ROOM_MAC, 0))
		__sync_fetch_and_add(&pushes, 1);
	if (kskb->head != head)
		__sync_fetch_and_add(&reallocated, 1);
	return TCX_NEXT;
}

char __license[] SEC("license") = "GPL";
