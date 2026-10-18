// tcplong keeps one TCP connection to an echo server open and round-trips a
// line every 10 s (or the interval given as the second argument): checks long-lived guest connections from a wasip1 program.
package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"time"
)

func main() {
	addr := "tcpbin.com:4242"
	if len(os.Args) > 1 {
		addr = os.Args[1]
	}
	every := 10 * time.Second
	if len(os.Args) > 2 {
		every, _ = time.ParseDuration(os.Args[2])
	}
	c, err := net.DialTimeout("tcp", addr, 15*time.Second)
	if err != nil {
		fmt.Println("dial:", err)
		os.Exit(1)
	}
	fmt.Println("connected", c.LocalAddr(), "->", c.RemoteAddr())
	r := bufio.NewReader(c)
	for i := 0; i < 6; i++ {
		t0 := time.Now()
		fmt.Fprintf(c, "ping %d %s\n", i, t0.Format(time.TimeOnly))
		c.SetReadDeadline(time.Now().Add(20 * time.Second))
		line, err := r.ReadString('\n')
		fmt.Printf("%3.0fs rtt=%v %q %v\n", (time.Duration(i) * every).Seconds(), time.Since(t0).Round(time.Millisecond), line, err)
		if err != nil {
			os.Exit(1)
		}
		time.Sleep(every)
	}
}
