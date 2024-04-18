package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"runtime"
	"strings"
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

func TestShellHook(t *testing.T) {
	assets := os.Getenv("TEST_ASSETS")
	if assets == "" {
		_, filename, _, _ := runtime.Caller(0)
		assets = path.Join(path.Dir(filename), "test-assets")
	}
	tempdir, err := os.MkdirTemp("", "testdir")
	ok(t, err)
	cmd := exec.Command("cp", "-vra", assets+"/.", tempdir) // nolint:gosec
	fmt.Printf("$ %s\n", strings.Join(cmd.Args, " "))
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	ok(t, cmd.Run())

	defer os.RemoveAll(tempdir)

	cmd = exec.Command("nix-shell", path.Join(assets, "shell.nix"), "--run", "gpg --list-keys") // nolint:gosec
	var stdoutBuf, stderrBuf bytes.Buffer
	cmd.Stdout = &stdoutBuf
	cmd.Stderr = &stderrBuf
	cmd.Dir = tempdir
	fmt.Println(tempdir)
	err = cmd.Run()
	stdout := stdoutBuf.String()
	stderr := stderrBuf.String()
	fmt.Printf("$ %s\nstdout: \n%s\nstderr: \n%s\n", strings.Join(cmd.Args, " "), stdout, stderr)
	ok(t, err)

	expectedKeys := []string{
		"C6DA56E69A7C756564A8AFEB4A6B05B714D13EFD",
		"4EC40F8E04A945339F7F7C0032C5225271038E3F",
		"7FB89715AADA920D65D25E63F9BA9DEBD03F57C0",
		"E3B7464FBE89F5378ED4BC60FC925B42FC8B773D",
	}
	for _, key := range expectedKeys {
		if !strings.Contains(stdout, key) {
			t.Fatalf("'%v' not in '%v'", key, stdout)
		}
	}

	// it should ignore subkeys from ./keys/key-with-subkeys.asc
	subkey := "94F174F588090494E73D0835A79B1680BC4D9A54"
	if strings.Contains(stdout, subkey) {
		t.Fatalf("subkey found in %s", stdout)
	}

	expectedStderr := "./non-existing-key.gpg does not exists"
	if !strings.Contains(stderr, expectedStderr) {
		t.Fatalf("'%v' not in '%v'", expectedStderr, stdout)
	}
}
