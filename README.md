# SquashFS Archive Helpers for macOS

This project packages large source trees into read-only SquashFS images and mounts them back on demand with a temporary writable layer.

It is intended for the workflow where you:

- archive an existing source directory
- optionally delete or move the original directory yourself
- keep the image as long-term storage
- mount it only when you need to inspect files or run a build
- discard all temporary build output on unmount

## What It Does

The scripts in this repository implement:

- SquashFS image creation on macOS with `mksquashfs`
- writable-on-demand mounts using `anylinuxfs`
- an ephemeral Linux `overlayfs` layer on top of the read-only image
- clean unmounting through `anylinuxfs`

The writable layer is temporary. New files and build artifacts disappear after unmount.

## Requirements

- macOS on Apple Silicon
- [Homebrew](https://brew.sh/)
- [`anylinuxfs`](https://github.com/nohajc/anylinuxfs)
- Homebrew `squashfs` package, which provides `mksquashfs`

`anylinuxfs` is required only for mounting. Image creation itself runs directly on macOS and does not require entering an `anylinuxfs shell`.

## Install

Install the required tools:

```bash
brew tap nohajc/anylinuxfs
brew install anylinuxfs squashfs
```

You can verify the commands are available:

```bash
anylinuxfs --version
mksquashfs -version
```

## Project Layout

- [scripts/create-squashfs-image.sh](/Volumes/sources/SquashFStest/scripts/create-squashfs-image.sh) creates a `.sqfs` image from a source directory
- [scripts/mount-squashfs-rw.sh](/Volumes/sources/SquashFStest/scripts/mount-squashfs-rw.sh) mounts a SquashFS image in read-only mode, ephemeral writable mode, or reusable overlay mode
- [scripts/unmount-anylinuxfs.sh](/Volumes/sources/SquashFStest/scripts/unmount-anylinuxfs.sh) unmounts the mount point and removes the empty directory if possible
- [scripts/reset-reuse-state.sh](/Volumes/sources/SquashFStest/scripts/reset-reuse-state.sh) deletes the persisted state for a `reuse` mount point
- [scripts/verify-mounted-image.sh](/Volumes/sources/SquashFStest/scripts/verify-mounted-image.sh) compares an original source tree against a mounted image view
- [scripts/list-reuse-state.sh](/Volumes/sources/SquashFStest/scripts/list-reuse-state.sh) lists local `reuse` sidecar metadata and state keys

## Usage

### 1. Create an archive image

```bash
./scripts/create-squashfs-image.sh \
  /path/to/source-dir \
  /path/to/archive.sqfs
```

Notes:

- the source directory is not modified
- the destination parent directory is created automatically
- existing destination files are rejected by default
- use `FORCE=1` if you want to overwrite an existing image

Example:

```bash
FORCE=1 ./scripts/create-squashfs-image.sh \
  ~/src/huge-project \
  /Volumes/archive/huge-project.sqfs
```

### 2. Mount the image

Read-only mode:

```bash
./scripts/mount-squashfs-rw.sh \
  --mode ro \
  /path/to/archive.sqfs \
  /tmp/archive-ro
```

This is just a direct `anylinuxfs mount` of the SquashFS image. No writable overlay is added.

Temporary writable mode:

```bash
./scripts/mount-squashfs-rw.sh \
  --mode rw \
  /path/to/archive.sqfs \
  /tmp/archive-rw
```

After that, work in `/tmp/archive-rw` as if it were a writable directory tree.

Reusable overlay mode:

```bash
./scripts/mount-squashfs-rw.sh \
  --mode reuse \
  /path/to/archive.sqfs \
  /tmp/archive-work
```

This is still a true mount. The difference is that the overlay `upper/work` state is preserved instead of discarded.

The script stores small metadata in a sidecar directory next to the mount point such as `/tmp/archive-work.sqfs-reuse`, and stores the actual reusable overlay state in the persistent `anylinuxfs` VM root filesystem.

If you keep using the same image and mount point, the next `--mode reuse` call will remount the same overlay state exactly as it was left before. If nothing was changed, the persistent overlay stays nearly empty.

Example:

```bash
./scripts/mount-squashfs-rw.sh \
  --mode reuse \
  /Volumes/archive/huge-project.sqfs \
  /tmp/huge-project-work
cd /tmp/huge-project-work
```

### 3. Unmount and discard temporary changes

```bash
./scripts/unmount-anylinuxfs.sh /tmp/archive-rw
```

This unmounts the current view and leaves the original `.sqfs` image unchanged.

For `--mode reuse`, unmount is still required. The difference is that its overlay state is kept for next time instead of being discarded.

To delete the saved `reuse` state and start fresh later:

```bash
./scripts/reset-reuse-state.sh /tmp/archive-work
```

To list known `reuse` state directories:

```bash
./scripts/list-reuse-state.sh
./scripts/list-reuse-state.sh /tmp /Volumes/work
```

### 4. Verify a mounted image against the original source tree

Quick verification by size+mtime:

```bash
./scripts/verify-mounted-image.sh \
  /path/to/source-dir \
  /tmp/archive-ro
```

Full content verification by checksum:

```bash
./scripts/verify-mounted-image.sh \
  --mode checksum \
  /path/to/source-dir \
  /tmp/archive-ro
```

The script intentionally ignores macOS owners, groups, permissions, ACLs, and xattrs, because the SquashFS image created by this project does not preserve macOS xattrs.

By default it uses the lighter `quick` mode and prints scan/comparison stages so long-running checks do not look stuck.

## How It Works

`create-squashfs-image.sh` runs `mksquashfs` directly on macOS and produces a compressed read-only filesystem image.

In `--mode ro`, the script runs a direct `anylinuxfs mount` on the `.sqfs` image.

In `--mode rw`, `mount-squashfs-rw.sh` then:

- ensures a custom `anylinuxfs` action exists in `~/.anylinuxfs/config.toml`
- mounts the `.sqfs` image inside the `anylinuxfs` Linux microVM
- creates an `overlayfs` mount with the SquashFS image as `lowerdir`
- exports the merged view back to macOS over NFS

The writable view is temporary by design. The upper layer lives only inside the running VM.

In `--mode reuse`, the script:

- mounts the `.sqfs` image through `anylinuxfs`
- reuses a persistent overlay `upper/work` pair keyed to the image and mount point
- stores small metadata in a sidecar directory next to the mount point
- restores the mounted view exactly as it was left at the last unmount

## Why `anylinuxfs shell` Is Not Needed for Image Creation

You only need `anylinuxfs` for mounting Linux filesystems on macOS.

For image creation, Homebrew `squashfs` already provides native macOS binaries:

- `mksquashfs`
- `unsquashfs`

That means the recommended workflow is:

1. create the `.sqfs` image directly on macOS
2. mount it later with `anylinuxfs` when needed

## Limitations

- mounting depends on `anylinuxfs`, which currently targets Apple Silicon macOS
- with current `anylinuxfs` releases, only one mount can be active at a time; the upstream project notes this may improve in the future
- `rw` mode is intentionally non-persistent
- `reuse` mode is persistent, but its state depends on the `anylinuxfs` VM rootfs and the reuse sidecar metadata remaining intact
- the first `rw` or `reuse` mount updates `~/.anylinuxfs/config.toml`
- mount and unmount behavior ultimately depends on `anylinuxfs` and macOS NFS behavior

This has an important consequence for archive design: it is fine to store many separate `.sqfs` images, but in normal use you should expect to mount only one of them at a time.

## Safety Notes

- treat the SquashFS image as the archive of record
- verify your build works from the mounted view before deleting the original directory
- if you want persistent changes, rebuild the image from a normal directory rather than editing the mounted overlay

## Tested Workflow

This repository has been tested end-to-end with:

- image creation through Homebrew `mksquashfs`
- mounting the generated `.sqfs` through `anylinuxfs`
- writing files into the mounted tree
- preserving files across `reuse` unmount and remount
- unmounting and discarding temporary changes
