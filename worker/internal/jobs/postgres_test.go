package jobs

import (
	"testing"
	"time"
)

func TestBackoff_GrowsExponentiallyAndCaps(t *testing.T) {
	cases := []struct {
		attempts int
		want     time.Duration
	}{
		{attempts: 1, want: 30 * time.Second},
		{attempts: 2, want: 60 * time.Second},
		{attempts: 3, want: 120 * time.Second},
		{attempts: 4, want: 240 * time.Second},
		{attempts: 5, want: 480 * time.Second},
		{attempts: 20, want: retryMaxDelay}, // muito além do teto
	}

	for _, tc := range cases {
		got := backoff(tc.attempts)
		if got != tc.want {
			t.Errorf("backoff(%d) = %s, esperado %s", tc.attempts, got, tc.want)
		}
	}
}

func TestIntervalLiteral(t *testing.T) {
	got := intervalLiteral(90 * time.Second)
	want := "90 seconds"
	if got != want {
		t.Errorf("intervalLiteral(90s) = %q, esperado %q", got, want)
	}
}
