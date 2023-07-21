#include "fpspin.h"

#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int slmp_socket() {
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
  return sockfd;
}

int slmp_sendmsg(int sockfd, in_addr_t srv_addr, int msgid, void *buf,
                 size_t sz, int fc_us) {
  printf("Sending SLMP message of size %ld\n", sz);
  if (fc_us) {
    printf("Flow control: %d us inter-packet gap\n", fc_us);
  }

  uint8_t packet[SLMP_PAYLOAD_SIZE + sizeof(slmp_hdr_t)];
  slmp_hdr_t *hdr = (slmp_hdr_t *)packet;
  uint8_t *payload = packet + sizeof(slmp_hdr_t);

  struct sockaddr_in server = {
      .sin_family = AF_INET,
      .sin_addr.s_addr = srv_addr,
      .sin_port = htons(SLMP_PORT),
  };

  hdr->msg_id = htonl(msgid);
  uint8_t *char_buf = (uint8_t *)buf;
  for (uint8_t *cur = char_buf; cur - char_buf < sz; cur += SLMP_PAYLOAD_SIZE) {
    bool expect_ack = true;
    if (cur + SLMP_PAYLOAD_SIZE >= char_buf + sz) {
      // last packet requires synchronisation
      hdr->flags = htons(MKEOM | MKSYN);
    } else if (cur == char_buf) {
      // first packet requires synchronisation
      hdr->flags = htons(MKSYN);
    } else {
      hdr->flags = 0;
      expect_ack = false;
    }

    uint32_t offset = cur - char_buf;
    hdr->pkt_off = htonl(offset);

    size_t left = sz - (cur - char_buf);
    size_t to_copy = left > SLMP_PAYLOAD_SIZE ? SLMP_PAYLOAD_SIZE : left;

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