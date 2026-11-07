package alerts

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
)

// FCM sends through Firebase Cloud Messaging HTTP v1. FCM also delivers to
// iOS (through APNs) once the APNs key is uploaded in the Firebase console.
type FCM struct {
	ProjectID string
	Tokens    oauth2.TokenSource
	Client    *http.Client
	BaseURL   string // default https://fcm.googleapis.com
}

const fcmScope = "https://www.googleapis.com/auth/firebase.messaging"

// NewFCMFromFile reads a Firebase service-account JSON key.
func NewFCMFromFile(ctx context.Context, path string) (*FCM, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	creds, err := google.CredentialsFromJSON(ctx, b, fcmScope)
	if err != nil {
		return nil, fmt.Errorf("fcm credentials: %w", err)
	}
	var meta struct {
		ProjectID string `json:"project_id"`
	}
	_ = json.Unmarshal(b, &meta)
	if meta.ProjectID == "" {
		return nil, fmt.Errorf("fcm credentials: no project_id")
	}
	return &FCM{ProjectID: meta.ProjectID, Tokens: creds.TokenSource}, nil
}

// Send implements [Notifier].
func (f *FCM) Send(ctx context.Context, s Subscription, e Event) error {
	tok, err := f.Tokens.Token()
	if err != nil {
		return fmt.Errorf("fcm token: %w", err)
	}
	data := map[string]string{"alert_key": e.Key}
	for k, v := range e.Data {
		data[k] = v
	}
	msg := map[string]any{
		"message": map[string]any{
			"token":        s.DeviceToken,
			"notification": map[string]string{"title": e.Title, "body": e.Body},
			"data":         data,
			"android": map[string]any{
				"priority":     "high",
				"collapse_key": e.Key,
				"notification": map[string]string{"channel_id": "nearby_alerts", "tag": e.Key},
			},
			"apns": map[string]any{
				"headers": map[string]string{"apns-collapse-id": trunc(e.Key, 64)},
			},
		},
	}
	body, _ := json.Marshal(msg)
	base := f.BaseURL
	if base == "" {
		base = "https://fcm.googleapis.com"
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		fmt.Sprintf("%s/v1/projects/%s/messages:send", base, f.ProjectID), bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	tok.SetAuthHeader(req)
	c := f.Client
	if c == nil {
		c = &http.Client{Timeout: 15 * time.Second}
	}
	res, err := c.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode/100 == 2 {
		return nil
	}
	rb, _ := io.ReadAll(io.LimitReader(res.Body, 64<<10))
	// UNREGISTERED / INVALID_ARGUMENT for a token = remove the device.
	if res.StatusCode == http.StatusNotFound || (res.StatusCode == http.StatusBadRequest && strings.Contains(string(rb), "registration token")) ||
		strings.Contains(string(rb), "UNREGISTERED") {
		return ErrInvalidToken
	}
	return fmt.Errorf("fcm: HTTP %d: %s", res.StatusCode, trunc(string(rb), 300))
}

func trunc(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

// Webhook POSTs every alert as JSON to a URL (Slack/Discord bridges, your
// own push service, testing).
type Webhook struct {
	URL    string
	Client *http.Client
}

// Send implements [Notifier].
func (h *Webhook) Send(ctx context.Context, s Subscription, e Event) error {
	body, _ := json.Marshal(map[string]any{"device_token": s.DeviceToken, "platform": s.Platform, "event": e})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, h.URL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	c := h.Client
	if c == nil {
		c = &http.Client{Timeout: 10 * time.Second}
	}
	res, err := c.Do(req)
	if err != nil {
		return err
	}
	res.Body.Close()
	if res.StatusCode == http.StatusGone {
		return ErrInvalidToken
	}
	if res.StatusCode/100 != 2 {
		return fmt.Errorf("webhook: HTTP %d", res.StatusCode)
	}
	return nil
}

// Multi sends to several notifiers; the first error wins.
type Multi []Notifier

// Send implements [Notifier].
func (m Multi) Send(ctx context.Context, s Subscription, e Event) error {
	var first error
	for _, n := range m {
		if err := n.Send(ctx, s, e); err != nil && first == nil {
			first = err
		}
	}
	return first
}
