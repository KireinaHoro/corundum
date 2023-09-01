#include "fpspin.h"

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int slmp_socket(slmp_sock_t *sock, bool always_ack, int align, int fc_us,
                bool parallel) {
  sock->always_ack = always_ack;
  sock->align = align;
  sock->fc_us = fc_us;
  sock->parallel = parallel;
  return 0;
}

static int send_single(int sockfd, int fc_us, uint8_t *cur, uint8_t *char_buf,
                       size_t sz, size_t payload_size, in_addr_t srv_addr,
                       uint16_t hflags, int msgid, bool expect_ack) {
  uint8_t packet[SLMP_PAYLOAD_SIZE + sizeof(slmp_hdr_t)];
  slmp_hdr_t *hdr = (slmp_hdr_t *)packet;
  uint32_t offset = cur - char_buf;
  uint8_t *payload = packet + sizeof(slmp_hdr_t);
  hdr->msg_id = htonl(msgid);
  hdr->flags = htons(hflags);
  hdr->pkt_off = htonl(offset);

  struct sockaddr_in server = {
      .sin_family = AF_INET,
      .sin_addr.s_addr = srv_addr,
      .sin_port = htons(SLMP_PORT),
  };

  size_t left = sz - (cur - char_buf);
  size_t to_copy = left > payload_size ? payload_size : left;

  memcpy(payload, cur, to_copy);

  // send the packet
  if (sendto(sockfd, packet, to_copy + sizeof(slmp_hdr_t), 0,
             (const struct sockaddr *)&server, sizeof(server)) < 0) {
    perror("sendto");
    return -1;
  }

  // printf("Sent packet offset=%d in msg #%d\n", offset, msgid);

  if (expect_ack) {
    uint8_t ack[sizeof(slmp_hdr_t)];
    ssize_t rcvd = recvfrom(sockfd, ack, sizeof(ack), 0, NULL, NULL);
    // we should be bound at this time == not setting addr
    if (rcvd < 0) {
      perror("recvfrom ACK");
      return -1;

    } else if (rcvd != sizeof(slmp_hdr_t)) {
      fprintf(stderr, "ACK size mismatch: expected %ld, got %ld\n",
              sizeof(slmp_hdr_t), rcvd);
      return -1;
    }
    slmp_hdr_t *hdr = (slmp_hdr_t *)ack;
    uint16_t flags = ntohs(hdr->flags);
    if (!ACK(flags)) {
      fprintf(stderr, "no ACK set in reply; flag=%#x\n", flags);
      return -1;
    }
  }

  usleep(fc_us);

  return 0;
}

int slmp_sendmsg(slmp_sock_t *sock, in_addr_t srv_addr, int msgid, void *buf,
                 size_t sz) {
  int sockfd = socket(AF_INET, SOCK_DGRAM, 0);
  struct timeval tv = {
      .tv_sec = 0,
      .tv_usec = 100 * 1000, // 100ms
  };
  if (setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) < 0) {
    perror("setsockopt");
    close(sockfd);
    return -1;
  }
  int ret = 0;

  bool ack_for_all = sock->always_ack;

  printf("Sending SLMP message #%d of size %ld\n", msgid, sz);
  if (sock->fc_us) {
    printf("Flow control: %d us inter-packet gap\n", sock->fc_us);
  }

  size_t payload_size = (SLMP_PAYLOAD_SIZE / sock->align) * sock->align;

  uint8_t *char_buf = (uint8_t *)buf;
  volatile bool exit_flag = false;

  uint8_t *cur = char_buf;
  uint16_t hflags = MKSYN;
  if (payload_size >= sz) {
    // will only send one message
    hflags |= MKEOM;
  }
  ret = send_single(sockfd, sock->fc_us, cur, char_buf, sz, payload_size,
                    srv_addr, hflags, msgid, true);

#pragma omp parallel for if (sock->parallel) reduction(+ : ret) shared(exit_flag) lastprivate(cur)
  for (/* first packet outside of the parallel loop*/
       cur = char_buf + payload_size;
       /* do not send last packet in the parallel loop */
       cur < char_buf + sz - payload_size; cur += payload_size) {
    if (exit_flag)
      continue;

    bool expect_ack = true;
    uint16_t hflags;
    if (cur == char_buf) {
      // first packet requires synchronisation
      hflags = MKSYN;
    } else {
      hflags = 0;
      expect_ack = false;
    }

    if (ack_for_all) {
      hflags |= MKSYN;
      expect_ack = true;
    }

    ret = send_single(sockfd, sock->fc_us, cur, char_buf, sz, payload_size,
                      srv_addr, hflags, msgid, expect_ack);
    if (ret)
      continue;
  }

  if (ret)
    goto out;

  // send last packet
  if (cur < char_buf + sz)
    ret = send_single(sockfd, sock->fc_us, cur, char_buf, sz, payload_size,
                      srv_addr, MKEOM | MKSYN, msgid, true);

out:
  close(sockfd);
  return ret;
}

int slmp_close(slmp_sock_t *sock) { return 0; }