/*
 * cc-keeper — keeps a terminal session alive after the app viewing it quits.
 *
 *   cc-keeper open  <socket> [-- command args...]   attach; start a server first if needed
 *   cc-keeper serve <socket> -- command args...      (internal) the background server
 *
 * The server owns the pseudo-terminal running the command and listens on a unix socket.
 * One client at a time relays keystrokes/resizes in and output out. Recent output is kept
 * in a ring buffer and replayed on attach, then the foreground program gets SIGWINCH so
 * full-screen apps (like Claude Code) redraw.
 *
 * Client -> server framing:  'd' <u16 len> <bytes>   |   'w' <u16 rows> <u16 cols>
 * Server -> client: raw terminal output.
 */
#include <errno.h>
#include <fcntl.h>
#include <sys/select.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

#define RING_SIZE (512 * 1024)

static char ring[RING_SIZE];
static size_t ring_len = 0, ring_pos = 0;

static void ring_add(const char *buf, size_t n) {
    if (n >= RING_SIZE) { buf += n - RING_SIZE; n = RING_SIZE; }
    size_t first = RING_SIZE - ring_pos < n ? RING_SIZE - ring_pos : n;
    memcpy(ring + ring_pos, buf, first);
    memcpy(ring, buf + first, n - first);
    ring_pos = (ring_pos + n) % RING_SIZE;
    ring_len = ring_len + n > RING_SIZE ? RING_SIZE : ring_len + n;
}

static int write_all(int fd, const char *buf, size_t n) {
    while (n > 0) {
        ssize_t w = write(fd, buf, n);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        buf += w; n -= (size_t)w;
    }
    return 0;
}

static int ring_send(int fd) {
    if (ring_len < RING_SIZE) return write_all(fd, ring, ring_len);
    /* Buffer wrapped: start at the next newline so we don't begin mid escape sequence. */
    size_t start = ring_pos, skipped = 0;
    while (skipped < 4096 && ring[(start + skipped) % RING_SIZE] != '\n') skipped++;
    start = (start + skipped + 1) % RING_SIZE;
    size_t total = RING_SIZE - skipped - 1;
    size_t first = RING_SIZE - start < total ? RING_SIZE - start : total;
    if (write_all(fd, ring + start, first) < 0) return -1;
    return write_all(fd, ring, total - first);
}

static int make_addr(const char *path, struct sockaddr_un *a) {
    memset(a, 0, sizeof(*a));
    a->sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(a->sun_path)) return -1;
    strcpy(a->sun_path, path);
    return 0;
}

static int connect_sock(const char *path) {
    struct sockaddr_un a;
    if (make_addr(path, &a) < 0) return -1;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) { close(fd); return -1; }
    return fd;
}

/* ---------------- server ---------------- */

static void redraw(int master) {
    pid_t pg = tcgetpgrp(master);
    if (pg > 0) kill(-pg, SIGWINCH);
}

static int serve(const char *sock, char **cmd) {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGHUP, SIG_IGN);

    struct sockaddr_un a;
    if (make_addr(sock, &a) < 0) return 1;
    int ls = socket(AF_UNIX, SOCK_STREAM, 0);
    unlink(sock);
    if (ls < 0 || bind(ls, (struct sockaddr *)&a, sizeof(a)) < 0 || listen(ls, 4) < 0) return 1;
    chmod(sock, 0600);

    struct winsize ws = { .ws_row = 40, .ws_col = 120 };
    int master;
    pid_t child = forkpty(&master, NULL, NULL, &ws);
    if (child < 0) { unlink(sock); return 1; }
    if (child == 0) {
        close(ls);
        execvp(cmd[0], cmd);
        perror("cc-keeper: exec");
        _exit(127);
    }

    int client = -1;
    char buf[65536];
    unsigned char in[70000];
    size_t inlen = 0;

    /* select(), not poll(): poll() on macOS misses readiness on terminal devices, which made
     * output (e.g. the echo after Enter) wait until the next keystroke. */
    for (;;) {
        fd_set rf; FD_ZERO(&rf);
        FD_SET(ls, &rf); FD_SET(master, &rf);
        int maxfd = ls > master ? ls : master;
        if (client >= 0) { FD_SET(client, &rf); if (client > maxfd) maxfd = client; }
        if (select(maxfd + 1, &rf, NULL, NULL, NULL) < 0) { if (errno == EINTR) continue; break; }

        if (FD_ISSET(master, &rf)) {
            ssize_t r = read(master, buf, sizeof(buf));
            if (r <= 0) { if (r < 0 && errno == EINTR) continue; break; } /* command exited */
            ring_add(buf, (size_t)r);
            if (client >= 0 && write_all(client, buf, (size_t)r) < 0) { close(client); client = -1; }
        }

        if (FD_ISSET(ls, &rf)) {
            int c = accept(ls, NULL, NULL);
            if (c >= 0) {
                if (client >= 0) close(client); /* newest viewer wins */
                client = c; inlen = 0;
                if (ring_send(client) < 0) { close(client); client = -1; }
            }
        }

        if (client >= 0 && FD_ISSET(client, &rf)) {
            ssize_t r = read(client, in + inlen, sizeof(in) - inlen);
            if (r <= 0) { if (r < 0 && errno == EINTR) continue; close(client); client = -1; continue; }
            inlen += (size_t)r;
            size_t off = 0;
            /* A 'd' frame is 3 header bytes + payload, so a single keypress is only 4 bytes. */
            while (inlen - off >= 3) {
                unsigned char t = in[off];
                uint16_t x = (uint16_t)(in[off + 1] << 8 | in[off + 2]);
                if (t == 'w') {
                    if (inlen - off < 5) break;
                    uint16_t cols = (uint16_t)(in[off + 3] << 8 | in[off + 4]);
                    struct winsize nw = { .ws_row = x, .ws_col = cols };
                    if (x > 0 && cols > 0) ioctl(master, TIOCSWINSZ, &nw);
                    redraw(master);
                    off += 5;
                } else if (t == 'd') {
                    if (inlen - off < 3u + x) break;
                    write_all(master, (char *)in + off + 3, x);
                    off += 3u + x;
                } else { off = inlen; } /* garbage: drop */
            }
            memmove(in, in + off, inlen - off);
            inlen -= off;
        }
    }

    if (client >= 0) close(client);
    unlink(sock);
    int st; waitpid(child, &st, 0);
    return 0;
}

static void spawn_server(const char *self, const char *sock, char **cmd, int ncmd) {
    pid_t pid = fork();
    if (pid < 0) return;
    if (pid > 0) { int st; waitpid(pid, &st, 0); return; }
    setsid();
    if (fork() > 0) _exit(0); /* double fork: fully detached from the viewer */
    int nul = open("/dev/null", O_RDWR);
    dup2(nul, 0); dup2(nul, 1); dup2(nul, 2);
    if (nul > 2) close(nul);
    /* Don't hold on to anything the launching app had open (sockets, pipes). */
    for (int f = 3; f < 1024; f++) close(f);
    char **argv = calloc((size_t)ncmd + 5, sizeof(char *));
    argv[0] = (char *)self; argv[1] = "serve"; argv[2] = (char *)sock; argv[3] = "--";
    for (int i = 0; i < ncmd; i++) argv[4 + i] = cmd[i];
    execv(self, argv);
    _exit(127);
}

/* ---------------- client ---------------- */

static struct termios saved;
static int raw_on = 0;
static volatile sig_atomic_t winch = 1;

static void restore(void) { if (raw_on) tcsetattr(0, TCSAFLUSH, &saved); }
static void on_winch(int s) { (void)s; winch = 1; }

static int send_size(int fd) {
    struct winsize ws;
    if (ioctl(0, TIOCGWINSZ, &ws) < 0) return 0;
    unsigned char m[5] = { 'w', ws.ws_row >> 8, ws.ws_row & 0xff, ws.ws_col >> 8, ws.ws_col & 0xff };
    return write_all(fd, (char *)m, 5);
}

static int attach(int fd) {
    if (isatty(0) && tcgetattr(0, &saved) == 0) {
        struct termios r = saved;
        cfmakeraw(&r);
        if (tcsetattr(0, TCSAFLUSH, &r) == 0) { raw_on = 1; atexit(restore); }
    }
    struct sigaction sa = { 0 };
    sa.sa_handler = on_winch;
    sigaction(SIGWINCH, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    char buf[65536];
    unsigned char frame[3 + 4096];
    for (;;) {
        if (winch) { winch = 0; if (send_size(fd) < 0) return 0; }
        fd_set rf; FD_ZERO(&rf); FD_SET(0, &rf); FD_SET(fd, &rf);
        if (select(fd + 1, &rf, NULL, NULL, NULL) < 0) { if (errno == EINTR) continue; return 1; }
        if (FD_ISSET(fd, &rf)) {
            ssize_t r = read(fd, buf, sizeof(buf));
            if (r <= 0) { if (r < 0 && errno == EINTR) continue; return 0; }
            if (write_all(1, buf, (size_t)r) < 0) return 1;
        }
        if (FD_ISSET(0, &rf)) {
            ssize_t r = read(0, frame + 3, 4096);
            if (r <= 0) { if (r < 0 && errno == EINTR) continue; return 0; }
            frame[0] = 'd'; frame[1] = (unsigned char)(r >> 8); frame[2] = (unsigned char)(r & 0xff);
            if (write_all(fd, (char *)frame, 3 + (size_t)r) < 0) return 0;
        }
    }
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: cc-keeper open|serve <socket> [-- cmd...]\n"); return 2; }
    const char *mode = argv[1], *sock = argv[2];
    if (strlen(sock) >= sizeof(((struct sockaddr_un *)0)->sun_path)) { fprintf(stderr, "cc-keeper: socket path too long\n"); return 2; }
    char **cmd = NULL; int ncmd = 0;
    if (argc > 4 && strcmp(argv[3], "--") == 0) { cmd = argv + 4; ncmd = argc - 4; }

    if (strcmp(mode, "serve") == 0) {
        if (!cmd) return 2;
        return serve(sock, cmd);
    }
    if (strcmp(mode, "open") == 0) {
        int fd = connect_sock(sock);
        if (fd < 0 && cmd) {
            spawn_server(argv[0], sock, cmd, ncmd);
            for (int i = 0; i < 100 && fd < 0; i++) { usleep(20000); fd = connect_sock(sock); }
        }
        if (fd < 0) { fprintf(stderr, "cc-keeper: session is no longer running\n"); return 1; }
        return attach(fd);
    }
    return 2;
}
