// The Fiber side of the benchmark (bench/run.sh): the same three routes as
// bench/anole, with no middleware.
//
//	go build -o fiber-bench . && ./fiber-bench 8090
package main

import (
	"log"
	"os"

	"github.com/gofiber/fiber/v3"
)

func main() {
	port := "8090"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}
	app := fiber.New()
	app.Get("/plaintext", func(c fiber.Ctx) error {
		return c.SendString("Hello, World!")
	})
	app.Get("/json", func(c fiber.Ctx) error {
		return c.JSON(fiber.Map{"message": "Hello, World!"})
	})
	app.Get("/users/:id", func(c fiber.Ctx) error {
		return c.SendString("user " + c.Params("id"))
	})
	log.Fatal(app.Listen("127.0.0.1:"+port, fiber.ListenConfig{DisableStartupMessage: true}))
}
