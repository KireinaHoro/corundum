#ifndef __PSPIN_IOCTL_H__
#define __PSPIN_IOCTL_H__

#include <linux/ioctl.h>
#include <linux/types.h>

struct ctx_dma_area {
  dma_addr_t dma_handle;
  u64 dma_size;
  bool enabled;
};

struct pspin_ioctl_msg {
  union {
    struct {
      int ctx_id;
    } req;
    struct ctx_dma_area resp;
  };
};

#define PSPIN_IOCTL_MAGIC 0x95910
#define PSPIN_HOSTDMA_QUERY _IOWR(PSPIN_IOCTL_MAGIC, 0x1, struct pspin_ioctl_msg)

#endif // __PSPIN_IOCTL_H__