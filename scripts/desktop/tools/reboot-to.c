// SPDX-License-Identifier: GPL-2.0
/*
 * Freestanding aarch64 helper for the bring-up initramfs: sync, then reboot with
 * the "bootloader" argument (busybox reboot cannot pass a reboot argument).
 * No libc needed. Built and pushed to the tablet by scripts/desktop/install.sh:
 *   aarch64-linux-gnu-gcc -static -nostdlib -ffreestanding -O2 -o reboot-to reboot-to.c
 */
static long sys4(long n, long a, long b, long c, long d)
{
	register long x8 __asm__("x8") = n;
	register long x0 __asm__("x0") = a;
	register long x1 __asm__("x1") = b;
	register long x2 __asm__("x2") = c;
	register long x3 __asm__("x3") = d;

	__asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
	return x0;
}

void _start(void)
{
	static const char arg[] = "bootloader";

	sys4(81, 0, 0, 0, 0);					/* sync */
	sys4(142, 0xfee1dead, 672274793, 0xA1B2C3D4, (long)arg);	/* reboot(RESTART2, arg) */
	sys4(93, 1, 0, 0, 0);					/* exit(1) if it failed */
	for (;;)
		;
}
