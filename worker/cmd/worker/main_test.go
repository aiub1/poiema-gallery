package main

import (
	"testing"
	"time"

	"github.com/aiub1/poiema-gallery/worker/internal/faces"
)

func TestParseDurationEnv_DefaultWhenUnset(t *testing.T) {
	d, err := parseDurationEnv("FACE_SERVICE_TIMEOUT_UNSET", 60*time.Second)
	if err != nil {
		t.Fatalf("parseDurationEnv retornou erro: %v", err)
	}
	if d != 60*time.Second {
		t.Errorf("duração = %s, esperado 60s", d)
	}
}

func TestParseDurationEnv_ParsesConfiguredValue(t *testing.T) {
	t.Setenv("FACE_SERVICE_TIMEOUT", "90s")
	d, err := parseDurationEnv("FACE_SERVICE_TIMEOUT", 60*time.Second)
	if err != nil {
		t.Fatalf("parseDurationEnv retornou erro: %v", err)
	}
	if d != 90*time.Second {
		t.Errorf("duração = %s, esperado 90s", d)
	}
}

func TestParseDurationEnv_ErrorOnInvalidFormat(t *testing.T) {
	t.Setenv("FACE_SERVICE_TIMEOUT", "noventa segundos")
	_, err := parseDurationEnv("FACE_SERVICE_TIMEOUT", 60*time.Second)
	if err == nil {
		t.Fatal("esperava erro para duração inválida, recebeu nil")
	}
}

func requiredEnvForLoadConfig(t *testing.T) {
	t.Helper()
	t.Setenv("WORKER_DATABASE_URL", "postgres://example.invalid/db")
	t.Setenv("FACE_SERVICE_URL", "https://face.example.invalid")
	t.Setenv("FACE_SERVICE_TOKEN", "dev-token")
	t.Setenv("R2_ACCOUNT_ID", "account")
	t.Setenv("R2_ACCESS_KEY_ID", "key")
	t.Setenv("R2_SECRET_ACCESS_KEY", "secret")
	t.Setenv("R2_BUCKET", "bucket")
}

func TestLoadConfig_DefaultsFaceServiceTimeoutWhenUnset(t *testing.T) {
	requiredEnvForLoadConfig(t)

	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig retornou erro: %v", err)
	}
	if cfg.faceServiceTimeout != faces.DefaultTimeout {
		t.Errorf("faceServiceTimeout = %s, esperado o padrão %s", cfg.faceServiceTimeout, faces.DefaultTimeout)
	}
}

func TestLoadConfig_UsesConfiguredFaceServiceTimeout(t *testing.T) {
	requiredEnvForLoadConfig(t)
	t.Setenv("FACE_SERVICE_TIMEOUT", "45s")

	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig retornou erro: %v", err)
	}
	if cfg.faceServiceTimeout != 45*time.Second {
		t.Errorf("faceServiceTimeout = %s, esperado 45s", cfg.faceServiceTimeout)
	}
}

func TestLoadConfig_ErrorsOnInvalidFaceServiceTimeout(t *testing.T) {
	requiredEnvForLoadConfig(t)
	t.Setenv("FACE_SERVICE_TIMEOUT", "logo-logo")

	if _, err := loadConfig(); err == nil {
		t.Fatal("esperava erro para FACE_SERVICE_TIMEOUT inválida, recebeu nil")
	}
}
