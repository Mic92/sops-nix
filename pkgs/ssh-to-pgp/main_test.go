package main

import (
	"fmt"
	"io/ioutil"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"runtime"
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

func TestCli(t *testing.T) {
	_, filename, _, _ := runtime.Caller(0)
	assets := path.Join(path.Dir(filename), "test-assets")
	tempdir, err := ioutil.TempDir("/tmp", "testdir")
	ok(t, err)
	defer os.RemoveAll(tempdir)

	gpgHome := path.Join(tempdir, "gpg-home")
	gpgEnv := append(os.Environ(), fmt.Sprintf("GNUPGHOME=%s", gpgHome))
	ok(t, os.Mkdir(gpgHome, os.FileMode(0700)))

	out := path.Join(tempdir, "out")
	privKey := path.Join(assets, "id_rsa")
	cmds := [][]string{
		{"ssh-to-pgp", "-i", privKey, "-o", out},
		{"ssh-to-pgp", "-format=binary", "-i", privKey, "-o", out},
		{"ssh-to-pgp", "-private-key", "-i", privKey, "-o", out},
		{"ssh-to-pgp", "-format=binary", "-private-key", "-i", privKey, "-o", out},
	}
	for _, cmd := range cmds {
		err = convertKeys(cmd)
		ok(t, err)
		cmd := exec.Command("gpg", "--with-fingerprint", "--show-key", out)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		cmd.Env = gpgEnv
		ok(t, cmd.Run())
	}
}
