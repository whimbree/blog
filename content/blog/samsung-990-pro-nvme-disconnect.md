+++
title = "Stabilizing the Samsung 990 PRO on Linux: Disabling ASPM and APST to Stop NVMe Disconnects"
date = 2026-04-18

[taxonomies]
tags = ["nixos", "linux", "nvme", "zfs", "homelab"]
+++

*Or: all that reseating, cleaning, and slot swapping for a kernel parameter fix.*

## The problem

I have a Samsung 990 PRO 4TB as the boot/rpool NVMe in my homelab server (bastion — ZFS everywhere, MicroVMs, 24/7 uptime). It started randomly disappearing. No warning, no graceful degradation — just gone. `dmesg` would light up with the NVMe controller giving up, followed by I/O errors on every operation that was in flight:

```
[204263.471182] nvme nvme0: Device not ready; aborting reset, CSTS=0x1
[204283.495338] nvme nvme0: Device not ready; aborting reset, CSTS=0x1
[204283.569360] I/O error, dev nvme0n1, sector 2623470496 op 0x1:(WRITE) flags 0x0 phys_seg 1 prio class 2
[204283.569365] I/O error, dev nvme0n1, sector 3026384936 op 0x1:(WRITE) flags 0x0 phys_seg 1 prio class 2
[204283.569369] I/O error, dev nvme0n1, sector 3025352880 op 0x0:(READ) flags 0x0 phys_seg 1 prio class 2
[204283.569369] I/O error, dev nvme0n1, sector 2623481976 op 0x1:(WRITE) flags 0x0 phys_seg 11 prio class 2
[204496.790887] systemd[1]: systemd-timesyncd.service: Watchdog timeout (limit 3min)!
```

Then swap would start failing because the device backing it was gone:

```
[248903.580981] Read-error on swap-device (254:1:78162624)
[248903.590087] Read-error on swap-device (254:1:78162632)
[248903.599150] Read-error on swap-device (254:1:78162640)
...
```

ZFS would notice the drive had vanished and mark the vdev as `FAULTED`. Game over until reboot.

<!-- more -->

## The wrong rabbit holes

The drive always came back after a power cycle. SMART data was clean:

```
Model Number:                       Samsung SSD 990 PRO 4TB
Firmware Version:                   4B2QJXD7

SMART overall-health self-assessment test result: PASSED

SMART/Health Information (NVMe Log 0x02)
Temperature:                        56 Celsius
Available Spare:                    100%
Media and Data Integrity Errors:    0
Error Information Log Entries:      0
Power Cycles:                       54
Power On Hours:                     9,871
Unsafe Shutdowns:                   37
Temperature Sensor 1:               56 Celsius
Temperature Sensor 2:               67 Celsius
```

Zero media errors, zero error log entries. The hardware was fine. So what was killing it?

**Attempt 1: it's the M.2 slot.** I had recently moved bastion into a new case (a [Jonsbo N5](https://www.jonsbo.com/en/products/N5Black.html)). Maybe I'd bumped the connector during the move. Reseated the drive, cleaned the slot, screwed it down carefully. Stable for a few days. Then it dropped again.

**Attempt 2: it's thermal.** The 990 PRO 4TB runs pretty hot. Sensor 2 was hitting 67°C at idle. I replaced the case fans with Noctuas, pointed airflow at the M.2 slot, added a heatsink. Temps improved. Drive still dropped.

**Attempt 3: it's the slot itself.** Bad solder joint? Damaged pins? I pulled the drive, plugged it into a USB-NVMe enclosure on my workstation, ran `smartctl -a` — perfect health, worked flawlessly. Moved it to the secondary M.2 slot on the server. Worked for a while. Dropped again.

37 unsafe shutdowns out of 54 power cycles. That's what happens when your boot drive repeatedly vanishes from under a running system.

## The actual cause

After a week of reseating and slot-swapping (and watching it drop again each time), I finally started reading forums instead of pulling hardware. Turns out this is a **known firmware bug with the Samsung 990 PRO**. The disconnect problem is well-documented on [AskUbuntu](https://askubuntu.com/questions/1538091/samsung-990-pro-installs-ubuntu-24-10-and-the-disk-will-drop-during-use-the-fai) and the [TrueNAS forums](https://forums.truenas.com/t/samsung-990-pro-early-failures-x4/8186), and my firmware version, `4B2QJXD7`, is [specifically called out](https://catcat.blog/en/2026/01/samsung-990-pro-ext4-readonly-fix). The root cause is Samsung's APST (Autonomous Power State Transition) implementation having compatibility issues with the Linux kernel's NVMe power management. When the drive enters certain low-power states, it fails to wake up, the controller resets, and the kernel removes the device.

But it's not just one thing — there are actually three independent layers of power management between the CPU and your NVMe drive, and none of them talk to each other.

## The three layers of power-saving that kill your drive

Think of the physical path from CPU to NVMe as three things stacked on top of each other:

1. **The PCIe port** — the M.2 connector on the motherboard. Provides power. The kernel's runtime PM can cut power to the entire port (D-states).
2. **The PCIe link** — the high-speed lanes between the port and the drive. ASPM can put just the link to sleep.
3. **The NVMe controller** — the chip on the drive. APST lets it put *itself* to sleep.

Each has its own power states, its own sleep/wake mechanism, and its own way of ruining your day.

### PCIe D-states (port power)

Every PCIe device has a power state: **D0** (fully on), **D3hot** (low power but still has auxiliary power), and **D3cold** (power completely cut — cold boot to come back). The kernel's runtime PM can transition ports to D3cold when idle, which is useful on laptops but catastrophic if the NVMe controller doesn't survive the re-initialization. This is the layer behind `Unable to change power state from D3cold to D0, device inaccessible` ([Ubuntu bug #2097618](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2097618)).

On a server that never suspends, D3cold transitions are unlikely but the kernel may still attempt them depending on your distro's defaults. The parameter `pcie_port_pm=off` prevents this.

### PCIe ASPM (link power)

ASPM manages the **link** — the PCIe lanes. The port and drive both stay powered; it's just the communication channel between them that sleeps. The states that matter:

- **L0** — fully active.
- **L0s** — lightweight idle, resumes in under a microsecond. Mostly harmless.
- **L1 / L1.1 / L1.2** — deep idle. Both ends power down. Re-entry takes microseconds to tens of microseconds. This is where things break — the link is deep enough asleep that waking it requires a retrain sequence, and if the drive's controller is *also* asleep, the wake handshake can fail.

ASPM is negotiated between the CPU and the device, but the UEFI firmware gets first say — it enables or disables ASPM per-port before Linux boots. This is important: **disabling ASPM in BIOS is the primary fix**, because it prevents the link from ever entering L1 in the first place.

The kernel parameter `pcie_aspm=off` is *not* a disable — [the kernel docs](https://docs.kernel.org/admin-guide/kernel-parameters.html) say it means "don't touch ASPM configuration at all, leave any configuration done by firmware unchanged." So if your BIOS has ASPM enabled (the default on most boards), `pcie_aspm=off` leaves it enabled. It's useful as a safety net to prevent the kernel from *re-enabling* ASPM on its own, but it won't override what the firmware already set.

You can check what your system negotiated:

```bash
sudo lspci -vv | grep -i aspm
```

Look for `LnkCtl: ASPM L1 Enabled` under your NVMe controller.

### NVMe APST (controller power)

This is the one that was actually killing my drive. APST lets the drive's controller autonomously cycle through internal power states (PS0 through PS4) when idle. The kernel configures it based on the drive's advertised latency table — "if idle for X microseconds, enter state Y." By default, any state with total entry+exit latency under 25ms qualifies.

The 990 PRO's firmware advertises latencies that are optimistic. The controller claims it can wake from PS4 in a few milliseconds, but under certain conditions it can't. The wake fails, the controller resets, the kernel removes the device.

You can check APST configuration with (requires `nvme-cli` — on NixOS: `nix-shell -p nvme-cli`):

```bash
sudo nvme get-feature -f 0x0c -H /dev/nvme0
```

If you see non-operational states (PS3/PS4) with non-zero idle times, APST is actively putting your drive to sleep.

### Why disabling one layer isn't always enough

All three layers are independent and unsynchronized. The drive's controller can enter PS4 via APST while the link independently enters L1.2 via ASPM. Coming back requires both to wake in the right order. If either fumbles the handshake, the kernel sees an unresponsive device and removes it.

This is why people on forums report that `nvme_core.default_ps_max_latency_us=0` alone "reduced but didn't eliminate" their drive drops — you fixed the drive's internal sleep, but the bus underneath it is still flapping.

## The fix

Four changes. The order doesn't matter — they're independent.

### 1. Disable ASPM L1 in UEFI/BIOS

This is the critical one. Go into UEFI setup and look for ASPM settings. The exact location varies by vendor, but common places include:

- **ASUS:** Advanced → PCI Subsystem Settings → ASPM Support
- **ASRock:** Advanced → Chipset Configuration → PCIe ASPM
- **Gigabyte:** Settings → Miscellaneous → PCIe ASPM
- **MSI:** Advanced → PCIe/PCI Subsystem Settings → ASPM

Set it to **Disabled**. This prevents the firmware from ever enabling L1 negotiation, so the link can't enter deep sleep regardless of what the kernel does.

### 2. Kernel parameters

```
nvme_core.default_ps_max_latency_us=0
pcie_aspm=off
pcie_port_pm=off
```

- `nvme_core.default_ps_max_latency_us=0` — disables APST entirely. Sets the max acceptable transition latency to zero, so no power state qualifies. The drive stays in PS0.
- `pcie_aspm=off` — tells the kernel not to touch ASPM, preserving whatever you set in BIOS (which should now be "disabled"). Prevents the kernel from re-enabling ASPM on its own.
- `pcie_port_pm=off` — disables runtime PM for PCIe ports, preventing D3cold transitions. Probably unnecessary on a server that never sleeps, but cheap insurance.

### On NixOS

```nix
boot.kernelParams = [
  # ... other params (ZFS ARC sizes, etc.)
  "nvme_core.default_ps_max_latency_us=0"
  "pcie_aspm=off"
  "pcie_port_pm=off"
];
```

Rebuild, reboot, done.

The full config: [bastion/filesystem.nix](https://github.com/whimbree/nixos-configuration/blob/main/bastion/filesystem.nix).

### On other distros

**GRUB** (Debian, Ubuntu, Fedora, etc.): edit `/etc/default/grub` and append to the existing `GRUB_CMDLINE_LINUX_DEFAULT`:

```bash
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash nvme_core.default_ps_max_latency_us=0 pcie_aspm=off pcie_port_pm=off"
```

Then regenerate the config — `sudo update-grub` on Debian/Ubuntu, `sudo grub2-mkconfig -o /boot/grub2/grub.cfg` on Fedora.

**systemd-boot** (Arch, etc.): edit your loader entry (e.g. `/boot/loader/entries/arch.conf`) and append to the `options` line:

```
options root=... rw nvme_core.default_ps_max_latency_us=0 pcie_aspm=off pcie_port_pm=off
```

## Verifying the fix

The `nvme` CLI comes from the `nvme-cli` package — on NixOS you can run it without installing via `nix-shell -p nvme-cli`, or add it to `environment.systemPackages`. On Debian/Ubuntu it's `apt install nvme-cli`, on Fedora `dnf install nvme-cli`, on Arch `pacman -S nvme-cli`.

**Check ASPM is off:**

```bash
sudo lspci -vv | grep -i "ASPM.*abled"
```

You should see `ASPM Disabled` for your NVMe controller's link. If you still see `ASPM L1 Enabled`, your BIOS setting didn't take — double-check it and verify with:

```bash
cat /proc/cmdline | tr ' ' '\n' | grep -i aspm
```

**Check APST is off:**

```bash
sudo nvme get-feature -f 0x0c -H /dev/nvme0
```

Look for `Autonomous Power State Transition Enable (APSTE): Disabled`.

**Check the drive is staying in PS0:**

```bash
sudo nvme get-feature -f 0x02 -H /dev/nvme0
```

Should report power state 0.

## The trade-off

The drive runs at full power all the time. For the 990 PRO that's about 6–7W active vs. ~30mW in the deepest sleep. On a server that's already pushing hundreds of watts through twelve spinning Exos drives, a couple extra watts from the NVMe staying awake is meaningless.

On a laptop you'd feel it. On a plugged-in machine? Just disable it.

## What about firmware updates?

Samsung has shipped many firmware revisions for the 990 PRO. Here's the full known timeline (sourced from [Samsung Magician release notes](https://semiconductor.samsung.com/consumer-storage/support/tools/), the [Rossmann Group](https://rossmanngroup.com/problems/samsung-990-pro-firmware-degradation), and community reports):

- **`0B2QJXD7`** (November 2022) — launch firmware. Contains the [SMART health degradation bug](https://www.neowin.net/news/samsung-issues-new-firmware-to-stop-but-not-reverse-990-pro-ssd-rapid-health-degradation/) where drives reported 30–50% wear within weeks despite minimal writes.
- **`1B2QJXD7`** (February 2023) — stops the accelerated SMART decline. Does not reset already-inflated counters. **Does not address disconnects.**
- **`3B2QJXD7`** (May 2023) — fixes drive lockups and Samsung Magician anomalies.
- **`4B2QJXD7`** (December 2023) — addresses temperature reporting bugs and general stability. The most common version in the wild (~52% of 2TB drives per [smarthdd.com](https://smarthdd.com/database/Samsung-SSD-990-PRO-2TB/)). **This is the version my drive was on.**
- **`5B2QJXD7`** (date unknown) — purpose undocumented by Samsung. ~9% prevalence on 2TB models.
- **`6B2QJXD7`** (~mid 2025) — purpose undocumented. ~2% prevalence.
- **`7B2QJXD7`** (September 2025) — Samsung's release notes say "to address the intermittent non-recognition and blue screen issue." First firmware that explicitly targets the disconnect problem.
- **`8B2QJXD7`** (December 2025) — "to improve read-operation stability."

Note: the 4TB model launched later with V8 NAND and a different base firmware (`0B2QJXG7`), so the version numbering doesn't map 1:1 across capacities.

You should update to the latest firmware regardless — it may reduce the frequency or severity of the issue, especially on Windows. But Linux's power management stack is more aggressive than Windows', and even if the firmware handles most transitions gracefully now, it only takes one botched wake to fault a ZFS pool. The kernel parameters are cheap insurance.

My drive was on `4B2QJXD7` — already three revisions past the SMART fix, but still predating any firmware that addressed disconnects. Kernel parameters fixed it completely.

## Further reading

- [TrueNAS forum: Samsung 990 Pro Early Failures (x4)](https://forums.truenas.com/t/samsung-990-pro-early-failures-x4/8186) — a user traces four 990 PRO "failures" to APST, disables it, confirms stable after 6+ months.
- [AskUbuntu: Samsung 990 PRO disk drops on Ubuntu 24.10](https://askubuntu.com/questions/1538091/samsung-990-pro-installs-ubuntu-24-10-and-the-disk-will-drop-during-use-the-fai) — same symptoms, same fix, Ubuntu-specific instructions.
- [cr0x.net: Ubuntu 24.04 NVMe Disappears Under Load](https://cr0x.net/en/ubuntu-nvme-disappears-aspm-fix/) — the best existing write-up on the ASPM side of this problem.
- [Launchpad Bug #2097618: Unable to change power state from D3cold to D0](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2097618) — the Ubuntu kernel bug tracking this class of NVMe power management failure.
- [Samsung Community: 990 PRO disappearing from BIOS](https://us.community.samsung.com/t5/Monitors-and-Memory/990-pro-intermittently-dissappearing-from-BIOS/td-p/2876845) — the issue manifests at the firmware level too, before Linux is involved.
- [Rossmann Group: Samsung 990 Pro Firmware Degradation](https://rossmanngroup.com/problems/samsung-990-pro-firmware-degradation) — comprehensive firmware version history with dates and purposes.
- [ArchWiki: Solid State Drives/NVMe](https://wiki.archlinux.org/title/Solid_State_Drives/NVMe) — general NVMe troubleshooting, including the APST section.
- [Unix StackExchange: Clarifying NVMe APST problems](https://unix.stackexchange.com/questions/612096/clarifying-nvme-apst-problems-for-linux) — good technical explainer of how the kernel configures APST.

---

Bastion has been running stable since the change. No drive drops, no ZFS faults, no surprises in `dmesg`. All that reseating, cleaning, and slot swapping — for a kernel parameter fix. At least the Noctuas were a good upgrade regardless.
