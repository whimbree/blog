+++
title = "Patching ACPI DSDT to enable S3 sleep on the Eluktronics MECH-15 G3"
date = 2021-06-12

[taxonomies]
tags = ["linux", "acpi", "sleep", "laptop", "cursed"]
+++

The Eluktronics MECH-15 G3 (Ryzen 9 5900HX / RTX 3070) ships with Windows-oriented S0ix "modern standby" as the only sleep mode in its ACPI tables. This is a problem on Linux, because modern standby is not really sleep — it's more like your laptop pretending to be asleep while it slowly drains your battery in its bag. I closed the lid, threw it in my well-insulated laptop bag, and pulled out a scorching hot potato with 40% less battery an hour later. Not ideal.

A quick primer on the sleep states, from worst to best:

**S0ix/s2idle** ("modern standby") — system stays in S0 but enters low-power idle substates where the SoC powers down components while keeping RAM alive. *In theory* this gives fast wake and background network activity. In practice, on Linux, it often falls back to plain s2idle (freeze userspace, idle CPU, pray) and drains like the laptop is awake.

**S3** ("suspend-to-RAM") — everything powers off except RAM. The classic. 3-5% battery drain overnight. **This is what we want.**

**S4** ("hibernate") — state saved to disk, full power off. Survives pulling the battery. Zero drain.

The 5900HX supports S3 just fine, but the stock DSDT (the ACPI table that tells the OS what the hardware can do) simply doesn't advertise it. The firmware vendor only bothered to declare S0ix because that's all Windows uses on modern laptops. Linux looks at the DSDT, sees no S3, and gives you `s2idle`. Thanks.

The fix: lie to the kernel. Patch the DSDT to add the S3 declaration that should have been there all along. [Rasmus Moorats documented the same technique for the RedmiBook 16](https://blog.nns.ee/2020/10/19/acpi-patching) — his writeup covers the full background and an alternative loading method via cpio/initrd for non-GRUB bootloaders like systemd-boot.

The steps below are for GRUB2, which is what I was using at the time.

<!-- more -->

If you see this then your system currently does not support S3 sleep.

```bash
❯ cat /sys/power/mem_sleep                        
[s2idle]
```

First, dump your current DSDT table.

```bash
sudo cat /sys/firmware/acpi/tables/DSDT > dsdt.aml
```

Use `iasl` from <https://www.acpica.org/downloads/> to decompile the dumped DSDT (your distro should have a package that provides this tool).

```bash
iasl -d dsdt.aml
```

Look through the `dsdt.dsl` file to find where the S4 and S5 states are declared.

I added the S3 system state declaration in the middle of these two existing blocks.

```asl
    Name (XS3, Package (0x04)
    {
        0x03, 
        Zero, 
        Zero, 
        Zero
    })
    Name (_S3, Package (0x04)  // _S3_: S3 System State
    {
        0x03, 
        0x03, 
        Zero, 
        Zero
    })
    Name (_S4, Package (0x04)  // _S4_: S4 System State
    {
        0x04, 
        Zero, 
        Zero, 
        Zero
    })
```

Recompile it once you make your changes.

```bash
iasl dsdt.dsl
```

I'm assuming you use GRUB2 as your bootloader. If not, [Rasmus's post](https://blog.nns.ee/2020/10/19/acpi-patching) covers how to load a patched DSDT via a cpio archive in the initrd, which works with systemd-boot and other bootloaders.

---

Copy the contents of this file to `/etc/grub.d/01_acpi`

```bash
#! /bin/sh -e

# Uncomment to load custom ACPI table
GRUB_CUSTOM_ACPI="/boot/dsdt.aml"

# DON'T MODIFY ANYTHING BELOW THIS LINE!

prefix=/usr
exec_prefix=${prefix}
datadir=${exec_prefix}/share

. ${datadir}/grub/grub-mkconfig_lib

# Load custom ACPI table
if [ x${GRUB_CUSTOM_ACPI} != x ] && [ -f ${GRUB_CUSTOM_ACPI} ] \
        && is_path_readable_by_grub ${GRUB_CUSTOM_ACPI}; then
    echo "Found custom ACPI table: ${GRUB_CUSTOM_ACPI}" >&2
    prepare_grub_to_access_device `${grub_probe} --target=device ${GRUB_CUSTOM_ACPI}` | sed -e "s/^/ /"
    cat << EOF
acpi (\$root)`make_system_path_relative_to_its_root ${GRUB_CUSTOM_ACPI}`
EOF
fi
```

Copy your patched DSDT to `/boot/dsdt.aml`.

Edit `/boot/grub/grub.cfg` and add this kernel parameter `mem_sleep_default=deep`

Run `sudo grub-mkconfig -o /boot/grub/grub.cfg` or what the grub configuration command is for your distro

Reboot, S3 sleep should now be enabled.

```bash
❯ cat /sys/power/mem_sleep
s2idle [deep]
```

---

*Originally posted on [r/eluktronics](https://old.reddit.com/r/eluktronics/comments/nybdpa/mech15_g3_ryzen_5th_gen_fixing_s3_sleep_on_linux/).*
