// A separately linked/ad-hoc-signed peer. It only connects to the fixture's
// private socket; it never checks permissions, starts a UI, or posts input.
#include <sys/socket.h>
#include <sys/un.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
int main(int argc, char **argv) {
    if (argc != 3 || strcmp(argv[1], "--fixture-probe") ||
        strncmp(argv[2], "/private/tmp/hanq-permission-", sizeof("/private/tmp/hanq-permission-")-1)) return 64;
    signal(SIGPIPE, SIG_IGN);
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    address.sun_len = sizeof(address);
    if (snprintf(address.sun_path, sizeof(address.sun_path), "%s/reply.sock", argv[2]) >= sizeof(address.sun_path)) return 64;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0 || connect(fd, (struct sockaddr *)&address, sizeof(address))) return 74;
    char reply[512];
    int size = snprintf(reply, sizeof(reply), "{\"token\":\"%s\",\"pid\":%d,\"ax\":true,\"post\":true}\n", strrchr(argv[2], '/')+1, getpid());
    if (write(fd, reply, size) != size) return 74;
    unsigned char ack = 0;
    int accepted = read(fd, &ack, 1) == 1 && ack == 1;
    close(fd);
    return accepted ? 0 : 74;
}
