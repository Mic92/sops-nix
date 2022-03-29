// +build linux

package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
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
	"time"

	"github.com/Mic92/sops-nix/pkgs/sops-install-secrets/sshkeys"
	agessh "github.com/Mic92/ssh-to-age"

	"github.com/mozilla-services/yaml"
	"go.mozilla.org/sops/v3/decrypt"
	"golang.org/x/sys/unix"
)

type secret struct {
	Name         string     `json:"name"`
	Key          string     `json:"key"`
	Path         string     `json:"path"`
	Owner        string     `json:"owner"`
	Group        string     `json:"group"`
	SopsFile     string     `json:"sopsFile"`
	Format       FormatType `json:"format"`
	Mode         string     `json:"mode"`
	RestartUnits []string   `json:"restartUnits"`
	ReloadUnits  []string   `json:"reloadUnits"`
	value        []byte
	mode         os.FileMode
	owner        int
	group        int
}

type loggingConfig struct {
	KeyImport     bool `json:"keyImport"`
	SecretChanges bool `json:"secretChanges"`
}

type manifest struct {
	Secrets           []secret      `json:"secrets"`
	SecretsMountPoint string        `json:"secretsMountPoint"`
	SymlinkPath       string        `json:"symlinkPath"`
	KeepGenerations   int           `json:"keepGenerations"`
	SSHKeyPaths       []string      `json:"sshKeyPaths"`
	GnupgHome         string        `json:"gnupgHome"`
	AgeKeyFile        string        `json:"ageKeyFile"`
	AgeSshKeyPaths    []string      `json:"ageSshKeyPaths"`
	UserMode          bool          `json:"userMode"`
	Logging           loggingConfig `json:"logging"`
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
	checkMode    CheckMode
	manifest     string
	ignorePasswd bool
}

type appContext struct {
	manifest     manifest
	secretFiles  map[string]secretFile
	checkMode    CheckMode
	ignorePasswd bool
}

func secureSymlinkChown(symlinkToCheck, expectedTarget string, owner, group int) error {
	fd, err := unix.Open(symlinkToCheck, unix.O_CLOEXEC|unix.O_PATH|unix.O_NOFOLLOW, 0)
	if err != nil {
		return fmt.Errorf("Failed to open %s: %w", symlinkToCheck, err)
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
	validUG := true
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		validUG = validUG && int(stat.Uid) == secret.owner
		validUG = validUG && int(stat.Gid) == secret.group
	} else {
		panic("Failed to cast fileInfo Sys() to *syscall.Stat_t. This is possibly an unsupported OS.")
	}
	return linkTarget == targetFile && validUG
}

func symlinkSecret(targetFile string, secret *secret, userMode bool) error {
	for {
		stat, err := os.Lstat(secret.Path)
		if os.IsNotExist(err) {
			if err := os.Symlink(targetFile, secret.Path); err != nil {
				return fmt.Errorf("Cannot create symlink '%s': %w", secret.Path, err)
			}
			if !userMode {
				if err := secureSymlinkChown(secret.Path, targetFile, secret.owner, secret.group); err != nil {
					return fmt.Errorf("Cannot chown symlink '%s': %w", secret.Path, err)
				}
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

func symlinkSecrets(targetDir string, secrets []secret, userMode bool) error {
	for _, secret := range secrets {
		targetFile := filepath.Join(targetDir, secret.Name)
		if targetFile == secret.Path {
			continue
		}
		parent := filepath.Dir(secret.Path)
		if err := os.MkdirAll(parent, os.ModePerm); err != nil {
			return fmt.Errorf("Cannot create parent directory of '%s': %w", secret.Path, err)
		}
		if err := symlinkSecret(targetFile, &secret, userMode); err != nil {
			return fmt.Errorf("Failed to symlink secret '%s': %w", secret.Path, err)
		}
	}
	return nil
}

type plainData struct {
	data   map[string]interface{}
	binary []byte
}

func recurseSecretKey(keys map[string]interface{}, wantedKey string) (string, error) {
	var val interface{}
	var ok bool
	currentKey := wantedKey
	currentData := keys
	keyUntilNow := ""

	for {
		slashIndex := strings.IndexByte(currentKey, '/')
		if slashIndex == -1 {
			// We got to the end
			val, ok = currentData[currentKey]
			if !ok {
				if keyUntilNow != "" {
					keyUntilNow += "/"
				}
				return "", fmt.Errorf("The key '%s%s' cannot be found", keyUntilNow, currentKey)
			}
			break
		}
		thisKey := currentKey[:slashIndex]
		if keyUntilNow == "" {
			keyUntilNow = thisKey
		} else {
			keyUntilNow += "/" + thisKey
		}
		currentKey = currentKey[(slashIndex + 1):]
		val, ok = currentData[thisKey]
		if !ok {
			return "", fmt.Errorf("The key '%s' cannot be found", keyUntilNow)
		}
		valWithWrongType, ok := val.(map[interface{}]interface{})
		if !ok {
			return "", fmt.Errorf("Key '%s' does not refer to a dictionary", keyUntilNow)
		}
		currentData = make(map[string]interface{})
		for key, value := range valWithWrongType {
			currentData[key.(string)] = value
		}
	}

	strVal, ok := val.(string)
	if !ok {
		return "", fmt.Errorf("The value of key '%s' is not a string", keyUntilNow)
	}
	return strVal, nil
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
		strVal, err := recurseSecretKey(sourceFile.data, s.Key)
		if err != nil {
			return fmt.Errorf("secret %s in %s is not valid: %w", s.Name, s.SopsFile, err)
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

const RAMFS_MAGIC int32 = -2054924042

func mountSecretFs(mountpoint string, keysGid int, userMode bool) error {
	if err := os.MkdirAll(mountpoint, 0751); err != nil {
		return fmt.Errorf("Cannot create directory '%s': %w", mountpoint, err)
	}

	// We can't create a ramfs as user
	if userMode {
		return nil
	}

	buf := unix.Statfs_t{}
	if err := unix.Statfs(mountpoint, &buf); err != nil {
		return fmt.Errorf("Cannot get statfs for directory '%s': %w", mountpoint, err)
	}
	if int32(buf.Type) != RAMFS_MAGIC {
		if err := unix.Mount("none", mountpoint, "ramfs", unix.MS_NODEV|unix.MS_NOSUID, "mode=0751"); err != nil {
			return fmt.Errorf("Cannot mount: %s", err)
		}
	}

	if err := os.Chown(mountpoint, 0, int(keysGid)); err != nil {
		return fmt.Errorf("Cannot change owner/group of '%s' to 0/%d: %w", mountpoint, keysGid, err)
	}

	return nil
}

func prepareSecretsDir(secretMountpoint string, linkName string, keysGid int, userMode bool) (*string, error) {
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
	if err := os.Mkdir(dir, os.FileMode(0751)); err != nil {
		return nil, fmt.Errorf("mkdir(): %w", err)
	}
	if !userMode {
		if err := os.Chown(dir, 0, int(keysGid)); err != nil {
			return nil, fmt.Errorf("Cannot change owner/group of '%s' to 0/%d: %w", dir, keysGid, err)
		}
	}
	return &dir, nil
}

func writeSecrets(secretDir string, secrets []secret, keysGid int, userMode bool) error {
	for _, secret := range secrets {
		fp := filepath.Join(secretDir, secret.Name)

		dirs := strings.Split(filepath.Dir(secret.Name), "/")
		pathSoFar := secretDir
		for _, dir := range dirs {
			pathSoFar = filepath.Join(pathSoFar, dir)
			if err := os.MkdirAll(pathSoFar, 0751); err != nil {
				return fmt.Errorf("Cannot create directory '%s' for %s: %w", pathSoFar, fp, err)
			}
			if !userMode {
				if err := os.Chown(pathSoFar, 0, int(keysGid)); err != nil {
					return fmt.Errorf("Cannot own directory '%s' for %s: %w", pathSoFar, fp, err)
				}
			}
		}

		if err := ioutil.WriteFile(fp, []byte(secret.value), secret.mode); err != nil {
			return fmt.Errorf("Cannot write %s: %w", fp, err)
		}
		if !userMode {
			if err := os.Chown(fp, secret.owner, secret.group); err != nil {
				return fmt.Errorf("Cannot change owner/group of '%s' to %d/%d: %w", fp, secret.owner, secret.group, err)
			}
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
		_, err := recurseSecretKey(file.keys, s.Key)
		if err != nil {
			return fmt.Errorf("secret %s in %s is not valid: %w", s.Name, s.SopsFile, err)
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

	if app.ignorePasswd {
		secret.owner = 0
		secret.group = 0
	} else if app.checkMode == Off || app.ignorePasswd {
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
	if m.GnupgHome != "" {
		errorFmt := "gnupgHome and %s were specified in the manifest. " +
			"Both options are mutually exclusive."
		if len(m.SSHKeyPaths) > 0 {
			return fmt.Errorf(errorFmt, "sshKeyPaths")
		}
		if m.AgeKeyFile != "" {
			return fmt.Errorf(errorFmt, "ageKeyFile")
		}
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

func pruneGenerations(secretsMountPoint, secretsDir string, keepGenerations int) error {
	if keepGenerations == 0 {
		return nil // Nothing to prune
	}

	// Prepare our failsafe
	currentGeneration, err := strconv.Atoi(path.Base(secretsDir))
	if err != nil {
		return fmt.Errorf("Logic error, current generation is not numeric: %w", err)
	}

	// Read files in the mount directory
	file, err := os.Open(secretsMountPoint)
	if err != nil {
		return fmt.Errorf("Cannot open %s: %w", secretsMountPoint, err)
	}
	defer file.Close()

	generations, err := file.Readdirnames(0)
	if err != nil {
		return fmt.Errorf("Cannot read %s: %w", secretsMountPoint, err)
	}
	for _, generationName := range generations {
		generationNum, err := strconv.Atoi(generationName)
		// Not a number? Not relevant
		if err != nil {
			continue
		}
		// Not strictly necessary but a good failsafe to
		// make sure we don't prune the current generation
		if generationNum == currentGeneration {
			continue
		}
		if currentGeneration-keepGenerations >= generationNum {
			os.RemoveAll(path.Join(secretsMountPoint, generationName))
		}
	}

	return nil
}

func importSSHKeys(logcfg loggingConfig, keyPaths []string, gpgHome string) error {
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

		if logcfg.KeyImport {
			fmt.Printf("%s: Imported %s with fingerprint %s\n", path.Base(os.Args[0]), p, hex.EncodeToString(gpgKey.PrimaryKey.Fingerprint[:]))
		}
	}

	return nil
}

func importAgeSSHKeys(keyPaths []string, ageFile os.File) error {
	for _, p := range keyPaths {
		// Read the key
		sshKey, err := ioutil.ReadFile(p)
		if err != nil {
			return fmt.Errorf("Cannot read ssh key '%s': %w", p, err)
		}
		// Convert the key to age
		bech32, err := agessh.SSHPrivateKeyToAge(sshKey)
		if err != nil {
			return fmt.Errorf("Cannot convert ssh key '%s': %w", p, err)
		}
		// Append it to the file
		_, err = ageFile.WriteString(*bech32 + "\n")
		if err != nil {
			return fmt.Errorf("Cannot write key to age file: %w", err)
		}
	}

	return nil
}

// Like filepath.Walk but symlink-aware.
// Inspired by https://github.com/facebookarchive/symwalk
func symlinkWalk(filename string, linkDirname string, walkFn filepath.WalkFunc) error {
	symWalkFunc := func(path string, info os.FileInfo, err error) error {

		if fname, err := filepath.Rel(filename, path); err == nil {
			path = filepath.Join(linkDirname, fname)
		} else {
			return err
		}

		if err == nil && info.Mode()&os.ModeSymlink == os.ModeSymlink {
			finalPath, err := filepath.EvalSymlinks(path)
			if err != nil {
				return err
			}
			info, err := os.Lstat(finalPath)
			if err != nil {
				return walkFn(path, info, err)
			}
			if info.IsDir() {
				return symlinkWalk(finalPath, path, walkFn)
			}
		}

		return walkFn(path, info, err)
	}
	return filepath.Walk(filename, symWalkFunc)
}

func handleModifications(isDry bool, logcfg loggingConfig, symlinkPath string, secretDir string, secrets []secret) error {
	var restart []string
	var reload []string

	newSecrets := make(map[string]bool)
	modifiedSecrets := make(map[string]bool)
	removedSecrets := make(map[string]bool)

	// When the symlink path does not exist yet, we are being run in stage-2-init.sh
	// where switch-to-configuration is not run so the services would only be restarted
	// the next time switch-to-configuration is run.
	if _, err := os.Stat(symlinkPath); os.IsNotExist(err) {
		return nil
	}

	// Find modified/new secrets
	for _, secret := range secrets {
		oldPath := filepath.Join(symlinkPath, secret.Name)
		newPath := filepath.Join(secretDir, secret.Name)

		// Read the old file
		oldData, err := ioutil.ReadFile(oldPath)
		if err != nil {
			if os.IsNotExist(err) {
				// File did not exist before
				restart = append(restart, secret.RestartUnits...)
				reload = append(reload, secret.ReloadUnits...)
				newSecrets[secret.Name] = true
				continue
			}
			return err
		}

		// Read the new file
		newData, err := ioutil.ReadFile(newPath)
		if err != nil {
			return err
		}

		if !bytes.Equal(oldData, newData) {
			restart = append(restart, secret.RestartUnits...)
			reload = append(reload, secret.ReloadUnits...)
			modifiedSecrets[secret.Name] = true
		}
	}

	writeLines := func(list []string, file string) error {
		if len(list) != 0 {
			f, err := os.OpenFile(file, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0600)
			if err != nil {
				return err
			}
			defer f.Close()
			for _, unit := range list {
				if _, err = f.WriteString(unit + "\n"); err != nil {
					return err
				}
			}
		}
		return nil
	}
	var dryPrefix string
	if isDry {
		dryPrefix = "/run/nixos/dry-activation"
	} else {
		dryPrefix = "/run/nixos/activation"
	}
	if err := writeLines(restart, dryPrefix+"-restart-list"); err != nil {
		return err
	}
	if err := writeLines(reload, dryPrefix+"-reload-list"); err != nil {
		return err
	}

	// Do not output changes if not requested
	if !logcfg.SecretChanges {
		return nil
	}

	// Find removed secrets
	err := symlinkWalk(symlinkPath, symlinkPath, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}
		path = strings.TrimPrefix(path, symlinkPath+string(os.PathSeparator))
		for _, secret := range secrets {
			if secret.Name == path {
				return nil
			}
		}
		removedSecrets[path] = true
		return nil
	})
	if err != nil {
		return err
	}

	// Output new/modified/removed secrets
	outputChanged := func(changed map[string]bool, regularPrefix, dryPrefix string) {
		if len(changed) > 0 {
			s := ""
			if len(changed) != 1 {
				s = "s"
			}
			if isDry {
				fmt.Printf("%s secret%s: ", dryPrefix, s)
			} else {
				fmt.Printf("%s secret%s: ", regularPrefix, s)
			}
			comma := ""
			for name := range changed {
				fmt.Printf("%s%s", comma, name)
				comma = ", "
			}
			fmt.Println()
		}
	}
	outputChanged(newSecrets, "adding", "would add")
	outputChanged(modifiedSecrets, "modifying", "would modify")
	outputChanged(removedSecrets, "removing", "would remove")

	return nil
}

type keyring struct {
	path string
}

func (k *keyring) Remove() {
	os.RemoveAll(k.path)
	os.Unsetenv("GNUPGHOME")
}

func setupGPGKeyring(logcfg loggingConfig, sshKeys []string, parentDir string) (*keyring, error) {
	dir, err := ioutil.TempDir(parentDir, "gpg")
	if err != nil {
		return nil, fmt.Errorf("Cannot create gpg home in '%s': %s", parentDir, err)
	}
	k := keyring{dir}

	if err := importSSHKeys(logcfg, sshKeys, dir); err != nil {
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
	fs.BoolVar(&opts.ignorePasswd, "ignore-passwd", false, `Don't look up anything in /etc/passwd. Causes everything to be owned by root:root or the user executing the tool in user mode`)
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

	if manifest.UserMode {
		rundir, ok := os.LookupEnv("XDG_RUNTIME_DIR")
		if !ok {
			rundir = fmt.Sprintf("/run/user/%d", os.Getuid())
		}
		manifest.SecretsMountPoint = strings.ReplaceAll(manifest.SecretsMountPoint, "%r", rundir)
		manifest.SymlinkPath = strings.ReplaceAll(manifest.SymlinkPath, "%r", rundir)
		var newSecrets []secret
		for _, secret := range manifest.Secrets {
			secret.Path = strings.ReplaceAll(secret.Path, "%r", rundir)
			newSecrets = append(newSecrets, secret)
		}
		manifest.Secrets = newSecrets
	}

	app := appContext{
		manifest:     *manifest,
		checkMode:    opts.checkMode,
		ignorePasswd: opts.ignorePasswd,
		secretFiles:  make(map[string]secretFile),
	}

	if err := app.validateManifest(); err != nil {
		return fmt.Errorf("Manifest is not valid: %w", err)
	}

	if app.checkMode != Off {
		return nil
	}

	var keysGid int
	if opts.ignorePasswd {
		keysGid = 0
	} else {
		keysGid, err = lookupKeysGroup()
		if err != nil {
			return err
		}
	}

	isDry := os.Getenv("NIXOS_ACTION") == "dry-activate"

	if err := mountSecretFs(manifest.SecretsMountPoint, keysGid, manifest.UserMode); err != nil {
		return fmt.Errorf("Failed to mount filesystem for secrets: %w", err)
	}

	if len(manifest.SSHKeyPaths) != 0 {
		keyring, err := setupGPGKeyring(manifest.Logging, manifest.SSHKeyPaths, manifest.SecretsMountPoint)
		if err != nil {
			return fmt.Errorf("Error setting up gpg keyring: %w", err)
		}
		defer keyring.Remove()
	} else if manifest.GnupgHome != "" {
		os.Setenv("GNUPGHOME", manifest.GnupgHome)
	}

	// Import age keys
	if len(manifest.AgeSshKeyPaths) != 0 || manifest.AgeKeyFile != "" {
		keyfile := filepath.Join(manifest.SecretsMountPoint, "age-keys.txt")
		os.Setenv("SOPS_AGE_KEY_FILE", keyfile)
		// Create the keyfile
		ageFile, err := os.OpenFile(keyfile, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
		if err != nil {
			return fmt.Errorf("Cannot create '%s': %w", keyfile, err)
		}
		defer ageFile.Close()
		fmt.Fprintf(ageFile, "# generated by sops-nix at %s\n", time.Now().Format(time.RFC3339))

		// Import SSH keys
		if len(manifest.AgeSshKeyPaths) != 0 {
			err = importAgeSSHKeys(manifest.AgeSshKeyPaths, *ageFile)
			if err != nil {
				return err
			}
		}
		// Import the keyfile
		if manifest.AgeKeyFile != "" {
			// Read the keyfile
			contents, err := ioutil.ReadFile(manifest.AgeKeyFile)
			if err != nil {
				return fmt.Errorf("Cannot read keyfile '%s': %w", manifest.AgeKeyFile, err)
			}
			// Append it to the file
			_, err = ageFile.WriteString(string(contents) + "\n")
			if err != nil {
				return fmt.Errorf("Cannot write key to age file: %w", err)
			}
		}
	}

	if err := decryptSecrets(manifest.Secrets); err != nil {
		return err
	}

	secretDir, err := prepareSecretsDir(manifest.SecretsMountPoint, manifest.SymlinkPath, keysGid, manifest.UserMode)
	if err != nil {
		return fmt.Errorf("Failed to prepare new secrets directory: %w", err)
	}
	if err := writeSecrets(*secretDir, manifest.Secrets, keysGid, manifest.UserMode); err != nil {
		return fmt.Errorf("Cannot write secrets: %w", err)
	}
	if !manifest.UserMode {
		if err := handleModifications(isDry, manifest.Logging, manifest.SymlinkPath, *secretDir, manifest.Secrets); err != nil {
			return fmt.Errorf("Cannot request units to restart: %w", err)
		}
	}
	// No need to perform the actual symlinking
	if isDry {
		return nil
	}
	if err := symlinkSecrets(manifest.SymlinkPath, manifest.Secrets, manifest.UserMode); err != nil {
		return fmt.Errorf("Failed to prepare symlinks to secret store: %w", err)
	}
	if err := atomicSymlink(*secretDir, manifest.SymlinkPath); err != nil {
		return fmt.Errorf("Cannot update secrets symlink: %w", err)
	}
	if err := pruneGenerations(manifest.SecretsMountPoint, *secretDir, manifest.KeepGenerations); err != nil {
		return fmt.Errorf("Cannot prune old secrets generations: %w", err)
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
