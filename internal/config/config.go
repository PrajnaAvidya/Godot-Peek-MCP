package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

type Config struct {
	DisabledTools []string `json:"disabled_tools"`

	// fast lookup built from DisabledTools after loading
	disabledSet map[string]bool
}

func Load(projectDir string) (*Config, error) {
	var cfg Config

	homeConfigDir, err := os.UserConfigDir()
	if err == nil {
		globalPath := filepath.Join(homeConfigDir, "godot-peek-mcp", "config.json")
		loadFile(globalPath, &cfg)
	}

	projectPath := filepath.Join(projectDir, ".godot-peek-mcp.json")
	loadFile(projectPath, &cfg)

	cfg.buildSet()
	return &cfg, nil
}

func (c *Config) Disabled(name string) bool {
	return c.disabledSet[name]
}

func (c *Config) buildSet() {
	c.disabledSet = make(map[string]bool, len(c.DisabledTools))
	for _, name := range c.DisabledTools {
		c.disabledSet[name] = true
	}
}

func loadFile(path string, cfg *Config) {
	data, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			fmt.Fprintf(os.Stderr, "warning: reading config %s: %v\n", path, err)
		}
		return
	}

	var fileCfg Config
	if err := json.Unmarshal(data, &fileCfg); err != nil {
		fmt.Fprintf(os.Stderr, "warning: parsing config %s: %v\n", path, err)
		return
	}

	merge(fileCfg, cfg)
}

// merge applies fileCfg on top of base (fileCfg fields replace base fields)
func merge(fileCfg Config, cfg *Config) {
	if fileCfg.DisabledTools != nil {
		cfg.DisabledTools = fileCfg.DisabledTools
	}
}
