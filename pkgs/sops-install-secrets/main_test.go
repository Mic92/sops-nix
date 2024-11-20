//go:build linux || darwin
// +build linux darwin

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path"
	"reflect"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

const (
	NOBODY  = "nobody"
	NOGROUP = "nogroup"
)

// ok fails the test if an err is not nil.
func ok(tb testing.TB, err error) {
	tb.Helper()

	if err != nil {
		fmt.Printf("\033[31munexpected error: %s\033[39m\n\n", err.Error())
		tb.FailNow()
	}
}

func equals(tb testing.TB, exp, act interface{}) {
	tb.Helper()

	if !reflect.DeepEqual(exp, act) {
		fmt.Printf("\033[31m\texp: %#v\n\n\tgot: %#v\033[39m\n\n", exp, act)
		tb.FailNow()
	}
}

func writeManifest(t *testing.T, dir string, m *manifest) string {
	t.Helper()

	filename := path.Join(dir, "manifest.json")
	f, err := os.OpenFile(filename, os.O_RDWR|os.O_CREATE, 0o755)
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
	t.Helper()

	tempdir, err := os.MkdirTemp("", "symlinkDir")
	ok(t, err)
	return testDir{tempdir, path.Join(tempdir, "secrets.d"), path.Join(tempdir, "secrets")}
}

func testInstallSecret(t *testing.T, testdir testDir, m *manifest) {
	t.Helper()

	path := writeManifest(t, testdir.path, m)
	ok(t, installSecrets([]string{"sops-install-secrets", path}))
}

// cannot run in parellel with TestSSHKey because we rely on GNUPGHOME environment variable
func TestGPG(t *testing.T) { //nolint:paralleltest
	assets := testAssetPath()

	testdir := newTestDir(t)
	defer testdir.Remove()
	gpgHome := path.Join(testdir.path, "gpg-home")
	gpgEnv := append(os.Environ(), "GNUPGHOME="+gpgHome)

	ok(t, os.Mkdir(gpgHome, os.FileMode(0o700)))

	cmd := exec.Command("gpg", "--import", path.Join(assets, "key.asc")) //nolint:gosec
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
	nobody := NOBODY
	nogroup := NOGROUP
	yamlSecret := secret{
		Name:         "test",
		Key:          "test_key",
		Owner:        &nobody,
		Group:        &nogroup,
		SopsFile:     path.Join(assets, "secrets.yaml"),
		Path:         path.Join(testdir.path, "test-target"),
		Mode:         "0400",
		RestartUnits: []string{"affected-service"},
		ReloadUnits:  []string{"affected-reload-service"},
	}

	var jsonSecret, binarySecret, dotenvSecret, iniSecret secret

	root := "root"
	// should not create a symlink
	jsonSecret = yamlSecret
	jsonSecret.Name = "test2"
	jsonSecret.Owner = &root
	jsonSecret.Format = "json"
	jsonSecret.Group = &root
	jsonSecret.SopsFile = path.Join(assets, "secrets.json")
	jsonSecret.Path = path.Join(testdir.secretsPath, "test2")
	jsonSecret.Mode = "0700"

	binarySecret = yamlSecret
	binarySecret.Name = "test3"
	binarySecret.Format = "binary"
	binarySecret.SopsFile = path.Join(assets, "secrets.bin")
	binarySecret.Path = path.Join(testdir.secretsPath, "test3")

	dotenvSecret = yamlSecret
	dotenvSecret.Name = "test4"
	dotenvSecret.Owner = &root
	dotenvSecret.Group = &root
	dotenvSecret.Format = "dotenv"
	dotenvSecret.SopsFile = path.Join(assets, "secrets.env")
	dotenvSecret.Path = path.Join(testdir.secretsPath, "test4")

	iniSecret = yamlSecret
	iniSecret.Name = "test5"
	iniSecret.Owner = &root
	iniSecret.Group = &root
	iniSecret.Format = "ini"
	iniSecret.SopsFile = path.Join(assets, "secrets.ini")
	iniSecret.Path = path.Join(testdir.secretsPath, "test5")

	m := manifest{
		Secrets:           []secret{yamlSecret, jsonSecret, binarySecret, dotenvSecret, iniSecret},
		SecretsMountPoint: testdir.secretsPath,
		SymlinkPath:       testdir.symlinkPath,
		GnupgHome:         gpgHome,
	}

	testInstallSecret(t, testdir, &m)

	_, err := os.Stat(m.SecretsMountPoint)
	ok(t, err)

	_, err = os.Stat(m.SymlinkPath)
	ok(t, err)

	yamlLinkStat, err := os.Lstat(yamlSecret.Path)
	ok(t, err)

	equals(t, os.ModeSymlink, yamlLinkStat.Mode()&os.ModeSymlink)

	yamlStat, err := os.Stat(yamlSecret.Path)
	ok(t, err)

	equals(t, true, yamlStat.Mode().IsRegular())
	equals(t, 0o400, int(yamlStat.Mode().Perm()))
	stat, success := yamlStat.Sys().(*syscall.Stat_t)
	equals(t, true, success)

	content, err := os.ReadFile(yamlSecret.Path)
	ok(t, err)
	equals(t, "test_value", string(content))

	u, err := user.LookupId(strconv.Itoa(int(stat.Uid)))
	ok(t, err)
	equals(t, NOBODY, u.Username)

	g, err := user.LookupGroupId(strconv.Itoa(int(stat.Gid)))
	ok(t, err)
	equals(t, NOGROUP, g.Name)

	jsonStat, err := os.Stat(jsonSecret.Path)
	ok(t, err)
	equals(t, true, jsonStat.Mode().IsRegular())
	equals(t, 0o700, int(jsonStat.Mode().Perm()))

	if stat, ok := jsonStat.Sys().(*syscall.Stat_t); ok {
		equals(t, 0, int(stat.Uid))
		equals(t, 0, int(stat.Gid))
	}

	content, err = os.ReadFile(binarySecret.Path)
	ok(t, err)
	equals(t, 13, len(content))

	testInstallSecret(t, testdir, &m)

	target, err := os.Readlink(testdir.symlinkPath)
	ok(t, err)
	equals(t, path.Join(testdir.secretsPath, "2"), target)
}

func TestSSHKey(t *testing.T) {
	t.Parallel()

	assets := testAssetPath()

	testdir := newTestDir(t)
	defer testdir.Remove()

	target := path.Join(testdir.path, "existing-target")
	file, err := os.Create(target)
	ok(t, err)
	file.Close()

	nobody := NOBODY
	nogroup := NOGROUP
	s := secret{
		Name:         "test",
		Key:          "test_key",
		Owner:        &nobody,
		Group:        &nogroup,
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
	t.Parallel()

	assets := testAssetPath()

	testdir := newTestDir(t)
	defer testdir.Remove()

	target := path.Join(testdir.path, "existing-target")
	file, err := os.Create(target)
	ok(t, err)
	file.Close()

	nobody := NOBODY
	nogroup := NOGROUP
	s := secret{
		Name:         "test",
		Key:          "test_key",
		Owner:        &nobody,
		Group:        &nogroup,
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
	t.Parallel()

	assets := testAssetPath()

	testdir := newTestDir(t)
	defer testdir.Remove()

	target := path.Join(testdir.path, "existing-target")
	file, err := os.Create(target)
	ok(t, err)
	file.Close()

	nobody := NOBODY
	nogroup := NOGROUP
	s := secret{
		Name:         "test",
		Key:          "test_key",
		Owner:        &nobody,
		Group:        &nogroup,
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
		AgeSSHKeyPaths:    []string{path.Join(assets, "ssh-ed25519-key")},
	}

	testInstallSecret(t, testdir, &m)
}

func TestValidateManifest(t *testing.T) {
	t.Parallel()

	assets := testAssetPath()

	testdir := newTestDir(t)
	defer testdir.Remove()

	nobody := NOBODY
	nogroup := NOGROUP
	s := secret{
		Name:         "test",
		Key:          "test_key",
		Owner:        &nobody,
		Group:        &nogroup,
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

func TestIsValidFormat(t *testing.T) {
	t.Parallel()

	generateCase := func(input string, mustBe bool) {
		result := IsValidFormat(input)
		if result != mustBe {
			t.Errorf("input %s must return %v but returned %v", input, mustBe, result)
		}
	}
	for _, format := range []string{string(Yaml), string(JSON), string(Binary), string(Dotenv)} {
		generateCase(format, true)
		generateCase(strings.ToUpper(format), false)
	}
}
