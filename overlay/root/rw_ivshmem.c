/* rw_ivshmem.c  –  build with:  gcc -O2 -Wall -o rw_ivshmem rw_ivshmem.c
 *
 * Changes vs your previous version:
 *  - REMOVE -FF / -DD completely.
 *  - New continuous flags:
 *      -P <infile>   (Producer, continuous single-slot): wait (write==read), then write, then write++
 *      -C <outfile>  (Consumer, continuous single-slot): wait (write==read+1 && ready==1), then dump, then read++
 *  - Add lots of debug:
 *      -v            enable verbose debug on stderr
 *      also respects RW_IVSHMEM_DEBUG=1
 *  - Debug prints around: parsing, mmap/open, wait loops, header snapshots, write/dump critical points.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <string.h>
#include <errno.h>
#include <getopt.h>
#include <stdint.h>
#include <sys/stat.h>
#include <time.h>
#include <stdarg.h>
#include <signal.h>
#include <setjmp.h>
#include <ctype.h>

#define DEFAULT_SHM_SIZE   (64 * 1024 * 1024)
#define SHORT_LEN          4000
#define LONG_LEN           (64 * 1024 * 1024)

#define HDR_MAGIC "IVSHFILE"
#define HDR_MAGIC_LEN 8
#define HDR_SIZE  0x20
#define PAYLOAD_OFF HDR_SIZE

typedef struct __attribute__((packed)) {
    uint32_t write_cnt;    /* producer increments after producing */
    uint32_t read_cnt;     /* consumer increments after consuming */
    char     magic[8];     /* "IVSHFILE" */
    uint64_t length;       /* payload length */
    uint32_t ready;        /* 0 while writing, 1 complete */
    uint32_t reserved;
} shm_hdr_t;

static int g_verbose = 0;
static sigjmp_buf g_pf_jmp;
static volatile sig_atomic_t g_pf_in_touch = 0;

static void pf_sig_handler(int sig);
static int touch_page_best_effort(volatile unsigned char *p);

static uint64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)ts.tv_nsec / 1000000ULL;
}

static void dlogf(const char *fmt, ...)
{
    if (!g_verbose) return;
    fprintf(stderr, "[%llu ms pid=%d] ",
            (unsigned long long)now_ms(), (int)getpid());
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

static void print_a(size_t len)
{
    for (size_t i = 0; i < len; ++i) putchar('A');
    putchar('\n');
}

static void usage(const char *prog, const char *def_path, size_t def_size)
{
    fprintf(stderr,
        "Usage:\n"
        "  %s -S                         # print 4000 × 'A'\n"
        "  %s -L                         # print LONG_LEN × 'A'\n"
        "  %s -R [short|long|N]          # read N bytes (default: SHM size)\n"
        "  %s -W <string>                # write string into BAR @ offset 0\n"
        "  %s -F <infile>                # one-shot: file -> shared mem (with header)\n"
        "  %s -D <outfile>               # one-shot: shared mem payload -> file\n"
        "  %s -P <infile>                # continuous producer: wait (write==read), then write, then write++\n"
        "  %s -C <outfile>               # continuous consumer: wait (write==read+1 && ready==1), then dump, then read++\n"
        "  %s --prefault <config.json>   # touch PROTECTED mapping pages from config, auto-using resource2/resource3/..\n"
        "\n"
        "Options:\n"
        "  -f <path>                     # BAR/resource file to mmap (default: %s)\n"
        "  -z <bytes>                    # mmap length AND max R/W cap (default: %zu)\n"
        "  -o <offset>                   # mmap file offset (page-aligned)\n"
        "  -v                            # verbose debug on stderr\n"
        "  -h                            # help\n"
        "\n"
        "Header (32 bytes @ offset 0):\n"
        "  write_cnt(u32), read_cnt(u32), magic[8], length(u64), ready(u32), reserved(u32)\n"
        "Payload starts at 0x%X.\n",
        prog, prog, prog, prog, prog, prog, prog, prog, prog,
        def_path, def_size, PAYLOAD_OFF);
    exit(1);
}

static int find_matching_brace(const char *s, int open_pos)
{
    int depth = 0, in_str = 0, esc = 0;
    int i;
    for (i = open_pos; s[i] != '\0'; i++) {
        char c = s[i];
        if (in_str) {
            if (esc) {
                esc = 0;
            } else if (c == '\\') {
                esc = 1;
            } else if (c == '"') {
                in_str = 0;
            }
            continue;
        }
        if (c == '"') {
            in_str = 1;
            continue;
        }
        if (c == '{') {
            depth++;
        } else if (c == '}') {
            depth--;
            if (depth == 0) return i;
        }
    }
    return -1;
}

static int parse_u64_at(const char *p, uint64_t *out)
{
    char *end = NULL;
    while (*p && isspace((unsigned char)*p)) p++;
    errno = 0;
    unsigned long long v = strtoull(p, &end, 0);
    if (errno || end == p) return -1;
    *out = (uint64_t)v;
    return 0;
}

static char *read_text_file(const char *path, size_t *out_len)
{
    int fd = open(path, O_RDONLY);
    char *buf;
    struct stat st;
    ssize_t n;
    if (fd < 0) return NULL;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) {
        close(fd);
        return NULL;
    }
    buf = (char *)malloc((size_t)st.st_size + 1U);
    if (!buf) {
        close(fd);
        return NULL;
    }
    n = read(fd, buf, (size_t)st.st_size);
    close(fd);
    if (n < 0 || (size_t)n != (size_t)st.st_size) {
        free(buf);
        return NULL;
    }
    buf[st.st_size] = '\0';
    if (out_len) *out_len = (size_t)st.st_size;
    return buf;
}

static int derive_resource_path(const char *base_path, unsigned int idx_off, char *out, size_t out_sz)
{
    const char *tag = strstr(base_path, "resource");
    const char *num_p;
    unsigned long base_num;
    char *end = NULL;
    size_t prefix_len;
    if (!tag) return -1;
    num_p = tag + strlen("resource");
    if (!isdigit((unsigned char)*num_p)) return -1;
    errno = 0;
    base_num = strtoul(num_p, &end, 10);
    if (errno || end == num_p) return -1;
    prefix_len = (size_t)(num_p - base_path);
    if (snprintf(out, out_sz, "%.*s%lu", (int)prefix_len, base_path, base_num + idx_off) >= (int)out_sz)
        return -1;
    return 0;
}

static int prefault_one_range(const char *res_path, uint64_t size,
                              unsigned long long *out_touched,
                              unsigned long long *out_faults)
{
    int fd;
    long pg = sysconf(_SC_PAGESIZE);
    size_t map_len;
    unsigned char *bar;
    uint64_t off;
    int faults = 0, touched = 0;

    if (out_touched) *out_touched = 0;
    if (out_faults) *out_faults = 0;

    if (pg <= 0 || size == 0) return -1;
    map_len = (size_t)((size + (uint64_t)pg - 1ULL) & ~((uint64_t)pg - 1ULL));

    fd = open(res_path, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "prefault: open failed for %s: %s\n", res_path, strerror(errno));
        return -1;
    }

    bar = mmap(NULL, map_len, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (bar == MAP_FAILED) {
        fprintf(stderr, "prefault: mmap failed for %s: %s\n", res_path, strerror(errno));
        return -1;
    }

    for (off = 0; off < map_len; off += (uint64_t)pg) {
        if (touch_page_best_effort((volatile unsigned char *)(bar + off)) != 0) {
            faults++;
            dlogf("PREFAULT: access fault path=%s off=0x%llx",
                  res_path, (unsigned long long)off);
        } else {
            touched++;
        }
    }

    munmap(bar, map_len);
    dlogf("PREFAULT: %s size=0x%llx touched=%d faults=%d", res_path,
          (unsigned long long)size, touched, faults);
    if (out_touched) *out_touched = (unsigned long long)touched;
    if (out_faults) *out_faults = (unsigned long long)faults;
    return 0;
}

static int prefault_from_config(const char *base_res_path, const char *cfg_path)
{
    char *json;
    int rc = 0;
    size_t json_len = 0;
    const char *p;
    unsigned int protected_idx = 0;
    unsigned long long total_touched = 0, total_faults = 0;
    struct sigaction sa, old_bus, old_segv;

    json = read_text_file(cfg_path, &json_len);
    if (!json) {
        fprintf(stderr, "prefault: failed to read config %s\n", cfg_path);
        return 1;
    }
    dlogf("PREFAULT: loaded config '%s' len=%zu", cfg_path, json_len);

    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = pf_sig_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGBUS, &sa, &old_bus);
    sigaction(SIGSEGV, &sa, &old_segv);

    p = json;
    while ((p = strstr(p, "\"Mem")) != NULL) {
        const char *colon = strchr(p, ':');
        const char *obj_open;
        int obj_end;
        const char *obj;
        const char *type_key;
        const char *maps_key;
        const char *size_key;
        uint64_t mem_size = 0;
        char res_path[512];

        if (!colon) break;
        obj_open = strchr(colon, '{');
        if (!obj_open) break;
        obj_end = find_matching_brace(obj_open, 0);
        if (obj_end < 0) break;
        obj = obj_open;

        type_key = strstr(obj, "\"type\"");
        if (!type_key || type_key > obj + obj_end ||
            strstr(type_key, "\"PROTECTED\"") == NULL ||
            strstr(type_key, "\"PROTECTED\"") > obj + obj_end) {
            p = obj + obj_end + 1;
            continue;
        }

        size_key = strstr(obj, "\"size\"");
        if (!size_key || size_key > obj + obj_end) {
            p = obj + obj_end + 1;
            continue;
        }
        {
            const char *sc = strchr(size_key, ':');
            if (!sc || sc > obj + obj_end || parse_u64_at(sc + 1, &mem_size) != 0) {
                p = obj + obj_end + 1;
                continue;
            }
        }

        maps_key = strstr(obj, "\"mappings\"");
        if (maps_key && maps_key < obj + obj_end) {
            const char *mcolon = strchr(maps_key, ':');
            const char *mopen = mcolon ? strchr(mcolon, '{') : NULL;
            int mend = mopen ? find_matching_brace(mopen, 0) : -1;
            if (mopen && mend > 0) {
                const char *mp = mopen;
                while ((mp = strstr(mp, "\"gpa\"")) != NULL && mp < mopen + mend) {
                    const char *gc = strchr(mp, ':');
                    uint64_t gpa = 0;
                    (void)gpa;
                    if (!gc || gc > mopen + mend || parse_u64_at(gc + 1, &gpa) != 0) {
                        mp += 5;
                        continue;
                    }
                    if (derive_resource_path(base_res_path, protected_idx, res_path, sizeof(res_path)) == 0) {
                        unsigned long long touched = 0, faults = 0;
                        dlogf("PREFAULT: protected_mem_idx=%u gpa=0x%llx size=0x%llx path=%s",
                              protected_idx, (unsigned long long)gpa,
                              (unsigned long long)mem_size, res_path);
                        if (prefault_one_range(res_path, mem_size, &touched, &faults) != 0) {
                            rc = 1;
                        } else {
                            total_touched += touched;
                            total_faults += faults;
                        }
                    } else {
                        fprintf(stderr, "prefault: failed to derive resource path from %s\n", base_res_path);
                        rc = 1;
                    }
                    mp += 5;
                }
            }
        }

        protected_idx++;
        p = obj + obj_end + 1;
    }

    fprintf(stderr, "prefault: summary touched=%llu faults=%llu\n",
            total_touched, total_faults);
    sigaction(SIGBUS, &old_bus, NULL);
    sigaction(SIGSEGV, &old_segv, NULL);
    free(json);
    if (total_faults > 0) rc = 1;
    return rc;
}

static void sleep_brief(void)
{
    struct timespec ts;
    ts.tv_sec = 0;
    ts.tv_nsec = 1000 * 1000; /* 1ms */
    nanosleep(&ts, NULL);
}

static void snap_hdr(shm_hdr_t *h, uint32_t *w, uint32_t *r, uint32_t *ready, uint64_t *len, char magic_out[9])
{
    __sync_synchronize();
    *w = h->write_cnt;
    *r = h->read_cnt;
    *ready = h->ready;
    *len = h->length;
    memcpy(magic_out, h->magic, 8);
    magic_out[8] = '\0';
    __sync_synchronize();
}

/* Non-destructive: only ensure magic exists; NEVER reset counters. */
static void ensure_magic_present(shm_hdr_t *h)
{
    if (memcmp(h->magic, HDR_MAGIC, HDR_MAGIC_LEN) == 0) return;
    dlogf("ensure_magic_present: magic missing/corrupt; writing magic (NOT touching counters).");
    memcpy(h->magic, HDR_MAGIC, HDR_MAGIC_LEN);
    h->ready = 0;
    __sync_synchronize();
}

static int write_file_to_shm_one_shot(char *bar, size_t shm_size, const char *infile)
{
    int fd = open(infile, O_RDONLY);
    if (fd < 0) { perror("open infile"); return 1; }

    struct stat st;
    if (fstat(fd, &st) != 0) { perror("fstat infile"); close(fd); return 1; }
    if (!S_ISREG(st.st_mode)) {
        fprintf(stderr, "Input is not a regular file: %s\n", infile);
        close(fd);
        return 1;
    }

    uint64_t file_len = (uint64_t)st.st_size;

    if (shm_size < PAYLOAD_OFF) {
        fprintf(stderr, "SHM region too small for header (need >= %u)\n", PAYLOAD_OFF);
        close(fd);
        return 1;
    }

    uint64_t cap = (uint64_t)(shm_size - PAYLOAD_OFF);
    if (file_len > cap) {
        fprintf(stderr, "File too large for SHM payload: file=%llu, cap=%llu\n",
                (unsigned long long)file_len, (unsigned long long)cap);
        close(fd);
        return 1;
    }

    shm_hdr_t *h = (shm_hdr_t*)bar;
    ensure_magic_present(h);

    dlogf("WRITE(one-shot): infile='%s' size=%llu bytes cap=%llu",
          infile, (unsigned long long)file_len, (unsigned long long)cap);

    /* publish "not ready" + length */
    h->ready = 0;
    __sync_synchronize();
    h->length = file_len;
    __sync_synchronize();

    uint8_t *dst = (uint8_t*)bar + PAYLOAD_OFF;

    uint64_t off = 0;
    while (off < file_len) {
        size_t chunk = (size_t)((file_len - off) > (1<<20) ? (1<<20) : (file_len - off));
        ssize_t r = pread(fd, dst + off, chunk, (off_t)off);
        if (r < 0) { perror("pread infile"); close(fd); return 1; }
        if (r == 0) break;
        off += (uint64_t)r;
    }
    close(fd);

    if (off != file_len) {
        fprintf(stderr, "Short read: copied %llu / %llu\n",
                (unsigned long long)off, (unsigned long long)file_len);
        return 1;
    }

    __sync_synchronize();
    h->ready = 1;
    __sync_synchronize();

    dlogf("WRITE(one-shot): complete; ready=1");
    return 0;
}

static int dump_shm_to_file_one_shot(char *bar, size_t shm_size, const char *outfile)
{
    if (shm_size < PAYLOAD_OFF) {
        fprintf(stderr, "SHM region too small for header\n");
        return 1;
    }

    shm_hdr_t *h = (shm_hdr_t*)bar;

    if (memcmp(h->magic, HDR_MAGIC, HDR_MAGIC_LEN) != 0) {
        fprintf(stderr, "Bad/missing header magic (expected '%s')\n", HDR_MAGIC);
        return 1;
    }

    __sync_synchronize();
    if (h->ready != 1) {
        fprintf(stderr, "Shared memory not marked ready yet (ready=%u)\n", h->ready);
        return 1;
    }

    uint64_t len = h->length;
    uint64_t cap = (uint64_t)(shm_size - PAYLOAD_OFF);
    if (len > cap) {
        fprintf(stderr, "Header length exceeds SHM payload cap: len=%llu cap=%llu\n",
                (unsigned long long)len, (unsigned long long)cap);
        return 1;
    }

    dlogf("DUMP(one-shot): outfile='%s' len=%llu", outfile, (unsigned long long)len);

    int fd = open(outfile, O_CREAT | O_TRUNC | O_WRONLY, 0644);
    if (fd < 0) { perror("open outfile"); return 1; }

    uint8_t *src = (uint8_t*)bar + PAYLOAD_OFF;

    uint64_t off = 0;
    while (off < len) {
        size_t chunk = (size_t)((len - off) > (1<<20) ? (1<<20) : (len - off));
        ssize_t w = write(fd, src + off, chunk);
        if (w < 0) { perror("write outfile"); close(fd); return 1; }
        off += (uint64_t)w;
    }

    if (fsync(fd) != 0) { perror("fsync outfile"); }
    close(fd);

    dlogf("DUMP(one-shot): complete");
    return 0;
}

/* -P: wait (write==read), then write, then write++ */
static int producer_continuous(char *bar, size_t shm_size, const char *infile)
{
    shm_hdr_t *h = (shm_hdr_t*)bar;

    dlogf("PRODUCER: entering wait loop for condition write_cnt==read_cnt");
    uint64_t last_report = now_ms();

    for (;;) {
        uint32_t w, r, ready;
        uint64_t len;
        char magic[9];
        snap_hdr(h, &w, &r, &ready, &len, magic);

        if (w == r) {
            dlogf("PRODUCER: condition met (w=%u r=%u ready=%u len=%llu magic='%s')",
                  w, r, ready, (unsigned long long)len, magic);
            break;
        }

        uint64_t t = now_ms();
        if (t - last_report >= 1000) {
            dlogf("PRODUCER: waiting... w=%u r=%u ready=%u len=%llu magic='%s'",
                  w, r, ready, (unsigned long long)len, magic);
            last_report = t;
        }
        sleep_brief();
    }

    ensure_magic_present(h);

    /* write payload + ready=1 */
    int rc = write_file_to_shm_one_shot(bar, shm_size, infile);
    if (rc != 0) return rc;

    /* publish write_cnt++ AFTER ready=1 */
    __sync_synchronize();
    uint32_t old = h->write_cnt;
    h->write_cnt = old + 1;
    __sync_synchronize();

    dlogf("PRODUCER: incremented write_cnt %u -> %u", old, old + 1);
    return 0;
}

/* -C: wait (write==read+1 && ready==1), then dump, then read++ */
static int consumer_continuous(char *bar, size_t shm_size, const char *outfile)
{
    shm_hdr_t *h = (shm_hdr_t*)bar;

    dlogf("CONSUMER: entering wait loop for condition write_cnt==read_cnt+1 && ready==1");
    uint64_t last_report = now_ms();

    for (;;) {
        uint32_t w, r, ready;
        uint64_t len;
        char magic[9];
        snap_hdr(h, &w, &r, &ready, &len, magic);

        int magic_ok = (memcmp(magic, HDR_MAGIC, HDR_MAGIC_LEN) == 0);
        int cond = (w == (uint32_t)(r + 1)) && (ready == 1) && magic_ok;

        if (cond) {
            dlogf("CONSUMER: condition met (w=%u r=%u ready=%u len=%llu magic='%s')",
                  w, r, ready, (unsigned long long)len, magic);
            break;
        }

        uint64_t t = now_ms();
        if (t - last_report >= 1000) {
            dlogf("CONSUMER: waiting... w=%u r=%u ready=%u len=%llu magic='%s'%s",
                  w, r, ready, (unsigned long long)len, magic,
                  magic_ok ? "" : " (magic BAD)");
            last_report = t;
        }
        sleep_brief();
    }

    int rc = dump_shm_to_file_one_shot(bar, shm_size, outfile);
    if (rc != 0) return rc;

    /* publish read_cnt++ and clear ready (optional) */
    __sync_synchronize();
    uint32_t old = h->read_cnt;
    h->read_cnt = old + 1;
    h->ready = 0;
    __sync_synchronize();

    dlogf("CONSUMER: incremented read_cnt %u -> %u; set ready=0", old, old + 1);
    return 0;
}

int main(int argc, char **argv)
{
    const char *default_bar_path = "/sys/bus/pci/devices/0000:00:03.0/resource2";
    const char *bar_path = default_bar_path;
    size_t shm_size = DEFAULT_SHM_SIZE;
    size_t max_rw_len = DEFAULT_SHM_SIZE;
    off_t map_off = 0;

    enum { MODE_NONE, MODE_S, MODE_L, MODE_R, MODE_W, MODE_F, MODE_D, MODE_P, MODE_C, MODE_PREF } mode = MODE_NONE;
    const char *read_arg = NULL;
    const char *write_arg = NULL;
    const char *file_in = NULL;
    const char *file_out = NULL;
    const char *prefault_cfg = NULL;

    /* env-based verbose */
    const char *envv = getenv("RW_IVSHMEM_DEBUG");
    if (envv && (strcmp(envv, "1") == 0 || strcmp(envv, "true") == 0)) g_verbose = 1;

    int c, opt_idx = 0;
    static struct option long_opts[] = {
        {"prefault", required_argument, 0, 1000},
        {0, 0, 0, 0}
    };
    opterr = 0;
    while ((c = getopt_long(argc, argv, "SLR:W:F:D:P:C:f:z:o:vh", long_opts, &opt_idx)) != -1) {
        switch (c) {
            case 'S': mode = MODE_S; break;
            case 'L': mode = MODE_L; break;
            case 'R': mode = MODE_R; read_arg = optarg; break;
            case 'W': mode = MODE_W; write_arg = optarg; break;
            case 'F': mode = MODE_F; file_in = optarg; break;
            case 'D': mode = MODE_D; file_out = optarg; break;
            case 'P': mode = MODE_P; file_in = optarg; break;   /* NEW producer flag */
            case 'C': mode = MODE_C; file_out = optarg; break;  /* NEW consumer flag */
            case 'f': bar_path = optarg; break;
            case 'z': {
                char *end = NULL;
                errno = 0;
                unsigned long v = strtoul(optarg, &end, 0);
                if (errno || !optarg[0] || (end && *end)) {
                    fprintf(stderr, "Invalid -z <bytes>: '%s'\n", optarg);
                    usage(argv[0], default_bar_path, DEFAULT_SHM_SIZE);
                }
                shm_size = (size_t)v;
                max_rw_len = (size_t)v;
            } break;
            case 'o': {
                char *end = NULL;
                errno = 0;
                unsigned long long v = strtoull(optarg, &end, 0);
                if (errno || !optarg[0] || (end && *end)) {
                    fprintf(stderr, "Invalid -o <offset>: '%s'\n", optarg);
                    usage(argv[0], default_bar_path, DEFAULT_SHM_SIZE);
                }
                map_off = (off_t)v;
            } break;
            case 'v':
                g_verbose = 1;
                break;
            case 'h':
            default:
                usage(argv[0], default_bar_path, DEFAULT_SHM_SIZE);
            case 1000:
                mode = MODE_PREF;
                prefault_cfg = optarg;
                break;
        }
    }

    if (mode == MODE_S) { print_a(SHORT_LEN); return 0; }
    if (mode == MODE_L) { print_a(LONG_LEN);  return 0; }

    if (mode != MODE_R && mode != MODE_W && mode != MODE_F && mode != MODE_D &&
        mode != MODE_P && mode != MODE_C && mode != MODE_PREF) {
        usage(argv[0], default_bar_path, DEFAULT_SHM_SIZE);
    }

    if (mode == MODE_PREF) {
        if (!prefault_cfg) {
            fprintf(stderr, "Missing config file for --prefault.\n");
            return 1;
        }
        return prefault_from_config(bar_path, prefault_cfg);
    }

    dlogf("ARGS: mode=%d bar_path='%s' shm_size=%zu map_off=%llu",
          mode, bar_path, shm_size, (unsigned long long)map_off);

    int fd = open(bar_path, O_RDWR);
    if (fd == -1) { perror("open"); return 1; }

    long pg = sysconf(_SC_PAGESIZE);
    if (pg <= 0) { fprintf(stderr, "sysconf(_SC_PAGESIZE) failed\n"); close(fd); return 1; }
    if (map_off % pg) {
        fprintf(stderr, "mmap offset must be page-aligned\n");
        close(fd);
        return 1;
    }

    int prot = (mode == MODE_R) ? PROT_READ : (PROT_READ | PROT_WRITE);
    char *bar = mmap(NULL, shm_size, prot, MAP_SHARED, fd, map_off);
    if (bar == MAP_FAILED) { perror("mmap"); close(fd); return 1; }

    dlogf("MMAP: ok addr=%p prot=%s", (void*)bar, (prot == PROT_READ) ? "R" : "RW");

    /* Early header snapshot */
    if (g_verbose) {
        shm_hdr_t *h = (shm_hdr_t*)bar;
        uint32_t w, r, ready;
        uint64_t len;
        char magic[9];
        snap_hdr(h, &w, &r, &ready, &len, magic);
        dlogf("HDR@START: w=%u r=%u ready=%u len=%llu magic='%s'",
              w, r, ready, (unsigned long long)len, magic);
    }

    int rc = 0;

    if (mode == MODE_R) {
        size_t len = shm_size;
        if (read_arg && read_arg[0]) {
            if      (strcmp(read_arg, "short") == 0) len = SHORT_LEN;
            else if (strcmp(read_arg, "long")  == 0) len = LONG_LEN;
            else {
                char *end = NULL;
                errno = 0;
                unsigned long v = strtoul(read_arg, &end, 0);
                if (errno || (end && *end)) {
                    munmap(bar, shm_size); close(fd);
                    usage(argv[0], default_bar_path, DEFAULT_SHM_SIZE);
                }
                len = (size_t)v;
            }
        }
        if (len > max_rw_len) len = max_rw_len;
        if (len > shm_size)  len = shm_size;
        fwrite(bar, 1, len, stdout);
        putchar('\n');
    }
    else if (mode == MODE_W) {
        if (!write_arg) {
            fprintf(stderr, "Missing string to write.\n");
            rc = 1;
        } else {
            size_t len = strlen(write_arg);
            if (len > max_rw_len) len = max_rw_len;
            if (len > shm_size)   len = shm_size;
            memcpy(bar, write_arg, len);
        }
    }
    else if (mode == MODE_F) {
        if (!file_in) { fprintf(stderr, "Missing input file for -F.\n"); rc = 1; }
        else rc = write_file_to_shm_one_shot(bar, shm_size, file_in);
    }
    else if (mode == MODE_D) {
        if (!file_out) { fprintf(stderr, "Missing output file for -D.\n"); rc = 1; }
        else rc = dump_shm_to_file_one_shot(bar, shm_size, file_out);
    }
    else if (mode == MODE_P) {
        if (!file_in) { fprintf(stderr, "Missing input file for -P.\n"); rc = 1; }
        else rc = producer_continuous(bar, shm_size, file_in);
    }
    else if (mode == MODE_C) {
        if (!file_out) { fprintf(stderr, "Missing output file for -C.\n"); rc = 1; }
        else rc = consumer_continuous(bar, shm_size, file_out);
    }

    if (g_verbose) {
        shm_hdr_t *h = (shm_hdr_t*)bar;
        uint32_t w, r, ready;
        uint64_t len;
        char magic[9];
        snap_hdr(h, &w, &r, &ready, &len, magic);
        dlogf("HDR@END: w=%u r=%u ready=%u len=%llu magic='%s'",
              w, r, ready, (unsigned long long)len, magic);
    }

    munmap(bar, shm_size);
    close(fd);
    return rc;
}
static void pf_sig_handler(int sig)
{
    if (g_pf_in_touch) {
        g_pf_in_touch = 0;
        siglongjmp(g_pf_jmp, sig);
    }
}

static int touch_page_best_effort(volatile unsigned char *p)
{
    int sig = sigsetjmp(g_pf_jmp, 1);
    if (sig != 0) {
        dlogf("PREFAULT: fault signal=%d", sig);
        return -1;
    }
    g_pf_in_touch = 1;
    (void)*p; /* Force data access fault path via normal userspace load */
    g_pf_in_touch = 0;
    return 0;
}
