#!/usr/bin/env bash
# ec-check.sh — diagnose why the EC read interface isn't available. Read-only.
echo "== 1. secure boot =="
mokutil --sb-state 2>&1 || echo "(mokutil not present)"

echo
echo "== 2. debugfs mounted? =="
mount | grep -q debugfs && echo "debugfs: mounted" || { echo "debugfs NOT mounted — mounting"; mount -t debugfs none /sys/kernel/debug 2>&1; }

echo
echo "== 3. ec_sys module =="
if [ -e /sys/kernel/debug/ec/ec0/io ]; then
  echo "io node already present (ec_sys built-in or loaded)"
else
  echo "loading ec_sys..."
  modprobe ec_sys 2>&1; echo "modprobe exit=$?"
  modprobe ec_sys write_support=1 2>&1; echo "modprobe(write) exit=$? (write attempt only to expose node; we still only READ)"
fi

echo
echo "== 4. ec directory =="
ls -la /sys/kernel/debug/ec/ 2>&1
ls -la /sys/kernel/debug/ec/ec0/ 2>&1

echo
echo "== 5. read 256 registers =="
if [ -e /sys/kernel/debug/ec/ec0/io ]; then
  dd if=/sys/kernel/debug/ec/ec0/io bs=256 count=1 2>/dev/null | xxd
  echo "^^ if you see 16 rows of hex above, the read works."
else
  echo "io node STILL missing — ec_sys not available in this kernel."
  echo "check: grep ACPI_EC_DEBUGFS /boot/config-\$(uname -r) 2>/dev/null"
  grep ACPI_EC_DEBUGFS "/boot/config-$(uname -r)" 2>/dev/null || echo "(no kernel config file to check)"
fi
