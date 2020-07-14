package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/ioutil"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/Mic92/sops-nix/pkgs/sshkeys"

	"github.com/mozilla-services/yaml"
	"go.mozilla.org/sops/v3/decrypt"
	"golang.org/x/sys/unix"
)

type secret struct {
	Name            string   `json:"name"`
	Key             string   `json:"key"`
	Path            string   `json:"path"`
	Owner           string   `json:"owner"`
	Group           string   `json:"group"`
	SopsFile        string   `json:"sopsFile"`
	Format          string   `json:"format"`
	Mode            string   `json:"mode"`
	RestartServices []string `json:"restartServices"`
	ReloadServices  []string `json:"reloadServices"`
	value           []byte
	mode            os.FileMode
	owner           int
	group           int
}

type manifest struct {
	Secrets           []secret `json:"secrets"`
	SecretsMountPoint string   `json:"secretsMountpoint"`
	SymlinkPath       string   `json:"symlinkPath"`
	SSHKeyPaths       []string `json:"sshKeyPaths"`
	GnupgHome         string   `json:"gnupgHome`
}

func readManifest(path string) (*manifest, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("Failed to open manifest: %s", err)
	}
	defer file.Close()
	dec := json.NewDecoder(file)
	var m manifest
	if err := dec.Decode(&m); err != nil {
		return nil, fmt.Errorf("Failed to parse manifest: %s", err)
	}
	return &m, nil
}

func symlinkSecret(targetFile string, secret *secret) error {
	for {
		currentLinkTarget, err := os.Readlink(secret.Path)
		if os.IsNotExist(err) {
			if err := os.Symlink(targetFile, secret.Path); err != nil {
				return fmt.Errorf("Cannot create symlink '%s': %s", secret.Path, err)
			}
			return nil
		} else if err != nil {
			return fmt.Errorf("Cannot read symlink: '%s'", err)
		} else if currentLinkTarget == targetFile {
			return nil
		}
		if err := os.Remove(secret.Path); err != nil {
			return fmt.Errorf("Cannot override %s", secret.Path)
		}
	}
}

func symlinkSecrets(targetDir string, secrets []secret) error {
	for _, secret := range secrets {
		targetFile := filepath.Join(targetDir, secret.Name)
		if targetFile == secret.Path {
			continue
		}
		parent := filepath.Dir(secret.Path)
		if err := os.MkdirAll(parent, os.ModePerm); err != nil {
			return fmt.Errorf("Cannot create parent directory of '%s': %s", secret.Path, err)
		}
		if err := symlinkSecret(targetFile, &secret); err != nil {
			return err
		}
	}
	return nil
}

type plainData struct {
	data   map[string]string
	binary []byte
}

func decryptSecret(s *secret, sourceFiles map[string]plainData) error {
	sourceFile := sourceFiles[s.SopsFile]
	if sourceFile.data == nil || sourceFile.binary == nil {
		plain, err := decrypt.File(s.SopsFile, s.Format)
		if err != nil {
			return fmt.Errorf("Failed to decrypt '%s': %s", s.SopsFile, err)
		}
		if s.Format == "binary" {
			sourceFile.binary = plain
		} else {
			if s.Format == "yaml" {
				if err := yaml.Unmarshal(plain, &sourceFile.data); err != nil {
					return fmt.Errorf("Cannot parse yaml of '%s': %s", s.SopsFile, err)
				}
			} else {
				if err := json.Unmarshal(plain, &sourceFile.data); err != nil {
					return fmt.Errorf("Cannot parse json of '%s': %s", s.SopsFile, err)
				}
			}
		}
	}
	if s.Format == "binary" {
		s.value = sourceFile.binary
	} else {
		val, ok := sourceFile.data[s.Key]
		if !ok {
			return fmt.Errorf("The key '%s' cannot be found in '%s'", s.Key, s.SopsFile)
		}
		s.value = []byte(val)
	}
	sourceFiles[s.SopsFile] = sourceFile
	return nil
}

func decryptSecrets(secrets []secret) error {
	sourceFiles := make(map[string]plainData)
	for i := range secrets {
		if err := decryptSecret(&secrets[i], sourceFiles); err != nil {
			return err
		}
	}
	return nil
}

func mountSecretFs(mountpoint string, keysGid int) error {
	if err := os.MkdirAll(mountpoint, 0750); err != nil {
		return fmt.Errorf("Cannot create directory '%s': %s", mountpoint, err)
	}

	if err := unix.Mount("none", mountpoint, "ramfs", unix.MS_NODEV|unix.MS_NOSUID, "mode=0750"); err != nil {
		return fmt.Errorf("Cannot mount: %s", err)
	}

	if err := os.Chown(mountpoint, 0, int(keysGid)); err != nil {
		return fmt.Errorf("Cannot change owner/group of '%s' to 0/%d: %s", mountpoint, keysGid, err)
	}

	return nil
}

func prepareSecretsDir(secretMountpoint string, linkName string, keysGid int) (*string, error) {
	var generation uint64
	linkTarget, err := os.Readlink(linkName)
	if err == nil {
		if strings.HasPrefix(linkTarget, secretMountpoint) {
			targetBasename := filepath.Base(linkTarget)
			generation, err = strconv.ParseUint(targetBasename, 10, 64)
			if err != nil {
				return nil, fmt.Errorf("Cannot parse %s of %s as a number: %s", targetBasename, linkTarget, err)
			}
		}
	} else if !os.IsNotExist(err) {
		return nil, fmt.Errorf("Cannot access %s: %s", linkName, err)
	}
	generation++
	dir := filepath.Join(secretMountpoint, strconv.Itoa(int(generation)))
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		if err := os.RemoveAll(dir); err != nil {
			return nil, fmt.Errorf("Cannot remove existing %s: %s", dir, err)
		}
	}
	if err := os.Mkdir(dir, os.FileMode(0750)); err != nil {
		return nil, fmt.Errorf("mkdir(): %s", err)
	}
	if err := os.Chown(dir, 0, int(keysGid)); err != nil {
		return nil, fmt.Errorf("Cannot change owner/group of '%s' to 0/%d: %s", dir, keysGid, err)
	}
	return &dir, nil
}

func writeSecrets(secretDir string, secrets []secret) error {
	for _, secret := range secrets {
		filepath := filepath.Join(secretDir, secret.Name)
		if err := ioutil.WriteFile(filepath, []byte(secret.value), secret.mode); err != nil {
			return fmt.Errorf("Cannot write %s: %s", filepath, err)
		}
		if err := os.Chown(filepath, secret.owner, secret.group); err != nil {
			return fmt.Errorf("Cannot change owner/group of '%s' to %d/%d: %s", filepath, secret.owner, secret.group, err)
		}
	}
	return nil
}

func lookupKeysGroup() (int, error) {
	group, err := user.LookupGroup("keys")
	if err != nil {
		return 0, fmt.Errorf("Failed to lookup 'keys' group: %s", err)
	}
	gid, err := strconv.ParseInt(group.Gid, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("Cannot parse keys gid %s: %s", group.Gid, err)
	}
	return int(gid), nil
}

func validateSecret(secret *secret) error {
	mode, err := strconv.ParseUint(secret.Mode, 8, 16)
	if err != nil {
		return fmt.Errorf("Invalid number in mode: %d: %s", mode, err)
	}
	secret.mode = os.FileMode(mode)

	owner, err := user.Lookup(secret.Owner)
	if err != nil {
		return fmt.Errorf("Failed to lookup user '%s': %s", secret.Owner, err)
	}
	ownerNr, err := strconv.ParseUint(owner.Uid, 10, 64)
	if err != nil {
		return fmt.Errorf("Cannot parse uid %s: %s", owner.Uid, err)
	}
	secret.owner = int(ownerNr)

	group, err := user.LookupGroup(secret.Group)
	if err != nil {
		return fmt.Errorf("Failed to lookup group '%s': %s", secret.Group, err)
	}
	groupNr, err := strconv.ParseUint(group.Gid, 10, 64)
	if err != nil {
		return fmt.Errorf("Cannot parse gid %s: %s", group.Gid, err)
	}
	secret.group = int(groupNr)

	if secret.Format == "" {
		secret.Format = "yaml"
	}

	if secret.Format != "yaml" && secret.Format != "json" && secret.Format != "binary" {
		return fmt.Errorf("Unsupported format %s for secret %s",
			secret.Format, secret.Name)
	}

	return nil
}

func validateManifest(m *manifest) error {
	if m.SecretsMountPoint == "" {
		m.SecretsMountPoint = "/run/secrets.d"
	}
	if m.SymlinkPath == "" {
		m.SymlinkPath = "/run/secrets"
	}
	if len(m.SSHKeyPaths) > 0 && m.GnupgHome != "" {
		return errors.New("gnupgHome and sshKeyPaths were specified in the manifest. " +
			"Both options are mutual exclusive.")
	}
	for i := range m.Secrets {
		if err := validateSecret(&m.Secrets[i]); err != nil {
			return err
		}
	}
	return nil
}

func atomicSymlink(oldname, newname string) error {
	// Fast path: if newname does not exist yet, we can skip the whole dance
	// below.
	if err := os.Symlink(oldname, newname); err == nil || !os.IsExist(err) {
		return err
	}

	// We need to use ioutil.TempDir, as we cannot overwrite a ioutil.TempFile,
	// and removing+symlinking creates a TOCTOU race.
	d, err := ioutil.TempDir(filepath.Dir(newname), "."+filepath.Base(newname))
	if err != nil {
		return err
	}
	cleanup := true
	defer func() {
		if cleanup {
			os.RemoveAll(d)
		}
	}()

	symlink := filepath.Join(d, "tmp.symlink")
	if err := os.Symlink(oldname, symlink); err != nil {
		return err
	}

	if err := os.Rename(symlink, newname); err != nil {
		return err
	}

	cleanup = false
	return os.RemoveAll(d)
}

func importSSHKeys(keyPaths []string, gpgHome string) error {
	secringPath := filepath.Join(gpgHome, "secring.gpg")

	secring, err := os.OpenFile(secringPath, os.O_WRONLY|os.O_CREATE, 0600)
	if err != nil {
		return fmt.Errorf("Cannot create %s: %s", secringPath, err)
	}
	for _, path := range keyPaths {
		sshKey, err := ioutil.ReadFile(path)
		if err != nil {
			return fmt.Errorf("Cannot read ssh key '%s': %s", path, err)
		}
		gpgKey, err := sshkeys.SSHPrivateKeyToPGP(sshKey)
		if err != nil {
			return err
		}
		if err := gpgKey.SerializePrivate(secring, nil); err != nil {
			return fmt.Errorf("Cannot write secring: %s", err)
		}
	}

	return nil
}

type keyring struct {
	path string
}

func (k *keyring) Remove() {
	os.RemoveAll(k.path)
	os.Unsetenv("GNUPGHOME")
}

func setupGPGKeyring(sshKeys []string, parentDir string) (*keyring, error) {
	dir, err := ioutil.TempDir(parentDir, "gpg")
	if err != nil {
		return nil, fmt.Errorf("Cannot create gpg home in '%s': %s", parentDir, err)
	}
	k := keyring{dir}

	if err := importSSHKeys(sshKeys, dir); err != nil {
		os.RemoveAll(dir)
		return nil, err
	}
	os.Setenv("GNUPGHOME", dir)

	return &k, nil
}

func installSecrets(args []string) error {
	if len(args) <= 1 {
		return fmt.Errorf("USAGE: %s manifest.json", args)
	}
	manifest, err := readManifest(args[1])
	if err != nil {
		return err
	}

	if err := validateManifest(manifest); err != nil {
		return fmt.Errorf("Manifest is not valid: %s", err)
	}

	keysGid, err := lookupKeysGroup()
	if err != nil {
		return err
	}

	if err := mountSecretFs(manifest.SecretsMountPoint, keysGid); err != nil {
		return fmt.Errorf("Failed to mount filesystem for secrets: %s", err)
	}

	if len(manifest.SSHKeyPaths) != 0 {
		keyring, err := setupGPGKeyring(manifest.SSHKeyPaths, manifest.SecretsMountPoint)
		if err != nil {
			return fmt.Errorf("Error setting up gpg keyring: %s", err)
		}
		defer keyring.Remove()
	} else if manifest.GnupgHome != "" {
		os.Setenv("GNUPGHOME", manifest.GnupgHome)
	}

	if err := decryptSecrets(manifest.Secrets); err != nil {
		return err
	}

	secretDir, err := prepareSecretsDir(manifest.SecretsMountPoint, manifest.SymlinkPath, keysGid)
	if err != nil {
		return fmt.Errorf("Failed to prepare new secrets directory: %s", err)
	}
	if err := writeSecrets(*secretDir, manifest.Secrets); err != nil {
		return fmt.Errorf("Cannot write secrets: %s", err)
	}
	if err := symlinkSecrets(manifest.SymlinkPath, manifest.Secrets); err != nil {
		return fmt.Errorf("Failed to prepare symlinks to secret store: %s", err)
	}
	if err := atomicSymlink(*secretDir, manifest.SymlinkPath); err != nil {
		return fmt.Errorf("Cannot update secrets symlink: %s", err)
	}

	return nil

}

func main() {
	if err := installSecrets(os.Args); err != nil {
		fmt.Fprintf(os.Stderr, "%s: %s\n", os.Args[0], err)
		os.Exit(1)
	}
}
