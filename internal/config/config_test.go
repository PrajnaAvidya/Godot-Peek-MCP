package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDisabled_EmptyConfig(t *testing.T) {
	cfg := &Config{}
	cfg.buildSet()

	if cfg.Disabled("run_main_scene") {
		t.Error("expected run_main_scene to be enabled (not disabled)")
	}
	if cfg.Disabled("nonexistent") {
		t.Error("expected nonexistent tool to be enabled")
	}
}

func TestDisabled_WithTools(t *testing.T) {
	cfg := &Config{
		DisabledTools: []string{"run_main_scene", "stop_scene"},
	}
	cfg.buildSet()

	if !cfg.Disabled("run_main_scene") {
		t.Error("expected run_main_scene to be disabled")
	}
	if !cfg.Disabled("stop_scene") {
		t.Error("expected stop_scene to be disabled")
	}
	if cfg.Disabled("get_output") {
		t.Error("expected get_output to be enabled")
	}
}

func TestMerge_ProjectOverridesGlobal(t *testing.T) {
	global := Config{DisabledTools: []string{"a", "b"}}
	project := Config{DisabledTools: []string{"c"}}

	merge(project, &global)

	if len(global.DisabledTools) != 1 || global.DisabledTools[0] != "c" {
		t.Errorf("expected project to replace global, got %v", global.DisabledTools)
	}
}

func TestMerge_ProjectEmptySlice(t *testing.T) {
	global := Config{DisabledTools: []string{"a", "b"}}
	project := Config{DisabledTools: []string{}}

	merge(project, &global)

	if len(global.DisabledTools) != 0 {
		t.Errorf("expected empty slice to override, got %v", global.DisabledTools)
	}
}

func TestMerge_NoProjectOverrides(t *testing.T) {
	global := Config{DisabledTools: []string{"a", "b"}}
	project := Config{} // nil DisabledTools

	merge(project, &global)

	if len(global.DisabledTools) != 2 {
		t.Errorf("expected global to be preserved, got %v", global.DisabledTools)
	}
}

func TestLoad_NoConfigFiles(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(dir, "nonexistent"))

	cfg, err := Load(dir)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if cfg.Disabled("any_tool") {
		t.Error("expected no tools disabled when no config files exist")
	}
}

func TestLoad_ProjectConfigOnly(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(dir, "nonexistent"))

	projectJSON := `{"disabled_tools": ["stop_scene", "restart_scene"]}`
	if err := os.WriteFile(filepath.Join(dir, ".godot-peek-mcp.json"), []byte(projectJSON), 0o644); err != nil {
		t.Fatalf("write project config: %v", err)
	}

	cfg, err := Load(dir)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}

	if !cfg.Disabled("stop_scene") {
		t.Error("expected stop_scene to be disabled")
	}
	if !cfg.Disabled("restart_scene") {
		t.Error("expected restart_scene to be disabled")
	}
	if cfg.Disabled("get_output") {
		t.Error("expected get_output to be enabled")
	}
}

func TestLoad_GlobalAndProject_Merge(t *testing.T) {
	dir := t.TempDir()
	configHome := filepath.Join(dir, "config")

	// create global config
	globalDir := filepath.Join(configHome, "godot-peek-mcp")
	if err := os.MkdirAll(globalDir, 0o755); err != nil {
		t.Fatalf("mkdir global: %v", err)
	}
	globalJSON := `{"disabled_tools": ["run_main_scene", "run_scene", "run_current_scene"]}`
	if err := os.WriteFile(filepath.Join(globalDir, "config.json"), []byte(globalJSON), 0o644); err != nil {
		t.Fatalf("write global config: %v", err)
	}

	// create project config that overrides (re-enables run_current_scene, disables extra)
	projectDir := filepath.Join(dir, "project")
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatalf("mkdir project: %v", err)
	}
	projectJSON := `{"disabled_tools": ["run_main_scene", "stop_scene"]}`
	if err := os.WriteFile(filepath.Join(projectDir, ".godot-peek-mcp.json"), []byte(projectJSON), 0o644); err != nil {
		t.Fatalf("write project config: %v", err)
	}

	t.Setenv("XDG_CONFIG_HOME", configHome)

	cfg, err := Load(projectDir)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}

	// project config replaces global, so only its tools should be disabled
	if !cfg.Disabled("run_main_scene") {
		t.Error("expected run_main_scene to be disabled")
	}
	if !cfg.Disabled("stop_scene") {
		t.Error("expected stop_scene to be disabled")
	}
	if cfg.Disabled("run_scene") {
		t.Error("expected run_scene to be re-enabled (project overrides global)")
	}
	if cfg.Disabled("run_current_scene") {
		t.Error("expected run_current_scene to be re-enabled (project overrides global)")
	}
}

func TestLoad_InvalidJSON(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(dir, "nonexistent"))

	projectJSON := `{bad json`
	if err := os.WriteFile(filepath.Join(dir, ".godot-peek-mcp.json"), []byte(projectJSON), 0o644); err != nil {
		t.Fatalf("write project config: %v", err)
	}

	cfg, err := Load(dir)
	if err != nil {
		t.Fatalf("expected no error (bad json should warn, not fail), got %v", err)
	}
	if cfg.Disabled("any_tool") {
		t.Error("expected no tools disabled when config parse fails")
	}
}

func TestBuildSet_NoDuplicates(t *testing.T) {
	cfg := &Config{
		DisabledTools: []string{"a", "b", "c"},
	}
	cfg.buildSet()

	if len(cfg.disabledSet) != 3 {
		t.Errorf("expected 3 entries, got %d", len(cfg.disabledSet))
	}
}
