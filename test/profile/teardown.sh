#!/usr/bin/env bash
set -euo pipefail
pvesm remove lab-bcachefs 2>/dev/null || true
umount /mnt/lab-bcachefs 2>/dev/null || true
