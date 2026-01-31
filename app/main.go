package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"
	"time"
)

var (
	version   = "dev"
	commit    = "unknown"
	buildTime = "unknown"
)

type metricsStore struct {
	mu    sync.Mutex
	count map[string]uint64
}

func newMetricsStore() *metricsStore {
	return &metricsStore{count: make(map[string]uint64)}
}

func (m *metricsStore) inc(path string) {
	m.mu.Lock()
	m.count[path]++
	m.mu.Unlock()
}

func (m *metricsStore) snapshot() map[string]uint64 {
	m.mu.Lock()
	defer m.mu.Unlock()

	out := make(map[string]uint64, len(m.count))
	for k, v := range m.count {
		out[k] = v
	}
	return out
}

func main() {
	port := envOrDefault("PORT", "8080")
	metrics := newMetricsStore()

	mux := http.NewServeMux()

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		metrics.inc("/health")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	mux.HandleFunc("/version", func(w http.ResponseWriter, r *http.Request) {
		metrics.inc("/version")
		w.Header().Set("Content-Type", "application/json")
		payload := map[string]string{
			"version":    version,
			"commit":     commit,
			"build_time": buildTime,
		}
		_ = json.NewEncoder(w).Encode(payload)
	})

	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		metrics.inc("/metrics")
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		fmt.Fprintln(w, "# HELP sre_app_requests_total Total HTTP requests by path")
		fmt.Fprintln(w, "# TYPE sre_app_requests_total counter")
		for path, count := range metrics.snapshot() {
			fmt.Fprintf(w, "sre_app_requests_total{path=%q} %d\n", path, count)
		}
	})

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		metrics.inc("/")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("sre gitops app"))
	})

	server := &http.Server{
		Addr:              ":" + port,
		Handler:           loggingMiddleware(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("listening on :%s", port)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("server error: %v", err)
	}
}

func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(start))
	})
}

func envOrDefault(key, fallback string) string {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	return value
}
