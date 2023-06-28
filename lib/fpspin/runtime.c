#include "fpspin.h"

#include <assert.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>

#define HOSTDMA_PAGES_FILE                                                     \
  "/sys/module/mqnic_app_pspin/parameters/hostdma_num_pages"
#define NM "nm"

void hexdump(const volatile void *data, size_t size) {
  char ascii[17];
  size_t i, j;
  ascii[16] = '\0';
  for (i = 0; i < size; ++i) {
    printf("%02X ", ((unsigned char *)data)[i]);
    if (((unsigned char *)data)[i] >= ' ' &&
        ((unsigned char *)data)[i] <= '~') {
      ascii[i % 16] = ((unsigned char *)data)[i];
    } else {
      ascii[i % 16] = '.';
    }
    if ((i + 1) % 8 == 0 || i + 1 == size) {
      printf(" ");
      if ((i + 1) % 16 == 0) {
        printf("|  %s \n", ascii);
      } else if (i + 1 == size) {
        ascii[(i + 1) % 16] = '\0';
        if ((i + 1) % 16 <= 8) {
          printf(" ");
        }
        for (j = (i + 1) % 16; j < 16; ++j) {
          printf("   ");
        }
        printf("|  %s \n", ascii);
      }
    }
  }
}

bool fpspin_init(fpspin_ctx_t *ctx, const char *dev, const char *img,
                 int dest_ctx, const fpspin_ruleset_t *rs, int num_rs) {
  if (!fpspin_get_regs_base())
    fpspin_set_regs_base("/sys/devices/pci0000:00/0000:00:03.1/0000:1d:00.0/"
                         "mqnic.app_12340100.0");

  ctx->fd = open(dev, O_RDWR | O_CLOEXEC | O_SYNC);
  if (ctx->fd < 0) {
    perror("open pspin device");
    exit(EXIT_FAILURE);
  }
  ctx->ctx_id = dest_ctx;

  FILE *fp = fopen(HOSTDMA_PAGES_FILE, "r");
  if (!fp) {
    perror("open hostdma configuration");
    goto fail;
  }
  int hostdma_num_pages = 0;
  if (fscanf(fp, "%d\n", &hostdma_num_pages) != 1) {
    fprintf(stderr, "failed to read host dma number of pages\n");
    goto fail;
  }
  if (fclose(fp)) {
    perror("close hostdma configuration");
  }
  printf("Host DMA buffer: %d pages\n", hostdma_num_pages);

  ctx->mmap_len = hostdma_num_pages * PAGE_SIZE;
  ctx->cpu_addr = mmap(NULL, ctx->mmap_len, PROT_READ | PROT_WRITE, MAP_SHARED,
                       ctx->fd, dest_ctx * ctx->mmap_len);
  if (ctx->cpu_addr == MAP_FAILED) {
    perror("map host dma area");
    goto fail;
  }
  if (madvise(ctx->cpu_addr, ctx->mmap_len, MADV_DONTFORK)) {
    perror("madvise DONTFORK");
    goto unmap;
  }
  printf("Mapped host dma at %p\n", ctx->cpu_addr);

  struct pspin_ioctl_msg msg = {
      .query.req.ctx_id = dest_ctx,
  };
  if (ioctl(ctx->fd, PSPIN_HOSTDMA_QUERY, &msg) < 0) {
    perror("ioctl query hostdma");
    goto unmap;
  }

  assert(msg.query.resp.enabled);
  printf("Host DMA physical addr: %#lx, size: %ld\n", msg.query.resp.dma_handle,
         msg.query.resp.dma_size);

  fpspin_load(img, msg.query.resp.dma_handle, msg.query.resp.dma_size,
              dest_ctx);
  fpspin_prog_me(rs, num_rs);

  // get host flag
  char cmd_buf[1024];
  snprintf(cmd_buf, sizeof(cmd_buf), NM " %s | grep __host_data", img);
  FILE *nm_fp = popen(cmd_buf, "r");
  if (!nm_fp) {
    perror("nm to get host flag");
    goto close_dev;
  }
  if (fscanf(nm_fp, "%lx", &ctx->host_flag_base) < 1) {
    fprintf(stderr, "failed to get host flags offset\n");
    goto close_dev;
  }
  fclose(nm_fp);
  printf("Host flags at %#lx\n", ctx->host_flag_base);

  memset(ctx->dma_idx, 0, sizeof(ctx->dma_idx));

  // initialise per-HPU DMA flag
  for (int i = 0; i < NUM_HPUS; ++i) {
    volatile uint8_t *flag_addr = (uint8_t *)ctx->cpu_addr + i * PAGE_SIZE;
    volatile uint64_t *flag = (uint64_t *)flag_addr;

    uint64_t flag_to_host = *flag;
    ctx->dma_idx[i] = FLAG_DMA_ID(flag_to_host);
  }

  return true;

close_dev:
  if (close(ctx->fd)) {
    perror("close pspin device");
  }

unmap:
  if (munmap(ctx->cpu_addr, ctx->mmap_len)) {
    perror("unmap");
  }

fail:
  return false;
}

void fpspin_exit(fpspin_ctx_t *ctx) {
  // shutdown ME to avoid packets writing to non-existent host memory
  fpspin_unload(ctx->ctx_id);

  if (close(ctx->fd)) {
    perror("close pspin device");
  }

  if (munmap(ctx->cpu_addr, ctx->mmap_len)) {
    perror("unmap");
  }
}

volatile void *fpspin_pop_req(fpspin_ctx_t *ctx, int hpu_id, uint64_t *f) {
  volatile uint8_t *flag_addr = (uint8_t *)ctx->cpu_addr + hpu_id * PAGE_SIZE;
  volatile uint64_t *flag = (uint64_t *)flag_addr;

  *f = *flag;
  if (FLAG_DMA_ID(*f) == ctx->dma_idx[hpu_id])
    return NULL;

  int dest = FLAG_HPU_ID(*f);
  if (dest != hpu_id) {
    printf("HPU ID mismatch!  Actual HPU ID: %d\n", dest);
  }

  // set as processed
  ctx->dma_idx[hpu_id] = FLAG_DMA_ID(*f);
  return flag_addr + DMA_ALIGN;
}

void fpspin_push_resp(fpspin_ctx_t *ctx, int hpu_id, uint64_t flag) {
  // make sure memory writes finish
  __sync_synchronize();

  // notify pspin via host flag
  uint64_t hpu_host_flag_off = ctx->host_flag_base - L2_BASE + 8 * hpu_id;
  struct pspin_ioctl_msg flag_msg = {
      .write_raw.addr = hpu_host_flag_off,
      .write_raw.data = flag | MKFLAG_LIB(ctx->dma_idx[hpu_id], hpu_id),
  };
  if (ioctl(ctx->fd, PSPIN_HOSTDMA_WRITE_RAW, &flag_msg) < 0) {
    perror("ioctl pspin device");
  }
  /* printf("Wrote flag %#lx to offset %#lx\n", flag_msg.write_raw.data,
         hpu_host_flag_off); */
}

uint32_t fpspin_get_avg_cycles(fpspin_ctx_t *ctx) {
  uint64_t perf_off =
      ctx->host_flag_base - L2_BASE + 8 * NUM_HPUS; // perf_count & perf_sum
  struct pspin_ioctl_msg perf_msg = {
      .read_raw.word = perf_off,
  };
  if (ioctl(ctx->fd, PSPIN_HOSTDMA_READ_RAW, &perf_msg) < 0) {
    perror("ioctl pspin device");
  }
  uint32_t count = (uint32_t)perf_msg.read_raw.word;
  uint32_t sum = (uint32_t)(perf_msg.read_raw.word >> 32);

  printf("Sum = %d, count = %d\n", sum, count);

  return count ? sum / count : 0;
}