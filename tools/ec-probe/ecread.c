/* ecread.c — READ-ONLY Embedded Controller register dumper via /dev/port.
 *
 * For kernels built without CONFIG_ACPI_EC_DEBUGFS (no ec_sys). Talks the
 * standard ACPI EC protocol over I/O ports 0x62 (data) / 0x66 (status+cmd),
 * issuing ONLY the read command (RD_EC = 0x80). It NEVER issues a write
 * (WR_EC = 0x81) — there is no code path here that writes an EC register.
 *
 * Build:  cc -O2 -o ecread ecread.c
 * Run:    sudo ./ecread          # dump 256 registers once
 *         sudo ./ecread <label>  # same, prefixed so diffs are easy to label
 *
 * Caveat (honest): direct port I/O does not take the kernel's EC mutex, so it
 * races with the kernel ACPI driver. Read collisions at worst yield a stale
 * byte; we re-time with status polling to minimise it. Writes would be the
 * dangerous part — and this tool cannot write.
 */
#include <stdio.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>

#define EC_DATA 0x62
#define EC_SC   0x66
#define RD_EC   0x80
#define OBF     0x01   /* output buffer full  */
#define IBF     0x02   /* input  buffer full  */

static int fd;

static int pget(unsigned port, uint8_t *v) {
    return pread(fd, v, 1, port) == 1 ? 0 : -1;
}
static int pput(unsigned port, uint8_t v) {
    return pwrite(fd, &v, 1, port) == 1 ? 0 : -1;
}
static int wait_clear(uint8_t mask) {           /* wait until status&mask == 0 */
    uint8_t s; for (int i = 0; i < 100000; i++) { if (pget(EC_SC, &s)) return -1; if (!(s & mask)) return 0; }
    return -1;
}
static int wait_set(uint8_t mask) {             /* wait until status&mask != 0 */
    uint8_t s; for (int i = 0; i < 100000; i++) { if (pget(EC_SC, &s)) return -1; if (s & mask) return 0; }
    return -1;
}
static int ec_read(uint8_t addr, uint8_t *out) {
    if (wait_clear(IBF)) return -1;
    if (pput(EC_SC, RD_EC)) return -1;          /* read command */
    if (wait_clear(IBF)) return -1;
    if (pput(EC_DATA, addr)) return -1;         /* register address */
    if (wait_set(OBF)) return -1;
    return pget(EC_DATA, out);
}

int main(int argc, char **argv) {
    fd = open("/dev/port", O_RDWR);
    if (fd < 0) { perror("open /dev/port (need root)"); return 1; }

    const char *label = argc > 1 ? argv[1] : "dump";
    uint8_t regs[256]; int ok = 0;
    for (int a = 0; a < 256; a++) {
        if (ec_read((uint8_t)a, &regs[a]) == 0) ok++;
        else regs[a] = 0xFF;
    }
    printf("EC-DUMP %s  (%d/256 read OK) READ-ONLY\n", label, ok);
    printf("     00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f\n");
    for (int r = 0; r < 16; r++) {
        printf("%02x:", r * 16);
        for (int c = 0; c < 16; c++) printf(" %02x", regs[r * 16 + c]);
        printf("\n");
    }
    close(fd);
    return ok ? 0 : 2;
}
