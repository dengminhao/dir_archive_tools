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
- [scripts/mount-squashfs-rw.sh](/Volumes/sources/SquashFStest/scripts/mount-squashfs-rw.sh) mounts a SquashFS image in either read-only mode or ephemeral writable mode
- [scripts/unmount-anylinuxfs.sh](/Volumes/sources/SquashFStest/scripts/unmount-anylinuxfs.sh) unmounts the mount point and removes the empty directory if possible

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

Example:

```bash
./scripts/mount-squashfs-rw.sh \
  --mode rw \
  /Volumes/archive/huge-project.sqfs \
  /tmp/huge-project-rw
cd /tmp/huge-project-rw
```

### 3. Unmount and discard temporary changes

```bash
./scripts/unmount-anylinuxfs.sh /tmp/archive-rw
```

This removes the writable overlay state from the Linux VM and leaves the original `.sqfs` image unchanged.

## How It Works

`create-squashfs-image.sh` runs `mksquashfs` directly on macOS and produces a compressed read-only filesystem image.

In `--mode ro`, the script runs a direct `anylinuxfs mount` on the `.sqfs` image.

In `--mode rw`, `mount-squashfs-rw.sh` then:

- ensures a custom `anylinuxfs` action exists in `~/.anylinuxfs/config.toml`
- mounts the `.sqfs` image inside the `anylinuxfs` Linux microVM
- creates an `overlayfs` mount with the SquashFS image as `lowerdir`
- exports the merged view back to macOS over NFS

The writable view is temporary by design. The upper layer lives only inside the running VM.

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
- the writable layer is intentionally non-persistent
- the first writable mount updates `~/.anylinuxfs/config.toml`
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
- unmounting and discarding temporary changes
