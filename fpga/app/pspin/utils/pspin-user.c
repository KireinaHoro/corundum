#include "../modules/mqnic_app_pspin/pspin_ioctl.h"
#include <assert.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <immintrin.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define PSPIN_DEV "/dev/pspin0"
#define PAGE_SIZE 4096
#define HOSTDMA_PAGES_FILE                                                     \
  "/sys/module/mqnic_app_pspin/parameters/hostdma_num_pages"
#define LOADER "./load.sh"
#define NUM_HPUS 16
#define NM "nm"

#define FLAG_DMA_ID(fl) ((fl)&0xf)
#define FLAG_LEN(fl) (((fl) >> 8) & 0xff)
#define FLAG_HPU_ID(fl) ((fl) >> 24 & 0xff)
#define MKFLAG(id, len, hpuid)                                                 \
  (((id)&0xf) | (((len)&0xff) << 8) | (((hpuid)&0xff) << 24))

static const uint64_t l2_base = 0x1c000000;

volatile sig_atomic_t exit_flag = 0;
static void sigint_handler(int signum) { exit_flag = 1; }

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

int main(int argc, char *argv[]) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s <ctx id> <img>\n", argv[0]);
    exit(EXIT_FAILURE);
  }

  struct sigaction sa = {
      .sa_handler = sigint_handler,
      .sa_flags = 0,
  };
  sigemptyset(&sa.sa_mask);
  if (sigaction(SIGINT, &sa, NULL)) {
    perror("sigaction");
    exit(EXIT_FAILURE);
  }

  int fd = open(PSPIN_DEV, O_RDWR | O_CLOEXEC | O_SYNC);
  int dest_ctx = 0;
  int ret = 0;
  if (fd < 0) {
    perror("open pspin device");
    exit(EXIT_FAILURE);
  }

  FILE *fp = fopen(HOSTDMA_PAGES_FILE, "r");
  if (!fp) {
    perror("open hostdma configuration");
    ret = EXIT_FAILURE;
    goto fail;
  }
  int hostdma_num_pages = 0;
  if (fscanf(fp, "%d\n", &hostdma_num_pages) != 1) {
    fprintf(stderr, "failed to read host dma number of pages\n");
    ret = EXIT_FAILURE;
    goto fail;
  }
  if (fclose(fp)) {
    perror("close hostdma configuration");
  }
  printf("Host DMA buffer: %d pages\n", hostdma_num_pages);

  int len = hostdma_num_pages * PAGE_SIZE;
  void *pspin_dma_mem =
      mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, dest_ctx * len);
  if (pspin_dma_mem == MAP_FAILED) {
    perror("map host dma area");
    ret = EXIT_FAILURE;
    goto fail;
  }
  if (madvise(pspin_dma_mem, len, MADV_DONTFORK)) {
    perror("madvise DONTFORK");
    ret = EXIT_FAILURE;
    goto unmap;
  }
  printf("Mapped host dma at %p\n", pspin_dma_mem);

  struct pspin_ioctl_msg msg = {
      .query.req.ctx_id = dest_ctx,
  };
  if (ioctl(fd, PSPIN_HOSTDMA_QUERY, &msg) < 0) {
    perror("ioctl pspin device");
    ret = EXIT_FAILURE;
    goto unmap;
  }

  assert(msg.query.resp.enabled);
  printf("Host DMA physical addr: %#lx, size: %ld\n", msg.query.resp.dma_handle,
         msg.query.resp.dma_size);

  char cmd_buf[512];
  snprintf(cmd_buf, sizeof(cmd_buf), LOADER " %s up %s %u %u %u", argv[1],
           argv[2], (unsigned int)(msg.query.resp.dma_handle >> 32),
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
  snprintf(cmd_buf, sizeof(cmd_buf), NM " %s | grep __host_flag", argv[2]);
  FILE *nm_fp = popen(cmd_buf, "r");
  if (!nm_fp) {
    perror("nm to get host flag");
    ret = EXIT_FAILURE;
    goto close_dev;
  }
  uint64_t host_flag_base;
  if (fscanf(nm_fp, "%lx", &host_flag_base) < 1) {
    fprintf(stderr, "failed to get host flags offset\n");
    ret = EXIT_FAILURE;
    goto close_dev;
  }
  fclose(nm_fp);
  printf("Host flags at %#lx\n", host_flag_base);

  uint8_t dma_idx[NUM_HPUS];
  memset(dma_idx, 0, sizeof(dma_idx));

  for (int i = 0; i < NUM_HPUS; ++i) {
    volatile uint8_t *flag_addr =
        (volatile uint8_t *)pspin_dma_mem + i * PAGE_SIZE;
    volatile uint64_t *flag = (volatile uint64_t *)flag_addr;

    uint64_t flag_to_host = *flag;
    dma_idx[i] = FLAG_DMA_ID(flag_to_host);
  }

  // loading finished - application logic from here
  // examples/ping_pong
  while (true) {
    if (exit_flag) {
      printf("\nReceived SIGINT, exiting...\n");
      break;
    }
    for (int i = 0; i < NUM_HPUS; ++i) {
      volatile uint8_t *flag_addr =
          (volatile uint8_t *)pspin_dma_mem + i * PAGE_SIZE;
      volatile uint64_t *flag = (volatile uint64_t *)flag_addr;
      volatile uint8_t *pkt_addr = flag_addr + sizeof(uint64_t);

      _mm_clflush((void *)flag);
      __sync_synchronize();

      uint64_t flag_to_host = *flag;

      // packet not ready yet
      if (FLAG_DMA_ID(flag_to_host) == dma_idx[i])
        continue;

      uint16_t pkt_len = FLAG_LEN(flag_to_host);

      // set as processed
      dma_idx[i] = FLAG_DMA_ID(flag_to_host);

      printf("Host flag addr: %p\n", flag);
      printf("Received packet on HPU %d, flag %#lx (id %#lx, len %d):\n", i,
             flag_to_host, FLAG_DMA_ID(flag_to_host), pkt_len);

      int dest = FLAG_HPU_ID(flag_to_host);
      if (dest != i) {
        printf("HPU ID mismatch!  Actual HPU ID: %d\n", dest);
      }
      hexdump(pkt_addr, pkt_len);

      // to upper
      // FIXME: IHL
      // 42: UDP + IP + ETH
      for (int pi = 42; pi < pkt_len; ++pi) {
        char *c = (char *)(pkt_addr + pi);
        *c = toupper(*c);
      }

      printf("Return packet:\n");
      hexdump(pkt_addr, pkt_len);
      // notify pspin via host flag
      uint64_t flag_from_host = MKFLAG(dma_idx[i], pkt_len, dest);
      uint64_t hpu_host_flag_off = host_flag_base - l2_base + 8 * dest;
      struct pspin_ioctl_msg flag_msg = {
          .write_raw.addr = hpu_host_flag_off,
          .write_raw.data = flag_from_host,
      };
      if (ioctl(fd, PSPIN_HOSTDMA_WRITE_RAW, &flag_msg) < 0) {
        perror("ioctl pspin device");
      }
      printf("Wrote flag %#lx to offset %#lx\n", flag_from_host, hpu_host_flag_off);
    }
  }

close_dev:
  if (close(fd)) {
    perror("close pspin device");
  }

  ret = EXIT_SUCCESS;

  // shutdown ME to avoid packets writing to non-existent host memory
  snprintf(cmd_buf, sizeof(cmd_buf), LOADER " %s down", argv[1]);
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

unmap:
  if (munmap(pspin_dma_mem, len)) {
    perror("unmap");
  }

fail:
  return ret;
}
