//go:build linux
// +build linux

package main

import (
	"fmt"
	"os"

	"golang.org/x/sys/unix"
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
	if useTmpfs {
		fstype = "tmpfs"
		fsmagic = TmpfsMagic
	}

	buf := unix.Statfs_t{}
	if err := unix.Statfs(mountpoint, &buf); err != nil {
		return fmt.Errorf("cannot get statfs for directory '%s': %w", mountpoint, err)
	}
	if int32(buf.Type) != fsmagic {
		if err := unix.Mount("none", mountpoint, fstype, unix.MS_NODEV|unix.MS_NOSUID, "mode=0751"); err != nil {
			return fmt.Errorf("cannot mount: %w", err)
		}
	}

	if err := os.Chown(mountpoint, 0, int(keysGID)); err != nil {
		return fmt.Errorf("cannot change owner/group of '%s' to 0/%d: %w", mountpoint, keysGID, err)
	}

	return nil
}
