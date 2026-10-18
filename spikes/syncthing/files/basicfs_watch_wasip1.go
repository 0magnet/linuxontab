// Copyright (C) 2025 The Syncthing Authors.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.

//go:build wasip1

// LinuxOnTab: filesystem watching for GOOS=wasip1 with the guest kernel's
// inotify (the notify package has no wasip1 backend). The inotify fd is
// non-blocking and read through Go's poller, so waiting for events never
// blocks the process's single thread; directories are watched one by one and
// new ones are added as they appear. Kernels built without inotify get a
// polling watcher instead: the tree is compared with its last snapshot every
// few seconds, which keeps sync latency low on the small folders a tab holds.

package fs

import (
	"context"
	"encoding/binary"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"
	"unsafe"
)

//go:wasmimport linux syscall
func inotifySyscall(nr, a0, a1, a2, a3, a4, a5 int32) int32

const (
	sysInotifyInit1    = 26
	sysInotifyAddWatch = 27

	inModify     = 0x2
	inAttrib     = 0x4
	inCloseWrite = 0x8
	inMovedFrom  = 0x40
	inMovedTo    = 0x80
	inCreate     = 0x100
	inDelete     = 0x200
	inDeleteSelf = 0x400
	inMoveSelf   = 0x800
	inQOverflow  = 0x4000
	inIgnored    = 0x8000
	inOnlydir    = 0x1000000
	inDontFollow = 0x2000000
	inIsdir      = 0x40000000

	inNonblock = 0x800
	inCloexec  = 0x80000
)

type inotifyWatch struct {
	f    *os.File
	fd   int
	mask uint32
	skip func(string) bool

	mu   sync.Mutex
	dirs map[int32]string // watch descriptor -> absolute directory
}

func (w *inotifyWatch) add(dir string) error {
	p := append([]byte(dir), 0)
	wd := inotifySyscall(sysInotifyAddWatch, int32(w.fd), int32(uintptr(unsafe.Pointer(&p[0]))), int32(w.mask|inOnlydir|inDontFollow), 0, 0, 0)
	if wd < 0 {
		return syscall.LinuxErrno(int(-wd))
	}
	w.mu.Lock()
	w.dirs[wd] = dir
	w.mu.Unlock()
	return nil
}

// addTree watches dir and every directory below it that is not ignored.
func (w *inotifyWatch) addTree(dir string) error {
	return filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			if path == dir {
				return err
			}
			return nil // vanished meanwhile, unreadable: skip
		}
		if !d.IsDir() {
			return nil
		}
		if path != dir && w.skip(path) {
			return filepath.SkipDir
		}
		if err := w.add(path); err != nil && path == dir {
			return err
		}
		return nil
	})
}

func (f *BasicFilesystem) Watch(name string, ignore Matcher, ctx context.Context, ignorePerms bool) (<-chan Event, <-chan error, error) {
	watchPath, roots, err := f.watchPaths(name)
	if err != nil {
		return nil, nil, err
	}
	watchPath = strings.TrimSuffix(watchPath, string(filepath.Separator)+"...")

	absShouldIgnore := func(absPath string) bool {
		if !utf8.ValidString(absPath) {
			return true
		}
		rel, err := f.unrootedChecked(absPath, roots)
		if err != nil {
			return true
		}
		return ignore.Match(rel).CanSkipDir()
	}

	fd := inotifySyscall(sysInotifyInit1, inNonblock|inCloexec, 0, 0, 0, 0, 0)
	if fd == -38 { // ENOSYS: kernel without inotify
		outChan := make(chan Event)
		go f.pollLoop(ctx, watchPath, name, roots, ignore, absShouldIgnore, outChan)
		return outChan, make(chan error), nil
	}
	if fd < 0 {
		return nil, nil, syscall.LinuxErrno(int(-fd))
	}
	mask := uint32(inModify | inCloseWrite | inCreate | inDelete | inDeleteSelf | inMovedFrom | inMovedTo | inMoveSelf)
	if !ignorePerms {
		mask |= inAttrib
	}
	w := &inotifyWatch{
		f:    os.NewFile(uintptr(fd), "inotify"),
		fd:   int(fd),
		mask: mask,
		skip: absShouldIgnore,
		dirs: make(map[int32]string),
	}
	if err := w.addTree(watchPath); err != nil {
		w.f.Close()
		if errors.Is(err, syscall.ENOSPC) {
			err = errors.New("failed to set up inotify handler. Please increase inotify limits, see https://docs.syncthing.net/users/faq.html#inotify-limits")
		}
		return nil, nil, err
	}

	outChan := make(chan Event)
	errChan := make(chan error)
	go func() {
		<-ctx.Done()
		w.f.Close() // ends the read below
	}()
	go f.inotifyLoop(ctx, w, name, roots, ignore, outChan)
	return outChan, errChan, nil
}

func (f *BasicFilesystem) inotifyLoop(ctx context.Context, w *inotifyWatch, name string, roots []string, ignore Matcher, outChan chan<- Event) {
	send := func(ev Event) bool {
		select {
		case outChan <- ev:
			l.Debugln(f.Type(), f.URI(), "Watch: Sending", ev.Name, ev.Type)
			return true
		case <-ctx.Done():
			return false
		}
	}
	buf := make([]byte, 64<<10)
	for {
		n, err := w.f.Read(buf)
		if err != nil {
			l.Debugln(f.Type(), f.URI(), "Watch: Stopped:", err)
			return
		}
		for off := 0; off+16 <= n; {
			wd := int32(binary.LittleEndian.Uint32(buf[off:]))
			mask := binary.LittleEndian.Uint32(buf[off+4:])
			nameLen := int(binary.LittleEndian.Uint32(buf[off+12:]))
			evName := strings.TrimRight(string(buf[off+16:off+16+nameLen]), "\x00")
			off += 16 + nameLen

			if mask&inQOverflow != 0 {
				// Events were lost: next scan covers the entire folder.
				if !send(Event{Name: name, Type: NonRemove}) {
					return
				}
				continue
			}
			w.mu.Lock()
			dir, ok := w.dirs[wd]
			if mask&inIgnored != 0 {
				delete(w.dirs, wd)
			}
			w.mu.Unlock()
			if !ok || mask&inIgnored != 0 {
				continue
			}
			path := dir
			if evName != "" {
				path = filepath.Join(dir, evName)
			}
			if mask&inIsdir != 0 && mask&(inCreate|inMovedTo) != 0 && !w.skip(path) {
				w.addTree(path)
			}
			if !utf8.ValidString(path) {
				continue
			}
			relPath, err := f.unrootedChecked(path, roots)
			if err != nil {
				continue
			}
			if ignore.Match(relPath).IsIgnored() {
				continue
			}
			evType := NonRemove
			if mask&(inDelete|inDeleteSelf|inMovedFrom|inMoveSelf) != 0 {
				evType = Remove
			}
			if !send(Event{Name: relPath, Type: evType}) {
				return
			}
		}
	}
}

// pollInterval is how often the polling watcher compares the tree.
const pollInterval = 3 * time.Second

type pollEntry struct {
	mod  int64
	size int64
	dir  bool
}

func pollSnapshot(root string, skip func(string) bool) map[string]pollEntry {
	snap := make(map[string]pollEntry)
	filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() && path != root && skip(path) {
			return filepath.SkipDir
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		snap[path] = pollEntry{mod: info.ModTime().UnixNano(), size: info.Size(), dir: d.IsDir()}
		return nil
	})
	return snap
}

func (f *BasicFilesystem) pollLoop(ctx context.Context, root, name string, roots []string, ignore Matcher, skip func(string) bool, outChan chan<- Event) {
	prev := pollSnapshot(root, skip)
	t := time.NewTicker(pollInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		cur := pollSnapshot(root, skip)
		var evs []Event
		for path, e := range cur {
			if p, ok := prev[path]; !ok || p != e {
				evs = append(evs, Event{Name: path, Type: NonRemove})
			}
		}
		for path := range prev {
			if _, ok := cur[path]; !ok {
				evs = append(evs, Event{Name: path, Type: Remove})
			}
		}
		prev = cur
		for _, ev := range evs {
			if !utf8.ValidString(ev.Name) {
				continue
			}
			rel, err := f.unrootedChecked(ev.Name, roots)
			if err != nil || ignore.Match(rel).IsIgnored() {
				continue
			}
			select {
			case outChan <- Event{Name: rel, Type: ev.Type}:
				l.Debugln(f.Type(), f.URI(), "Watch (poll): Sending", rel, ev.Type)
			case <-ctx.Done():
				return
			}
		}
	}
}
