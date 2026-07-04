package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strings"

	spore "github.com/sporevm/sporevm/bindings/go"
)

func main() {
	if err := run(context.Background()); err != nil {
		fmt.Fprintf(os.Stderr, "standalone-libspore: %v\n", err)
		os.Exit(1)
	}
}

func run(ctx context.Context) error {
	name := flag.String("name", "", "named VM name")
	backend := flag.String("backend", "auto", "SporeVM backend")
	memoryMiB := flag.Uint64("memory-mib", 256, "guest memory in MiB")
	timeoutMs := flag.Uint64("timeout-ms", 60000, "named create timeout in milliseconds")
	network := flag.Bool("network", false, "enable spore-managed networking")
	flag.Parse()

	if *name == "" {
		return fmt.Errorf("-name is required")
	}

	client, err := spore.New()
	if err != nil {
		return err
	}
	defer client.Close()
	for _, name := range []string{"HOME", "TMPDIR", "PATH", "SPOREVM_RUNTIME_DIR", "DYLD_LIBRARY_PATH", "LD_LIBRARY_PATH"} {
		if value := os.Getenv(name); value != "" {
			if err := client.SetEnv(ctx, name, value); err != nil {
				return fmt.Errorf("set %s: %w", name, err)
			}
		}
	}

	create := spore.CreateNamedOptions{
		Name:           *name,
		Backend:        *backend,
		MemoryBytes:    *memoryMiB * 1024 * 1024,
		TimeoutMs:      *timeoutMs,
		NetworkEnabled: *network,
	}
	result, err := client.CreateNamed(ctx, create)
	if err != nil {
		return fmt.Errorf("create named VM: %w", err)
	}
	created := true
	defer func() {
		if created {
			_, _ = client.RemoveNamed(context.Background(), spore.RemoveNamedOptions{Name: *name})
		}
	}()
	if result.Name != *name {
		return fmt.Errorf("created VM name = %q, want %q", result.Name, *name)
	}

	argv := []string{"/bin/writeout"}
	if *network {
		argv = []string{"/bin/true"}
	}
	execResult, err := client.ExecNamed(ctx, spore.ExecNamedOptions{
		Name: *name,
		Argv: argv,
	})
	if err != nil {
		return fmt.Errorf("exec named VM: %w", err)
	}
	if execResult.ExitCode != 0 {
		return fmt.Errorf("exec exit code = %d", execResult.ExitCode)
	}
	if !*network {
		if execResult.Stdout != "spore stdout\n" {
			return fmt.Errorf("exec stdout = %q", execResult.Stdout)
		}
		if !strings.Contains(execResult.Stderr, "spore stderr") {
			return fmt.Errorf("exec stderr = %q", execResult.Stderr)
		}
	}

	remove, err := client.RemoveNamed(ctx, spore.RemoveNamedOptions{Name: *name})
	if err != nil {
		return fmt.Errorf("remove named VM: %w", err)
	}
	created = false
	if remove.Name != *name {
		return fmt.Errorf("removed VM name = %q, want %q", remove.Name, *name)
	}

	fmt.Printf("standalone-libspore ok name=%s network=%t\n", *name, *network)
	return nil
}
