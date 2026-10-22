package main

import (
	"sync"

	"github.com/gofiber/contrib/v3/websocket"
	"github.com/gofiber/fiber/v3"
)

// wsConn serializes writes: a websocket.Conn allows one writer at a time.
type wsConn struct {
	mu sync.Mutex
	c  *websocket.Conn
}

func (w *wsConn) SendText(msg []byte) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.c.WriteMessage(websocket.TextMessage, msg)
}

func (w *wsConn) SendMedia(_ byte, msg []byte) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.c.WriteMessage(websocket.BinaryMessage, msg)
}

func registerWS(app *fiber.App, hub *Hub) {
	app.Get("/ws", func(c fiber.Ctx) error {
		u := hub.UserByToken(c.Query("token"))
		if u == nil {
			return errorJSON(c, fiber.StatusUnauthorized, "unauthorized")
		}
		if !websocket.IsWebSocketUpgrade(c) {
			return errorJSON(c, fiber.StatusUpgradeRequired, "upgrade required")
		}
		if !hub.Reserve(u) {
			return errorJSON(c, fiber.StatusConflict, "already connected")
		}
		c.Locals("user", u)
		if err := c.Next(); err != nil {
			hub.Release(u)
			return err
		}
		return nil
	}, websocket.New(func(c *websocket.Conn) {
		u := c.Locals("user").(*User)
		// Over the limit, the read fails and the connection closes with 1009.
		c.SetReadLimit(maxMessage)
		conn := &wsConn{c: c}
		hub.Attach(u, conn)
		defer hub.Detach(u)
		for {
			mt, msg, err := c.ReadMessage()
			if err != nil {
				return
			}
			switch mt {
			case websocket.TextMessage:
				hub.HandleText(u, conn, msg)
			case websocket.BinaryMessage:
				hub.RelayMedia(u, msg)
			}
		}
	}))
}
