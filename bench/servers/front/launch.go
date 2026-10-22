// Command launch runs a framework behind nginx in one container: the app
// (its own entrypoint, the arguments) on 127.0.0.1:9080 over HTTP/1.1, and
// nginx on the bench ports in the container's MODE (h1, tls, h3). It exits
// when either does, stopping the other, and passes SIGTERM/SIGINT on.
package main

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

const appPort = "9080"

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: launch <app command...>")
		os.Exit(2)
	}
	mode := env("MODE", "h1")
	https := env("HTTPS_PORT", "8443")
	var listen string
	switch mode {
	case "h1":
		listen = "listen " + env("HTTP_PORT", "8080") + " reuseport backlog=65535;"
	case "tls":
		listen = "listen " + https + " ssl reuseport backlog=65535; http2 on;"
	case "h3":
		listen = "listen " + https + " ssl reuseport backlog=65535; listen " + https + " quic reuseport; http2 on; http3 on; " +
			`add_header Alt-Svc 'h3=":` + https + `"; ma=86400' always;`
	default:
		fmt.Fprintf(os.Stderr, "MODE=%s is not supported behind nginx\n", mode)
		os.Exit(3)
	}

	if err := os.MkdirAll("/tmp/front", 0o755); err != nil {
		fail(err)
	}
	tmpl, err := os.ReadFile("/front/nginx.conf.in")
	if err != nil {
		fail(err)
	}
	conf := strings.NewReplacer(
		"@WORKERS@", env("WORKERS", "1"), "@LISTEN@", listen,
		"@CERT@", env("CERT_FILE", "/certs/cert.pem"), "@KEY@", env("KEY_FILE", "/certs/key.pem"),
	).Replace(string(tmpl))
	if err := os.WriteFile("/tmp/front/nginx.conf", []byte(conf), 0o644); err != nil {
		fail(err)
	}

	// The app: plain HTTP/1.1 on the upstream port, everything else as given.
	app := exec.Command(os.Args[1], os.Args[2:]...)
	app.Env = append(os.Environ(), "MODE=h1", "HTTP_PORT="+appPort)
	app.Stdout, app.Stderr = os.Stdout, os.Stderr
	if err := app.Start(); err != nil {
		fail(err)
	}
	appDone := make(chan error, 1)
	go func() { appDone <- app.Wait() }()

	// nginx once the app accepts connections.
	deadline := time.Now().Add(60 * time.Second)
	for {
		c, err := net.DialTimeout("tcp", "127.0.0.1:"+appPort, 200*time.Millisecond)
		if err == nil {
			c.Close()
			break
		}
		select {
		case err := <-appDone:
			fmt.Fprintf(os.Stderr, "app exited before listening: %v\n", err)
			os.Exit(exitCode(err))
		default:
		}
		if time.Now().After(deadline) {
			app.Process.Kill()
			fail(fmt.Errorf("app not listening on %s after 60 s", appPort))
		}
		time.Sleep(50 * time.Millisecond)
	}
	nginx := exec.Command("/front/nginx", "-c", "/tmp/front/nginx.conf", "-g", "daemon off;")
	nginx.Stdout, nginx.Stderr = os.Stdout, os.Stderr
	if err := nginx.Start(); err != nil {
		app.Process.Kill()
		fail(err)
	}
	nginxDone := make(chan error, 1)
	go func() { nginxDone <- nginx.Wait() }()

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT)
	stop := func() {
		nginx.Process.Signal(syscall.SIGQUIT)
		app.Process.Signal(syscall.SIGTERM)
	}
	select {
	case s := <-sigs:
		nginx.Process.Signal(syscall.SIGQUIT)
		app.Process.Signal(s)
		<-appDone
		<-nginxDone
		os.Exit(0)
	case err := <-appDone:
		fmt.Fprintf(os.Stderr, "app exited: %v\n", err)
		stop()
		<-nginxDone
		os.Exit(exitCode(err))
	case err := <-nginxDone:
		fmt.Fprintf(os.Stderr, "nginx exited: %v\n", err)
		stop()
		<-appDone
		os.Exit(exitCode(err))
	}
}

func exitCode(err error) int {
	if ee, ok := err.(*exec.ExitError); ok {
		return ee.ExitCode()
	}
	if err != nil {
		return 1
	}
	return 0
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "launch:", err)
	os.Exit(1)
}
