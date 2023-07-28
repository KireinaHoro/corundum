#include "fpspin.h"

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int slmp_socket(slmp_sock_t *sock, bool always_ack, int align) {
  sock->fd = socket(AF_INET, SOCK_DGRAM, 0);
  struct timeval tv = {
      .tv_sec = 0,
      .tv_usec = 100 * 1000, // 100ms
  };
  if (setsockopt(sock->fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) < 0) {
    perror("setsockopt");
    close(sock->fd);
    return -1;
  }
  sock->always_ack = always_ack;
  sock->align = align;
  return 0;
}

int slmp_sendmsg(slmp_sock_t *sock, in_addr_t srv_addr, int msgid, void *buf,
                 size_t sz, int fc_us) {
  int sockfd = sock->fd;
  bool ack_for_all = sock->always_ack;

  printf("Sending SLMP message of size %ld\n", sz);
  if (fc_us) {
    printf("Flow control: %d us inter-packet gap\n", fc_us);
  }

  uint8_t packet[SLMP_PAYLOAD_SIZE + sizeof(slmp_hdr_t)];
  slmp_hdr_t *hdr = (slmp_hdr_t *)packet;
  uint8_t *payload = packet + sizeof(slmp_hdr_t);
  size_t payload_size = (SLMP_PAYLOAD_SIZE / sock->align) * sock->align;

  struct sockaddr_in server = {
      .sin_family = AF_INET,
      .sin_addr.s_addr = srv_addr,
      .sin_port = htons(SLMP_PORT),
  };

  hdr->msg_id = htonl(msgid);
  uint8_t *char_buf = (uint8_t *)buf;
  for (uint8_t *cur = char_buf; cur - char_buf < sz; cur += payload_size) {
    bool expect_ack = true;
    uint16_t hflags;
    if (cur + payload_size >= char_buf + sz) {
      // last packet requires synchronisation
      hflags = MKEOM | MKSYN;
    } else if (cur == char_buf) {
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
    hdr->flags = htons(hflags);

    uint32_t offset = cur - char_buf;
    hdr->pkt_off = htonl(offset);

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
  }

  return 0;
}

int slmp_close(slmp_sock_t *sock) { return close(sock->fd); }