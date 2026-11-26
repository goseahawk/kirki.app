#!/usr/bin/env python3
"""Starts a freshly built kirki disk image in QEMU and checks that it works as the Mac app needs.

    python3 image/test-boot.py out/kirki-vm-VERSION.img RESULTS_DIR

QEMU stands in for macOS's Virtualization framework with the same kinds of devices: EFI firmware,
virtio disk, network, GPU (2D, no 3D), sound and console ports, including the kirki app's control port
(org.kirki.control). The disk is given 40 GB, as the app does when it installs kirki. It checks that:

  - kirki starts and kirk-vm-agent says "ready" on the control port,
  - the root file system grew to fill the bigger disk (kirk-vm-grow),
  - the virtio sound driver (built with DKMS) found the sound card,
  - the first-start setup window opens (screenshots are saved),
  - "shutdown" from the app shuts kirki down and kirk-vm-power reports it ("power poweroff").

The image itself isn't changed (QEMU writes to a temporary overlay). Needs qemu-system-aarch64,
qemu-img and EFI firmware (Debian/Ubuntu: qemu-system-arm qemu-utils qemu-efi-aarch64). Uses KVM
when /dev/kvm is there; otherwise everything is emulated, which takes a while.
"""
import json
import os
import socket
import subprocess
import sys
import time

FIRMWARE = ["/usr/share/qemu-efi-aarch64/QEMU_EFI.fd", "/usr/share/AAVMF/AAVMF_CODE.fd"]
DISK_GB = 40


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


class Lines:
    """Line-based connection to a QEMU socket chardev."""

    def __init__(self, path, timeout=120):
        end = time.time() + timeout
        while True:
            try:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(path)
                break
            except OSError:
                if time.time() > end:
                    raise
                time.sleep(0.5)
        self.buf = b""

    def send(self, line):
        self.sock.sendall((line + "\n").encode())

    def read(self, timeout):
        """The next line, or None after timeout seconds."""
        end = time.time() + timeout
        while b"\n" not in self.buf:
            left = end - time.time()
            if left <= 0:
                return None
            self.sock.settimeout(min(left, 5))
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                continue
            if not chunk:
                return None
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return line.decode(errors="replace").rstrip("\r")


class QMP:
    def __init__(self, path):
        self.conn = Lines(path)
        self.conn.read(30)                       # greeting
        self.cmd("qmp_capabilities")

    def cmd(self, name, **args):
        self.conn.send(json.dumps({"execute": name, "arguments": args}))
        while True:
            line = self.conn.read(60)
            if line is None:
                raise RuntimeError(f"no answer to {name}")
            msg = json.loads(line)
            if "return" in msg or "error" in msg:
                return msg


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    image = os.path.abspath(sys.argv[1])
    out = os.path.abspath(sys.argv[2])
    os.makedirs(out, exist_ok=True)
    firmware = next((f for f in FIRMWARE if os.path.exists(f)), None)
    if not firmware:
        sys.exit("No aarch64 EFI firmware found (install qemu-efi-aarch64).")
    kvm = os.access("/dev/kvm", os.R_OK | os.W_OK)
    # Emulated, everything takes many times longer than on a Mac.
    slow = 1 if kvm else 5
    log(f"KVM: {'yes' if kvm else 'no (emulating; slow)'}")

    disk = os.path.join(out, "test-disk.qcow2")
    subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", "-F", "raw", "-b", image, disk, f"{DISK_GB}G"], check=True)
    ctl_path, qmp_path = os.path.join(out, "ctl.sock"), os.path.join(out, "qmp.sock")
    for p in (ctl_path, qmp_path):
        if os.path.exists(p):
            os.unlink(p)
    qemu = [
        "qemu-system-aarch64", "-machine", "virt", "-smp", "4", "-m", "4096",
        *(["-accel", "kvm", "-cpu", "host"] if kvm else ["-accel", "tcg,thread=multi", "-cpu", "max,pauth-impdef=on"]),
        "-bios", firmware,
        "-drive", f"if=none,id=disk,file={disk},format=qcow2", "-device", "virtio-blk-pci,drive=disk",
        "-device", "virtio-gpu-pci,xres=1920,yres=1200",
        "-device", "qemu-xhci", "-device", "usb-kbd", "-device", "usb-tablet",
        "-netdev", "user,id=net", "-device", "virtio-net-pci,netdev=net",
        "-device", "virtio-rng-pci",
        "-audiodev", "none,id=snd", "-device", "virtio-sound-pci,audiodev=snd",
        "-device", "virtio-serial-pci",
        "-chardev", f"file,id=con,path={os.path.join(out, 'console.log')}", "-device", "virtconsole,chardev=con",
        "-chardev", f"socket,id=ctl,path={ctl_path},server=on,wait=off",
        "-device", "virtserialport,chardev=ctl,name=org.kirki.control",
        "-qmp", f"unix:{qmp_path},server=on,wait=off",
        "-serial", f"file:{os.path.join(out, 'firmware.log')}",
        "-display", "none",
    ]
    log("Starting: " + " ".join(qemu))
    vm = subprocess.Popen(qemu)
    results = {"kvm": kvm, "ready": False, "statuses": [], "screenshots": [], "power": None, "exited": False}
    problems = []

    def shot(name):
        path = os.path.join(out, f"{name}.png")
        r = qmp.cmd("screendump", filename=path, format="png")
        if "error" in r:
            log(f"screenshot failed: {r['error']}")
        else:
            results["screenshots"].append(path)
            log(f"screenshot: {path}")

    def status():
        ctl.send("status")
        end = time.time() + 60 * slow
        while time.time() < end:
            line = ctl.read(end - time.time())
            if line is None:
                break
            if line.startswith("status "):
                st = dict(kv.split("=", 1) for kv in line.split()[1:] if "=" in kv)
                results["statuses"].append(st)
                log(f"status: {st}")
                return st
            log(f"(guest: {line})")
        return None

    try:
        ctl = Lines(ctl_path)
        qmp = QMP(qmp_path)
        line = None
        end = time.time() + 6 * 60 * slow
        next_shot, n = time.time() + 300, 0
        while time.time() < end:
            line = ctl.read(min(end, next_shot) - time.time())
            if line is not None and line.startswith("ready"):
                break
            if line is not None:
                log(f"(guest: {line})")
            else:
                time.sleep(1)
            if time.time() >= next_shot:       # where is it? a screenshot every 5 minutes
                n += 1
                shot(f"waiting-{n:02d}")
                log(f"console so far: {os.path.getsize(os.path.join(out, 'console.log'))} bytes, "
                    f"firmware: {os.path.getsize(os.path.join(out, 'firmware.log'))} bytes")
                next_shot = time.time() + 300
            if vm.poll() is not None:
                break
        if not line or not line.startswith("ready"):
            problems.append("kirk-vm-agent never said ready")
            shot("no-agent")
            raise RuntimeError(problems[-1])
        results["ready"] = True
        log(f"Guest: {line}")
        ctl.send("hostinfo KEYBOARD_LAYOUT=us TIMEZONE=Europe/Berlin MAC_MODEL=MacBook%20Air MAC_CHIP=Apple%20M2 DISPLAY_SCALE=1 APP_VERSION=test")
        ctl.send(f"time {time.time():.3f}")

        # First-start setup should open: wait for Calamares, then give it time to draw
        st = None
        end = time.time() + 8 * 60 * slow
        while time.time() < end:
            st = status()
            if st and st.get("ui") == "setup":
                break
            time.sleep(15)
        time.sleep(40 * slow)
        shot("first-start")
        st = status() or st or {}
        if st.get("ui") != "setup":
            problems.append(f"the first-start setup window didn't open (ui={st.get('ui')})")
        if int(st.get("root_bytes", 0)) < (DISK_GB - 5) * 10**9:
            problems.append(f"the root file system didn't grow to the disk ({st.get('root_bytes')} bytes)")
        if st.get("sound") != "yes":
            problems.append("no virtio sound card (the DKMS driver didn't load)")
        if st.get("failed", "none") != "none":
            log(f"WARNING: failed units: {st.get('failed')}")

        # Shut down the way the app does when you log out of macOS
        ctl.send("shutdown")
        end = time.time() + 5 * 60 * slow
        while time.time() < end:
            line = ctl.read(end - time.time())
            if line is None:
                break
            if line.startswith("power "):
                results["power"] = line.split()[1]
                log(f"Guest: {line}")
                break
            log(f"(guest: {line})")
        if results["power"] != "poweroff":
            problems.append(f"no 'power poweroff' from kirk-vm-power (got {results['power']})")
        try:
            vm.wait(timeout=120 * slow)
            results["exited"] = True
        except subprocess.TimeoutExpired:
            problems.append("QEMU didn't exit after kirki shut down")
    except Exception as e:  # noqa: BLE001 - report everything, keep the logs
        if str(e) not in problems:
            problems.append(f"{type(e).__name__}: {e}")
    finally:
        if vm.poll() is None:
            vm.kill()
            vm.wait()
        if os.path.exists(disk):
            os.unlink(disk)
        for p in (ctl_path, qmp_path):        # sockets can't go in the artifact
            if os.path.exists(p):
                os.unlink(p)
        if problems:                           # the logs, where the job log shows them
            for name in ("firmware.log", "console.log"):
                path = os.path.join(out, name)
                if os.path.exists(path):
                    with open(path, "rb") as f:
                        tail = f.read()[-6000:].decode(errors="replace")
                    print(f"---- {name} (last 6000 bytes) ----\n{tail}\n---- end of {name} ----", flush=True)
        results["problems"] = problems
        with open(os.path.join(out, "results.json"), "w") as f:
            json.dump(results, f, indent=2)
    if problems:
        log("FAILED:\n  " + "\n  ".join(problems))
        sys.exit(1)
    log("All checks passed.")


if __name__ == "__main__":
    main()
