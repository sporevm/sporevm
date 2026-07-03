package spore

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"unsafe"
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

func TestClientNetworkCapabilities(t *testing.T) {
	client, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	caps, err := client.NetworkCapabilities(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !caps.Supported {
		t.Fatal("network support unexpectedly disabled")
	}
	if !caps.TCPIPv4 {
		t.Fatal("expected TCP IPv4 support")
	}
	if caps.TCPIPv6 {
		t.Fatal("TCP IPv6 unexpectedly supported")
	}
	if !caps.UDPDNS {
		t.Fatal("expected UDP DNS support")
	}
	if !caps.ExactHostPort {
		t.Fatal("expected exact host/port support")
	}
	if caps.StagePolicyUpdate {
		t.Fatal("stage policy updates unexpectedly supported")
	}
	if !caps.BoundServices {
		t.Fatal("expected bound service support")
	}
	if !caps.DecisionEvents {
		t.Fatal("expected decision event support")
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

func TestInspectSporeAnnotations(t *testing.T) {
	client, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	dir := writeSporeFixture(t, map[string]string{
		"cleanroom.workspace":  "/workspaces/app",
		"cleanroom.provenance": "sha256:abc123",
	})
	result, err := client.InspectSpore(context.Background(), InspectSporeOptions{SporeDir: dir})
	if err != nil {
		t.Fatal(err)
	}
	if got := result.Annotations["cleanroom.workspace"]; got != "/workspaces/app" {
		t.Fatalf("cleanroom.workspace = %q", got)
	}
	if got := result.Annotations["cleanroom.provenance"]; got != "sha256:abc123" {
		t.Fatalf("cleanroom.provenance = %q", got)
	}
	if len(result.AnnotationKeys) != 2 {
		t.Fatalf("annotation keys = %#v", result.AnnotationKeys)
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

func TestSporeExecutableOptionDefaults(t *testing.T) {
	if got := sporeExecutableOption(""); got != "spore" {
		t.Fatalf("default spore executable = %q", got)
	}
	if got := sporeExecutableOption("/tmp/spore"); got != "/tmp/spore" {
		t.Fatalf("explicit spore executable = %q", got)
	}
}

func TestCreateNamedNetworkMarshaling(t *testing.T) {
	allowCIDRs, freeAllowCIDRs := cStringList([]string{"93.184.216.34/32"})
	defer freeAllowCIDRs()
	allowHosts, freeAllowHosts := cStringList([]string{"example.com"})
	defer freeAllowHosts()
	rules, freeRules := cNetworkRules([]NetworkRule{{
		Host:  "github.com",
		Ports: []uint16{443, 8443},
	}})
	defer freeRules()
	services, freeServices := cBoundUnixServices([]BoundUnixService{{
		Name:      "cleanroom-gateway",
		GuestHost: "gateway.cleanroom.internal",
		GuestPort: 8170,
		UnixPath:  "/tmp/cleanroom-gateway.sock",
	}})
	defer freeServices()

	if got := goString(allowCIDRs[0]); got != "93.184.216.34/32" {
		t.Fatalf("allow cidr = %q", got)
	}
	if got := goString(allowHosts[0]); got != "example.com" {
		t.Fatalf("allow host = %q", got)
	}
	if got := goString(rules[0].host); got != "github.com" {
		t.Fatalf("rule host = %q", got)
	}
	if got := int(rules[0].port_count); got != 2 {
		t.Fatalf("rule port count = %d", got)
	}
	ports := unsafe.Slice(rules[0].ports, int(rules[0].port_count))
	if uint16(ports[0]) != 443 || uint16(ports[1]) != 8443 {
		t.Fatalf("rule ports = [%d %d]", ports[0], ports[1])
	}
	if got := goString(services[0].name); got != "cleanroom-gateway" {
		t.Fatalf("service name = %q", got)
	}
	if got := goString(services[0].guest_host); got != "gateway.cleanroom.internal" {
		t.Fatalf("service guest host = %q", got)
	}
	if got := uint16(services[0].guest_port); got != 8170 {
		t.Fatalf("service guest port = %d", got)
	}
	if got := goString(services[0].unix_path); got != "/tmp/cleanroom-gateway.sock" {
		t.Fatalf("service unix path = %q", got)
	}
}

func TestCreateNamedNetworkingFailsClosedWhenDisabled(t *testing.T) {
	client, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if !supportsNamedLifecycle(t, client) {
		t.Skip("named lifecycle backend is not supported on this host")
	}

	tests := []struct {
		name    string
		options CreateNamedOptions
	}{
		{
			name: "allow cidr",
			options: CreateNamedOptions{
				AllowCIDRs: []string{"93.184.216.34/32"},
			},
		},
		{
			name: "allow host",
			options: CreateNamedOptions{
				AllowHosts: []string{"example.com"},
			},
		},
		{
			name: "exact host port",
			options: CreateNamedOptions{
				NetworkRules: []NetworkRule{{
					Host:  "github.com",
					Ports: []uint16{443},
				}},
			},
		},
		{
			name: "bound service",
			options: CreateNamedOptions{
				BoundServices: []BoundUnixService{{
					Name:      "metadata",
					GuestHost: "metadata.spore.internal",
					GuestPort: 80,
					UnixPath:  "/tmp/metadata.sock",
				}},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := client.CreateNamed(context.Background(), tt.options)
			if err == nil {
				t.Fatal("expected create to reject disabled networking with policy")
			}
			var callErr *CallError
			if !errors.As(err, &callErr) {
				t.Fatalf("expected CallError, got %T: %v", err, err)
			}
			if callErr.Message != "InvalidNetworkPolicy" {
				t.Fatalf("error message = %q", callErr.Message)
			}
		})
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

func TestCopyNamedOptions(t *testing.T) {
	options := CopyNamedOptions{
		Name:      "worker",
		HostPath:  "/tmp/host.txt",
		GuestPath: "/tmp/guest.txt",
	}
	if options.Name != "worker" || options.HostPath == "" || options.GuestPath == "" {
		t.Fatalf("copy options = %#v", options)
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

func TestExecNamedStreamFakeMonitor(t *testing.T) {
	client, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	baseDir, err := os.MkdirTemp("/tmp", "spore-go-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(baseDir)
	runtimeDir := filepath.Join(baseDir, "runtime")
	vmDir := filepath.Join(runtimeDir, "vms", "stream-box")
	mustMkdirMode(t, runtimeDir, 0o700)
	mustMkdirMode(t, filepath.Join(runtimeDir, "vms"), 0o700)
	mustMkdirMode(t, vmDir, 0o700)
	controlSocket := filepath.Join(vmDir, "control.sock")
	consoleLog := filepath.Join(vmDir, "console.log")
	mustWrite(t, filepath.Join(vmDir, "spec.json"), `{"name":"stream-box"}`)
	mustWrite(t, filepath.Join(vmDir, "ready.json"), `{"pid":`+strconv.Itoa(os.Getpid())+`,"control_socket_path":`+jsonString(t, controlSocket)+`,"console_log_path":`+jsonString(t, consoleLog)+`}`)
	mustWrite(t, filepath.Join(vmDir, "pid"), strconv.Itoa(os.Getpid())+"\n")

	listener, err := net.Listen("unix", controlSocket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	serverDone := make(chan error, 1)
	go func() {
		serverDone <- serveExecStreamFakeMonitor(listener)
	}()

	if err := client.SetEnv(context.Background(), "SPOREVM_RUNTIME_DIR", runtimeDir); err != nil {
		t.Fatal(err)
	}
	stream, err := client.OpenExecNamedStream(context.Background(), ExecNamedStreamOptions{
		Name:         "stream-box",
		Argv:         []string{"/bin/sh"},
		Interactive:  true,
		TTY:          true,
		TerminalName: "xterm-256color",
		TerminalRows: 40,
		TerminalCols: 120,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()

	if err := stream.WriteTerminal(context.Background(), []byte("hi")); err != nil {
		t.Fatal(err)
	}
	if err := stream.ResizeTerminal(context.Background(), 50, 100); err != nil {
		t.Fatal(err)
	}
	if err := stream.CloseTerminal(context.Background()); err != nil {
		t.Fatal(err)
	}

	event, err := stream.Next(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if event.Type != ExecNamedStreamTerminal || string(event.Bytes) != "pong" {
		t.Fatalf("terminal event = %#v", event)
	}
	event, err = stream.Next(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if event.Type != ExecNamedStreamExit || event.ExitCode != 7 {
		t.Fatalf("exit event = %#v", event)
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
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

const (
	spioHeaderLen       = 24
	spioMaxPayload      = 4096
	spioData       byte = 1
	spioClose      byte = 2
	spioExit       byte = 3
	spioResize     byte = 4
	spioControl         = 0
	spioTerminal        = 4
)

type spioFrame struct {
	Type     byte
	StreamID uint32
	Offset   uint64
	Payload  []byte
}

func serveExecStreamFakeMonitor(listener net.Listener) error {
	conn, err := listener.Accept()
	if err != nil {
		return err
	}
	defer conn.Close()

	reader := bufio.NewReader(conn)
	requestLine, err := reader.ReadBytes('\n')
	if err != nil {
		return err
	}
	var request struct {
		Type         string   `json:"type"`
		Argv         []string `json:"argv"`
		Stdio        string   `json:"stdio"`
		Interactive  bool     `json:"interactive"`
		Term         string   `json:"term"`
		TerminalRows uint16   `json:"terminal_rows"`
		TerminalCols uint16   `json:"terminal_cols"`
	}
	if err := json.Unmarshal(requestLine, &request); err != nil {
		return err
	}
	if request.Type != "exec-stream-v1" || request.Stdio != "tty" || !request.Interactive {
		return fmt.Errorf("bad stream request: %#v", request)
	}
	if len(request.Argv) != 1 || request.Argv[0] != "/bin/sh" {
		return fmt.Errorf("bad argv: %#v", request.Argv)
	}
	if request.Term != "xterm-256color" || request.TerminalRows != 40 || request.TerminalCols != 120 {
		return fmt.Errorf("bad terminal metadata: %#v", request)
	}

	frame, err := readSPIOFrame(reader)
	if err != nil {
		return err
	}
	if frame.Type != spioData || frame.StreamID != spioTerminal || frame.Offset != 0 || string(frame.Payload) != "hi" {
		return fmt.Errorf("bad terminal data frame: %#v", frame)
	}
	frame, err = readSPIOFrame(reader)
	if err != nil {
		return err
	}
	if frame.Type != spioResize || frame.StreamID != spioTerminal || frame.Offset != 0 || len(frame.Payload) != 4 ||
		binary.LittleEndian.Uint16(frame.Payload[0:2]) != 50 || binary.LittleEndian.Uint16(frame.Payload[2:4]) != 100 {
		return fmt.Errorf("bad resize frame: %#v", frame)
	}
	frame, err = readSPIOFrame(reader)
	if err != nil {
		return err
	}
	if frame.Type != spioClose || frame.StreamID != spioTerminal || frame.Offset != 2 || len(frame.Payload) != 0 {
		return fmt.Errorf("bad terminal close frame: %#v", frame)
	}

	if err := writeSPIOFrame(conn, spioData, spioTerminal, 0, []byte("pong")); err != nil {
		return err
	}
	var exitPayload [4]byte
	binary.LittleEndian.PutUint32(exitPayload[:], 7)
	return writeSPIOFrame(conn, spioExit, spioControl, 0, exitPayload[:])
}

func readSPIOFrame(reader io.Reader) (spioFrame, error) {
	var header [spioHeaderLen]byte
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		return spioFrame{}, err
	}
	if string(header[0:4]) != "SPIO" || header[4] != 1 {
		return spioFrame{}, fmt.Errorf("bad spio header: %q", header[0:5])
	}
	if flags := binary.LittleEndian.Uint16(header[6:8]); flags != 0 {
		return spioFrame{}, fmt.Errorf("bad spio flags: %d", flags)
	}
	payloadLen := binary.LittleEndian.Uint32(header[20:24])
	if payloadLen > spioMaxPayload {
		return spioFrame{}, fmt.Errorf("payload too large: %d", payloadLen)
	}
	payload := make([]byte, payloadLen)
	if payloadLen != 0 {
		if _, err := io.ReadFull(reader, payload); err != nil {
			return spioFrame{}, err
		}
	}
	return spioFrame{
		Type:     header[5],
		StreamID: binary.LittleEndian.Uint32(header[8:12]),
		Offset:   binary.LittleEndian.Uint64(header[12:20]),
		Payload:  payload,
	}, nil
}

func writeSPIOFrame(writer io.Writer, typ byte, streamID uint32, offset uint64, payload []byte) error {
	if len(payload) > spioMaxPayload {
		return fmt.Errorf("payload too large: %d", len(payload))
	}
	var header [spioHeaderLen]byte
	copy(header[0:4], "SPIO")
	header[4] = 1
	header[5] = typ
	binary.LittleEndian.PutUint32(header[8:12], streamID)
	binary.LittleEndian.PutUint64(header[12:20], offset)
	binary.LittleEndian.PutUint32(header[20:24], uint32(len(payload)))
	if _, err := writer.Write(header[:]); err != nil {
		return err
	}
	if len(payload) != 0 {
		_, err := writer.Write(payload)
		return err
	}
	return nil
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

func writeSporeFixture(t *testing.T, annotations map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	annotationJSON, err := json.Marshal(annotations)
	if err != nil {
		t.Fatal(err)
	}
	manifest := strings.Replace(tinyManifest, `  "platform": {`, `  "annotations": `+string(annotationJSON)+","+"\n"+`  "platform": {`, 1)
	mustWrite(t, filepath.Join(dir, "manifest.json"), manifest)
	return dir
}

func mustMkdir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
}

func mustMkdirMode(t *testing.T, path string, mode os.FileMode) {
	t.Helper()
	if err := os.Mkdir(path, mode); err != nil {
		t.Fatal(err)
	}
}

func mustWrite(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
		t.Fatal(err)
	}
}

func jsonString(t *testing.T, value string) string {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func supportsNamedLifecycle(t *testing.T, client *Client) bool {
	t.Helper()
	info, err := client.HostInfo(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, backend := range info.Backends {
		if backend.Supported && (backend.Name == "hvf" || backend.Name == "kvm") {
			return true
		}
	}
	return false
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
