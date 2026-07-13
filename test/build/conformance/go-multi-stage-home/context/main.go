package main

import (
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"syscall"
)

//go:embed message.txt
var message string

type scanRecord struct {
	Path          string            `json:"path"`
	Type          string            `json:"type"`
	Mode          *string           `json:"mode"`
	UID           *uint32           `json:"uid"`
	GID           *uint32           `json:"gid"`
	Size          *int64            `json:"size"`
	ContentDigest *string           `json:"content_digest"`
	Link          *string           `json:"link"`
	MtimeNS       *int64            `json:"mtime_ns"`
	HardlinkTo    *string           `json:"hardlink_to"`
	Xattrs        map[string]string `json:"xattrs"`
}

func scan(path string) (scanRecord, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return scanRecord{}, err
	}
	stat := info.Sys().(*syscall.Stat_t)
	mode := fmt.Sprintf("%04o", info.Mode().Perm())
	uid, gid := stat.Uid, stat.Gid
	size := info.Size()
	mtimeNS := stat.Mtim.Sec*1_000_000_000 + stat.Mtim.Nsec

	file, err := os.Open(path)
	if err != nil {
		return scanRecord{}, err
	}
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		file.Close()
		return scanRecord{}, err
	}
	if err := file.Close(); err != nil {
		return scanRecord{}, err
	}
	contentDigest := "sha256:" + hex.EncodeToString(digest.Sum(nil))

	return scanRecord{
		Path:          path,
		Type:          "file",
		Mode:          &mode,
		UID:           &uid,
		GID:           &gid,
		Size:          &size,
		ContentDigest: &contentDigest,
		MtimeNS:       &mtimeNS,
		Xattrs:        map[string]string{},
	}, nil
}

func main() {
	if len(os.Args) == 1 {
		fmt.Println(strings.TrimSpace(message))
		return
	}

	paths := append([]string(nil), os.Args[1:]...)
	sort.Strings(paths)
	encoder := json.NewEncoder(os.Stdout)
	for _, path := range paths {
		record, err := scan(path)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		if err := encoder.Encode(record); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
}
