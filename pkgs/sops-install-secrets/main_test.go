//go:build linux || darwin
// +build linux darwin

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

func testAssetPath() string {
	assets := os.Getenv("TEST_ASSETS")
	if assets != "" {
		return assets
	}
	_, filename, _, _ := runtime.Caller(0)
	return path.Join(path.Dir(filename), "test-assets")
}

type testDir struct {
	path, secretsPath, symlinkPath string
}

func (dir testDir) Remove() {
	os.RemoveAll(dir.path)
}

func newTestDir(t *testing.T) testDir {
	tempdir, err := ioutil.TempDir("", "symlinkDir")
	ok(t, err)
	return testDir{tempdir, path.Join(tempdir, "secrets.d"), path.Join(tempdir, "secrets")}
}

func testInstallSecret(t *testing.T, testdir testDir, m *manifest) {
	path := writeManifest(t, testdir.path, m)
	ok(t, installSecrets([]string{"sops-install-secrets", path}))
}

func testGPG(t *testing.T) {
	assets := testAssetPath()

	testdir := newTestDir(t)
	defer testdir.Remove()
	gpgHome := path.Join(testdir.path, "gpg-home")
	gpgEnv := append(os.Environ(), fmt.Sprintf("GNUPGHOME=%s", gpgHome))

	ok(t, os.Mkdir(gpgHome, os.FileMode(0700)))
	cmd := exec.Command("gpg", "--import", path.Join(assets, "key.asc"))
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = gpgEnv
	ok(t, cmd.Run())
	stopGpgCmd := exec.Command("gpgconf", "--kill", "gpg-agent")
	stopGpgCmd.Stdout = os.Stdout
	stopGpgCmd.Stderr = os.Stderr
	stopGpgCmd.Env = gpgEnv
	defer func() {
		if err := stopGpgCmd.Run(); err != nil {
			fmt.Printf("failed to stop gpg-agent: %s\n", err)
		}
	}()

	// should create a symlink
	yamlSecret := secret{
		Name:         "test",
		Key:          "test_key",
		Owner:        "nobody",
		Group:        "nogroup",
		SopsFile:     path.Join(assets, "secrets.yaml"),
		Path:         path.Join(testdir.path, "test-target"),
		Mode:         "0400",
		RestartUnits: []string{"affected-service"},
		ReloadUnits:  []string{"affected-reload-service"},
	}

	var jsonSecret, binarySecret secret
	// should not create a symlink
	jsonSecret = yamlSecret
	jsonSecret.Name = "test2"
	jsonSecret.Owner = "root"
	jsonSecret.Format = "json"
	jsonSecret.Group = "root"
	jsonSecret.SopsFile = path.Join(assets, "secrets.json")
	jsonSecret.Path = path.Join(testdir.secretsPath, "test2")
	jsonSecret.Mode = "0700"

	binarySecret = yamlSecret
	binarySecret.Name = "test3"
	binarySecret.Format = "binary"
	binarySecret.SopsFile = path.Join(assets, "secrets.bin")
	binarySecret.Path = path.Join(testdir.secretsPath, "test3")

	manifest := manifest{
		Secrets:           []secret{yamlSecret, jsonSecret, binarySecret},
		SecretsMountPoint: testdir.secretsPath,
		SymlinkPath:       testdir.symlinkPath,
		GnupgHome:         gpgHome,
	}

	testInstallSecret(t, testdir, &manifest)

	_, err := os.Stat(manifest.SecretsMountPoint)
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
	equals(t, 13, len(content))

	testInstallSecret(t, testdir, &manifest)

	target, err := os.Readlink(testdir.symlinkPath)
	ok(t, err)
	equals(t, path.Join(testdir.secretsPath, "2"), target)
}

func testSSHKey(t *testing.T) {
	assets := testAssetPath()

	testdir := newTestDir(t)
	defer testdir.Remove()

	target := path.Join(testdir.path, "existing-target")
	file, err := os.Create(target)
	ok(t, err)
	file.Close()

	s := secret{
		Name:         "test",
		Key:          "test_key",
		Owner:        "nobody",
		Group:        "nogroup",
		SopsFile:     path.Join(assets, "secrets.yaml"),
		Path:         target,
		Mode:         "0400",
		RestartUnits: []string{"affected-service"},
		ReloadUnits:  []string{"affected-reload-service"},
	}

	m := manifest{
		Secrets:           []secret{s},
		SecretsMountPoint: testdir.secretsPath,
		SymlinkPath:       testdir.symlinkPath,
		SSHKeyPaths:       []string{path.Join(assets, "ssh-key")},
	}

	testInstallSecret(t, testdir, &m)
}

func TestAge(t *testing.T) {
	assets := testAssetPath()

	testdir := newTestDir(t)
	defer testdir.Remove()

	target := path.Join(testdir.path, "existing-target")
	file, err := os.Create(target)
	ok(t, err)
	file.Close()

	s := secret{
		Name:         "test",
		Key:          "test_key",
		Owner:        "nobody",
		Group:        "nogroup",
		SopsFile:     path.Join(assets, "secrets.yaml"),
		Path:         target,
		Mode:         "0400",
		RestartUnits: []string{"affected-service"},
		ReloadUnits:  []string{"affected-reload-service"},
	}

	m := manifest{
		Secrets:           []secret{s},
		SecretsMountPoint: testdir.secretsPath,
		SymlinkPath:       testdir.symlinkPath,
		AgeKeyFile:        path.Join(assets, "age-keys.txt"),
	}

	testInstallSecret(t, testdir, &m)
}

func TestAgeWithSSH(t *testing.T) {
	assets := testAssetPath()

	testdir := newTestDir(t)
	defer testdir.Remove()

	target := path.Join(testdir.path, "existing-target")
	file, err := os.Create(target)
	ok(t, err)
	file.Close()

	s := secret{
		Name:         "test",
		Key:          "test_key",
		Owner:        "nobody",
		Group:        "nogroup",
		SopsFile:     path.Join(assets, "secrets.yaml"),
		Path:         target,
		Mode:         "0400",
		RestartUnits: []string{"affected-service"},
		ReloadUnits:  []string{"affected-reload-service"},
	}

	m := manifest{
		Secrets:           []secret{s},
		SecretsMountPoint: testdir.secretsPath,
		SymlinkPath:       testdir.symlinkPath,
		AgeSshKeyPaths:    []string{path.Join(assets, "ssh-ed25519-key")},
	}

	testInstallSecret(t, testdir, &m)
}

func TestAll(t *testing.T) {
	// we can't test in parallel because we rely on GNUPGHOME environment variable
	testGPG(t)
	testSSHKey(t)
}

func TestValidateManifest(t *testing.T) {
	assets := testAssetPath()

	testdir := newTestDir(t)
	defer testdir.Remove()

	s := secret{
		Name:         "test",
		Key:          "test_key",
		Owner:        "nobody",
		Group:        "nogroup",
		SopsFile:     path.Join(assets, "secrets.yaml"),
		Path:         path.Join(testdir.path, "test-target"),
		Mode:         "0400",
		RestartUnits: []string{},
		ReloadUnits:  []string{},
	}

	m := manifest{
		Secrets:           []secret{s},
		SecretsMountPoint: testdir.secretsPath,
		SymlinkPath:       testdir.symlinkPath,
		SSHKeyPaths:       []string{"non-existing-key"},
	}

	path := writeManifest(t, testdir.path, &m)

	ok(t, installSecrets([]string{"sops-install-secrets", "-check-mode=manifest", path}))
	ok(t, installSecrets([]string{"sops-install-secrets", "-check-mode=sopsfile", path}))
}
