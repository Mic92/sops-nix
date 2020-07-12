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
	tempdir, err := ioutil.TempDir("", "testdir")
	ok(t, err)
	defer os.RemoveAll(tempdir)

	out := path.Join(tempdir, "out")
	pubKey := path.Join(assets, "id_rsa.pub")
	privKey := path.Join(assets, "id_rsa")
	cmds := [][]string{
		{"ssh-to-pgp", "-pubkey", pubKey, "-o", out},
		{"ssh-to-pgp", "-format=armor", "-pubkey", pubKey, "-o", out},
		{"ssh-to-pgp", "-privkey", privKey, "-o", out},
		{"ssh-to-pgp", "-format=armor", "-privkey", privKey, "-o", out},
	}
	for _, cmd := range cmds {
		err = convertKeys(cmd)
		ok(t, err)
		cmd := exec.Command("gpg", "--with-fingerprint", "--show-key", out)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		ok(t, cmd.Run())
	}
}
