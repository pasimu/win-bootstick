# Windows 10/11 Bootstick Creation Tool

> **Document number:** BASH-2025-019<br>
> **Author:** pasimu (Patrick Siegmund) - <patricksiegmund@gmx.de><br>
> **Date:** 2025-09-25<br>

## Abstract

This tool automates the creation of a Windows 10/11 UEFI bootable USB stick using GPT partitioning and a dual-filesystem layout (**FAT32** + **NTFS**). It supports unattended installations via `autounattend.xml` templates and is designed for reproducible, non-interactive use in IT environments.

## Content

- [Features](#features)
- [Requirements](#requirements)
- [Usage](#usage)
- [Examples](#examples)
- [Structure](#structure)
- [References](#references)

## Features

- Creates a GPT-partitioned USB stick with **FAT32** (for boot files) and **NTFS** (for install payload).
- Copies Windows ISO contents efficiently using `rsync`.
- Supports unattended setup through XML templates with token substitution.
- Bypasses Windows 11 hardware checks (configurable).
- Automated user account creation, locale settings, and OOBE skipping.
- Works in *main* mode (device creation) and *xml-only* mode (generate `autounattend.xml`).
- Safe by design: refuses to operate on system disks and enforces minimum size checks.

## Requirements

Host system must provide the following tools:

```
mktemp, lsblk, sgdisk, wipefs, parted, blockdev, partprobe,
udevadm, mkfs.fat, mkfs.ntfs, mount, rsync, sed, realpath,
flock, id, sync, mkdir, findmnt, stat, sleep
```

## Usage

```bash
sudo -E ./create-bootstick.sh --device=/dev/sdX --iso=/path/to/win.iso [OPTIONS]
```

Common options:

- `--non-interactive` suppresses prompts
- `--dry-run` prints actions without modifying devices
- `--autounattend-out=` generates XML only (no device writes)
- `--bypass-hw-reqs` toggles Windows 11 hardware requirement bypass

## Examples

**1. Create a bootable stick with unattended install**

```bash
sudo -E ./create-bootstick.sh --device=/dev/sdb --iso=~/Downloads/isos/Win11_24H2_German_x64.iso --oobe-skip=false --bypass-hw-reqs=false --win-lang=de-DE --non-interactive
```

**2. Advanced autounattend.xml installation (using environment file in script dir)**

```bash
( set -a; . "./default.env"; set +a; sudo -E ./create-bootstick.sh --device=/dev/sdb )
```

**3. Generate only autounattend.xml from a template**

```bash
./create-bootstick.sh --template=./templates/xml/win11-autounattend.xml --autounattend-out=./autounattend.xml --non-interactive
```

**4. Batch rendering with company.env, user list and product keys**

This example generates multiple `autounattend.xml` files using a shared environment file and a tab-separated user list.

```bash
./examples/render-users.sh
```

## Structure

- **create-bootstick.sh** - main script
- **templates/xml** - `autounattend.xml` templates
- **examples/** - example for in script usage

## References

- [Microsoft: Windows Setup Automation Overview](https://docs.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-automation-overview)
- [UEFI Specification](https://uefi.org/specifications)
- [Linux man-pages](https://man7.org/linux/man-pages/)
