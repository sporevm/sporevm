package spore

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestBuildInfo(t *testing.T) {
	info, err := Build()
	if err != nil {
		t.Fatal(err)
	}
	if info.Version == "" {
		t.Fatal("empty version")
	}
	if info.ABIVersion < minABIVersion {
		t.Fatalf("ABI version %d < %d", info.ABIVersion, minABIVersion)
	}
}

func TestClientHostInfo(t *testing.T) {
	client, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	info, err := client.HostInfo(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if info.Schema != "spore.host-info.v1" {
		t.Fatalf("schema = %q", info.Schema)
	}
	if len(info.Backends) == 0 {
		t.Fatal("expected backend facts")
	}
}

func TestInspectBundle(t *testing.T) {
	client, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	dir := writeInspectBundleFixture(t)
	result, err := client.InspectBundle(context.Background(), InspectBundleOptions{
		Source:  dir,
		ChildID: "1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.Schema != "spore.bundle.inspect.v1" {
		t.Fatalf("schema = %q", result.Schema)
	}
	if !result.Indexed {
		t.Fatal("expected indexed bundle")
	}
	if result.Selection.Kind != "child" || result.Selection.SelectedCount != 1 {
		t.Fatalf("selection = %#v", result.Selection)
	}
	if got := result.Selection.Children[0].ID; got != "000001" {
		t.Fatalf("selected child = %q", got)
	}
}

func TestPull(t *testing.T) {
	client, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	dir := writeInspectBundleFixture(t)
	outDir := filepath.Join(t.TempDir(), "pulled.spore")
	result, err := client.Pull(context.Background(), PullOptions{
		Source:      "file://" + dir,
		OutDir:      outDir,
		RootfsCache: CacheRoot{Kind: CacheRootNone},
		BundleCache: CacheRoot{Kind: CacheRootNone},
		ChildID:     "1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.Schema != "spore.pull.result.v1" {
		t.Fatalf("schema = %q", result.Schema)
	}
	if result.OutDir != outDir {
		t.Fatalf("out_dir = %q", result.OutDir)
	}
	if result.Children.SelectedChild == nil || *result.Children.SelectedChild != "000001" {
		t.Fatalf("selected child = %#v", result.Children.SelectedChild)
	}
	if result.Materialization.ChunkCount != 1 || result.Materialization.MaterializedChunkCount != 0 {
		t.Fatalf("materialization = %#v", result.Materialization)
	}
	if _, err := os.Stat(filepath.Join(outDir, "manifest.json")); err != nil {
		t.Fatalf("expected pulled manifest: %v", err)
	}
}

func writeInspectBundleFixture(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	mustMkdir(t, filepath.Join(dir, "chunkpacks"))
	mustMkdir(t, filepath.Join(dir, "manifests", "children"))
	mustWrite(t, filepath.Join(dir, "chunkpacks", "000000.pack"), "")
	mustWrite(t, filepath.Join(dir, "chunkpack.index.json"), `{"version":0,"chunk_size":2097152,"chunks":[]}`)
	mustWrite(t, filepath.Join(dir, "bundle.json"), `{"version":0,"parent_manifest":"manifests/parent.json","children":[{"id":"000001","manifest":"manifests/children/000001.json"}],"chunkpack_index":"chunkpack.index.json","rootfs_index":null}`)
	mustWrite(t, filepath.Join(dir, "manifests", "parent.json"), tinyManifest)
	mustWrite(t, filepath.Join(dir, "manifests", "children", "000001.json"), tinyManifest)
	return dir
}

func mustMkdir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
}

func mustWrite(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
		t.Fatal(err)
	}
}

const tinyManifest = `{
  "version": 0,
  "platform": {
    "arch": "aarch64",
    "cpu_profile": "sporevm-aarch64-v0",
    "device_model_version": 4,
    "ram_base": 2147483648,
    "ram_size": 1,
    "gic_dist_base": 134217728,
    "gic_redist_base": 134283264,
    "counter_frequency_hz": 24000000
  },
  "machine": {
    "gprs": [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
    "pc": 0,
    "cpsr": 0,
    "fpcr": 0,
    "fpsr": 0,
    "simd": [[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0],[0,0]],
    "sys_regs": [],
    "icc_regs": [],
    "vtimer": {"cntvct":0,"cntv_ctl":0,"cntv_cval":0},
    "gic": {"kind":"gicv3","gicv3":{"schema_version":0,"dist_regs":[{"offset":24832,"width_bits":64,"value":0}],"redist_regs":[{"offset":65664,"width_bits":32,"value":0}],"line_levels":[{"intid":16,"asserted":false}]}}
  },
  "devices": [],
  "generation": {"generation":0,"interrupt_status":0,"params_b64":""},
  "rootfs": null,
  "disk": null,
  "network": null,
  "memory": {"chunk_size":2097152,"chunks":[null],"backing":null}
}`
