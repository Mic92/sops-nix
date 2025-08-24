//go:build linux
// +build linux

package main

import (
	"errors"
	"fmt"
	"os"

	"golang.org/x/sys/unix"
	"github.com/moby/sys/mountinfo"
)

func RuntimeDir() (string, error) {
	rundir, ok := os.LookupEnv("XDG_RUNTIME_DIR")
	if !ok {
		return "", fmt.Errorf("$XDG_RUNTIME_DIR is not set")
	}
	return rundir, nil
}

func MountSecretFs(mountpoint string, keysGID int, useTmpfs bool, userMode bool) error {
	if err := os.MkdirAll(mountpoint, 0o751); err != nil {
		return fmt.Errorf("cannot create directory '%s': %w", mountpoint, err)
	}

	// We can't create a ramfs as user
	if userMode {
		return nil
	}

	var fstype = "ramfs"
	var fsmagic = RamfsMagic
	var fsoptions = "mode=0751"
	if useTmpfs {
		fstype = "tmpfs"
		fsmagic = TmpfsMagic
		fsoptions += ",noswap"
	}

	buf := unix.Statfs_t{}
	if err := unix.Statfs(mountpoint, &buf); err != nil {
		return fmt.Errorf("cannot get statfs for directory '%s': %w", mountpoint, err)
	}
	mounted, err := mountinfo.Mounted(mountpoint)
	if err != nil {
		return fmt.Errorf("cannot check if directory '%s' is a mountpoint: %w", mountpoint, err)
	}
	if !mounted || int32(buf.Type) != fsmagic {
		flags := uintptr(unix.MS_NODEV | unix.MS_NOSUID | unix.MS_NOEXEC)
		if err := unix.Mount("none", mountpoint, fstype, flags, fsoptions); err != nil {
			if useTmpfs && errors.Is(err, unix.EINVAL) {
				if err := unix.Mount("none", mountpoint, fstype, flags, "mode=0751"); err != nil {
					return fmt.Errorf("cannot mount (fallback without noswap failed): %w", err)
				}
			} else {
				return fmt.Errorf("cannot mount: %w", err)
			}
		}
	}

	if err := os.Chown(mountpoint, 0, int(keysGID)); err != nil {
		return fmt.Errorf("cannot change owner/group of '%s' to 0/%d: %w", mountpoint, keysGID, err)
	}

	return nil
}
