// +build linux

package main

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io/ioutil"
	"os"
	"os/user"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"github.com/Mic92/sops-nix/pkgs/sshkeys"

	"github.com/mozilla-services/yaml"
	"go.mozilla.org/sops/v3/decrypt"
	"golang.org/x/sys/unix"
)

type secret struct {
	Name            string     `json:"name"`
	Key             string     `json:"key"`
	Path            string     `json:"path"`
	Owner           string     `json:"owner"`
	Group           string     `json:"group"`
	SopsFile        string     `json:"sopsFile"`
	Format          FormatType `json:"format"`
	Mode            string     `json:"mode"`
	RestartServices []string   `json:"restartServices"`
	ReloadServices  []string   `json:"reloadServices"`
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
	GnupgHome         string   `json:"gnupgHome"`
}

type secretFile struct {
	cipherText []byte
	keys       map[string]interface{}
	/// First secret that defined this secretFile, used for error messages
	firstSecret *secret
}

type FormatType string

const (
	Yaml   FormatType = "yaml"
	Json   FormatType = "json"
	Binary FormatType = "binary"
)

func (f *FormatType) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	var t = FormatType(s)
	switch t {
	case "":
		*f = Yaml
	case Yaml, Json, Binary:
		*f = t
	}

	return nil
}

func (f FormatType) MarshalJSON() ([]byte, error) {
	return json.Marshal(string(f))
}

type CheckMode string

const (
	Manifest CheckMode = "manifest"
	SopsFile CheckMode = "sopsfile"
	Off      CheckMode = "off"
)

type options struct {
	checkMode CheckMode
	manifest  string
}

type appContext struct {
	manifest    manifest
	secretFiles map[string]secretFile
	checkMode   CheckMode
}

func secureSymlinkChown(symlinkToCheck, expectedTarget string, owner, group int) error {
	fd, err := unix.Open(symlinkToCheck, unix.O_CLOEXEC|unix.O_PATH|unix.O_NOFOLLOW, 0)
	if err != nil {
			return fmt.Errorf("Failed to open %s: %w", symlinkToCheck, err)
	}
	defer unix.Close(fd)

	buf := make([]byte, len(expectedTarget) + 1) // oversize by one to detect trunc
	n, err := unix.Readlinkat(fd, "", buf)
	if err != nil {
		return fmt.Errorf("couldn't readlinkat %s", symlinkToCheck)
	}
	if n > len(expectedTarget) || string(buf[:n]) != expectedTarget  {
		return fmt.Errorf("symlink %s does not point to %s", symlinkToCheck, expectedTarget)
	}
	err = unix.Fchownat(fd, "", owner, group, unix.AT_EMPTY_PATH)
	if err != nil {
		return fmt.Errorf("cannot change owner of '%s' to %d/%d: %w", symlinkToCheck, owner, group, err)
	}
	return nil
}

func readManifest(path string) (*manifest, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("Failed to open manifest: %w", err)
	}
	defer file.Close()
	dec := json.NewDecoder(file)
	var m manifest
	if err := dec.Decode(&m); err != nil {
		return nil, fmt.Errorf("Failed to parse manifest: %w", err)
	}
	return &m, nil
}

func linksAreEqual(linkTarget, targetFile string, info os.FileInfo, secret *secret) bool {
	validUG := true;
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		validUG = validUG && int(stat.Uid) == secret.owner
		validUG = validUG && int(stat.Gid) == secret.group
	} else {
		panic("Failed to cast fileInfo Sys() to *syscall.Stat_t. This is possibly an unsupported OS.")
	}
	return linkTarget == targetFile && validUG
}

func symlinkSecret(targetFile string, secret *secret) error {
	for {
		stat, err := os.Lstat(secret.Path)
		if os.IsNotExist(err) {
			if err := os.Symlink(targetFile, secret.Path); err != nil {
				return fmt.Errorf("Cannot create symlink '%s': %w", secret.Path, err)
			}
			if err := secureSymlinkChown(secret.Path, targetFile, secret.owner, secret.group); err != nil {
				return fmt.Errorf("Cannot chown symlink '%s': %w", secret.Path, err)
			}
			return nil
		} else if err != nil {
			return fmt.Errorf("Cannot stat '%s': %w", secret.Path, err)
		}
		if stat.Mode()&os.ModeSymlink == os.ModeSymlink {
			linkTarget, err := os.Readlink(secret.Path)
			if os.IsNotExist(err) {
				continue
			} else if err != nil {
				return fmt.Errorf("Cannot read symlink '%s': %w", secret.Path, err)
			} else if linksAreEqual(linkTarget, targetFile, stat, secret) {
				return nil
			}
		}
		if err := os.Remove(secret.Path); err != nil {
			return fmt.Errorf("Cannot override %s: %w", secret.Path, err)
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
			return fmt.Errorf("Cannot create parent directory of '%s': %w", secret.Path, err)
		}
		if err := symlinkSecret(targetFile, &secret); err != nil {
			return fmt.Errorf("Failed to symlink secret '%s': %w", secret.Path, err)
		}
	}
	return nil
}

type plainData struct {
	data   map[string]interface{}
	binary []byte
}

func decryptSecret(s *secret, sourceFiles map[string]plainData) error {
	sourceFile := sourceFiles[s.SopsFile]
	if sourceFile.data == nil || sourceFile.binary == nil {
		plain, err := decrypt.File(s.SopsFile, string(s.Format))
		if err != nil {
			return fmt.Errorf("Failed to decrypt '%s': %w", s.SopsFile, err)
		}
		if s.Format == Binary {
			sourceFile.binary = plain
		} else {
			if s.Format == Yaml {
				if err := yaml.Unmarshal(plain, &sourceFile.data); err != nil {
					return fmt.Errorf("Cannot parse yaml of '%s': %w", s.SopsFile, err)
				}
			} else {
				if err := json.Unmarshal(plain, &sourceFile.data); err != nil {
					return fmt.Errorf("Cannot parse json of '%s': %w", s.SopsFile, err)
				}
			}
		}
	}
	if s.Format == Binary {
		s.value = sourceFile.binary
	} else {
		val, ok := sourceFile.data[s.Key]

		if !ok {
			return fmt.Errorf("The key '%s' cannot be found in '%s'", s.Key, s.SopsFile)
		}
		strVal, ok := val.(string)
		if !ok {
			return fmt.Errorf("The value of key '%s' in '%s' is not a string", s.Key, s.SopsFile)
		} 
		s.value = []byte(strVal)
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
		return fmt.Errorf("Cannot create directory '%s': %w", mountpoint, err)
	}

	if err := unix.Mount("none", mountpoint, "ramfs", unix.MS_NODEV|unix.MS_NOSUID, "mode=0750"); err != nil {
		return fmt.Errorf("Cannot mount: %s", err)
	}

	if err := os.Chown(mountpoint, 0, int(keysGid)); err != nil {
		return fmt.Errorf("Cannot change owner/group of '%s' to 0/%d: %w", mountpoint, keysGid, err)
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
				return nil, fmt.Errorf("Cannot parse %s of %s as a number: %w", targetBasename, linkTarget, err)
			}
		}
	} else if !os.IsNotExist(err) {
		return nil, fmt.Errorf("Cannot access %s: %w", linkName, err)
	}
	generation++
	dir := filepath.Join(secretMountpoint, strconv.Itoa(int(generation)))
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		if err := os.RemoveAll(dir); err != nil {
			return nil, fmt.Errorf("Cannot remove existing %s: %w", dir, err)
		}
	}
	if err := os.Mkdir(dir, os.FileMode(0750)); err != nil {
		return nil, fmt.Errorf("mkdir(): %w", err)
	}
	if err := os.Chown(dir, 0, int(keysGid)); err != nil {
		return nil, fmt.Errorf("Cannot change owner/group of '%s' to 0/%d: %w", dir, keysGid, err)
	}
	return &dir, nil
}

func writeSecrets(secretDir string, secrets []secret) error {
	for _, secret := range secrets {
		filepath := filepath.Join(secretDir, secret.Name)
		if err := ioutil.WriteFile(filepath, []byte(secret.value), secret.mode); err != nil {
			return fmt.Errorf("Cannot write %s: %w", filepath, err)
		}
		if err := os.Chown(filepath, secret.owner, secret.group); err != nil {
			return fmt.Errorf("Cannot change owner/group of '%s' to %d/%d: %w", filepath, secret.owner, secret.group, err)
		}
	}
	return nil
}

func lookupKeysGroup() (int, error) {
	group, err := user.LookupGroup("keys")
	if err != nil {
		return 0, fmt.Errorf("Failed to lookup 'keys' group: %w", err)
	}
	gid, err := strconv.ParseInt(group.Gid, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("Cannot parse keys gid %s: %w", group.Gid, err)
	}
	return int(gid), nil
}

func (app *appContext) loadSopsFile(s *secret) (*secretFile, error) {
	if app.checkMode == Manifest {
		return &secretFile{firstSecret: s}, nil
	}

	cipherText, err := ioutil.ReadFile(s.SopsFile)
	if err != nil {
		return nil, fmt.Errorf("Failed reading %s: %w", s.SopsFile, err)
	}

	var keys map[string]interface{}
	if s.Format == Binary {
		if err := json.Unmarshal(cipherText, &keys); err != nil {
			return nil, fmt.Errorf("Cannot parse json of '%s': %w", s.SopsFile, err)
		}
		return &secretFile{cipherText: cipherText, firstSecret: s}, nil
	}

	if s.Format == Yaml {
		if err := yaml.Unmarshal(cipherText, &keys); err != nil {
			return nil, fmt.Errorf("Cannot parse yaml of '%s': %w", s.SopsFile, err)
		}
	} else if err := json.Unmarshal(cipherText, &keys); err != nil {
		return nil, fmt.Errorf("Cannot parse json of '%s': %w", s.SopsFile, err)
	}

	return &secretFile{
		cipherText:  cipherText,
		keys:        keys,
		firstSecret: s,
	}, nil

}

func (app *appContext) validateSopsFile(s *secret, file *secretFile) error {
	if file.firstSecret.Format != s.Format {
		return fmt.Errorf("secret %s defined the format of %s as %s, but it was specified as %s in %s before",
			s.Name, s.SopsFile, s.Format,
			file.firstSecret.Format, file.firstSecret.Name)
	}
	if app.checkMode != Manifest && s.Format != Binary {
		if _, ok := file.keys[s.Key]; !ok {
			return fmt.Errorf("secret %s with the key %s not found in %s", s.Name, s.Key, s.SopsFile)
		}
	}
	return nil
}

func (app *appContext) validateSecret(secret *secret) error {
	mode, err := strconv.ParseUint(secret.Mode, 8, 16)
	if err != nil {
		return fmt.Errorf("Invalid number in mode: %d: %w", mode, err)
	}
	secret.mode = os.FileMode(mode)

	if app.checkMode == Off {
		// we only access to the user/group during deployment
		owner, err := user.Lookup(secret.Owner)
		if err != nil {
			return fmt.Errorf("Failed to lookup user '%s': %w", secret.Owner, err)
		}
		ownerNr, err := strconv.ParseUint(owner.Uid, 10, 64)
		if err != nil {
			return fmt.Errorf("Cannot parse uid %s: %w", owner.Uid, err)
		}
		secret.owner = int(ownerNr)

		group, err := user.LookupGroup(secret.Group)
		if err != nil {
			return fmt.Errorf("Failed to lookup group '%s': %w", secret.Group, err)
		}
		groupNr, err := strconv.ParseUint(group.Gid, 10, 64)
		if err != nil {
			return fmt.Errorf("Cannot parse gid %s: %w", group.Gid, err)
		}
		secret.group = int(groupNr)
	}

	if secret.Format == "" {
		secret.Format = "yaml"
	}

	if secret.Format != "yaml" && secret.Format != "json" && secret.Format != "binary" {
		return fmt.Errorf("Unsupported format %s for secret %s", secret.Format, secret.Name)
	}

	file, ok := app.secretFiles[secret.SopsFile]
	if !ok {
		maybeFile, err := app.loadSopsFile(secret)
		if err != nil {
			return err
		}
		app.secretFiles[secret.SopsFile] = *maybeFile
		file = *maybeFile
	}

	return app.validateSopsFile(secret, &file)
}

func (app *appContext) validateManifest() error {
	m := &app.manifest
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
		if err := app.validateSecret(&m.Secrets[i]); err != nil {
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
		return fmt.Errorf("Cannot create %s: %w", secringPath, err)
	}
	for _, p := range keyPaths {
		sshKey, err := ioutil.ReadFile(p)
		if err != nil {
			return fmt.Errorf("Cannot read ssh key '%s': %w", p, err)
		}
		gpgKey, err := sshkeys.SSHPrivateKeyToPGP(sshKey)
		if err != nil {
			return err
		}

		if err := gpgKey.SerializePrivate(secring, nil); err != nil {
			return fmt.Errorf("Cannot write secring: %w", err)
		}

		fmt.Printf("%s: Imported %s with fingerprint %s\n", path.Base(os.Args[0]), p, hex.EncodeToString(gpgKey.PrimaryKey.Fingerprint[:]))
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

func parseFlags(args []string) (*options, error) {
	var opts options
	fs := flag.NewFlagSet(args[0], flag.ContinueOnError)
	fs.Usage = func() {
		fmt.Fprintf(flag.CommandLine.Output(), "Usage: %s [OPTION] manifest.json\n", args[0])
		fs.PrintDefaults()
	}
	var checkMode string
	fs.StringVar(&checkMode, "check-mode", "off", `Validate configuration without installing it (possible values: "manifest","sopsfile","off")`)
	if err := fs.Parse(args[1:]); err != nil {
		return nil, err
	}

	switch CheckMode(checkMode) {
	case Manifest, SopsFile, Off:
		opts.checkMode = CheckMode(checkMode)
	default:
		return nil, fmt.Errorf("Invalid value provided for -check-mode flag: %s", opts.checkMode)
	}

	if fs.NArg() != 1 {
		flag.Usage()
		return nil, flag.ErrHelp
	}
	opts.manifest = fs.Arg(0)
	return &opts, nil
}

func installSecrets(args []string) error {
	opts, err := parseFlags(args)
	if err != nil {
		return err
	}

	manifest, err := readManifest(opts.manifest)
	if err != nil {
		return err
	}

	app := appContext{
		manifest:    *manifest,
		checkMode:   opts.checkMode,
		secretFiles: make(map[string]secretFile),
	}

	if err := app.validateManifest(); err != nil {
		return fmt.Errorf("Manifest is not valid: %w", err)
	}

	if app.checkMode != Off {
		return nil
	}

	keysGid, err := lookupKeysGroup()
	if err != nil {
		return err
	}

	if err := mountSecretFs(manifest.SecretsMountPoint, keysGid); err != nil {
		return fmt.Errorf("Failed to mount filesystem for secrets: %w", err)
	}

	if len(manifest.SSHKeyPaths) != 0 {
		keyring, err := setupGPGKeyring(manifest.SSHKeyPaths, manifest.SecretsMountPoint)
		if err != nil {
			return fmt.Errorf("Error setting up gpg keyring: %w", err)
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
		return fmt.Errorf("Failed to prepare new secrets directory: %w", err)
	}
	if err := writeSecrets(*secretDir, manifest.Secrets); err != nil {
		return fmt.Errorf("Cannot write secrets: %w", err)
	}
	if err := symlinkSecrets(manifest.SymlinkPath, manifest.Secrets); err != nil {
		return fmt.Errorf("Failed to prepare symlinks to secret store: %w", err)
	}
	if err := atomicSymlink(*secretDir, manifest.SymlinkPath); err != nil {
		return fmt.Errorf("Cannot update secrets symlink: %w", err)
	}

	return nil

}

func main() {
	if err := installSecrets(os.Args); err != nil {
		if err == flag.ErrHelp {
			return
		}
		fmt.Fprintf(os.Stderr, "%s: %s\n", os.Args[0], err)
		os.Exit(1)
	}
}
