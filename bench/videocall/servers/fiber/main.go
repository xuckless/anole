// The video-call relay (bench/videocall/SPEC.md) on Fiber v3: the HTTP API
// and WebSockets over TLS on TCP PORT, WebTransport (draft-02, via
// webtransport-go v0.10.0 on quic-go) on UDP PORT, in one process.
package main

import (
	"crypto/tls"
	"encoding/json"
	"log"
	"os"
	"strconv"
	"strings"

	"github.com/gofiber/fiber/v3"
)

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func errorJSON(c fiber.Ctx, status int, msg string) error {
	return c.Status(status).JSON(fiber.Map{"error": msg})
}

func validName(name string) bool {
	if len(name) < 1 || len(name) > 32 {
		return false
	}
	for _, r := range name {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '_', r == '-':
		default:
			return false
		}
	}
	return true
}

type userResponse struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	Token string `json:"token"`
}

type historyResponse struct {
	CallID   int               `json:"call_id"`
	Messages []json.RawMessage `json:"messages"`
}

func main() {
	port := env("PORT", "8443")
	certFile := env("CERT", "/certs/cert.pem")
	keyFile := env("KEY", "/certs/key.pem")
	hub := NewHub()

	app := fiber.New(fiber.Config{
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

	app.Get("/health", func(c fiber.Ctx) error {
		return c.JSON(fiber.Map{"status": "ok"})
	})

	app.Post("/api/users", func(c fiber.Ctx) error {
		body := c.Body()
		if !json.Valid(body) {
			return errorJSON(c, fiber.StatusBadRequest, "malformed JSON body")
		}
		var req struct {
			Name any `json:"name"`
		}
		if err := json.Unmarshal(body, &req); err != nil {
			return errorJSON(c, fiber.StatusBadRequest, "invalid name")
		}
		name, ok := req.Name.(string)
		if !ok || !validName(name) {
			return errorJSON(c, fiber.StatusBadRequest, "invalid name")
		}
		u := hub.CreateUser(name)
		return c.Status(fiber.StatusCreated).JSON(userResponse{ID: u.ID, Name: u.Name, Token: u.Token})
	})

	app.Get("/api/calls/:id/messages", func(c fiber.Ctx) error {
		token, ok := strings.CutPrefix(c.Get(fiber.HeaderAuthorization), "Bearer ")
		u := hub.UserByToken(token)
		if !ok || u == nil {
			return errorJSON(c, fiber.StatusUnauthorized, "unauthorized")
		}
		id, err := strconv.Atoi(c.Params("id"))
		if err != nil {
			return errorJSON(c, fiber.StatusNotFound, "call not found")
		}
		msgs, status := hub.History(id, u)
		switch status {
		case fiber.StatusNotFound:
			return errorJSON(c, status, "call not found")
		case fiber.StatusForbidden:
			return errorJSON(c, status, "forbidden")
		}
		return c.JSON(historyResponse{CallID: id, Messages: msgs})
	})

	registerWS(app, hub)

	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		log.Fatal(err)
	}
	wt := newWTServer(hub, ":"+port, cert)
	go func() { log.Fatal(wt.ListenAndServe()) }()

	log.Fatal(app.Listen(":"+port, fiber.ListenConfig{
		DisableStartupMessage: true,
		CertFile:              certFile,
		CertKeyFile:           keyFile,
		TLSConfigFunc:         func(tc *tls.Config) { tc.NextProtos = []string{"http/1.1"} },
	}))
}
