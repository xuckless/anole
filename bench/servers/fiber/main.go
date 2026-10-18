// The Fiber v3 bench server: the contract in bench/SPEC.md, on fasthttp.
//
//	MODE=h1  HTTP/1.1 on HTTP_PORT (default 8080)
//	MODE=tls HTTPS (http/1.1 ALPN) on HTTPS_PORT (default 8443)
package main

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"runtime"
	"strconv"

	"github.com/gofiber/fiber/v3"
	"github.com/gofiber/fiber/v3/middleware/static"
)

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	n, err := strconv.Atoi(env(key, strconv.Itoa(def)))
	if err != nil {
		log.Fatalf("%s: %v", key, err)
	}
	return n
}

type Message struct {
	Message string `json:"message"`
}

type Item struct {
	ID     int    `json:"id"`
	Name   string `json:"name"`
	Active bool   `json:"active"`
	Score  int    `json:"score"`
}

type Node struct {
	ID     int      `json:"id"`
	Name   string   `json:"name"`
	Tags   []string `json:"tags"`
	Active bool     `json:"active"`
}

type Retained struct {
	ID   int      `json:"id"`
	Name string   `json:"name"`
	Tags []string `json:"tags"`
}

// retained stays reachable for the life of the process (the GC test).
var retained []Retained

func buildRetained(n int) {
	retained = make([]Retained, n)
	for i := range n {
		retained[i] = Retained{
			ID:   i,
			Name: "retained-" + strconv.Itoa(i),
			Tags: []string{"x" + strconv.Itoa(i%7), "y" + strconv.Itoa(i%11), "z" + strconv.Itoa(i%13)},
		}
	}
}

func errorJSON(c fiber.Ctx, status int, msg string) error {
	return c.Status(status).JSON(fiber.Map{"error": msg})
}

func main() {
	runtime.GOMAXPROCS(envInt("WORKERS", 1))
	buildRetained(envInt("RETAIN", 0))

	mode := env("MODE", "h1")
	if mode != "h1" && mode != "tls" {
		fmt.Fprintf(os.Stderr, "fiber: unsupported MODE %q (supported: h1, tls)\n", mode)
		os.Exit(3)
	}

	app := fiber.New(fiber.Config{
		BodyLimit: 8 << 20,
		ErrorHandler: func(c fiber.Ctx, err error) error {
			if e, ok := err.(*fiber.Error); ok {
				if e.Code == fiber.StatusNotFound {
					return errorJSON(c, e.Code, "not found")
				}
				return errorJSON(c, e.Code, e.Message)
			}
			log.Printf("error: %v", err)
			return errorJSON(c, fiber.StatusInternalServerError, "internal server error")
		},
	})

	app.Get("/plaintext", func(c fiber.Ctx) error {
		return c.SendString("Hello, World!")
	})
	app.Get("/json", func(c fiber.Ctx) error {
		return c.JSON(Message{Message: "Hello, World!"})
	})
	app.Get("/users/:id", func(c fiber.Ctx) error {
		return c.SendString("user " + c.Params("id"))
	})
	app.Get("/list", func(c fiber.Ctx) error {
		items := make([]Item, 50)
		for i := 1; i <= 50; i++ {
			items[i-1] = Item{ID: i, Name: "item-" + strconv.Itoa(i), Active: i%2 == 0, Score: i * 7}
		}
		return c.JSON(fiber.Map{"items": items})
	})
	app.Post("/echo", func(c fiber.Ctx) error {
		c.Set(fiber.HeaderContentType, fiber.MIMEOctetStream)
		return c.Send(c.Body())
	})
	app.Get("/gc/alloc", func(c fiber.Ctx) error {
		n := fiber.Query(c, "n", 2000)
		nodes := make([]Node, n)
		for i := range n {
			nodes[i] = Node{
				ID:     i,
				Name:   "node-" + strconv.Itoa(i),
				Tags:   []string{"a" + strconv.Itoa(i%7), "b" + strconv.Itoa(i%11), "c" + strconv.Itoa(i%13)},
				Active: i%2 == 0,
			}
		}
		out, err := json.Marshal(nodes)
		if err != nil {
			return err
		}
		return c.JSON(struct {
			N     int `json:"n"`
			Bytes int `json:"bytes"`
		}{n, len(out)})
	})
	app.Get("/gc/stats", func(c fiber.Ctx) error {
		return c.JSON(fiber.Map{"retained": len(retained)})
	})
	app.Get("/static*", static.New(env("MEDIA_DIR", "/media"), static.Config{
		ByteRange: true,
		NotFoundHandler: func(c fiber.Ctx) error {
			return fiber.ErrNotFound
		},
	}))

	registerWebSockets(app, envInt("TICK_HZ", 1000))

	if dsn := os.Getenv("DATABASE_URL"); dsn != "" {
		registerTwelve(app, dsn, envInt("PG_POOL", 20), env("JWT_SECRET", "twelve-dollar-challenge"))
	}

	cfg := fiber.ListenConfig{DisableStartupMessage: true}
	addr := "0.0.0.0:" + env("HTTP_PORT", "8080")
	if mode == "tls" {
		addr = "0.0.0.0:" + env("HTTPS_PORT", "8443")
		cfg.CertFile = env("CERT_FILE", "/certs/cert.pem")
		cfg.CertKeyFile = env("KEY_FILE", "/certs/key.pem")
		cfg.TLSConfigFunc = func(tc *tls.Config) { tc.NextProtos = []string{"http/1.1"} }
	}
	log.Fatal(app.Listen(addr, cfg))
}
