#!/usr/bin/env bash
# apply-oom-gates.sh - bring a DGX Spark's OOM stack up to the kit launch policy.
# Run:  sudo bash scripts/apply-oom-gates.sh
# Idempotent; safe to re-run. Prints current state first (step 0 = the record),
# then only writes what is missing, then verifies EFFECTIVE state
# (probe-what-you-built: a headerless drop-in parses to nothing, so the file
# existing proves nothing).
#
# Naming that matters here: "user.slice" the UNIT ships with systemd and always
# exists (systemctl cat user.slice -> /usr/lib/systemd/system/user.slice).
# /etc/systemd/system/user.slice.d/ is OUR admin drop-in dir - systemd does NOT
# pre-create it. An absent dir means the 120G cap was never persistently
# applied (or was removed); it is not a systemd problem.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo (installs systemd-oomd, writes a system drop-in)" >&2; exit 2; }

DROPIN=/etc/systemd/system/user.slice.d/oom-protection.conf
WANT=$'[Slice]\nMemoryMax=120G\nManagedOOMMemoryPressure=kill\nManagedOOMMemoryPressureLimit=80%\n'

echo "[0/4] current state (paste this block back if anything surprises you)"
echo "  systemd version:       $(systemctl --version | head -1)"
echo "  oomd unit file:        $(systemctl cat systemd-oomd.service >/dev/null 2>&1 && echo present || echo ABSENT)"
echo "  oomd active:           $(systemctl is-active systemd-oomd 2>/dev/null || echo no)"
echo "  drop-in dir:           $(ls -ld /etc/systemd/system/user.slice.d 2>/dev/null || echo ABSENT)"
echo "  drop-in file:          $(ls -l "$DROPIN" 2>/dev/null || echo ABSENT)"
echo "  MemoryMax (effective): $(systemctl show user.slice -p MemoryMax --value)"

echo "[1/4] systemd-oomd package"
if systemctl cat systemd-oomd.service >/dev/null 2>&1; then
  echo "  unit file present"
elif command -v apt-get >/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-oomd
else
  echo "  no apt on this box (non-DGX-OS?) - SKIP; the cap applied below still stops the whole-box freeze via kernel cgroup OOM (oomd adds an early-pressure kill layer on top; runbook appendix A)" >&2
fi

echo "[2/4] enable systemd-oomd"
if systemctl cat systemd-oomd.service >/dev/null 2>&1; then
  systemctl enable --now systemd-oomd
else
  echo "  no oomd unit to enable (status noted in step 0)"
fi

echo "[3/4] drop-in $DROPIN"
mkdir -p "$(dirname "$DROPIN")"   # check-before-create: systemd ships the UNIT, not this dir
if [ -f "$DROPIN" ] && cmp -s <(printf '%s' "$WANT") "$DROPIN"; then
  echo "  already correct"
else
  printf '%s' "$WANT" > "$DROPIN"
  chmod 644 "$DROPIN"
  echo "  written ([Slice] header REQUIRED - headerless drop-ins parse to nothing)"
fi

echo "[4/4] daemon-reload + VERIFY effective state"
systemctl daemon-reload
MAX=$(systemctl show user.slice -p MemoryMax --value)
ACT=$(systemctl is-active systemd-oomd 2>/dev/null || true)
echo "  systemd-oomd:         ${ACT:-inactive}"
echo "  user.slice MemoryMax: $MAX (120G = 128849018880 bytes)"
if [ -z "$MAX" ] || [ "$MAX" = "infinity" ]; then
  echo "CAP DID NOT TAKE - runbook appendix A has the hints (wrong dir / missing [Slice] header / typo)" >&2
  exit 1
fi
if [ "$ACT" != "active" ]; then
  echo "NOTE: oomd is not ACTIVE (early-pressure layer missing). The MemoryMax cap alone prevents the freeze via kernel cgroup OOM; the ManagedOOM lines stay dormant without it. The kit preflight still wants an oom daemon: install systemd-oomd (Ubuntu: apt) or earlyoom before ./start.sh." >&2
  exit 1
fi
echo "OOM gates applied and verified - run ./start.sh from the kit root"
