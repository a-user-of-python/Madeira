// Minimal gzip + ustar extractor. Handles the subset of tar produced by
// /usr/bin/tar on macOS: regular files (type '0'), directories (type '5'),
// and pax extended headers (type 'x', ignored).

#include "PrefixExtractor.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <zlib.h>

#define BLOCK 512

static int parse_octal(const char *s, size_t n) {
    int v = 0;
    for (size_t i = 0; i < n && s[i]; i++) {
        if (s[i] == ' ' || s[i] == 0) continue;
        if (s[i] < '0' || s[i] > '7') return -1;
        v = (v << 3) | (s[i] - '0');
    }
    return v;
}

static int mkdir_p(const char *path) {
    char buf[1024];
    strncpy(buf, path, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = 0;
    for (char *p = buf + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            if (mkdir(buf, 0755) != 0 && errno != EEXIST) return -1;
            *p = '/';
        }
    }
    if (mkdir(buf, 0755) != 0 && errno != EEXIST) return -1;
    return 0;
}

int madeira_extract_prefix_tgz(const char *tgz_path, const char *dest_dir) {
    gzFile gz = gzopen(tgz_path, "rb");
    if (!gz) {
        fprintf(stderr, "[prefix-extract] gzopen failed: %s\n", tgz_path);
        return -1;
    }

    if (mkdir_p(dest_dir) != 0) {
        fprintf(stderr, "[prefix-extract] mkdir_p dest failed: %s\n", dest_dir);
        gzclose(gz);
        return -1;
    }

    char header[BLOCK];
    char buf[BLOCK];
    int files = 0, dirs = 0;

    for (;;) {
        int n = gzread(gz, header, BLOCK);
        if (n == 0) break;
        if (n != BLOCK) {
            fprintf(stderr, "[prefix-extract] short header read: %d\n", n);
            gzclose(gz);
            return -1;
        }
        // End-of-archive: two zero blocks. Bail on any all-zero block.
        int all_zero = 1;
        for (int i = 0; i < BLOCK; i++) if (header[i]) { all_zero = 0; break; }
        if (all_zero) break;

        char name[101] = {0};
        memcpy(name, header, 100);
        int size = parse_octal(header + 124, 12);
        char type = header[156];

        // Strip leading "prefix/" so files land directly under dest_dir.
        const char *relname = name;
        if (strncmp(relname, "prefix/", 7) == 0) relname += 7;
        else if (strcmp(relname, "prefix") == 0) relname = "";

        char outpath[1200];
        if (*relname) {
            snprintf(outpath, sizeof(outpath), "%s/%s", dest_dir, relname);
        } else {
            snprintf(outpath, sizeof(outpath), "%s", dest_dir);
        }

        if (type == '5' || (type == 0 && name[strlen(name) - 1] == '/')) {
            // Directory
            if (*relname) {
                if (mkdir_p(outpath) != 0) {
                    fprintf(stderr, "[prefix-extract] mkdir %s: %s\n", outpath, strerror(errno));
                    gzclose(gz);
                    return -1;
                }
                dirs++;
            }
        } else if (type == '0' || type == 0) {
            // Regular file — ensure parent dir, then write size bytes
            char parent[1200];
            strncpy(parent, outpath, sizeof(parent) - 1);
            parent[sizeof(parent) - 1] = 0;
            char *slash = strrchr(parent, '/');
            if (slash) { *slash = 0; mkdir_p(parent); }

            int fd = open(outpath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd < 0) {
                fprintf(stderr, "[prefix-extract] open %s: %s\n", outpath, strerror(errno));
                gzclose(gz);
                return -1;
            }
            int remaining = size;
            while (remaining > 0) {
                int want = remaining < BLOCK ? remaining : BLOCK;
                int got = gzread(gz, buf, BLOCK);
                if (got != BLOCK) {
                    fprintf(stderr, "[prefix-extract] short data read for %s\n", relname);
                    close(fd);
                    gzclose(gz);
                    return -1;
                }
                if (write(fd, buf, want) != want) {
                    fprintf(stderr, "[prefix-extract] write %s: %s\n", outpath, strerror(errno));
                    close(fd);
                    gzclose(gz);
                    return -1;
                }
                remaining -= want;
            }
            close(fd);
            files++;
        } else if (type == 'x' || type == 'g' || type == 'L' || type == 'K') {
            // pax extended / GNU long-name headers — skip payload
            int pad = (size + BLOCK - 1) / BLOCK * BLOCK;
            while (pad > 0) {
                if (gzread(gz, buf, BLOCK) != BLOCK) {
                    fprintf(stderr, "[prefix-extract] short ext-header skip\n");
                    gzclose(gz);
                    return -1;
                }
                pad -= BLOCK;
            }
        } else {
            // Unknown type — skip its data blocks
            int pad = (size + BLOCK - 1) / BLOCK * BLOCK;
            while (pad > 0) {
                if (gzread(gz, buf, BLOCK) != BLOCK) break;
                pad -= BLOCK;
            }
        }
    }

    gzclose(gz);
    fprintf(stderr, "[prefix-extract] extracted %d files, %d dirs to %s\n", files, dirs, dest_dir);
    return 0;
}

// Minimal zip extractor (stored + deflated entries). Appended for the
// "Import from Web" feature: game archives downloaded from the user's own
// web server are usually zips, and iOS ships no unzip API.
//
// Returns 0 on success, -1 on error. Rejects encrypted entries, absolute
// paths and ".." traversal (zip-slip); skips __MACOSX metadata dirs.
// Streaming inflate keeps memory flat no matter the archive size.

#include <stdint.h>

static uint16_t zip_rd16(const unsigned char *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t zip_rd32(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

// 1 = safe to extract, 0 = reject. Zip paths use '/' separators.
static int zip_path_safe(const char *name, size_t len) {
    if (len == 0) return 0;
    if (name[0] == '/') return 0;
    for (size_t i = 0; i + 1 < len; i++) {
        if (name[i] == '.' && name[i + 1] == '.') {
            int prev_ok = (i == 0) || (name[i - 1] == '/');
            int next_ok = (i + 2 == len) || (name[i + 2] == '/');
            if (prev_ok && next_ok) return 0;
        }
    }
    return 1;
}

static int zip_inflate_stream(FILE *fin, uint32_t comp_len, FILE *fout) {
    unsigned char in[65536];
    unsigned char out[65536];
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    // -MAX_WBITS: raw deflate, no zlib/gzip header (that is what zip stores).
    if (inflateInit2(&strm, -MAX_WBITS) != Z_OK) return -1;
    uint32_t remaining = comp_len;
    int zret = Z_OK;
    int stream_end = 0;
    while (!stream_end) {
        if (strm.avail_in == 0 && remaining > 0) {
            size_t want = remaining > sizeof(in) ? sizeof(in) : remaining;
            size_t got = fread(in, 1, want, fin);
            if (got == 0) { zret = Z_DATA_ERROR; break; }
            strm.next_in = in;
            strm.avail_in = (uInt)got;
            remaining -= (uint32_t)got;
        }
        strm.next_out = out;
        strm.avail_out = sizeof(out);
        int finished_input = (remaining == 0 && strm.avail_in == 0);
        zret = inflate(&strm, finished_input ? Z_FINISH : Z_NO_FLUSH);
        size_t have = sizeof(out) - strm.avail_out;
        if (have > 0 && fwrite(out, 1, have, fout) != have) { zret = Z_ERRNO; break; }
        if (zret == Z_STREAM_END) { stream_end = 1; break; }
        if (zret != Z_OK) break;
        if (finished_input && strm.avail_out != 0) {
            zret = Z_DATA_ERROR;  // truncated stream
            break;
        }
    }
    inflateEnd(&strm);
    return stream_end ? 0 : -1;
}

static int zip_copy_stream(FILE *fin, uint32_t len, FILE *fout) {
    unsigned char buf[65536];
    while (len > 0) {
        size_t want = len > sizeof(buf) ? sizeof(buf) : len;
        size_t got = fread(buf, 1, want, fin);
        if (got == 0) return -1;
        if (fwrite(buf, 1, got, fout) != got) return -1;
        len -= (uint32_t)got;
    }
    return 0;
}

int madeira_extract_zip(const char *zip_path, const char *dest_dir) {
    FILE *f = fopen(zip_path, "rb");
    if (!f) {
        fprintf(stderr, "[zip-extract] open failed: %s\n", zip_path);
        return -1;
    }
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return -1; }
    long file_size = ftell(f);
    if (file_size < 22) { fclose(f); return -1; }

    // Find End of Central Directory: at most 64KB comment + 22-byte record.
    long scan_len = file_size < 65557 ? file_size : 65557;
    unsigned char *tail = malloc((size_t)scan_len);
    if (!tail) { fclose(f); return -1; }
    fseek(f, file_size - scan_len, SEEK_SET);
    if (fread(tail, 1, (size_t)scan_len, f) != (size_t)scan_len) {
        free(tail); fclose(f); return -1;
    }
    long eocd_off = -1;
    for (long i = scan_len - 22; i >= 0; i--) {
        if (zip_rd32(tail + (size_t)i) == 0x06054b50) {
            eocd_off = file_size - scan_len + i;
            break;
        }
    }
    free(tail);
    if (eocd_off < 0) {
        fprintf(stderr, "[zip-extract] EOCD not found: %s\n", zip_path);
        fclose(f);
        return -1;
    }

    unsigned char eocd[22];
    fseek(f, eocd_off, SEEK_SET);
    if (fread(eocd, 1, 22, f) != 22) { fclose(f); return -1; }
    uint16_t cd_count = zip_rd16(eocd + 10);
    uint32_t cd_offset = zip_rd32(eocd + 16);
    if (cd_count == 0xFFFF || cd_offset == 0xFFFFFFFF) {
        fprintf(stderr, "[zip-extract] zip64 not supported: %s\n", zip_path);
        fclose(f);
        return -1;
    }

    if (mkdir_p(dest_dir) != 0) { fclose(f); return -1; }

    int files = 0, dirs = 0, skipped = 0;
    long cd_pos = (long)cd_offset;
    for (uint16_t i = 0; i < cd_count; i++) {
        unsigned char hdr[46];
        fseek(f, cd_pos, SEEK_SET);
        if (fread(hdr, 1, 46, f) != 46) {
            fprintf(stderr, "[zip-extract] short central-dir read\n");
            fclose(f);
            return -1;
        }
        if (zip_rd32(hdr) != 0x02014b50) {
            fprintf(stderr, "[zip-extract] bad central-dir signature\n");
            fclose(f);
            return -1;
        }
        uint16_t flags = zip_rd16(hdr + 8);
        uint16_t method = zip_rd16(hdr + 10);
        uint32_t comp_size = zip_rd32(hdr + 20);
        uint16_t name_len = zip_rd16(hdr + 28);
        uint16_t extra_len = zip_rd16(hdr + 30);
        uint16_t comment_len = zip_rd16(hdr + 32);
        uint32_t local_off = zip_rd32(hdr + 42);
        cd_pos += 46 + name_len + extra_len + comment_len;

        if (name_len == 0 || name_len >= 1024) { skipped++; continue; }
        char name[1024];
        if (fread(name, 1, name_len, f) != name_len) { fclose(f); return -1; }
        name[name_len] = 0;

        if (flags & 0x01) {
            fprintf(stderr, "[zip-extract] encrypted entry unsupported: %s\n", name);
            fclose(f);
            return -1;
        }
        if (method != 0 && method != 8) {
            fprintf(stderr, "[zip-extract] unsupported method %u: %s\n", method, name);
            fclose(f);
            return -1;
        }
        if (!zip_path_safe(name, name_len)) {
            fprintf(stderr, "[zip-extract] unsafe path skipped: %s\n", name);
            skipped++;
            continue;
        }
        if (strncmp(name, "__MACOSX/", 9) == 0) { skipped++; continue; }

        char outpath[2048];
        snprintf(outpath, sizeof(outpath), "%s/%s", dest_dir, name);

        if (name[name_len - 1] == '/') {
            if (mkdir_p(outpath) != 0) { fclose(f); return -1; }
            dirs++;
            continue;
        }

        // Ensure the parent directory exists.
        char parent[2048];
        strncpy(parent, outpath, sizeof(parent) - 1);
        parent[sizeof(parent) - 1] = 0;
        char *slash = strrchr(parent, '/');
        if (slash) { *slash = 0; mkdir_p(parent); }

        // Data starts after the local header (sizes come from the central
        // directory, which is authoritative even when the local header uses
        // a data descriptor).
        unsigned char lh[30];
        fseek(f, (long)local_off, SEEK_SET);
        if (fread(lh, 1, 30, f) != 30 || zip_rd32(lh) != 0x04034b50) {
            fprintf(stderr, "[zip-extract] bad local header: %s\n", name);
            fclose(f);
            return -1;
        }
        uint16_t lh_name = zip_rd16(lh + 26);
        uint16_t lh_extra = zip_rd16(lh + 28);
        fseek(f, (long)local_off + 30 + lh_name + lh_extra, SEEK_SET);

        FILE *fout = fopen(outpath, "wb");
        if (!fout) {
            fprintf(stderr, "[zip-extract] open %s: %s\n", outpath, strerror(errno));
            fclose(f);
            return -1;
        }
        int rc = (method == 0)
            ? zip_copy_stream(f, comp_size, fout)
            : zip_inflate_stream(f, comp_size, fout);
        fclose(fout);
        if (rc != 0) {
            fprintf(stderr, "[zip-extract] data error: %s\n", name);
            fclose(f);
            return -1;
        }
        files++;
    }

    fclose(f);
    fprintf(stderr, "[zip-extract] extracted %d files, %d dirs (%d skipped) to %s\n",
            files, dirs, skipped, dest_dir);
    return 0;
}
