// Command worker consome a fila `jobs` do Postgres e fala com o serviço
// facial (services/face/) e o R2. Ver worker/README.md antes de rodar —
// o role worker_service que este binário usa ainda não existe no banco.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aiub1/poiema-gallery/worker/internal/faces"
	"github.com/aiub1/poiema-gallery/worker/internal/jobs"
	"github.com/aiub1/poiema-gallery/worker/internal/storage"
)

// pollInterval segue docs/ARQUITETURA.md §6: "polling a cada 5s".
const pollInterval = 5 * time.Second

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	if err := run(logger); err != nil {
		logger.Error("worker encerrado com erro", "err", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	cfg, err := loadConfig()
	if err != nil {
		return fmt.Errorf("carregar configuração: %w", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, err := pgxpool.New(ctx, cfg.databaseURL)
	if err != nil {
		return fmt.Errorf("conectar no banco: %w", err)
	}
	defer pool.Close()

	store := jobs.NewPostgresStore(pool)
	faceClient := faces.NewClient(cfg.faceServiceURL, cfg.faceServiceToken)
	objectStore := storage.NewClient(storage.Config{
		AccountID:       cfg.r2AccountID,
		AccessKeyID:     cfg.r2AccessKeyID,
		SecretAccessKey: cfg.r2SecretAccessKey,
		Bucket:          cfg.r2Bucket,
	})

	workerID, err := workerID()
	if err != nil {
		return fmt.Errorf("determinar identificador do worker: %w", err)
	}

	runner := &jobs.Runner{
		Store: store,
		Deps: jobs.Deps{
			Photos:   store,
			Signer:   objectStore,
			Detector: faceClient,
			Objects:  objectStore,
		},
		Logger:   logger,
		WorkerID: workerID,
	}

	logger.Info("worker iniciado", "worker_id", workerID, "poll_interval", pollInterval.String())

	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()

	for {
		claimed, err := runner.RunOnce(ctx)
		if err != nil {
			logger.Error("erro processando job", "err", err)
		}

		if claimed {
			// Há chance de ter mais trabalho na fila — tenta de novo sem
			// esperar o próximo tick.
			continue
		}

		select {
		case <-ctx.Done():
			logger.Info("worker encerrando", "motivo", ctx.Err())
			return nil
		case <-ticker.C:
		}
	}
}

type config struct {
	databaseURL       string
	faceServiceURL    string
	faceServiceToken  string
	r2AccountID       string
	r2AccessKeyID     string
	r2SecretAccessKey string
	r2Bucket          string
}

func loadConfig() (config, error) {
	cfg := config{
		databaseURL:       os.Getenv("WORKER_DATABASE_URL"),
		faceServiceURL:    os.Getenv("FACE_SERVICE_URL"),
		faceServiceToken:  os.Getenv("FACE_SERVICE_TOKEN"),
		r2AccountID:       os.Getenv("R2_ACCOUNT_ID"),
		r2AccessKeyID:     os.Getenv("R2_ACCESS_KEY_ID"),
		r2SecretAccessKey: os.Getenv("R2_SECRET_ACCESS_KEY"),
		r2Bucket:          os.Getenv("R2_BUCKET"),
	}

	var missing []string
	for name, value := range map[string]string{
		"WORKER_DATABASE_URL":  cfg.databaseURL,
		"FACE_SERVICE_URL":     cfg.faceServiceURL,
		"FACE_SERVICE_TOKEN":   cfg.faceServiceToken,
		"R2_ACCOUNT_ID":        cfg.r2AccountID,
		"R2_ACCESS_KEY_ID":     cfg.r2AccessKeyID,
		"R2_SECRET_ACCESS_KEY": cfg.r2SecretAccessKey,
		"R2_BUCKET":            cfg.r2Bucket,
	} {
		if value == "" {
			missing = append(missing, name)
		}
	}
	if len(missing) > 0 {
		return config{}, fmt.Errorf("variáveis de ambiente ausentes: %v", missing)
	}

	return cfg, nil
}

func workerID() (string, error) {
	host, err := os.Hostname()
	if err != nil {
		return "", errors.New("não foi possível determinar o hostname")
	}
	return host + "-" + strconv.Itoa(os.Getpid()), nil
}
