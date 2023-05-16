#include "../modules/mqnic_app_pspin/pspin_ioctl.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
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

volatile sig_atomic_t exit_flag = 0;
static void sigint_handler(int signum) { exit_flag = 1; }

void hexdump(const void *data, size_t size) {
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
      .req.ctx_id = dest_ctx,
  };
  if (ioctl(fd, PSPIN_HOSTDMA_QUERY, &msg) < 0) {
    perror("ioctl pspin device");
    ret = EXIT_FAILURE;
    goto unmap;
  }
  // we can close after mmap and ioctl already - map will stay active
  if (close(fd)) {
    perror("close pspin device");
  }

  assert(msg.resp.enabled);
  printf("Host DMA physical addr: %#lx, size: %ld\n", msg.resp.dma_handle,
         msg.resp.dma_size);

  char cmd_buf[512];
  snprintf(cmd_buf, sizeof(cmd_buf), LOADER " %s up %s %u %u %u", argv[1],
           argv[2], (unsigned int)(msg.resp.dma_handle >> 32),
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
  } else if (WIFSIGNALED(ret)) {
    fprintf(stderr, "loader killed by signal: %s\n", strsignal(WTERMSIG(ret)));
    ret = EXIT_FAILURE;
    goto unmap;
  }

  // loading finished - application logic from here
  // examples/ping_pong
  size_t line_size = 64;
  char *line = malloc(line_size);
  while (true) {
    printf("Press enter to dump DMA area:");
    fflush(stdout);
    if (getline(&line, &line_size, stdin) == -1) {
      if (errno != EINTR) {
        perror("getline");
        ret = EXIT_FAILURE;
        goto stop_pspin;
      }
    }
    if (exit_flag) {
      printf("\nReceived SIGINT, exiting...\n");
      break;
    }
    hexdump(pspin_dma_mem, 128);
  }
  free(line);

  ret = EXIT_SUCCESS;

stop_pspin:
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
