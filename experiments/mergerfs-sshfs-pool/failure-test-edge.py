#!/usr/bin/env python3
"""Run as: sudo PHONE=<tailscale ip> python3 failure-test-edge.py
Kills the ssh process under sshfs, then queries the pool every ~50 ms and logs what a directory
listing and a stat of the phone-branch canary return, until the pool unmounts.
DANGEROUS = pool mounted AND listing succeeded AND canary absent from it (scanner would drop rows).
Errors/timeouts are fine: the scanner keeps index rows for anything it cannot read."""
import os, signal, subprocess, sys, time

POOL, PIXEL = "/srv/pocket/pool", "/srv/pocket/pixel"
PHONE = os.environ["PHONE"]  # phone tailscale ip
CANARY = "failure-test-canary.txt"
USER = os.environ["SUDO_USER"]


def mounted(path):
    with open("/proc/self/mountinfo") as f:
        return any(line.split()[4] == path for line in f)


class Timeout(Exception):
    pass


def _alarm(*_):
    raise Timeout()


signal.signal(signal.SIGALRM, _alarm)


def probe():
    """(mounted, listing outcome, canary-in-listing outcome)."""
    m = mounted(POOL)
    signal.setitimer(signal.ITIMER_REAL, 2)
    try:
        names = os.listdir(POOL)
        listing = "ok"
        has = CANARY in names
    except Timeout:
        listing, has = "TIMEOUT", None
    except OSError as e:
        listing, has = "ERR:" + (e.strerror or str(e.errno)), None
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
    return m, listing, has


if not mounted(POOL):
    sys.exit("pool is not mounted; nothing to test")
subprocess.run(["sudo", "-u", USER, "sh", "-c", f"echo canary > {PIXEL}/{CANARY}"], check=True)
m, listing, has = probe()
print("baseline:", m, listing, "canary-listed" if has else "canary-MISSING")
if not has:
    sys.exit("canary not visible at baseline; aborting")

subprocess.run(["pkill", "-KILL", "-f", f"ssh -x -a.*root@{PHONE}"])
t0 = time.time()
last, dangerous = None, 0
try:
    while time.time() - t0 < 20:
        m, listing, has = probe()
        state = (m, listing, has)
        danger = m and listing == "ok" and not has
        dangerous += danger
        if state != last:
            print(f"+{time.time() - t0:6.3f}s mounted={m!s:5} listing={listing:<14} canary_in_listing={has}{'   <-- DANGEROUS' if danger else ''}")
            last = state
        if not m:
            break
        time.sleep(0.05)
finally:
    print(f"dangerous samples: {dangerous}")
    for _ in range(90):  # wait for the phone mount to come back, then remove the canary
        if mounted(PIXEL) and mounted(POOL):
            break
        time.sleep(1)
    subprocess.run(["sudo", "-u", USER, "rm", "-f", f"{PIXEL}/{CANARY}"], stderr=subprocess.DEVNULL, timeout=15)
    print("recovered:", mounted(PIXEL) and mounted(POOL))
