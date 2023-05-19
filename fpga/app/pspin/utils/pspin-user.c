#include "../modules/mqnic_app_pspin/pspin_ioctl.h"
#include "fpspin.h"

#include <arpa/inet.h>
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

volatile sig_atomic_t exit_flag = 0;
static void sigint_handler(int signum) { exit_flag = 1; }

// http://www.microhowto.info/howto/calculate_an_internet_protocol_checksum_in_c.html
uint16_t ip_checksum(void *vdata, size_t length) {
  // Cast the data pointer to one that can be indexed.
  char *data = (char *)vdata;

  // Initialise the accumulator.
  uint32_t acc = 0xffff;

  // Handle complete 16-bit blocks.
  for (size_t i = 0; i + 1 < length; i += 2) {
    uint16_t word;
    memcpy(&word, data + i, 2);
    acc += ntohs(word);
    if (acc > 0xffff) {
      acc -= 0xffff;
    }
  }

  // Handle any partial block at the end of the data.
  if (length & 1) {
    uint16_t word = 0;
    memcpy(&word, data + length - 1, 1);
    acc += ntohs(word);
    if (acc > 0xffff) {
      acc -= 0xffff;
    }
  }

  // Return the checksum in network byte order.
  return htons(~acc);
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

  // TODO: take initialization code into lib
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
      mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, dest_ctx * len);
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
    volatile uint8_t *flag_addr = (uint8_t *)pspin_dma_mem + i * PAGE_SIZE;
    volatile uint64_t *flag = (uint64_t *)flag_addr;

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
      volatile uint8_t *flag_addr = (uint8_t *)pspin_dma_mem + i * PAGE_SIZE;
      volatile uint64_t *flag = (uint64_t *)flag_addr;
      volatile uint8_t *pkt_addr = flag_addr + DMA_ALIGN;
      volatile pkt_hdr_t *hdrs = (pkt_hdr_t *)pkt_addr;
      volatile uint8_t *payload = (uint8_t *)hdrs + sizeof(pkt_hdr_t);

      uint64_t flag_to_host = *flag;

      // packet not ready yet
      if (FLAG_DMA_ID(flag_to_host) == dma_idx[i])
        continue;

      // set as processed
      dma_idx[i] = FLAG_DMA_ID(flag_to_host);

      uint16_t dma_len = FLAG_LEN(flag_to_host);
      uint16_t udp_len = ntohs(hdrs->udp_hdr.length);
      uint16_t payload_len = udp_len - sizeof(udp_hdr_t);

      printf("Host flag addr: %p\n", flag);
      printf("Received packet on HPU %d, flag %#lx (id %#lx, dma len %d, UDP "
             "payload len %d):\n",
             i, flag_to_host, FLAG_DMA_ID(flag_to_host), dma_len, payload_len);

      int dest = FLAG_HPU_ID(flag_to_host);
      if (dest != i) {
        printf("HPU ID mismatch!  Actual HPU ID: %d\n", dest);
      }
      hexdump(pkt_addr, dma_len);

      // to upper
      for (int pi = 0; pi < payload_len; ++pi) {
        volatile char *c = (char *)(payload + pi);
        // FIXME: bounds check for large packets
        volatile char *lower = (char *)(payload + payload_len + pi);
        *lower = *c;
        if (*c == '\n') {
          *c = '|';
        } else {
          *c = toupper(*c);
        }
      }

      // recalculate lengths
      uint16_t ul_host = 2 * payload_len + sizeof(udp_hdr_t);
      uint16_t il_host = sizeof(ip_hdr_t) + ul_host;
      uint16_t return_len = il_host + sizeof(eth_hdr_t);
      hdrs->udp_hdr.length = htons(ul_host);
      hdrs->udp_hdr.checksum = 0;
      hdrs->ip_hdr.length = htons(il_host);
      hdrs->ip_hdr.checksum = 0;
      hdrs->ip_hdr.checksum =
          ip_checksum((uint8_t *)&hdrs->ip_hdr, sizeof(ip_hdr_t));

      printf("Return packet:\n");
      hexdump(pkt_addr, return_len);

      // make sure memory writes finish
      __sync_synchronize();

      // notify pspin via host flag
      uint64_t flag_from_host = MKFLAG(dma_idx[i], return_len, dest);
      uint64_t hpu_host_flag_off = host_flag_base - L2_BASE + 8 * dest;
      struct pspin_ioctl_msg flag_msg = {
          .write_raw.addr = hpu_host_flag_off,
          .write_raw.data = flag_from_host,
      };
      if (ioctl(fd, PSPIN_HOSTDMA_WRITE_RAW, &flag_msg) < 0) {
        perror("ioctl pspin device");
      }
      printf("Wrote flag %#lx to offset %#lx\n", flag_from_host,
             hpu_host_flag_off);
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
