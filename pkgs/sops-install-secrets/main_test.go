package main

import (
	"encoding/json"
	"fmt"
	"io/ioutil"
	"os"
	"os/exec"
	"os/user"
	"path"
	"path/filepath"
	"reflect"
	"runtime"
	"strconv"
	"syscall"
	"testing"
)

// ok fails the test if an err is not nil.
func ok(tb testing.TB, err error) {
	if err != nil {
		_, file, line, _ := runtime.Caller(1)
		fmt.Printf("\033[31m%s:%d: unexpected error: %s\033[39m\n\n", filepath.Base(file), line, err.Error())
		tb.FailNow()
	}
}

func equals(tb testing.TB, exp, act interface{}) {
	if !reflect.DeepEqual(exp, act) {
		_, file, line, _ := runtime.Caller(1)
		fmt.Printf("\033[31m%s:%d:\n\n\texp: %#v\n\n\tgot: %#v\033[39m\n\n", filepath.Base(file), line, exp, act)
		tb.FailNow()
	}
}

func writeManifest(t *testing.T, dir string, m *manifest) string {
	filename := path.Join(dir, "manifest.json")
	f, err := os.OpenFile(filename, os.O_RDWR|os.O_CREATE, 0755)
	ok(t, err)
	encoder := json.NewEncoder(f)
	ok(t, encoder.Encode(m))
	f.Close()
	return filename
}

func TestCliArgs(t *testing.T) {
	_, filename, _, _ := runtime.Caller(0)
	var testSecrets = path.Join(path.Dir(filename), "test-secrets")

	tempdir, err := ioutil.TempDir("", "symlinkDir")
	ok(t, err)
	defer os.RemoveAll(tempdir)
	secretsPath := path.Join(tempdir, "secrets.d")
	symlinkPath := path.Join(tempdir, "secrets")
	gpgHome := path.Join(tempdir, "gpg-home")

	ok(t, os.Mkdir(gpgHome, os.FileMode(0700)))
	os.Setenv("GNUPGHOME", gpgHome)
	cmd := exec.Command("gpg", "--import", path.Join(testSecrets, "key.asc"))
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	ok(t, cmd.Run())
	stopGpgCmd := exec.Command("gpgconf", "--kill", "gpg-agent")
	defer func() {
		if err := stopGpgCmd.Run(); err != nil {
			fmt.Printf("failed to stop gpg-agent: %s\n", err)
		}
	}()

	// should create a symlink
	yamlSecret := secret{
		Name:            "test",
		Key:             "test_key",
		Owner:           "nobody",
		Group:           "nogroup",
		SourceFile:      path.Join(testSecrets, "secrets.yaml"),
		Path:            path.Join(tempdir, "test-target"),
		Mode:            "0400",
		RestartServices: []string{"affected-service"},
		ReloadServices:  make([]string, 0),
	}

	var jsonSecret secret
	// should not create a symlink
	jsonSecret = yamlSecret
	jsonSecret.Name = "test2"
	jsonSecret.Owner = "root"
	jsonSecret.Format = "json"
	jsonSecret.Group = "root"
	jsonSecret.SourceFile = path.Join(testSecrets, "secrets.json")
	jsonSecret.Path = path.Join(symlinkPath, "test2")
	jsonSecret.Mode = "0700"

	var binarySecret secret
	binarySecret = yamlSecret
	binarySecret.Name = "test3"
	binarySecret.Format = "binary"
	binarySecret.SourceFile = path.Join(testSecrets, "secrets.bin")
	binarySecret.Path = path.Join(symlinkPath, "test3")

	manifest := manifest{
		Secrets:           []secret{yamlSecret, jsonSecret, binarySecret},
		SecretsMountPoint: secretsPath,
		SymlinkPath:       symlinkPath,
	}

	manifestPath := writeManifest(t, tempdir, &manifest)

	err = installSecrets([]string{"sops-install-secrets", manifestPath})
	ok(t, err)

	_, err = os.Stat(manifest.SecretsMountPoint)
	ok(t, err)

	_, err = os.Stat(manifest.SymlinkPath)
	ok(t, err)

	yamlLinkStat, err := os.Lstat(yamlSecret.Path)
	ok(t, err)

	equals(t, os.ModeSymlink, yamlLinkStat.Mode()&os.ModeSymlink)

	yamlStat, err := os.Stat(yamlSecret.Path)
	ok(t, err)

	equals(t, true, yamlStat.Mode().IsRegular())
	equals(t, 0400, int(yamlStat.Mode().Perm()))
	stat, success := yamlStat.Sys().(*syscall.Stat_t)
	equals(t, true, success)
	content, err := ioutil.ReadFile(yamlSecret.Path)
	ok(t, err)
	equals(t, "test_value", string(content))

	u, err := user.LookupId(strconv.Itoa(int(stat.Uid)))
	ok(t, err)
	equals(t, "nobody", u.Username)

	g, err := user.LookupGroupId(strconv.Itoa(int(stat.Gid)))
	ok(t, err)
	equals(t, "nogroup", g.Name)

	jsonStat, err := os.Stat(jsonSecret.Path)
	ok(t, err)
	equals(t, true, jsonStat.Mode().IsRegular())
	equals(t, 0700, int(jsonStat.Mode().Perm()))
	if stat, ok := jsonStat.Sys().(*syscall.Stat_t); ok {
		equals(t, 0, int(stat.Uid))
		equals(t, 0, int(stat.Gid))
	}

	content, err = ioutil.ReadFile(binarySecret.Path)
	ok(t, err)
	equals(t, "binary_value\n", string(content))

	manifestPath = writeManifest(t, symlinkPath, &manifest)

	err = installSecrets([]string{"sops-install-secrets", manifestPath})
	ok(t, err)

	target, err := os.Readlink(symlinkPath)
	equals(t, path.Join(secretsPath, "2"), target)
}
