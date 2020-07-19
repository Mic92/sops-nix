package main

import (
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"io/ioutil"
	"os"

	"github.com/Mic92/sops-nix/pkgs/sshkeys"
	"golang.org/x/crypto/openpgp"
	"golang.org/x/crypto/openpgp/armor"
)

type options struct {
	format, out, in string
	privateKey      bool
}

func parseFlags(args []string) options {
	var opts options
	f := flag.NewFlagSet(args[0], flag.ExitOnError)
	f.BoolVar(&opts.privateKey, "private-key", false, "Export private key instead of public key")
	f.StringVar(&opts.format, "format", "armor", "GPG format encoding (binary|armor)")
	f.StringVar(&opts.in, "i", "-", "Input path. Reads by default from standard output")
	f.StringVar(&opts.out, "o", "-", "Output path. Prints by default to standard output")
	if err := f.Parse(args[1:]); err != nil {
		// should never happen since flag.ExitOnError
		panic(err)
	}

	return opts
}

func convertKeys(args []string) error {
	opts := parseFlags(args)
	var err error
	var sshKey []byte
	if opts.in == "-" {
		sshKey, _ = ioutil.ReadAll(os.Stdin)
		if err != nil {
			return fmt.Errorf("error reading stdin: %s", err)
		}
	} else {
		sshKey, err = ioutil.ReadFile(opts.in)
		if err != nil {
			return fmt.Errorf("error reading %s: %s", opts.in, err)
		}
	}

	writer := io.WriteCloser(os.Stdout)
	if opts.out != "-" {
		writer, err = os.Create(opts.out)
		if err != nil {
			return fmt.Errorf("failed to create %s: %s", opts.out, err)
		}
		defer writer.Close()
	}

	if opts.format == "armor" {
		keyType := openpgp.PublicKeyType
		if opts.privateKey {
			keyType = openpgp.PrivateKeyType
		}
		writer, err = armor.Encode(writer, keyType, make(map[string]string))
		if err != nil {
			return fmt.Errorf("failed to encode armor writer")
		}
	}

	gpgKey, err := sshkeys.SSHPrivateKeyToPGP(sshKey)
	if err != nil {
		return err
	}

	if opts.privateKey {
		err = gpgKey.SerializePrivate(writer, nil)
	} else {
		err = gpgKey.Serialize(writer)
	}
	if err == nil {
		if opts.format == "armor" {
			writer.Close()
		}
		fmt.Fprintf(os.Stderr, "%s\n", hex.EncodeToString(gpgKey.PrimaryKey.Fingerprint[:]))
	}
	return err
}

func main() {
	if err := convertKeys(os.Args); err != nil {
		fmt.Fprintf(os.Stderr, "%s: %s\n", os.Args[0], err)
		os.Exit(1)
	}
}
