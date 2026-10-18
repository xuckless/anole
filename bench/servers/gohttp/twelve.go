package main

// The $12 challenge routes (bench/twelve/SPEC.md) on Postgres.

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

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

func internalError(w http.ResponseWriter, err error) {
	log.Printf("error: %v", err)
	writeError(w, http.StatusInternalServerError, "internal server error")
}

func registerTwelve(mux *http.ServeMux, dsn string, poolSize int, secret string) {
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

	// withAuth checks the bearer token before calling next.
	withAuth := func(next func(http.ResponseWriter, *http.Request, user)) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
			if !ok {
				writeError(w, http.StatusUnauthorized, "missing bearer token")
				return
			}
			claims := jwt.MapClaims{}
			if _, err := parser.ParseWithClaims(token, claims, func(*jwt.Token) (any, error) { return key, nil }); err != nil {
				writeError(w, http.StatusUnauthorized, "invalid or expired token")
				return
			}
			sub, _ := claims["sub"].(string)
			name, ok := claims["username"].(string)
			id := positiveID(sub)
			if id == 0 || !ok {
				writeError(w, http.StatusUnauthorized, "invalid token payload")
				return
			}
			next(w, r, user{id, name})
		}
	}

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		var one int
		if err := pool.QueryRow(r.Context(), sqlHealth).Scan(&one); err != nil {
			writeJSON(w, http.StatusServiceUnavailable, HealthDown{"degraded", "unreachable", err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, Health{"ok", "ok", int64(time.Since(started).Seconds())})
	})

	mux.HandleFunc("GET /feed", func(w http.ResponseWriter, r *http.Request) {
		rows, err := pool.Query(r.Context(), sqlFeed)
		if err != nil {
			internalError(w, err)
			return
		}
		posts := make([]Post, 0, 20)
		for rows.Next() {
			var p Post
			if err := rows.Scan(&p.ID, &p.Body, &p.CreatedAt, &p.Author, &p.LikeCount); err != nil {
				rows.Close()
				internalError(w, err)
				return
			}
			posts = append(posts, p)
		}
		if err := rows.Err(); err != nil {
			internalError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, FeedResponse{posts})
	})

	mux.HandleFunc("GET /posts/{id}", func(w http.ResponseWriter, r *http.Request) {
		id := positiveID(r.PathValue("id"))
		if id == 0 {
			writeError(w, http.StatusBadRequest, "invalid post id")
			return
		}
		var p Post
		err := pool.QueryRow(r.Context(), sqlPost, id).Scan(&p.ID, &p.Body, &p.CreatedAt, &p.Author, &p.LikeCount)
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, http.StatusNotFound, "post not found")
			return
		} else if err != nil {
			internalError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, PostResponse{p})
	})

	mux.HandleFunc("POST /posts", withAuth(func(w http.ResponseWriter, r *http.Request, u user) {
		var req struct {
			Body any `json:"body"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "malformed JSON body")
			return
		}
		s, _ := req.Body.(string)
		body := strings.TrimSpace(s)
		if body == "" {
			writeError(w, http.StatusBadRequest, "body is required")
			return
		}
		if utf8.RuneCountInString(body) > 500 {
			writeError(w, http.StatusBadRequest, "body must be at most 500 characters")
			return
		}
		p := Post{Body: body, Author: u.name}
		if err := pool.QueryRow(r.Context(), sqlCreate, u.id, body).Scan(&p.ID, &p.CreatedAt); err != nil {
			internalError(w, err)
			return
		}
		writeJSON(w, http.StatusCreated, PostResponse{p})
	}))

	mux.HandleFunc("POST /posts/{id}/like", withAuth(func(w http.ResponseWriter, r *http.Request, u user) {
		id := positiveID(r.PathValue("id"))
		if id == 0 {
			writeError(w, http.StatusBadRequest, "invalid post id")
			return
		}
		var found, inserted int64
		if err := pool.QueryRow(r.Context(), sqlLike, u.id, id).Scan(&found, &inserted); err != nil {
			internalError(w, err)
			return
		}
		switch {
		case found == 0:
			writeError(w, http.StatusNotFound, "post not found")
		case inserted == 1:
			writeJSON(w, http.StatusCreated, LikeResponse{true, false, id})
		default:
			writeJSON(w, http.StatusOK, LikeResponse{true, true, id})
		}
	}))
}
