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

func TestNamedLifecycleOptionsCarryBoundServices(t *testing.T) {
	create := CreateNamedOptions{
		Name:           "worker",
		NetworkEnabled: true,
		NetworkRules: []NetworkRule{{
			Host:  "github.com",
			Ports: []uint16{443},
		}},
		BoundServices: []BoundUnixService{{
			Name:      "cleanroom-gateway",
			GuestHost: "gateway.cleanroom.internal",
			GuestPort: 8170,
			UnixPath:  "/tmp/cleanroom-gateway.sock",
		}},
	}
	if !create.NetworkEnabled {
		t.Fatal("expected network enabled")
	}
	if got := create.BoundServices[0].UnixPath; got != "/tmp/cleanroom-gateway.sock" {
		t.Fatalf("bound service path = %q", got)
	}

	resume := ResumeNamedOptions{
		SporeDir: "worker.spore",
		Name:     "worker-resumed",
		BoundServiceBindings: []BoundUnixServiceBinding{{
			Name:     "cleanroom-gateway",
			UnixPath: "/tmp/fresh-cleanroom-gateway.sock",
		}},
	}
	if got := resume.BoundServiceBindings[0].UnixPath; got != "/tmp/fresh-cleanroom-gateway.sock" {
		t.Fatalf("resume binding path = %q", got)
	}
}

func TestExecNamedArgvMarshaling(t *testing.T) {
	argv, freeArgv := cStringList([]string{"/bin/echo", "hello world"})
	defer freeArgv()

	if len(argv) != 2 {
		t.Fatalf("argv len = %d", len(argv))
	}
	if got := goString(argv[0]); got != "/bin/echo" {
		t.Fatalf("argv[0] = %q", got)
	}
	if got := goString(argv[1]); got != "hello world" {
		t.Fatalf("argv[1] = %q", got)
	}
}

func TestDecodeExecNamedResult(t *testing.T) {
	result, err := decodeJSON[ExecNamedResult]([]byte(`{
		"exit_code": 7,
		"stdout": "ok\n",
		"stderr": "err\n",
		"network_events_jsonl": "{\"event\":\"network_decision\"}\n",
		"stdout_truncated": false,
		"stderr_truncated": true
	}`), "exec named result")
	if err != nil {
		t.Fatal(err)
	}
	if result.ExitCode != 7 {
		t.Fatalf("exit code = %d", result.ExitCode)
	}
	if result.Stdout != "ok\n" {
		t.Fatalf("stdout = %q", result.Stdout)
	}
	if result.Stderr != "err\n" {
		t.Fatalf("stderr = %q", result.Stderr)
	}
	if result.NetworkEventsJSONL != "{\"event\":\"network_decision\"}\n" {
		t.Fatalf("network events = %q", result.NetworkEventsJSONL)
	}
	if result.StdoutTruncated {
		t.Fatal("stdout unexpectedly truncated")
	}
	if !result.StderrTruncated {
		t.Fatal("stderr truncation not decoded")
	}

	binary, err := decodeJSON[ExecNamedResult]([]byte(`{
		"exit_code": 0,
		"stdout": [255, 0, 65],
		"stderr": [],
		"network_events_jsonl": "",
		"stdout_truncated": false,
		"stderr_truncated": false
	}`), "exec named result")
	if err != nil {
		t.Fatal(err)
	}
	if binary.Stdout != string([]byte{255, 0, 65}) {
		t.Fatalf("binary stdout = %q", binary.Stdout)
	}
}

func TestDecodeNamedList(t *testing.T) {
	entries, err := decodeJSON[[]NamedListEntry]([]byte(`[
		{
			"name": "worker",
			"state": "ready",
			"pid": 42,
			"memory": {"policy": "auto", "bytes": 17179869184},
			"stats": {
				"resident_bytes": 4096,
				"backing_logical_bytes": null,
				"backing_allocated_bytes": null,
				"chunk_size": 2097152,
				"chunks_total": 8,
				"chunks_nonzero": 1,
				"dirty_chunks_pending": 0
			}
		}
	]`), "named list")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("entry count = %d", len(entries))
	}
	entry := entries[0]
	if entry.Name != "worker" || entry.State != "ready" {
		t.Fatalf("entry = %#v", entry)
	}
	if entry.PID == nil || *entry.PID != 42 {
		t.Fatalf("pid = %#v", entry.PID)
	}
	if entry.Memory == nil || entry.Memory.Policy != "auto" || entry.Memory.Bytes != 17179869184 {
		t.Fatalf("memory = %#v", entry.Memory)
	}
	if entry.Stats.ResidentBytes == nil || *entry.Stats.ResidentBytes != 4096 {
		t.Fatalf("resident bytes = %#v", entry.Stats.ResidentBytes)
	}
	if entry.Stats.DirtyChunksPending == nil || *entry.Stats.DirtyChunksPending != 0 {
		t.Fatalf("dirty chunks = %#v", entry.Stats.DirtyChunksPending)
	}
}

func TestListNamedEmptyRuntime(t *testing.T) {
	client, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	runtimeDir := filepath.Join(t.TempDir(), "runtime")
	if err := os.Mkdir(runtimeDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := client.SetEnv(context.Background(), "SPOREVM_RUNTIME_DIR", runtimeDir); err != nil {
		t.Fatal(err)
	}
	entries, err := client.ListNamed(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("entries = %#v", entries)
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
