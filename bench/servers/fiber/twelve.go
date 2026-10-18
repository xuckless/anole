package main

// The $12 challenge routes (bench/twelve/SPEC.md) on Postgres.

import (
	"context"
	"errors"
	"log"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/gofiber/fiber/v3"
	"github.com/golang-jwt/jwt/v5"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	sqlHealth = `SELECT 1`
	sqlFeed   = `SELECT p.id, p.body, p.created_at, u.username,
       (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
  FROM posts p JOIN users u ON u.id = p.user_id
 ORDER BY p.created_at DESC, p.id DESC LIMIT 20`
	sqlPost = `SELECT p.id, p.body, p.created_at, u.username,
       (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
  FROM posts p JOIN users u ON u.id = p.user_id
 WHERE p.id = $1`
	sqlCreate = `INSERT INTO posts (user_id, body) VALUES ($1, $2) RETURNING id, created_at`
	sqlLike   = `WITH p AS (SELECT id FROM posts WHERE id = $2),
     ins AS (INSERT INTO likes (user_id, post_id) SELECT $1, id FROM p
             ON CONFLICT (user_id, post_id) DO NOTHING RETURNING 1)
SELECT (SELECT count(*) FROM p) AS found, (SELECT count(*) FROM ins) AS inserted`
)

type Post struct {
	ID        int64  `json:"id"`
	Body      string `json:"body"`
	CreatedAt string `json:"created_at"`
	Author    string `json:"author"`
	LikeCount int64  `json:"like_count"`
}

type PostResponse struct {
	Post Post `json:"post"`
}

type FeedResponse struct {
	Posts []Post `json:"posts"`
}

type LikeResponse struct {
	Liked        bool  `json:"liked"`
	AlreadyLiked bool  `json:"already_liked"`
	PostID       int64 `json:"post_id"`
}

type Health struct {
	Status  string `json:"status"`
	DB      string `json:"db"`
	UptimeS int64  `json:"uptime_s"`
}

type HealthDown struct {
	Status string `json:"status"`
	DB     string `json:"db"`
	Error  string `json:"error"`
}

// positiveID parses a decimal string of digits that is > 0, else returns 0.
func positiveID(s string) int64 {
	if s == "" || strings.Trim(s, "0123456789") != "" {
		return 0
	}
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil || n <= 0 {
		return 0
	}
	return n
}

type user struct {
	id   int64
	name string
}

func registerTwelve(app *fiber.App, dsn string, poolSize int, secret string) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		log.Fatalf("DATABASE_URL: %v", err)
	}
	cfg.MaxConns = int32(poolSize)
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		log.Fatalf("pgxpool: %v", err)
	}
	started := time.Now()
	key := []byte(secret)
	parser := jwt.NewParser(jwt.WithValidMethods([]string{"HS256"}), jwt.WithExpirationRequired())

	// auth checks the bearer token and stores the user in Locals.
	auth := func(c fiber.Ctx) error {
		token, ok := strings.CutPrefix(c.Get(fiber.HeaderAuthorization), "Bearer ")
		if !ok {
			return errorJSON(c, fiber.StatusUnauthorized, "missing bearer token")
		}
		claims := jwt.MapClaims{}
		if _, err := parser.ParseWithClaims(token, claims, func(*jwt.Token) (any, error) { return key, nil }); err != nil {
			return errorJSON(c, fiber.StatusUnauthorized, "invalid or expired token")
		}
		sub, _ := claims["sub"].(string)
		name, ok := claims["username"].(string)
		id := positiveID(sub)
		if id == 0 || !ok {
			return errorJSON(c, fiber.StatusUnauthorized, "invalid token payload")
		}
		c.Locals("user", user{id, name})
		return c.Next()
	}

	app.Get("/health", func(c fiber.Ctx) error {
		var one int
		if err := pool.QueryRow(c.Context(), sqlHealth).Scan(&one); err != nil {
			return c.Status(fiber.StatusServiceUnavailable).JSON(HealthDown{"degraded", "unreachable", err.Error()})
		}
		return c.JSON(Health{"ok", "ok", int64(time.Since(started).Seconds())})
	})

	app.Get("/feed", func(c fiber.Ctx) error {
		rows, err := pool.Query(c.Context(), sqlFeed)
		if err != nil {
			return err
		}
		posts := make([]Post, 0, 20)
		for rows.Next() {
			var p Post
			if err := rows.Scan(&p.ID, &p.Body, &p.CreatedAt, &p.Author, &p.LikeCount); err != nil {
				rows.Close()
				return err
			}
			posts = append(posts, p)
		}
		if err := rows.Err(); err != nil {
			return err
		}
		return c.JSON(FeedResponse{posts})
	})

	app.Get("/posts/:id", func(c fiber.Ctx) error {
		id := positiveID(c.Params("id"))
		if id == 0 {
			return errorJSON(c, fiber.StatusBadRequest, "invalid post id")
		}
		var p Post
		err := pool.QueryRow(c.Context(), sqlPost, id).Scan(&p.ID, &p.Body, &p.CreatedAt, &p.Author, &p.LikeCount)
		if errors.Is(err, pgx.ErrNoRows) {
			return errorJSON(c, fiber.StatusNotFound, "post not found")
		} else if err != nil {
			return err
		}
		return c.JSON(PostResponse{p})
	})

	app.Post("/posts", auth, func(c fiber.Ctx) error {
		u := c.Locals("user").(user)
		var req struct {
			Body any `json:"body"`
		}
		if err := c.Bind().JSON(&req); err != nil {
			return errorJSON(c, fiber.StatusBadRequest, "malformed JSON body")
		}
		s, _ := req.Body.(string)
		body := strings.TrimSpace(s)
		if body == "" {
			return errorJSON(c, fiber.StatusBadRequest, "body is required")
		}
		if utf8.RuneCountInString(body) > 500 {
			return errorJSON(c, fiber.StatusBadRequest, "body must be at most 500 characters")
		}
		p := Post{Body: body, Author: u.name}
		if err := pool.QueryRow(c.Context(), sqlCreate, u.id, body).Scan(&p.ID, &p.CreatedAt); err != nil {
			return err
		}
		return c.Status(fiber.StatusCreated).JSON(PostResponse{p})
	})

	app.Post("/posts/:id/like", auth, func(c fiber.Ctx) error {
		u := c.Locals("user").(user)
		id := positiveID(c.Params("id"))
		if id == 0 {
			return errorJSON(c, fiber.StatusBadRequest, "invalid post id")
		}
		var found, inserted int64
		if err := pool.QueryRow(c.Context(), sqlLike, u.id, id).Scan(&found, &inserted); err != nil {
			return err
		}
		if found == 0 {
			return errorJSON(c, fiber.StatusNotFound, "post not found")
		}
		if inserted == 1 {
			return c.Status(fiber.StatusCreated).JSON(LikeResponse{true, false, id})
		}
		return c.JSON(LikeResponse{true, true, id})
	})
}
