+++
title = "Temp-Based HDD Fan Control on ASRock Rack X470D4U via IPMI and NixOS"
date = 2026-04-13

[taxonomies]
tags = ["nixos", "homelab", "ipmi", "fan-control", "zfs"]
+++

*Or: how I spent an hour turning "my drives feel warm" into a nixos module that handles fan control over IPMI, and every dead end I hit along the way.*

## The problem

I have a homelab server with twelve 16TB HDDs in a ZFS array, plus the usual CPU/NVMe/case suspects. The whole thing lives in a [Jonsbo N5](https://www.jonsbo.com/en/products/N5Black.html) — a NAS case with a two-chamber layout. The bottom compartment holds the PSU, a 12-drive hot-swap backplane, and the fans that cool it. The top compartment holds the motherboard, CPU, and GPU. This means the HDD fans and CPU fans are in completely separate airflow zones, which is great for thermals but means the motherboard's fan curves (tuned for CPU temps) have no business controlling the drives below.

The bottom fans originally were those industrial "24/7 no PWM go brrr" fans that sound like a small jet engine. I replaced them with Noctuas. Much quieter. Possibly too quiet.

So I started wondering: are my HDDs cooking in there?

First check:

```bash
for d in /dev/sd?; do
  temp=$(sudo smartctl -A "$d" 2>/dev/null | awk '/Temperature_Celsius|Airflow_Temperature/ {print $10; exit}')
  echo "$d: ${temp:-N/A}°C"
done
```

Output:

```
/dev/sda: 33°C
/dev/sdb: 46°C
/dev/sdc: 47°C
/dev/sdd: 46°C
...
```

33 to 47°C is a wide spread, and 47 under idle-ish load means scrubs could push into uncomfortable territory. The ones in the middle of the drive cage (sdb-sdd, sdg) were clearly getting less airflow than the ones on the edges.

Time to do something about it.

<!-- more -->

## Attempt 1: fancontrol

The obvious tool is `fancontrol` from `lm_sensors`. You run `sensors-detect`, load the suggested kernel module (`nct6775` for my Nuvoton Super I/O chip), run `pwmconfig`, and you get a nice `/etc/fancontrol` config that drives fans based on temperatures.

Except:

```
fan1:                     0 RPM
fan2:                     0 RPM
fan3:                     0 RPM
fan4:                     0 RPM
fan5:                     0 RPM
```

All fans reading zero. But they were clearly spinning — I could hear them, and my CPU wasn't on fire. What?

This is where you discover that **ASRock Rack boards route all fan control through the BMC** (the little management computer on the motherboard), not through the Nuvoton chip that `nct6775` knows how to talk to. The Nuvoton is there. The driver loads fine. The PWM registers exist. They just... aren't wired to anything. Writing to them does nothing.

So `fancontrol` is out. Not because it's broken, but because the abstraction it relies on (hwmon PWM) doesn't exist on this class of hardware. Welcome to server boards.

## Attempt 2: IPMI

"Okay, I'll use IPMI to talk to the BMC." Simple:

```bash
ls /dev/ipmi*
# ls: cannot access '/dev/ipmi*': No such file or directory
```

Great. Load the modules:

```bash
sudo modprobe ipmi_devintf ipmi_si
```

`dmesg`:

```
ipmi_si: Unable to find any System Interface(s)
```

The BMC is sitting *right there*. I can see it in `sensors-detect`'s output. But `ipmi_si` politely scans the standard ACPI/SMBIOS locations, finds nothing, and gives up without so much as an error. On consumer boards the BMC (usually) advertises itself via ACPI DSDT or SMBIOS Type 38. ASRock Rack's firmware just... doesn't bother.

## The IPMI port mystery

`sensors-detect` helpfully reports:

```
Probing for `IPMI BMC KCS' at 0xca0...  Success! (confidence 4, driver `to-be-written')
```

So I tried:

```bash
sudo modprobe ipmi_si type=kcs ports=0xca0
```

`dmesg`:

```
ipmi_si: Trying hardcoded-specified kcs state machine at i/o address 0xca0
ipmi_si hardcode-ipmi-si.0: Interface detection failed
```

Interface detection failed. Cool cool cool. `sensors-detect` claims to see a BMC there, `ipmi_si` says there isn't one. Somebody's lying and I don't have the oscilloscope to find out who.

Out of nowhere (read: the LLM I was pairing with just confidently suggested it), I tried `0xca2` instead:

```bash
sudo modprobe ipmi_si type=kcs ports=0xca2
```

```
ipmi_si: Trying hardcoded-specified kcs state machine at i/o address 0xca2
ipmi_si hardcode-ipmi-si.0: Found new BMC (man_id: 0x00c1d6, prod_id: 0x1012, dev_id: 0x20)
ipmi_si hardcode-ipmi-si.0: IPMI kcs interface initialized
```

It just... worked. No justification, no explanation in any doc I could find, just "the port is two higher than what `sensors-detect` says."

I'll admit my suspicion: KCS interfaces have command and data registers at consecutive even addresses, so `0xca0`/`0xca1` might be one register pair and `0xca2`/`0xca3` another. `sensors-detect` may be detecting the presence of *something* at `0xca0` but the actual command register the BMC listens on is `0xca2`. But I'm speculating; I haven't gone DSDT-diving to confirm.

If you have an X470D4U: use `0xca2`, don't trust `sensors-detect`, and move on with your life.

## Attempt 3: the actual fan commands

Now I need to actually *set* fan speeds. `ipmitool` can do this, but the standard IPMI "set fan speed" commands are basically useless because no vendor implements them — everyone has their own OEM extensions under NetFn 0x3a.

First I found [Cole Deck's post on X470D4U fan control](https://www.deck.sh/asrock-ipmi-fan-control/) describing the command for older ASRock Rack boards:

```bash
ipmitool raw 0x3a 0x01 AA BB CC DD EE FF 0x00 0x00
```

Six bytes, one per fan header, 0x00 = "smart auto mode" and 0x01-0x64 = manual duty percentage. Perfect.

```bash
sudo ipmitool raw 0x3a 0x01 0x00 0x00 0x00 0x00 0x32 0x32 0x00 0x00
# Unable to send RAW command: Invalid command
```

Invalid command. Turns out this board's BMC firmware (v3.02) doesn't speak that old command anymore. It went through a regression cycle: old firmware supported `0x3a 0x01`, BMC 2.x broke it, BMC 3.02 replaced it with a new command family. None of this is documented in one place, of course.

Eventually found a PDF on ASRock's download server titled "TSDQA-72.pdf" — technical support doc for fan control on AST2500/AST2600 BMCs. The actual current commands are:

```
0x3a 0xd6  — set fan duties (16 bytes)
0x3a 0xd7  — read fan modes
0x3a 0xd8  — set fan modes (16 bytes; 0x0 = auto, 0x1 = manual)
0x3a 0xda  — read current fan duties
```

Sixteen bytes, even though my board has six physical fan headers. Why? Because the command is generic across ASRock Rack's entire AST2500 lineup, some of which have more headers. Slots 7-16 are padding. Sure.

`sudo ipmitool raw 0x3a 0xda` returned `1e 1e 1e 1e 1e 1e 1e 1e 00 00 00 00 00 00 00 00` — the first eight slots at 30% duty (the BMC reports 0x1e for these regardless of whether a fan is physically attached), slots 9-16 are padding. This is the BMC's auto curve sitting at minimum. Confirmed the read command works.

## The first real test

Set FAN5 and FAN6 (my HDD cage fans) to manual mode, leave everything else on auto:

```bash
sudo ipmitool raw 0x3a 0xd8 0x0 0x0 0x0 0x0 0x1 0x1 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0
```

Then crank HDD fans to 100%:

```bash
sudo ipmitool raw 0x3a 0xd6 0x00 0x00 0x00 0x00 0x64 0x64 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00
# Unable to send RAW command: Invalid data field in request
```

...what.

Length is right (16 bytes). Values are all within 0x00-0x64. Why is it rejecting this?

Try with `0x04` instead of `0x00` for the auto-mode slots (maybe zero is being interpreted as "stop fan entirely" which the BMC refuses on safety grounds):

```bash
sudo ipmitool raw 0x3a 0xd6 0x04 0x04 0x04 0x04 0x64 0x64 0x04 0x04 0x04 0x04 0x04 0x04 0x04 0x04 0x04 0x04
# Invalid data field in request
```

Still no. Try filling every slot with 0x64:

```bash
sudo ipmitool raw 0x3a 0xd6 0x64 0x64 0x64 0x64 0x64 0x64 0x64 0x64 0x64 0x64 0x64 0x64 0x64 0x64 0x64 0x64
# (no output — success)
```

And `sdr type fan`:

```
FAN1: 500 RPM   (CPU, untouched)
FAN2: 700 RPM   (case, untouched)
FAN5: 1700 RPM  (HDD, was 500)
FAN6: 1800 RPM  (HDD, was 500)
```

It worked! CPU and case fans didn't change even though I sent them 0x64, because those fans are in auto mode and the BMC ignores the duty byte in that case. Only manual-mode slots consume their duty value.

So the rule is: **the BMC rejects low duty bytes (~below 0x14) even in slots whose fans are on auto, but it ignores all duty bytes for auto-mode slots.** You have to fill every slot with a "safe" value like 0x64 to get the command accepted. This is not documented anywhere. I figured it out by flailing.

Also found via someone else's notes later: manual mode and duty settings don't persist across BMC reboots. If the BMC watchdog fires and the little ARM chip resets, fans silently revert to auto and you wouldn't know. So the daemon needs to re-assert manual mode periodically.

## Wrapping it in NixOS

Now I need a daemon that:

1. Reads SMART temps from all HDDs
2. Takes the max
3. Maps to a duty cycle via a configurable curve
4. Sends the appropriate IPMI command
5. Re-asserts manual mode every poll (for BMC-reset resilience)
6. Retries on transient "unexpected ID" errors from `ipmitool`
7. Hands fans back to BMC auto on shutdown

And because this is NixOS, I want all of it declared in config. The setup ended up as two modules:

- [hardware-monitoring.nix](https://github.com/whimbree/nixos-configuration/blob/5357e4a7b7c9f144078d2ca89689c314cf3d83b4/bastion/hardware-monitoring.nix) — loads the IPMI kernel modules, hardcodes the KCS port at 0xca2, installs ipmitool/smartmontools/lm_sensors, and defines convenience commands like hddtemps, fanspeeds, fanduties, and ipmistatus. Reusable for anything that needs to talk to the BMC.

- [hdd-fan-control.nix](https://github.com/whimbree/nixos-configuration/blob/5357e4a7b7c9f144078d2ca89689c314cf3d83b4/bastion/hdd-fan-control.nix) — the actual fan-control daemon. Imports the monitoring module as a foundation.

The fan-control module embeds a Python script via pkgs.writers.writePython3, which runs pyflakes at build time (catching unused imports etc.). About 120 lines of Python plus 70 lines of Nix module wrapper with heavy comments documenting every quirk.

Key settings:

```nix
minTempC = 32;
maxTempC = 50;
minDutyPct = 35;
maxDutyPct = 100;
hddFanSlots = [ 5 6 ];
```

Temperature below 32°C → fans at 35% (the floor). At 50°C or above → fans at 100%. Linear ramp between. Controls only FAN5/FAN6; everything else stays on BMC auto.

## Does it work?

Pre-fan-controller, the hottest drive under idle sat at 47°C with BMC fans pinned at 30%.

After fan controller, the hottest drive under idle sits at 42°C with fans at ~65%.

Under a full ZFS scrub of 25TB across twelve drives (worst-case sustained load), temps peaked at 44°C with fans at ~70%. Never exceeded 45°C. Previously, scrubs on the original fan profile had pushed drives toward 50°C.

Also the system is quiet at idle. The fans can spin down when drives are cool, and ramp up gracefully when they warm. No thermal surprises.

## Things I learned that weren't in any single doc

1. **`lm_sensors` can't help on server boards with BMCs.** Fan headers don't route through the Super I/O chip even when that chip is present and its driver loads.
2. **ASRock Rack's BMC doesn't advertise itself where `ipmi_si` looks** (no ACPI/SMBIOS entries), and the KCS port `sensors-detect` reports is off by two — at least on my board. You have to hardcode the correct port via `modprobe` options.
3. **IPMI fan control is all OEM raw commands.** The standard ones don't work; every vendor has their own under NetFn 0x3a.
4. **This particular BMC firmware (3.02) rejects low duty bytes even in auto-mode slots.** Workaround: fill all slots with a safe value.
5. **Manual mode doesn't persist across BMC resets.** Re-assert periodically.
6. **ASRock's TSDQA-72.pdf** exists and has the command reference. Nearly impossible to find via Google. Easier once you know to search for it by name.

## What about AST2600 boards?
If you have a newer ASRock Rack board with an AST2600 BMC (X570D4U-2L2T, W680D4U, ROMED series, etc.), the command family is different again — same NetFn 0x3a, but subcommands prefixed with `0xd0` and with three mode values instead of two (disabled/auto/manual).

I haven't tested any of this on an AST2600 board, but [Visual-Synthesizer/asrock-rack-fan-control](https://github.com/Visual-Synthesizer/asrock-rack-fan-control) has a README documenting the commands and a Python script that claims to use them.

Can't vouch for the script — haven't run it — but the command reference in the README looks sensible and should at least give you a starting point to poke at your own board.

## See also

- [Austin's Nerdy Things: Controlling AsrockRack fan speeds via ipmitool & PID loops](https://austinsnerdythings.com/2023/07/26/controlling-asrockrack-cpu-chassis-fan-speeds-via-ipmitool-pid-loops/) — a PID-based approach instead of a linear ramp, targeting CPU/motherboard temps on a 1U Datto NAS. Uses the old `0x3a 0x01` command.
- [LokiMetaSmith/ASRock-Rack-IPMI-Fan-Controler](https://github.com/LokiMetaSmith/ASRock-Rack-IPMI-Fan-Controler) — a systemd-based fan controller with ini-file config, also using `0x3a 0x01`.

---

Meanwhile, my twelve drives are sitting at 42°C and the Noctuas are barely audible. If all goes well, I'll never think about fan speeds again.
