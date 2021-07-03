package main

import (
	"encoding/json"
	"io/ioutil"
	"os"
	"path/filepath"
	"sort"
)

type fetchInfo struct {
	Type   string `toml:"type"`
	URL    string `toml:"url"`
	Rev    string `toml:"rev"`
	Sha256 string `toml:"sha256"`
}

type packageT struct {
	SumVersion string     `toml:"sumVersion"`
	RelPath    string     `toml:"relPath,omitempty"`
	VendorPath string     `toml:"vendorPath,omitempty"`
	Fetch      *fetchInfo `toml:"fetch"`
}

func main() {

	pkgs := make(map[string]*packageT)
	sources := make(map[string]string)

	b, err := ioutil.ReadFile(os.Getenv("sourcesPath"))
	if err != nil {
		panic(err)
	}

	err = json.Unmarshal(b, &sources)
	if err != nil {
		panic(err)
	}

	b, err = ioutil.ReadFile(os.Getenv("jsonPath"))
	if err != nil {
		panic(err)
	}

	err = json.Unmarshal(b, &pkgs)
	if err != nil {
		panic(err)
	}

	keys := make([]string, 0, len(pkgs))
	for key := range pkgs {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	// Iterate, in reverse order
	for i := len(keys) - 1; i >= 0; i-- {
		key := keys[i]
		src := sources[key]
		pkg := pkgs[key]

		paths := []string{key}
		if pkg.VendorPath != "" {
			paths = append(paths, pkg.VendorPath)
		}

		for _, path := range paths {

			vendorDir := filepath.Join("vendor", filepath.Dir(path))
			os.MkdirAll(vendorDir, 0755)

			if _, err := os.Stat(filepath.Join("vendor", path)); err == nil {
				files, err := ioutil.ReadDir(src)
				if err != nil {
					panic(err)
				}

				for _, f := range files {
					os.Symlink(filepath.Join(src, f.Name()), filepath.Join("vendor", path, f.Name()))
				}

				continue
			}

			// If the file doesn't already exist, just create a simple symlink
			err := os.Symlink(src, filepath.Join("vendor", path))
			if err != nil {
				panic(err)
			}

		}
	}

}
