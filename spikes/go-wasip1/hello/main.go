// gohello exercises the WASI bridge from a GOOS=wasip1 Go program.
package main

import (
	"fmt"
	"os"
	"sync"
	"time"
)

func main() {
	fmt.Println("args:", os.Args)
	wd, _ := os.Getwd()
	fmt.Println("cwd:", wd, "PWD:", os.Getenv("PWD"), "HOME:", os.Getenv("HOME"))
	fmt.Println("now:", time.Now().Format(time.RFC3339))
	if b, err := os.ReadFile("/etc/hostname"); err == nil {
		fmt.Printf("hostname: %q\n", b)
	} else {
		fmt.Println("read /etc/hostname:", err)
	}
	ents, err := os.ReadDir("/")
	fmt.Print("ls /: ")
	for _, e := range ents {
		fmt.Print(e.Name(), " ")
	}
	fmt.Println(err)
	f := "/tmp/gohello.txt"
	if err := os.WriteFile(f, []byte("hello from go\n"), 0644); err != nil {
		fmt.Println("write:", err)
	}
	st, err := os.Stat(f)
	if err == nil {
		fmt.Println("stat:", st.Name(), st.Size(), st.Mode(), st.ModTime().Format(time.Kitchen))
	} else {
		fmt.Println("stat:", err)
	}
	os.Rename(f, f+".2")
	b, err := os.ReadFile(f + ".2")
	fmt.Printf("renamed: %q %v\n", b, err)
	fmt.Println("remove:", os.Remove(f+".2"))
	t0 := time.Now()
	var wg sync.WaitGroup
	for i := 0; i < 3; i++ {
		wg.Add(1)
		go func(i int) { defer wg.Done(); time.Sleep(time.Duration(100*(i+1)) * time.Millisecond) }(i)
	}
	wg.Wait()
	fmt.Println("goroutines slept:", time.Since(t0).Round(10*time.Millisecond))
	os.Exit(3)
}
