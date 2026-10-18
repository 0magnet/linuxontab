// gonet exercises real sockets from a GOOS=wasip1 Go program on LinuxOnTab.
package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"time"
)

func check(name string, err error) {
	if err != nil {
		fmt.Printf("%s: FAIL %v\n", name, err)
	}
}

func main() {
	// TCP loopback
	ln, err := net.Listen("tcp", "127.0.0.1:7070")
	check("listen", err)
	if err == nil {
		fmt.Println("listening on", ln.Addr())
		go func() {
			c, err := ln.Accept()
			check("accept", err)
			if err != nil {
				return
			}
			fmt.Println("server: accepted", c.RemoteAddr(), "->", c.LocalAddr())
			line, _ := bufio.NewReader(c).ReadString('\n')
			fmt.Fprintf(c, "echo: %s", line)
			c.Close()
		}()
		c, err := net.DialTimeout("tcp", "127.0.0.1:7070", 5*time.Second)
		check("dial", err)
		if err == nil {
			fmt.Println("client:", c.LocalAddr(), "->", c.RemoteAddr())
			fmt.Fprintf(c, "hello over tcp\n")
			b, err := io.ReadAll(c)
			fmt.Printf("client got %q %v\n", b, err)
			c.Close()
		}
	}
	// UDP
	u, err := net.ListenPacket("udp", "127.0.0.1:7071")
	check("udp listen", err)
	if err == nil {
		s, err := net.Dial("udp", "127.0.0.1:7071")
		check("udp dial", err)
		if err == nil {
			s.Write([]byte("ping over udp"))
			buf := make([]byte, 100)
			u.SetReadDeadline(time.Now().Add(3 * time.Second))
			n, from, err := u.ReadFrom(buf)
			fmt.Printf("udp got %q from %v %v\n", buf[:n], from, err)
		}
	}
	// refused + timeout
	_, err = net.DialTimeout("tcp", "127.0.0.1:1", 2*time.Second)
	fmt.Println("dial closed port:", err)
	if len(os.Args) > 1 && os.Args[1] == "local" {
		return
	}
	// DNS + HTTPS
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	addrs, err := net.DefaultResolver.LookupHost(ctx, "example.com")
	fmt.Println("lookup example.com:", addrs, err)
	url := "https://example.com/"
	if len(os.Args) > 1 {
		url = os.Args[1]
	}
	t0 := time.Now()
	req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		fmt.Println("GET:", err)
		return
	}
	body, err := io.ReadAll(resp.Body)
	fmt.Printf("GET %s: %s, %d bytes in %v (%v)\n", url, resp.Status, len(body), time.Since(t0).Round(time.Millisecond), err)
}
