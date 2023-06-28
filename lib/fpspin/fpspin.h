#ifndef __FPSPIN_H__
#define __FPSPIN_H__

#include "../../fpga/app/pspin/modules/mqnic_app_pspin/pspin_ioctl.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct mac_addr {
  uint8_t data[6];
} __attribute__((__packed__)) mac_addr_t;

typedef struct eth_hdr {
  mac_addr_t dest;
  mac_addr_t src;
  uint16_t length;
} __attribute__((__packed__)) eth_hdr_t;

typedef struct ip_hdr {
  // ip-like
  // FIXME: bitfield endianness is purely compiler-dependent
  // we should use bit operations
  uint8_t ihl : 4;
  uint8_t version : 4;
  uint8_t tos;
  uint16_t length;

  uint16_t identification;
  uint16_t offset;

  uint8_t ttl;
  uint8_t protocol;
  uint16_t checksum;

  uint32_t source_id; // 4
  uint32_t dest_id;   // 4

} __attribute__((__packed__)) ip_hdr_t;

typedef struct udp_hdr {
  uint16_t src_port;
  uint16_t dst_port;
  uint16_t length;
  uint16_t checksum;
} __attribute__((__packed__)) udp_hdr_t;

/*
typedef struct app_hdr
{ //QUIC-like
    uint64_t            connection_id;
    uint16_t            packet_num;
    uint16_t             frame_type; //frame_type 1: connection closing
} __attribute__((__packed__)) app_hdr_t;
*/
typedef struct pkt_hdr {
  eth_hdr_t eth_hdr;
  ip_hdr_t ip_hdr;
  udp_hdr_t udp_hdr;
  // app_hdr_t app_hdr;
} __attribute__((__packed__)) pkt_hdr_t;

#define NUM_HPUS 16

typedef struct {
  int ctx_id;
  int fd;
  void *cpu_addr;
  size_t mmap_len;
  uint8_t dma_idx[NUM_HPUS];
  uint64_t host_flag_base;
} fpspin_ctx_t;

// TODO: refactor into descriptor struct?
//       different format for to_host and from_host
// TODO: do proper descriptor ring
// used by fpspin_pop_req
#define FLAG_DMA_ID(fl) ((fl)&0xf)
// can be freely redefined by app
#define FLAG_LEN(fl) (((fl) >> 8) & 0xff)
#define FLAG_HPU_ID(fl) ((fl) >> 24 & 0xff)
#define MKFLAG_FULL(id, hpuid, len)                                            \
  (((id)&0xf) | (((len)&0xff) << 8) | (((hpuid)&0xff) << 24))
#define MKFLAG_LIB(id, hpuid) MKFLAG_FULL(id, hpuid, 0)
#define MKFLAG(len) MKFLAG_FULL(0, 0, len)
#define DMA_BUS_WIDTH 512
#define DMA_ALIGN (DMA_BUS_WIDTH / 8)

#define L2_BASE 0x1c000000UL
#define L2_END 0x1c100000UL
#define PROG_BASE 0x1d000000UL
#define PAGE_SIZE 4096

void hexdump(const volatile void *data, size_t size);

// public API
// XXX: rbase should have static lifetime
void fpspin_set_regs_base(const char *rbase);
const char *fpspin_get_regs_base();

#define NUM_RULES_PER_RULESET 4
#define NUM_RULESETS 4
#define NUM_CLUSTERS 2
typedef struct {
  struct fpspin_rule {
    int idx;
    uint32_t mask;
    uint32_t start;
    uint32_t end;
  } r[NUM_RULES_PER_RULESET];
  enum {
    FPSPIN_MODE_AND,
    FPSPIN_MODE_OR,
  } mode;
} fpspin_ruleset_t;

#define FPSPIN_RULE_FALSE ((struct fpspin_rule){0, 0, 1, 0})
#define FPSPIN_RULE_EMPTY ((struct fpspin_rule){0, 0, 0, 0})
#define FPSPIN_RULE_IP                                                         \
  ((struct fpspin_rule){                                                       \
      .idx = 3, .mask = 0xffff0000, .start = 0x08000000, .end = 0x08000000})
#define FPSPIN_RULE_IP_PROTO(num)                                              \
  ((struct fpspin_rule){.idx = 5, .mask = 0xff, .start = num, .end = num})

void fpspin_set_me_ruleset(int ctx_id, const fpspin_ruleset_t *rs);
void fpspin_ruleset_bypass(fpspin_ruleset_t *rs);
void fpspin_ruleset_match(fpspin_ruleset_t *rs);
void fpspin_ruleset_udp(fpspin_ruleset_t *rs);

void fpspin_prog_me(const fpspin_ruleset_t *rs, int num_rs);
void fpspin_load(const char *elf, uint64_t hostmem_ptr, uint32_t hostmem_size,
                 int ctx_id);
void fpspin_unload(int ctx_id);

bool fpspin_init(fpspin_ctx_t *ctx, const char *dev, const char *img,
                 int dest_ctx, const fpspin_ruleset_t *rs, int num_rs);
void fpspin_exit(fpspin_ctx_t *ctx);
// TODO: rework to use streaming DMA; the coherent buffer should only be used
// for descriptors
// XXX: multi-core and out-of-order response (with ring buffer)?
volatile void *fpspin_pop_req(fpspin_ctx_t *ctx, int hpu_id, uint64_t *flag);
void fpspin_push_resp(fpspin_ctx_t *ctx, int hpu_id, uint64_t flag);

uint32_t fpspin_get_avg_cycles(fpspin_ctx_t *ctx);

#endif // __FPSPIN_H__