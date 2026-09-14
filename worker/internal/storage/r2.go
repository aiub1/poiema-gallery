// Package storage fala com o Cloudflare R2 (S3-compatible): URL assinada
// de leitura para o serviço facial (docs/ARQUITETURA.md §8) e exclusão de
// objetos para o job delete_objects (docs/CONTRATO.md §7).
package storage

import (
	"context"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

// readURLTTL segue a regra geral de ARQUITETURA.md §8 ("Leitura por URL
// assinada de 15 min"). O pseudocódigo de §6 usa 10 min para este mesmo
// caso — tratado aqui como ilustrativo, não como valor à parte; a regra
// geral de §8 é a fonte de verdade.
const readURLTTL = 15 * time.Minute

// Config são as credenciais S3-compatible do bucket R2 — nunca provisionadas
// pelo Tofu (infra/README.md), sempre por Fly secret (CLAUDE.md §5.3).
type Config struct {
	AccountID       string
	AccessKeyID     string
	SecretAccessKey string
	Bucket          string
}

// Client implementa as interfaces jobs.URLSigner e jobs.ObjectDeleter.
type Client struct {
	s3      *s3.Client
	presign *s3.PresignClient
	bucket  string
}

func NewClient(cfg Config) *Client {
	endpoint := fmt.Sprintf("https://%s.r2.cloudflarestorage.com", cfg.AccountID)
	creds := credentials.NewStaticCredentialsProvider(cfg.AccessKeyID, cfg.SecretAccessKey, "")

	s3Client := s3.New(s3.Options{
		Credentials:  creds,
		Region:       "auto",
		BaseEndpoint: aws.String(endpoint),
	})

	return &Client{
		s3:      s3Client,
		presign: s3.NewPresignClient(s3Client),
		bucket:  cfg.Bucket,
	}
}

func (c *Client) SignedReadURL(ctx context.Context, storageKey string) (string, error) {
	out, err := c.presign.PresignGetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(c.bucket),
		Key:    aws.String(storageKey),
	}, s3.WithPresignExpires(readURLTTL))
	if err != nil {
		return "", fmt.Errorf("storage: assinar URL de leitura: %w", err)
	}
	return out.URL, nil
}

func (c *Client) DeleteObjects(ctx context.Context, keys []string) error {
	if len(keys) == 0 {
		return nil
	}

	objects := make([]types.ObjectIdentifier, len(keys))
	for i, key := range keys {
		objects[i] = types.ObjectIdentifier{Key: aws.String(key)}
	}

	_, err := c.s3.DeleteObjects(ctx, &s3.DeleteObjectsInput{
		Bucket: aws.String(c.bucket),
		Delete: &types.Delete{Objects: objects},
	})
	if err != nil {
		return fmt.Errorf("storage: excluir objetos: %w", err)
	}
	return nil
}
