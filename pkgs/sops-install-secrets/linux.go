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
  	return "", fmt.Errorf("$XDG_RUNTIME_DIR is not set!")
  }
  return rundir, nil
}

func SecureSymlinkChown(symlinkToCheck, expectedTarget string, owner, group int) error {
	// fd, err := unix.Open(symlinkToCheck, unix.O_CLOEXEC|unix.O_PATH|unix.O_NOFOLLOW, 0)
	fd, err := unix.Open(symlinkToCheck, unix.O_CLOEXEC|unix.O_PATH|unix.O_NOFOLLOW, 0)
	if err != nil {
		return fmt.Errorf("Failed to open %s: %w", symlinkToCheck, err)
	}
	defer unix.Close(fd)

	buf := make([]byte, len(expectedTarget)+1) // oversize by one to detect trunc
	n, err := unix.Readlinkat(fd, "", buf)
	if err != nil {
		return fmt.Errorf("couldn't readlinkat %s", symlinkToCheck)
	}
	if n > len(expectedTarget) || string(buf[:n]) != expectedTarget {
		return fmt.Errorf("symlink %s does not point to %s", symlinkToCheck, expectedTarget)
	}
	err = unix.Fchownat(fd, "", owner, group, unix.AT_EMPTY_PATH)
	if err != nil {
		return fmt.Errorf("cannot change owner of '%s' to %d/%d: %w", symlinkToCheck, owner, group, err)
	}
	return nil
}

func MountSecretFs(mountpoint string, keysGid int, useTmpfs bool, userMode bool) error {
	if err := os.MkdirAll(mountpoint, 0751); err != nil {
		return fmt.Errorf("Cannot create directory '%s': %w", mountpoint, err)
	}

  // We can't create a ramfs as user
	if userMode {
		return nil
	}

	var fstype string = "ramfs"
	var fsmagic int32 = RAMFS_MAGIC
	if useTmpfs {
		fstype = "tmpfs"
		fsmagic = TMPFS_MAGIC
	}

	buf := unix.Statfs_t{}
	if err := unix.Statfs(mountpoint, &buf); err != nil {
		return fmt.Errorf("Cannot get statfs for directory '%s': %w", mountpoint, err)
	}
	if int32(buf.Type) != fsmagic {
		if err := unix.Mount("none", mountpoint, fstype, unix.MS_NODEV|unix.MS_NOSUID, "mode=0751"); err != nil {
			return fmt.Errorf("Cannot mount: %s", err)
		}
	}

	if err := os.Chown(mountpoint, 0, int(keysGid)); err != nil {
		return fmt.Errorf("Cannot change owner/group of '%s' to 0/%d: %w", mountpoint, keysGid, err)
	}

	return nil
}
