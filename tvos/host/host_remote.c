/* Development aid: the game's keyboard from another machine (tvos/tools/keyrelay.py on the Mac), until a
 * pad or a Bluetooth keyboard is paired with the Apple TV.  UDP port 9777 (NFSU2_REMOTE_PORT; the
 * option NFSU2_REMOTE=0 turns it off).  Packets, text, numbers in hex:
 *     "D <dik> [<vk>]"   key down: the DirectInput key, and WM_KEYDOWN when a virtual-key code follows
 *     "U <dik> [<vk>]"   key up (WM_KEYUP)
 *     "C <char> [<dik>]" a typed character (WM_CHAR), what the game's text fields read
 *     "R"                every key up
 * Anyone on the local network can send them: not for a version that is shared. */
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include "kbd.h"

/* the message's lParam: repeat count 1, the scan code, the previous and transition bits */
static uint32_t lparam(unsigned dik, int prev, int up){
    return 1u | ((dik & 0x7Fu) << 16) | ((dik & 0x80u) ? (1u << 24) : 0u) | (prev ? (1u << 30) : 0u) | (up ? (1u << 31) : 0u);
}

static void *remote_main(void *arg){
    (void)arg;
    pthread_setname_np("remote keys");
    const char *pe = getenv("NFSU2_REMOTE_PORT");
    int port = pe && *pe ? atoi(pe) : 9777;
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_addr.s_addr = htonl(INADDR_ANY); a.sin_port = htons((uint16_t)port);
    if (s < 0 || bind(s, (struct sockaddr *)&a, sizeof a) != 0){
        fprintf(stderr, "remote keys: cannot listen on UDP %d\n", port);
        if (s >= 0) close(s);
        return NULL;
    }
    fprintf(stderr, "remote keys: listening on UDP %d\n", port);
    struct ifaddrs *ifa, *i;       /* the address to give keyrelay.py */
    if (getifaddrs(&ifa) == 0){
        for (i = ifa; i; i = i->ifa_next){
            if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET || !(i->ifa_flags & IFF_UP) || (i->ifa_flags & IFF_LOOPBACK)) continue;
            char ip[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, ip, sizeof ip);
            fprintf(stderr, "remote keys: this device is %s (%s)\n", ip, i->ifa_name);
        }
        freeifaddrs(ifa);
    }
    char buf[64];
    for (;;){
        ssize_t n = recv(s, buf, sizeof buf - 1, 0);
        if (n <= 0) continue;
        buf[n] = 0;
        unsigned a = 0, b = 0;
        int k = buf[0] == 'R' ? 0 : sscanf(buf + 1, " %x %x", &a, &b);
        if (buf[0] == 'R') kbd_release_source(KSRC_HOST);
        else if (buf[0] == 'D' && k >= 1 && a > 0 && a < 256){
            kbd_set_key(KSRC_HOST, a, 1);
            if (k >= 2 && b) kbd_post(0x0100u, b, lparam(a, 0, 0));          /* WM_KEYDOWN */
        } else if (buf[0] == 'U' && k >= 1 && a > 0 && a < 256){
            kbd_set_key(KSRC_HOST, a, 0);
            if (k >= 2 && b) kbd_post(0x0101u, b, lparam(a, 1, 1));          /* WM_KEYUP */
        } else if (buf[0] == 'C' && k >= 1 && a > 0)
            kbd_post(0x0102u, a, lparam(k >= 2 ? b : 0, 0, 0));              /* WM_CHAR */
    }
    return NULL;
}

void nfsu2_remote_start(void){
    const char *e = getenv("NFSU2_REMOTE");
    if (e && *e == '0') return;
    pthread_t th;
    if (pthread_create(&th, NULL, remote_main, NULL) == 0) pthread_detach(th);
}
