/*
 * convert.c - Generate OpenPiton mem.image from raw binary files.
 *
 * Usage: convert -o mem.image 0x80000000:checkpoint_combined.bin
 *
 * Output format (compatible with OpenPiton bw_lib.c read_mem):
 *   @<16-hex-digit-addr>
 *   <32 bytes as 4 groups of 16 hex chars, space-separated>
 *   ...
 *   Data is padded to 64-byte cache line boundary.
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define CACHELINE 64u
#define LINE_BYTES 32u
#define BUF_SIZE (1024u * 1024u)

static const char HEX[] = "0123456789abcdef";

typedef struct {
    uint64_t addr;
    uint64_t size;
    char path[4096];
} Block;

static void die(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "error: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    exit(1);
}

static uint64_t get_file_size(const char *path)
{
    struct stat st;
    if (stat(path, &st) != 0)
        die("stat %s: %s", path, strerror(errno));
    return (uint64_t)st.st_size;
}

static uint64_t pad64(uint64_t n)
{
    uint64_t r = n % CACHELINE;
    return r ? n + (CACHELINE - r) : n;
}

static void flush_line(FILE *out, const unsigned char *line)
{
    char buf[LINE_BYTES * 2 + 3 + 1];
    int pos = 0;
    for (unsigned i = 0; i < LINE_BYTES; i++) {
        if (i > 0 && (i % 8) == 0)
            buf[pos++] = ' ';
        buf[pos++] = HEX[line[i] >> 4];
        buf[pos++] = HEX[line[i] & 0xf];
    }
    buf[pos++] = '\n';
    fwrite(buf, 1, (size_t)pos, out);
}

static void emit_block(FILE *out, const Block *b)
{
    FILE *in = fopen(b->path, "rb");
    if (!in)
        die("open %s: %s", b->path, strerror(errno));

    fprintf(out, "@%016" PRIx64 "\t// %s (%" PRIu64 " bytes)\n", b->addr, b->path, b->size);

    unsigned char *buf = malloc(BUF_SIZE);
    if (!buf) die("out of memory");

    unsigned char line[LINE_BYTES];
    unsigned line_pos = 0;
    uint64_t remain = b->size;

    while (remain > 0) {
        size_t want = remain > BUF_SIZE ? BUF_SIZE : (size_t)remain;
        size_t got = fread(buf, 1, want, in);
        if (got != want)
            die("short read from %s", b->path);
        for (size_t i = 0; i < got; i++) {
            line[line_pos++] = buf[i];
            if (line_pos == LINE_BYTES) {
                flush_line(out, line);
                line_pos = 0;
            }
        }
        remain -= got;
    }

    /* Zero-pad to cacheline boundary */
    uint64_t zeros = pad64(b->size) - b->size;
    while (zeros > 0) {
        line[line_pos++] = 0;
        if (line_pos == LINE_BYTES) {
            flush_line(out, line);
            line_pos = 0;
        }
        zeros--;
    }

    if (line_pos > 0) {
        memset(line + line_pos, 0, LINE_BYTES - line_pos);
        flush_line(out, line);
    }

    free(buf);
    fclose(in);
}

static int parse_spec(const char *arg, Block *b)
{
    const char *colon = strchr(arg, ':');
    if (!colon || colon == arg || colon[1] == '\0')
        return -1;

    char addr_buf[64];
    size_t alen = (size_t)(colon - arg);
    if (alen >= sizeof(addr_buf))
        return -1;
    memcpy(addr_buf, arg, alen);
    addr_buf[alen] = '\0';

    char *end = NULL;
    errno = 0;
    b->addr = strtoull(addr_buf, &end, 0);
    if (errno || !end || *end != '\0')
        return -1;

    const char *path = colon + 1;
    if (strlen(path) >= sizeof(b->path))
        return -1;
    strcpy(b->path, path);
    b->size = get_file_size(path);
    return 0;
}

static int block_cmp(const void *a, const void *b)
{
    uint64_t aa = ((const Block *)a)->addr;
    uint64_t bb = ((const Block *)b)->addr;
    return (aa > bb) - (aa < bb);
}

int main(int argc, char **argv)
{
    const char *outfile = "mem.image";
    Block blocks[64];
    int nblocks = 0;

    for (int i = 1; i < argc; i++) {
        if ((strcmp(argv[i], "-o") == 0 || strcmp(argv[i], "--output") == 0) && i + 1 < argc) {
            outfile = argv[++i];
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            printf("Usage: %s [-o FILE] ADDR:FILE [...]\n", argv[0]);
            return 0;
        } else if (strchr(argv[i], ':')) {
            if (nblocks >= 64) die("too many blocks (max 64)");
            if (parse_spec(argv[i], &blocks[nblocks]) != 0)
                die("invalid spec: %s", argv[i]);
            nblocks++;
        } else {
            die("unknown argument: %s", argv[i]);
        }
    }

    if (nblocks == 0)
        die("no input files. Usage: convert -o FILE ADDR:FILE [...]");

    qsort(blocks, (size_t)nblocks, sizeof(blocks[0]), block_cmp);

    printf("Blocks to write:\n");
    for (int i = 0; i < nblocks; i++) {
        printf("  @%016" PRIx64 ": %" PRIu64 " bytes (padded to %" PRIu64 ") - %s\n",
               blocks[i].addr, blocks[i].size, pad64(blocks[i].size), blocks[i].path);
    }

    FILE *out = fopen(outfile, "w");
    if (!out)
        die("open %s: %s", outfile, strerror(errno));

    for (int i = 0; i < nblocks; i++)
        emit_block(out, &blocks[i]);

    if (fclose(out) != 0)
        die("close %s: %s", outfile, strerror(errno));

    uint64_t total = 0;
    for (int i = 0; i < nblocks; i++)
        total += pad64(blocks[i].size);
    printf("Wrote %s: %d blocks, %" PRIu64 " bytes total\n", outfile, nblocks, total);
    return 0;
}
