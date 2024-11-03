//go:build darwin
// +build darwin

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"golang.org/x/sys/unix"
)

func RuntimeDir() (string, error) {
	// TODO this could be garbage collected on a 3d basis
	out, err := exec.Command("getconf", "DARWIN_USER_TEMP_DIR").Output()
	rundir := strings.TrimRight(string(out[:]), " \t\n")
	if err != nil {
		return "", fmt.Errorf("cannot get DARWIN_USER_TEMP_DIR: %v", err)
	}
	return strings.TrimSuffix(rundir, "/"), nil
}

func SecureSymlinkChown(symlinkToCheck string, expectedTarget string, owner, group int) error {
	// not sure what O_PATH is needed for anyways
	fd, err := unix.Open(symlinkToCheck, unix.O_CLOEXEC|unix.O_SYMLINK|unix.O_NOFOLLOW, 0)
	if err != nil {
		return fmt.Errorf("failed to open %s: %w", symlinkToCheck, err)
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
	err = unix.Fchownat(fd, "", owner, group, unix.AT_SYMLINK_NOFOLLOW)
	if err != nil {
		return fmt.Errorf("cannot change owner of '%s' to %d/%d: %w", symlinkToCheck, owner, group, err)
	}
	return nil
}

// Does:
// mkdir /tmp/mymount
// NUMSECTORS=128000       # a sector is 512 bytes
// mydev=`hdiutil attach -nomount ram://$NUMSECTORS`
// newfs_hfs $mydev
// mount -t hfs $mydev /tmp/mymount
func MountSecretFs(mountpoint string, keysGID int, _useTmpfs bool, userMode bool) error {
	if err := os.MkdirAll(mountpoint, 0o751); err != nil {
		return fmt.Errorf("cannot create directory '%s': %w", mountpoint, err)
	}
	if _, err := os.Stat(mountpoint + "/sops-nix-secretfs"); !errors.Is(err, os.ErrNotExist) {
		return nil // secret fs already exists
	}

	// MacOS/darwin options for temporary files:
	// - /tmp or NSTemporaryDirectory is persistent, and regularly wiped from files not touched >3d
	//   https://wiki.lazarus.freepascal.org/Locating_the_macOS_tmp_directory
	// - there is no ramfs, also `man statfs` doesn't have flags for memfs things
	// - we can allocate and mount statically allocated memory (ram://), however most
	//   functions for that are not publicly exposed to userspace.
	mb := 64                       // size in MB
	size := mb * 1024 * 1024 / 512 // size in sectors a 512 bytes
	cmd := exec.Command("hdiutil", "attach", "-nomount", fmt.Sprintf("ram://%d", int(size)))
	out, err := cmd.Output() // /dev/diskN
	diskpath := strings.TrimRight(string(out[:]), " \t\n")

	// format as hfs
	out, err = exec.Command("newfs_hfs", "-s", diskpath).Output()

	// "posix" mount takes `struct hfs_mount_args` which we dont have bindings for at hand.
	// See https://stackoverflow.com/a/49048846/4108673
	// err = unix.Mount("hfs", mountpoint, unix.MNT_NOEXEC|unix.MNT_NODEV, mount_args)
	// Instead we call:
	out, err = exec.Command("mount", "-t", "hfs", "-o", "nobrowse,nodev,nosuid,-m=0751", diskpath, mountpoint).Output()

	// There is no documented way to check for memfs mountpoint. Thus we place a file.
	path := mountpoint + "/sops-nix-secretfs"
	_, err = os.Create(path)
	if err != nil {
		return fmt.Errorf("cannot create file '%s': %w", path, err)
	}

	// This would be the way to check on unix.
	//buf := unix.Statfs_t{}
	//if err := unix.Statfs(mountpoint, &buf); err != nil {
	//	return fmt.Errorf("Cannot get statfs for directory '%s': %w", mountpoint, err)
	//}
	//
	//if int32(buf.Type) != RAMFS_MAGIC {
	//	if err := unix.Mount("none", mountpoint, "ramfs", unix.MS_NODEV|unix.MS_NOSUID, "mode=0751"); err != nil {
	//		return fmt.Errorf("Cannot mount: %s", err)
	//	}
	//}

	if !userMode {
		if err := os.Chown(mountpoint, 0, int(keysGID)); err != nil {
			return fmt.Errorf("cannot change owner/group of '%s' to 0/%d: %w", mountpoint, keysGID, err)
		}
	}

	return nil
}
