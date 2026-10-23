package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/quic-go/webtransport-go"
)

var apiHTTP = &http.Client{Timeout: 10 * time.Second,
	Transport: &http.Transport{TLSClientConfig: tlsConfig, MaxIdleConnsPerHost: 64}}

type account struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	Token string `json:"token"`
}

// request makes an API call and returns the status and body.
func request(method, url, token string, body []byte) (int, []byte, error) {
	req, err := http.NewRequest(method, url, bytes.NewReader(body))
	if err != nil {
		return 0, nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rsp, err := apiHTTP.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer rsp.Body.Close()
	b, err := io.ReadAll(rsp.Body)
	return rsp.StatusCode, b, err
}

func signup(base, name string) (account, error) {
	var a account
	st, b, err := request("POST", base+"/api/users", "", []byte(`{"name":"`+name+`"}`))
	if err != nil {
		return a, err
	}
	if st != 201 {
		return a, fmt.Errorf("signup: status %d: %s", st, b)
	}
	return a, json.Unmarshal(b, &a)
}

// dialer connects users over the run's transport.
type dialer struct {
	base      string
	transport string
	wt        *webtransport.Dialer
}

func newDialer(base, transport string) *dialer {
	d := &dialer{base: base, transport: transport}
	if transport == "wt" {
		d.wt = newWTDialer()
	}
	return d
}

func (d *dialer) dial(token string, h handlers) (conn, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	switch d.transport {
	case "wt":
		return dialWT(ctx, d.wt, d.base, token, h)
	case "ws-h2":
		return dialWSH2(ctx, d.base, token, h)
	case "ws-h3":
		return dialWSH3(ctx, d.base, token, h)
	}
	return dialWS(ctx, d.base, token, h)
}

// msg is a server text message, decoded loosely.
type msg struct {
	Type   string          `json:"type"`
	CallID int             `json:"call_id"`
	ID     int             `json:"id"`
	From   string          `json:"from"`
	Text   string          `json:"text"`
	SentUS int64           `json:"sent_us"`
	Error  string          `json:"error"`
	User   *account        `json:"user"`
	Peer   *account        `json:"peer"`
	Raw    json.RawMessage `json:"-"`
}
