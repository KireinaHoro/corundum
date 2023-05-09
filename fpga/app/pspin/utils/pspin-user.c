#include "../modules/mqnic_app_pspin/pspin_ioctl.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
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

int main(int argc, char *argv[]) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s <ctx id> <img>\n", argv[0]);
    exit(EXIT_FAILURE);
  }

  int fd = open(PSPIN_DEV, O_RDWR | O_CLOEXEC);
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
  printf("Host DMA buffer: %d pages\n", hostdma_num_pages);

  fclose(fp);

  int len = hostdma_num_pages * PAGE_SIZE;
  void *pspin_dma_mem =
      mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, dest_ctx * len);
  if (pspin_dma_mem == MAP_FAILED) {
    perror("map host dma area");
    ret = EXIT_FAILURE;
    goto fail;
  }

  printf("Mapped host dma at %p\n", pspin_dma_mem);

  struct pspin_ioctl_msg msg = {
      .req.ctx_id = dest_ctx,
  };
  if (ioctl(fd, PSPIN_HOSTDMA_QUERY, &msg) < 0) {
    perror("ioctl device");
    ret = EXIT_FAILURE;
    goto unmap;
  }

  assert(msg.resp.enabled);
  printf("Host DMA physical addr: %#lx, size: %ld\n", msg.resp.dma_handle,
         msg.resp.dma_size);

  char cmd_buf[512];
  snprintf(cmd_buf, sizeof(cmd_buf), LOADER " %s %s %d %d %d", argv[1], argv[2],
           (unsigned int)(msg.resp.dma_handle >> 32),
           (unsigned int)msg.resp.dma_handle, (unsigned int)msg.resp.dma_size);
  ret = system(cmd_buf);
  if (ret == -1) {
    perror("call loader");
    ret = EXIT_FAILURE;
    goto unmap;
  } else if (WIFEXITED(ret) && WEXITSTATUS(ret) != 0) {
    fprintf(stderr, "loader returned %d\n", WEXITSTATUS(ret));
    ret = EXIT_FAILURE;
    goto unmap;
  }

  ret = EXIT_SUCCESS;

unmap:
  if (munmap(pspin_dma_mem, len)) {
    perror("unmap");
  }

fail:
  close(fd);
  return ret;
}