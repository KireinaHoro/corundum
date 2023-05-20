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
#define LOADER "./load.sh"
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
                 int dest_ctx) {
  ctx->fd = open(dev, O_RDWR | O_CLOEXEC | O_SYNC);
  int ret = 0;
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

  // TODO: port loader bash script into C
  char cmd_buf[512];
  snprintf(cmd_buf, sizeof(cmd_buf), LOADER " %d up %s %u %u %u", dest_ctx, img,
           (unsigned int)(msg.query.resp.dma_handle >> 32),
           (unsigned int)msg.query.resp.dma_handle,
           (unsigned int)msg.query.resp.dma_size);
  ret = system(cmd_buf);
  if (ret == -1) {
    perror("call loader");
    ret = EXIT_FAILURE;
    goto unmap;
  } else if (WIFEXITED(ret) && WEXITSTATUS(ret) != 0) {
    fprintf(stderr, "loader returned %d\n", WEXITSTATUS(ret));
    ret = EXIT_FAILURE;
    goto unmap;
  } else if (WIFSIGNALED(ret)) {
    fprintf(stderr, "loader killed by signal: %s\n", strsignal(WTERMSIG(ret)));
    ret = EXIT_FAILURE;
    goto unmap;
  }

  // get host flag
  snprintf(cmd_buf, sizeof(cmd_buf), NM " %s | grep __host_flag", img);
  FILE *nm_fp = popen(cmd_buf, "r");
  if (!nm_fp) {
    perror("nm to get host flag");
    ret = EXIT_FAILURE;
    goto close_dev;
  }
  if (fscanf(nm_fp, "%lx", &ctx->host_flag_base) < 1) {
    fprintf(stderr, "failed to get host flags offset\n");
    ret = EXIT_FAILURE;
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
  char cmd_buf[512];
  int ret;

  // TODO: port loader bash script into C
  // shutdown ME to avoid packets writing to non-existent host memory
  snprintf(cmd_buf, sizeof(cmd_buf), LOADER " %d down", ctx->ctx_id);
  ret = system(cmd_buf);
  if (ret == -1) {
    perror("call loader");
  } else if (WIFEXITED(ret) && WEXITSTATUS(ret) != 0) {
    fprintf(stderr, "loader returned %d\n", WEXITSTATUS(ret));
  } else if (WIFSIGNALED(ret)) {
    fprintf(stderr, "loader killed by signal: %s\n", strsignal(WTERMSIG(ret)));
  }

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
  printf("Wrote flag %#lx to offset %#lx\n", flag_msg.write_raw.data,
         hpu_host_flag_off);
}